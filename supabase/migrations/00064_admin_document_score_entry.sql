-- 새봄고 입학전형 시스템 — 서류평가 관리자 대리 채점 입력 (2026-09-28)
--
-- 배경: 심층역량평가(모둠·면접·글쓰기)에는 이미 관리자 대리 입력이 있다(00052/00053).
-- 서류평가 5개 영역(출결·학업성실도·공동체·자기소개서·학부모소견서)에는 없어서,
-- 평가위원이 로그인이 안 되거나 시스템 문제로 입력하지 못하면 대안이 없었다.
-- 첫 운영이라 그런 상황이 생길 수 있어 같은 안전장치를 만든다.
--
-- ┌─ 설계상 가장 중요한 결정 ────────────────────────────────────────┐
-- │ 00052(심층역량평가)는 채점 계산 로직을 admin_* 함수에 복사해 넣었다. │
-- │ 서류평가에서 같은 방식을 쓰면 계산 로직이 두 벌(총 490여 줄)이 되고,│
-- │ 나중에 배점을 고칠 때 한쪽만 고치면 "누가 입력했느냐에 따라 점수가  │
-- │ 달라지는" 버그가 생긴다. 채점에서 이건 치명적이다.                  │
-- │                                                                  │
-- │ 그래서 여기서는 복사하지 않는다. 관리자 함수는 권한·사유를 검증한 뒤 │
-- │ request.jwt.claims를 대상 평가위원으로 잠시(트랜잭션 한정) 바꾸고    │
-- │ 기존 submit_*_score를 그대로 호출한다. 계산·검증·설정 조회가 전부   │
-- │ 원래 경로 한 곳에서만 일어나므로 점수가 갈라질 수 없다.             │
-- │ (테스트 시드 스크립트가 쓰는 것과 같은 방식이다)                    │
-- └──────────────────────────────────────────────────────────────────┘
--
-- 감사 기록: 안쪽 submit_*는 평가위원 명의로 기록을 남기고(원래 동작 그대로),
-- 바깥 관리자 함수가 "관리자가 누구를 대신해 왜 입력했는지"를 따로 한 줄 더 남긴다.
-- 두 줄이 같이 남아야 나중에 "이 점수를 실제로 누가 넣었나"를 설명할 수 있다.

-- ============================================================
-- 0. 영역별로 필요한 역할이 다르다
--    출결·학업은 quant, 나머지는 evaluator.
-- ============================================================

create or replace function public._score_area_required_role(p_area evaluation_area)
returns app_role
language sql
immutable
as $$
  select case
    when p_area in ('attendance', 'academic') then 'quant'::app_role
    else 'evaluator'::app_role
  end;
$$;

-- 기존 목록 함수는 'evaluator'만 보고 있어 출결·학업 담당(quant)이 하나도
-- 나오지 않았다. 영역에 맞는 역할을 보도록 고친다.
create or replace function public.admin_list_score_entry_evaluators(
  p_area evaluation_area
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_role app_role;
  v_result jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  v_role := public._score_area_required_role(p_area);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email
  ) order by display_name), '[]'::jsonb)
  into v_result
  from public.users
  where active = true
    and v_role = any(roles)
    and p_area = any(assigned_areas);

  return v_result;
end;
$$;

revoke all on function public.admin_list_score_entry_evaluators(evaluation_area) from public, anon;
grant execute on function public.admin_list_score_entry_evaluators(evaluation_area) to authenticated;

-- ============================================================
-- 1. 대리 입력 공통 검증 — 관리자 권한·사유·대상 평가위원 자격
-- ============================================================

create or replace function public._admin_score_proxy_check(
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_role app_role;
  valid_reasons text[] := array['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code using errcode = '22023';
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 사유 내용을 반드시 입력해야 합니다.' using errcode = '23514';
  end if;

  v_role := public._score_area_required_role(p_area);

  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid
      and u.active = true
      and v_role = any(u.roles)
      and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역(%) 담당으로 등록되어 있지 않습니다.', p_area
      using errcode = '42501';
  end if;

  return caller;
end;
$$;

revoke execute on function public._admin_score_proxy_check(evaluation_area, uuid, text, text) from anon, authenticated;

-- ============================================================
-- 2. 대리 입력 사실 기록 (관리자 명의)
-- ============================================================

create or replace function public._admin_score_proxy_log(
  p_admin_uid uuid,
  p_applicant_id uuid,
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app record;
begin
  select year, round into v_app from public.applicants where id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id,
     applicant_id, area, reason_code, metadata)
  values
    (v_app.year, v_app.round, 'user', p_admin_uid::text,
     'score.' || p_area::text || '.submitted_on_behalf',
     'scores_' || p_area::text, p_applicant_id::text, p_applicant_id::text, p_area,
     p_reason_code,
     jsonb_build_object(
       'targetEvaluatorUid', p_target_evaluator_uid,
       'reasonText', p_reason_text));
end;
$$;

revoke execute on function public._admin_score_proxy_log(uuid, uuid, evaluation_area, uuid, text, text) from anon, authenticated;

-- ============================================================
-- 3. 영역별 대리 제출 — 전부 원래 submit_*_score를 그대로 호출한다
--    (계산 로직 복사 없음. 상단 주석 참고)
-- ============================================================

create or replace function public.admin_submit_attendance_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_unexcused_absences int,
  p_tardy_early_result_count int,
  p_no_record boolean,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('attendance', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_attendance_score(
    p_applicant_id, p_unexcused_absences, p_tardy_early_result_count, coalesce(p_no_record, false));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'attendance', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_attendance_score(uuid, uuid, int, int, boolean, text, text) from public, anon;
grant execute on function public.admin_submit_attendance_score(uuid, uuid, int, int, boolean, text, text) to authenticated;

create or replace function public.admin_submit_academic_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_input_type text,
  p_subjects jsonb,
  p_no_document boolean,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('academic', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_academic_score(
    p_applicant_id, p_input_type, coalesce(p_subjects, '[]'::jsonb), coalesce(p_no_document, false));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'academic', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_academic_score(uuid, uuid, text, jsonb, boolean, text, text) from public, anon;
grant execute on function public.admin_submit_academic_score(uuid, uuid, text, jsonb, boolean, text, text) to authenticated;

create or replace function public.admin_submit_community_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_grade int,
  p_evidence_memo text,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('community', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_community_score(p_applicant_id, p_grade, p_evidence_memo);

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'community', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_community_score(uuid, uuid, int, text, text, text) from public, anon;
grant execute on function public.admin_submit_community_score(uuid, uuid, int, text, text, text) to authenticated;

create or replace function public.admin_submit_essay_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_items jsonb,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('essay', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_essay_score(p_applicant_id, p_items);

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'essay', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_essay_score(uuid, uuid, jsonb, text, text) from public, anon;
grant execute on function public.admin_submit_essay_score(uuid, uuid, jsonb, text, text) to authenticated;

create or replace function public.admin_submit_opinion_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_items jsonb,
  p_deduction_flags jsonb,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('opinion', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_opinion_score(
    p_applicant_id, p_items, coalesce(p_deduction_flags, '{}'::jsonb));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'opinion', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_opinion_score(uuid, uuid, jsonb, jsonb, text, text) from public, anon;
grant execute on function public.admin_submit_opinion_score(uuid, uuid, jsonb, jsonb, text, text) to authenticated;

-- ============================================================
-- 4. 대리 입력 화면용 조회 — 대상 평가위원이 이 영역에서 어디까지 했는지
-- ============================================================

create or replace function public.admin_get_document_score_entry_context(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_target_evaluator_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_role app_role;
  v_table text;
  v_items jsonb;
  v_area_open boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '이 화면은 서류평가 5개 영역만 지원합니다 (입력값: %).', p_area
      using errcode = '22023';
  end if;

  v_role := public._score_area_required_role(p_area);
  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and v_role = any(u.roles) and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역 담당으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  select (stage_status = 'open' and p_area = any(open_evaluation_areas))
  into v_area_open
  from public.admission_rounds
  where year = p_year and round = p_round;

  -- 영역마다 점수 테이블이 다르다. 위에서 영역을 5개로 좁혀 검증했으므로
  -- 테이블명 조립은 안전하다(사용자 입력이 그대로 들어가지 않는다).
  v_table := 'scores_' || p_area::text;

  -- 값은 문자열로 끼워 넣지 않고 USING으로 넘긴다(따옴표·형변환 사고 방지).
  -- 테이블명만 %I로 조립하며, 위에서 영역을 5개로 좁혀 검증했으므로 안전하다.
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', r.applicant_id,
      'examNo', r.exam_no,
      'displayName', r.display_name,
      'receiptNo', r.receipt_no,
      'submissionState', s.submission_state,
      'serverComputed', s.server_computed,
      'submittedAt', s.submitted_at
    ) order by r.receipt_no), '[]'::jsonb)
    from public.evaluation_roster r
    left join public.%I s
      on s.applicant_id = r.applicant_id and s.evaluator_uid = $1
    where r.year = $2 and r.round = $3 and r.evaluation_active = true
  $q$, v_table)
  into v_items
  using p_target_evaluator_uid, p_year, p_round;

  return jsonb_build_object(
    'area', p_area,
    'areaOpen', coalesce(v_area_open, false),
    'targetEvaluatorUid', p_target_evaluator_uid,
    'items', v_items
  );
end;
$$;

revoke all on function public.admin_get_document_score_entry_context(int, admission_round, evaluation_area, uuid) from public, anon;
grant execute on function public.admin_get_document_score_entry_context(int, admission_round, evaluation_area, uuid) to authenticated;
