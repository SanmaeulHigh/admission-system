-- 새봄고 입학전형 시스템 — M3a/b/c 서류평가 채점 (Sprint 3)
-- 마스터 스펙 v1.2 섹션 1246행(M3), 5.1(공통 계산 원칙), 6.7~6.8(Rules) 대응.
--
-- 이번 마이그레이션 범위: 출결(quant)·학업성실도(quant)·공동체생활적합성
-- (evaluator). 자소서·소견서(M3d/e)는 루브릭 확보 후 별도 마이그레이션.
--
-- 핵심 원칙(5.1 그대로 적용):
--   - 서버(RPC)만 점수를 계산한다. 클라이언트가 계산한 합계는 미리보기일 뿐.
--   - 미채점·미제출은 숫자 0이 아니라 값 자체가 없는 상태로 남긴다
--     (submission_state로 구분 — 여기서는 제출 즉시 확정되는 단순 흐름이라
--     draft 단계 없이 submitted로 직접 기록한다. 자동저장이 필요한
--     자소서(M3d)는 별도 마이그레이션에서 draft 상태를 추가한다).
--   - 실제 배점 파라미터는 config_revisions.scoring_params에서만 읽는다
--     (하드코딩 금지 — 섹션 9.2).
--   - 평가문서는 반드시 해당 라운드의 "현재 잠긴 revision"을 사용해야 하며,
--     클라이언트가 configRevisionId를 지정하지 않고 서버가 admission_rounds
--     에서 조회해 채운다 (클라이언트 위조 방지).

-- ============================================================
-- 1. 영역 open 여부 helper (스펙: "날짜만이 아니라 stage/stageStatus/
--    openEvaluationAreas를 함께 검증")
-- ============================================================

create or replace function public._is_area_open(
  target_year int, target_round admission_round, target_area evaluation_area
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.admission_rounds
    where year = target_year and round = target_round
      and stage_status = 'open'
      and target_area = any(open_evaluation_areas)
  );
$$;

revoke execute on function public._is_area_open(int, admission_round, evaluation_area) from anon;

-- 현재 라운드의 활성 config_revision_id 조회 (RPC 내부 전용)
create or replace function public._current_config_revision_id(target_year int, target_round admission_round)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select config_revision_id from public.admission_rounds
  where year = target_year and round = target_round;
$$;

revoke execute on function public._current_config_revision_id(int, admission_round) from anon, authenticated;

-- 지원자가 평가 활성 상태인지 (evaluation_roster 기준)
create or replace function public._is_evaluation_active(p_applicant_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select evaluation_active from public.evaluation_roster where applicant_id = p_applicant_id),
    false
  );
$$;

revoke execute on function public._is_evaluation_active(uuid) from anon;

-- ============================================================
-- 2. 테이블 (공통 형태: inputs 원본 입력값 / server_computed 서버 산출값)
-- ============================================================

create table public.scores_attendance (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_academic (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_community (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

comment on table public.scores_attendance is 'M3a. role=quant, area=attendance. requiredSubmissions=1 (config).';
comment on table public.scores_academic is 'M3b. role=quant, area=academic. requiredSubmissions=1 (config).';
comment on table public.scores_community is 'M3c. role=evaluator, area=community. requiredSubmissions=2, combine=avg (config) — 집계는 M4/aggregate에서.';

-- ============================================================
-- 3. RLS — 6.7 공통검증(본인만 read/write) + 6.8 영역별 role/area
-- ============================================================

alter table public.scores_attendance enable row level security;
alter table public.scores_academic enable row level security;
alter table public.scores_community enable row level security;

create policy scores_attendance_select_own_or_admin
  on public.scores_attendance for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_academic_select_own_or_admin
  on public.scores_academic for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_community_select_own_or_admin
  on public.scores_community for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = 아래 RPC로만 (섹션 2.12, 6.7 "서버만 계산")

-- ============================================================
-- 4. submit_attendance_score RPC
--    inputs: 미인정결석 일수, 지각·조퇴·결과 합산 횟수(3회=1일 환산),
--    학생부 자체가 없는 경우(검정고시 등) p_no_record=true → noRecordScore
-- ============================================================

create or replace function public.submit_attendance_score(
  p_applicant_id uuid,
  p_unexcused_absences int,
  p_tardy_early_result_count int,
  p_no_record boolean default false
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
  effective_days int;
  computed_score numeric;
  used_no_record boolean := p_no_record;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('quant') and public.has_area('attendance')) then
    raise exception '출결 평가 권한이 없습니다 (quant + attendance 배정 필요).';
  end if;

  select * into existing from public.scores_attendance
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'attendance') then
    raise exception '출결 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'attendance' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 attendance 배점 파라미터가 없습니다.';
  end if;

  if used_no_record then
    computed_score := (params ->> 'noRecordScore')::numeric;
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_tardy_early_result_count is null or p_tardy_early_result_count < 0 then
      raise exception '입력값은 0 이상의 정수여야 합니다.';
    end if;
    effective_days := p_unexcused_absences
      + floor(p_tardy_early_result_count::numeric / (params ->> 'attendanceEventPerAbsence')::numeric);
    computed_score := greatest(
      0,
      least(
        (params ->> 'max')::numeric,
        (params ->> 'max')::numeric - (params ->> 'perDayDeduction')::numeric * effective_days
      )
    );
  end if;

  insert into public.scores_attendance
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'tardyEarlyResultCount', p_tardy_early_result_count,
       'noRecord', used_no_record
     ),
     jsonb_build_object(
       'effectiveAbsenceDays', effective_days,
       'score', computed_score,
       'usedNoRecordScore', used_no_record,
       'configRevisionId', rev_id
     ))
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
    (app.year, app.round, 'user', caller::text, 'score.attendance.submitted', 'scores_attendance',
     p_applicant_id::text, p_applicant_id::text, 'attendance');

  return jsonb_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days)::json;
end;
$$;

revoke execute on function public.submit_attendance_score(uuid, int, int, boolean) from anon;

-- ============================================================
-- 5. submit_academic_score RPC
--    p_input_type: 'regular'(성취도) | 'ged'(검정고시 원점수)
--    p_subjects: [{"subject":"국어","achievement":"A"}, ...] 또는
--                [{"subject":"국어","rawScore":85}, ...]
--    서버가 상위 5과목 선정. 증빙 자체 없음 = p_no_document=true
-- ============================================================

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

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
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
     jsonb_build_object('inputType', p_input_type, 'subjects', p_subjects, 'noDocument', p_no_document),
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

-- ============================================================
-- 6. submit_community_score RPC — evaluator, 1~5등급 + 근거메모 필수
-- ============================================================

create or replace function public.submit_community_score(
  p_applicant_id uuid,
  p_grade int,
  p_evidence_memo text
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
  computed_score numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('community')) then
    raise exception '공동체 평가 권한이 없습니다 (evaluator + community 배정 필요).';
  end if;

  select * into existing from public.scores_community
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;
  if p_grade is null or p_grade < 1 or p_grade > 5 then
    raise exception '등급은 1~5 사이여야 합니다.';
  end if;
  if p_evidence_memo is null or length(trim(p_evidence_memo)) < 10 then
    raise exception '근거 메모는 최소 10자 이상 입력해야 합니다.';
  end if;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'community') then
    raise exception '공동체 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'community' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 community 배점 파라미터가 없습니다.';
  end if;

  computed_score := ((params -> 'grades') ->> p_grade::text)::numeric;
  if computed_score is null then
    raise exception '등급 %에 대한 배점이 config에 없습니다.', p_grade;
  end if;

  insert into public.scores_community
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object('grade', p_grade, 'evidenceMemo', p_evidence_memo),
     jsonb_build_object('score', computed_score, 'configRevisionId', rev_id))
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
    (app.year, app.round, 'user', caller::text, 'score.community.submitted', 'scores_community',
     p_applicant_id::text, p_applicant_id::text, 'community');

  return jsonb_build_object('score', computed_score)::json;
end;
$$;

revoke execute on function public.submit_community_score(uuid, int, text) from anon;

-- ============================================================
-- 7. 재개방 RPC (superadmin/admin 전용) — 제출된 점수 재수정 허용
-- ============================================================

create or replace function public.reopen_score(
  p_score_table text,
  p_score_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_score_table not in ('scores_attendance', 'scores_academic', 'scores_community') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke execute on function public.reopen_score(text, uuid) from anon;
