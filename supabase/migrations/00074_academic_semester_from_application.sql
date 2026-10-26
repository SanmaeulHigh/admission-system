-- 새봄고 입학전형 시스템 — 학업성실도: 원서의 반영 학기 자동 표시·기록 (2026-09-28)
--
-- 요강: 학업성실도는 "지원자가 입학원서에 학업성실도 반영을 선택하여 기재한 학기"의
-- 상위 5개 과목 성취도로 산정한다. 반영 학기는 접수 때 applicants.semester_choice에
-- 이미 들어가 있으므로, 채점 화면에서 따로 입력받지 않고 원서 값을 보여주고(get_academic_context),
-- 제출할 때 서버가 그 값을 inputs.semesterChoice에 함께 저장한다(채점표·XLSX에 표시).
-- 채점 담당(quant)은 applicants 표를 직접 읽을 수 없어서 전용 조회 함수를 둔다.
--
-- 입력 유형(학생부 성취도 / 검정고시 원점수)도 채점자가 고르지 않고 원서의 학적을 따른다
-- (2026-09-28 — 선생님들이 잘못 고르는 실수 방지). 졸업예정·졸업 → 학생부(regular),
-- 검정고시 → 원점수(ged). '기타'(동등학력 인정 등)만 화면에서 고른다. 서버도 같은 규칙으로
-- 원서 학적과 맞지 않는 유형의 제출을 거부한다.

create or replace function public.get_academic_context(p_applicant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_app record;
begin
  if not (public.has_role('superadmin') or public.has_role('admin')
          or (public.has_role('quant') and public.has_area('academic'))) then
    raise exception '학업성실도 평가 권한이 없습니다.' using errcode = '42501';
  end if;

  select semester_choice, academic_status into v_app
  from public.applicants where id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'semesterChoice', v_app.semester_choice,
    'academicStatus', v_app.academic_status
  );
end;
$$;

revoke all on function public.get_academic_context(uuid) from public, anon;
grant execute on function public.get_academic_context(uuid) to authenticated;

-- submit_academic_score: 00005 원문에서 반영 학기 저장만 추가
create or replace function public.submit_academic_score(
  p_applicant_id uuid,
  p_input_type text,
  p_subjects jsonb default '[]'::jsonb,
  p_no_document boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  params jsonb;
  grade_map jsonb;
  ged_bands jsonb;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('quant') and public.has_area('academic')) then
    raise exception '학업성실도 평가 권한이 없습니다 (quant + academic 배정 필요).';
  end if;
  if p_input_type not in ('regular', 'ged') then
    raise exception 'p_input_type은 regular 또는 ged여야 합니다.';
  end if;

  select * into existing from public.scores_academic
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  select id, year, round, semester_choice, academic_status into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  -- 원서 학적과 입력 유형이 맞아야 한다(무증빙 점수 적용은 예외).
  if not p_no_document then
    if app.academic_status = '검정고시' and p_input_type <> 'ged' then
      raise exception '원서 학적이 검정고시인 지원자입니다. 검정고시 원점수로 입력하세요.' using errcode = '23514';
    end if;
    if app.academic_status in ('졸업예정', '졸업') and p_input_type <> 'regular' then
      raise exception '원서 학적이 %인 지원자입니다. 학교생활기록부 성취도(A~E)로 입력하세요.', app.academic_status using errcode = '23514';
    end if;
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'academic') then
    raise exception '학업성실도 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'academic' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 academic 배점 파라미터가 없습니다.';
  end if;

  if p_no_document then
    computed_score := (params ->> 'noDocumentScore')::numeric;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    grade_map := params -> 'gradeMap';
    ged_bands := params -> 'gedBands';

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_input_type = 'regular' then
        points := (grade_map ->> (subj ->> 'achievement'))::numeric;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
          band jsonb;
          matched boolean := false;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception 'GED 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          for band in select * from jsonb_array_elements(ged_bands)
          loop
            if raw >= (band ->> 0)::numeric and raw <= (band ->> 1)::numeric then
              points := (band ->> 2)::numeric;
              matched := true;
              exit;
            end if;
          end loop;
          if not matched then
            raise exception 'GED 원점수 %에 해당하는 구간을 찾지 못했습니다.', raw;
          end if;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    -- 상위 5과목 선정·합산 (서버만 수행 — 클라이언트가 고르지 않음)
    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, (params ->> 'max')::numeric);
  end if;

  insert into public.scores_academic
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object('inputType', p_input_type, 'subjects', p_subjects, 'noDocument', p_no_document,
                        'semesterChoice', case when p_input_type = 'regular' then app.semester_choice end),
     jsonb_build_object('score', computed_score, 'usedNoDocumentScore', p_no_document, 'configRevisionId', rev_id))
  on conflict (applicant_id, evaluator_uid) do update set
    inputs = excluded.inputs,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.academic.submitted', 'scores_academic',
     p_applicant_id::text, p_applicant_id::text, 'academic');

  return jsonb_build_object('score', computed_score)::json;
end;
$$;

revoke execute on function public.submit_academic_score(uuid, text, jsonb, boolean) from anon;
