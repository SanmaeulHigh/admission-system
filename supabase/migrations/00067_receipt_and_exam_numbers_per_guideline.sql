-- 새봄고 입학전형 시스템 — 접수번호·수험번호를 원서 접수 지침에 맞춤 (2026-09-28)
--
-- 근거: 「2026학년도 신입생 입학전형 원서 접수 업무 진행 지침(수정 2025.10.21.)」
--   3. 기본 방침
--     · (접수번호 부여) 전형별로 접수일자 및 일자별 접수 순서순으로 부여
--     · (수험번호 부여) 접수 마감 후 지원 전형에 상관없이 지원자 성명 가나다 순으로 부여
--   4-(2) 번호 형식
--     · 접수번호: YYMMDD + 전형코드(G 일반 / I 일반+인천학생추천 / U 일반+사회통합) + XXX
--                 (접수일마다 전형별로 001부터 다시 셈)
--     · 수험번호: A + 회차(1 신입생 입학전형 / 2 1차 추가모집 / 3 2차 추가모집) + XXX
--                 (수험번호로 지원 전형·성별 등을 특정할 수 없어야 함)
--     · 원서 접수 마감 이후 3일 이내 개인별 연락처로 수험번호 안내
--
-- 지금까지의 구현이 지침과 달랐던 점:
--   · 접수번호: 초기 개발 때 G·U를 "접수방법(등기·방문)"으로 잘못 읽었고, 핫픽스
--     002에서 아예 M(우편)·V(방문)로 바꿨다. 지침의 G/I/U는 "전형" 코드다.
--   · 수험번호: 00008은 1차 합격자에게 "2027-001" 형식으로 부여했다. 지침은
--     접수 마감 후 전원에게, 가나다순으로, A+회차+순번 형식으로 부여한다.
--
-- 바뀌는 것:
--   1. register_applicant — 접수번호 가운데 글자를 전형코드(G/I/U)로
--   2. assign_exam_numbers — 접수 마감 후 관리자가 한 번 실행하는 수험번호 일괄 부여
--   3. run_document_decision — 1차 사정에서 수험번호를 더 이상 매기지 않음
--
-- 이미 만들어진 지원자의 접수번호는 바꾸지 않는다(접수증이 이미 나갔을 수 있다).
-- 현재 저장소에는 테스트 데이터뿐이므로, 새 형식은 이후 접수분부터 적용된다.

-- ============================================================
-- 0. 이전 시도 정리 (접수 즉시 수험번호를 주던 초안이 적용된 경우 대비)
-- ============================================================

drop function if exists public._allocate_exam_no(int, admission_round);
drop table if exists public.exam_no_counters;

-- 지침 형식(A+회차+3자리)이 아닌 수험번호는 비운다. 단, 1차 사정이 이미 확정된
-- 회차는 건드리지 않는다(그 번호로 이미 안내·평가가 진행됐을 수 있다).
update public.evaluation_roster er
set exam_no = null, updated_at = now()
where er.exam_no is not null
  and er.exam_no !~ '^A[123][0-9]{3}$'
  and not exists (
    select 1 from public.admission_rounds r
    where r.year = er.year and r.round = er.round and r.document_decision_run_id is not null
  );

update public.applicants a
set exam_no = null, updated_at = now()
where a.exam_no is not null
  and a.exam_no !~ '^A[123][0-9]{3}$'
  and not exists (
    select 1 from public.admission_rounds r
    where r.year = a.year and r.round = a.round and r.document_decision_run_id is not null
  );

-- ============================================================
-- 1. 접수번호 카운터가 전형코드(G/I/U)를 받을 수 있게
--    (기존 M/V 행이 남아 있을 수 있어 함께 허용한다)
-- ============================================================

do $$
declare
  cname text;
begin
  select conname into cname
  from pg_constraint
  where conrelid = 'public.receipt_counters'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%method%';
  if cname is not null then
    execute format('alter table public.receipt_counters drop constraint %I', cname);
  end if;
  alter table public.receipt_counters
    add constraint receipt_counters_method_check check (method in ('G', 'I', 'U', 'M', 'V'));
end $$;

-- ============================================================
-- 2. register_applicant — 접수번호 전형코드 반영
--    (00059 버전에서 접수번호 채번 부분만 바꿨다. 수험번호는 여기서 주지 않는다)
-- ============================================================

create or replace function public.register_applicant(
  p_year int,
  p_round admission_round,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null,
  -- 2026-09-04 추가분
  p_nationality text default 'KOR',
  p_name_english text default null,
  p_applicant_landline text default null,
  p_bonus_eligible boolean default null,   -- null = 미확인 (null ≠ false)
  p_bonus_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_applicant_id uuid;
  v_track_code text;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds
    where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다. init_admission_round를 먼저 실행하세요.', p_year, p_round;
  end if;

  -- 접수번호 = YYMMDD + 전형코드 + 순번 (원서 접수 지침 4-(2)).
  --   G: 일반 / I: 일반+인천학생추천 / U: 일반+사회통합
  -- 순번은 접수일자별·전형별로 001부터 다시 센다. 접수방법(우편/방문)은
  -- 번호에 넣지 않고 receipt_method 컬럼에만 기록한다.
  v_track_code := case
    when 'incheon' = any(p_tracks) then 'I'
    when 'social'  = any(p_tracks) then 'U'
    else 'G'
  end;
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, v_track_code);

  insert into public.applicants
    (year, round, receipt_no, name, name_english, nationality, tracks, academic_status,
     school, grade_class_no, semester_choice, receipt_method,
     bonus_eligible, bonus_reason, bonus_verified_at, bonus_verified_by,
     created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, trim(p_name), nullif(trim(coalesce(p_name_english,'')), ''),
     coalesce(nullif(trim(coalesce(p_nationality,'')), ''), 'KOR'),
     p_tracks, p_academic_status,
     p_school, p_grade_class_no, p_semester_choice, p_receipt_method,
     p_bonus_eligible, p_bonus_reason,
     case when p_bonus_eligible is not null then now() end,
     case when p_bonus_eligible is not null then caller::text end,
     caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, applicant_landline, email, address,
     guardian_name, guardian_relation, guardian_phone, guardian_address)
  values
    (new_applicant_id, p_gender, p_birth_date, p_applicant_phone, p_applicant_landline,
     p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_guardian_address);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, trim(p_name));

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_applicant(
  int, admission_round, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text, text, text, text, boolean, text
) from anon;


-- ============================================================
-- 3. 수험번호 일괄 부여 (접수 마감 후 1회)
-- ============================================================

create or replace function public.assign_exam_numbers(
  p_year int,
  p_round admission_round,
  p_reassign boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round_digit text;
  v_decision uuid;
  v_already int;
  v_seq int := 0;
  v_first text;
  v_last text;
  v_no text;
  app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  -- 회차 코드: 신입생 입학전형(1) / 1차 추가모집(2) / 2차 추가모집(3)
  v_round_digit := case p_round
    when 'main' then '1'
    when 'extra1' then '2'
    when 'extra2' then '3'
  end;

  select document_decision_run_id into v_decision
  from public.admission_rounds where year = p_year and round = p_round;
  if not found then
    raise exception '전형 회차(%, %)가 없습니다.', p_year, p_round using errcode = 'P0002';
  end if;

  select count(*) into v_already
  from public.applicants
  where year = p_year and round = p_round and exam_no is not null;

  if v_already > 0 and not p_reassign then
    raise exception '이미 수험번호가 부여된 지원자가 %명 있습니다. 다시 매기려면 재부여를 선택하세요.', v_already
      using errcode = '55000';
  end if;

  -- 1차 사정이 확정된 뒤에는 번호를 바꾸지 못하게 막는다
  -- (평가·안내가 이미 그 번호로 진행됐다).
  if p_reassign and v_decision is not null then
    raise exception '1차 사정이 확정된 회차는 수험번호를 다시 매길 수 없습니다.' using errcode = '55000';
  end if;

  -- 재부여: 먼저 전부 비운다(철회·제외된 지원자의 옛 번호도 함께 정리).
  update public.applicants set exam_no = null, updated_at = now()
    where year = p_year and round = p_round;
  update public.evaluation_roster set exam_no = null, updated_at = now()
    where year = p_year and round = p_round;

  -- 지원 전형에 상관없이 성명 가나다순. 한글 완성형 음절은 유니코드 순서가
  -- 가나다순과 같으므로 collate "C"로 서버 로캘과 무관하게 정렬한다.
  -- 동명이인은 접수번호 순으로 정한다. 철회·제외된 지원자는 번호를 받지 않는다.
  for app in
    select a.id
    from public.applicants a
    where a.year = p_year and a.round = p_round
      and a.application_status not in ('withdrawn', 'excluded')
    order by a.name collate "C", a.receipt_no collate "C"
  loop
    v_seq := v_seq + 1;
    if v_seq > 999 then
      raise exception '수험번호는 회차당 999명까지 부여할 수 있습니다.' using errcode = '22003';
    end if;
    v_no := 'A' || v_round_digit || lpad(v_seq::text, 3, '0');
    if v_first is null then v_first := v_no; end if;
    v_last := v_no;

    update public.applicants set exam_no = v_no, updated_at = now(), updated_by = caller::text
      where id = app.id;
    update public.evaluation_roster set exam_no = v_no, updated_at = now()
      where applicant_id = app.id;
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when p_reassign then 'exam_no.reassigned' else 'exam_no.assigned' end,
     'admission_rounds', p_year::text || '_' || p_round::text,
     jsonb_build_object('count', v_seq, 'first', v_first, 'last', v_last));

  return jsonb_build_object('assigned', v_seq, 'first', v_first, 'last', v_last);
end;
$$;

revoke all on function public.assign_exam_numbers(int, admission_round, boolean) from public, anon;
grant execute on function public.assign_exam_numbers(int, admission_round, boolean) to authenticated;

-- ============================================================
-- 4. run_document_decision — 수험번호 채번 제거
--    (00008 원문에서 채번 블록만 기계적으로 교체. 나머지는 그대로다)
-- ============================================================

create or replace function public.run_document_decision(
  p_year int,
  p_round admission_round,
  p_mode decision_mode
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  quota jsonb;
  pass_limit int;
  v_run_id uuid;
  blocking_count int;
  applicant_row record;
  agg jsonb;
  boundary_rank int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  next_exam_seq int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(p_year, p_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'quota' into quota from public.config_revisions where id = rev_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다. setup 스크립트를 먼저 실행하세요.';
  end if;
  pass_limit := floor((quota ->> 'total')::numeric * (quota ->> 'screeningMultiple')::numeric);

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'document', p_mode, 'running', rev_id, caller::text)
  returning id into v_run_id;

  -- 후보군: 접수완료 + 사정제외 아님 (섹션 5.3.1 — evaluationStage 게이트는
  -- 아직 별도 전환 단계를 만들지 않아 이번 구현에서는 생략, 검토메모 기록)
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    document_final numeric,
    community numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  for applicant_row in
    select a.id from public.applicants a
    left join public.applicants_admin aa on aa.applicant_id = a.id
    where a.year = p_year and a.round = p_round and a.application_status = 'complete'
      and coalesce(aa.exclusion_status, 'none') <> 'excluded'
  loop
    agg := public._compute_document_aggregate(applicant_row.id);
    if (agg ->> 'complete')::boolean then
      insert into tmp_candidates values (
        applicant_row.id,
        (agg ->> 'finalTotal')::numeric,
        (agg ->> 'community')::numeric,
        (agg ->> 'essay')::numeric,
        (agg ->> 'attendance')::numeric,
        (agg ->> 'academic')::numeric
      );
      v_candidate_count := v_candidate_count + 1;
    end if;
  end loop;

  -- 순위 산정 (섹션 5.3.3 정렬 기준 그대로) + 동점 경계 판정
  create temp table tmp_ranked on commit drop as
  select *,
    rank() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rn
  from tmp_candidates;

  select rnk into boundary_rank from tmp_ranked where rn = pass_limit;

  -- decision_results 기록
  for applicant_row in select * from tmp_ranked loop
    declare
      this_outcome decision_outcome;
    begin
      if boundary_rank is not null and applicant_row.rnk = boundary_rank
         and (select count(*) from tmp_ranked where rnk = boundary_rank and rn > pass_limit) > 0 then
        this_outcome := 'manualDecisionRequired';
        unresolved_count := unresolved_count + 1;
      elsif applicant_row.rnk <= coalesce(boundary_rank, pass_limit) then
        this_outcome := 'passed';
      else
        this_outcome := 'failed';
      end if;

      insert into public.decision_results
        (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values, outcome)
      values
        (v_run_id, applicant_row.applicant_id, p_year, p_round, 'document', applicant_row.document_final,
         applicant_row.rnk,
         jsonb_build_object(
           'community', applicant_row.community, 'essay', applicant_row.essay,
           'attendance', applicant_row.attendance, 'academic', applicant_row.academic
         ),
         this_outcome);
      v_result_count := v_result_count + 1;
    end;
  end loop;

  update public.decision_runs
  set candidate_count = v_candidate_count, result_count = v_result_count,
      unresolved_tie_count = unresolved_count, blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 실제 반영 ──────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;

    -- 2026-09-28: 수험번호는 원서 접수 지침에 따라 접수 마감 후 일괄 부여한다
    -- (assign_exam_numbers, 00067). 1차 사정에서는 더 이상 수험번호를 매기지 않고
    -- 합격 단계만 표시한다. 여기서 다시 매기면 이미 안내한 번호와 어긋난다.
    for applicant_row in
      select dr.applicant_id from public.decision_results dr
      where dr.run_id = v_run_id and dr.outcome = 'passed'
      order by dr.rank
    loop
      update public.applicants set evaluation_stage = 'documentPassed', updated_at = now(), updated_by = caller::text
        where id = applicant_row.applicant_id;
      update public.evaluation_roster
        set evaluation_stage = 'documentPassed', updated_at = now()
        where applicant_id = applicant_row.applicant_id;
    end loop;

    update public.applicants set evaluation_stage = 'documentFailed', updated_at = now(), updated_by = caller::text
      where id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');
    update public.evaluation_roster set evaluation_stage = 'documentFailed', updated_at = now()
      where applicant_id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;
