begin;

-- 새봄고 입학전형 시스템 — M5c 학생·학부모면접 독립 채점
-- 마스터 스펙 v1.2 섹션 2.8, 3.15, 5.4.3~5.4.4, M5c 대응.
--
-- 핵심 불변조건
--   1) evaluator + interview 영역 + scope + finalized interview team membership + 지원자 team 배정이 모두 필요하다.
--   2) 같은 조 2인은 독립 채점하며 evaluator는 자기 점수만 읽는다.
--   3) 학생면접과 학부모면접은 별도 draft/submitted/reopened/revision/lock 상태를 갖는다.
--   4) 2인 모두 제출 전 해당 면접 aggregate는 score=null, complete=false다.
--   5) 점수 기준·허용 단계값·만점·편차경보·소요시간은 immutable config revision에서 읽는다.
--   6) draft stale replay와 동시 저장/제출은 applicant+evaluator 단위 advisory lock으로 직렬화한다.
--   7) 대체 평가위원 지정은 superadmin 전용 RPC + 사유·감사로그로만 수행한다.

-- ============================================================
-- 1. 면접조 계획 / 조 / 조원 / 시간표
-- ============================================================

create table public.interview_team_plans (
  year int not null,
  round admission_round not null,
  status text not null default 'draft' check (status in ('draft', 'finalized')),
  document_source_run_id uuid not null references public.decision_runs (id),
  config_revision_id uuid not null references public.config_revisions (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.interview_teams (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  team_code text not null check (length(trim(team_code)) between 1 and 20),
  location text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (year, round, team_code),
  unique (id, year, round),
  foreign key (year, round)
    references public.interview_team_plans (year, round) on delete cascade
);

create table public.interview_team_members (
  team_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  member_slot smallint not null check (member_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (team_id, member_slot),
  unique (team_id, evaluator_uid),
  unique (year, round, evaluator_uid),
  foreign key (team_id, year, round)
    references public.interview_teams (id, year, round) on delete cascade
);

create table public.interview_schedules (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null,
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.evaluation_roster (applicant_id) on delete cascade,
  student_starts_at timestamptz not null,
  student_ends_at timestamptz not null,
  parent_starts_at timestamptz not null,
  parent_ends_at timestamptz not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check (student_ends_at > student_starts_at),
  check (parent_ends_at > parent_starts_at),
  unique (year, round, applicant_id),
  foreign key (team_id, year, round)
    references public.interview_teams (id, year, round) on delete cascade
);

comment on table public.interview_team_plans is
  'M5c 면접조 편성 계획. document_source_run_id는 M4 final 합격자 스냅샷, config_revision_id는 면접 배점 스냅샷 기준이며 final 이후 일반 수정 금지.';
comment on table public.interview_team_members is
  '면접조 위원 2인. 동일 evaluator는 같은 연도/차수에서 하나의 면접조에만 소속된다.';
comment on table public.interview_schedules is
  '학생 25분·학부모 20분 등 실제 시간표. duration은 해당 config revision의 deep.interview* 파라미터로 검증한다.';

alter table public.interview_team_plans enable row level security;
alter table public.interview_teams enable row level security;
alter table public.interview_team_members enable row level security;
alter table public.interview_schedules enable row level security;

create policy interview_team_plans_select_staff
  on public.interview_team_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('interview')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or interview_team_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or interview_team_plans.round = any(u.round_scopes))
      )
    )
  );

create policy interview_teams_select_member_or_admin
  on public.interview_teams for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or exists (
      select 1 from public.interview_team_members m
      where m.team_id = interview_teams.id
        and m.evaluator_uid = auth.uid()
        and public.has_role('evaluator')
        and public.has_area('interview')
    )
  );

create policy interview_team_members_select_member_or_admin
  on public.interview_team_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      evaluator_uid = auth.uid()
      and public.has_role('evaluator')
      and public.has_area('interview')
    )
  );

create policy interview_schedules_select_member_or_admin
  on public.interview_schedules for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or exists (
      select 1 from public.interview_team_members m
      where m.team_id = interview_schedules.team_id
        and m.evaluator_uid = auth.uid()
        and public.has_role('evaluator')
        and public.has_area('interview')
    )
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. 개별 점수 / 서버 집계
-- ============================================================

create table public.scores_interview (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  team_id uuid not null references public.interview_teams (id),

  student_items jsonb not null default '{}'::jsonb,
  student_memo text,
  student_server_computed jsonb,
  student_submission_state text not null default 'draft'
    check (student_submission_state in ('draft', 'submitted', 'reopened')),
  student_revision int not null default 0 check (student_revision >= 0),
  student_client_updated_at timestamptz,
  student_submitted_at timestamptz,

  parent_items jsonb not null default '{}'::jsonb,
  parent_memo text,
  parent_server_computed jsonb,
  parent_submission_state text not null default 'draft'
    check (parent_submission_state in ('draft', 'submitted', 'reopened')),
  parent_revision int not null default 0 check (parent_revision >= 0),
  parent_client_updated_at timestamptz,
  parent_submitted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_interview_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  team_id uuid not null references public.interview_teams (id),

  student_complete boolean not null default false,
  student_score numeric,
  student_required int not null,
  student_submitted int not null,
  student_gap numeric,

  parent_complete boolean not null default false,
  parent_score numeric,
  parent_required int not null,
  parent_submitted int not null,
  parent_gap numeric,

  source_revision_summary jsonb not null default '{}'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_interview is
  'M5c 면접위원 본인 채점. 학생/학부모 section별 draft·submitted·reopened·revision·잠금을 완전히 분리한다.';
comment on table public.deep_interview_aggregates is
  'M5c 서버 집계. 학생/학부모 각각 requiredSubmissions 충족 전 score=null/complete=false, 충족 후 2인 평균.';

alter table public.scores_interview enable row level security;
alter table public.deep_interview_aggregates enable row level security;

create policy scores_interview_select_own
  on public.scores_interview for select
  using (evaluator_uid = auth.uid());

create policy deep_interview_aggregates_select_admin_viewer
  on public.deep_interview_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- ============================================================
-- 3. private config / 권한 / 점수 검증 helpers
-- ============================================================

create or replace function public._m5c_interview_params(
  p_revision_id uuid,
  p_section text
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_criteria jsonb;
  v_sum_max numeric;
  c jsonb;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다: %', p_section using errcode = '22023';
  end if;

  select case
           when p_section = 'student' then scoring_params #> '{deep,interviewStudent}'
           else scoring_params #> '{deep,interviewParent}'
         end
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.interview%s 파라미터가 없습니다. M5c 배점 설정을 먼저 반영하세요.',
      case when p_section = 'student' then 'Student' else 'Parent' end
      using errcode = '55000';
  end if;

  v_criteria := v_params -> 'criteria';
  if jsonb_typeof(v_criteria) is distinct from 'array'
     or jsonb_array_length(v_criteria) = 0
     or coalesce((v_params ->> 'max')::numeric, 0) <= 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredSubmissions')::int, 0) <= 0
     or v_params ->> 'combine' <> 'avg'
     or coalesce((v_params ->> 'durationMinutes')::int, 0) <= 0
     or coalesce((v_params ->> 'alertGap')::numeric, -1) < 0 then
    raise exception 'deep interview 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  v_sum_max := 0;
  for c in select value from jsonb_array_elements(v_criteria)
  loop
    if jsonb_typeof(c) is distinct from 'object'
       or coalesce(length(trim(c ->> 'key')), 0) = 0
       or coalesce(length(trim(c ->> 'label')), 0) = 0
       or coalesce((c ->> 'max')::numeric, 0) <= 0
       or jsonb_typeof(c -> 'scoreValues') is distinct from 'array'
       or jsonb_array_length(c -> 'scoreValues') = 0 then
      raise exception '면접 criterion 구조가 올바르지 않습니다: %', c using errcode = '23514';
    end if;
    if exists (
      select 1
      from jsonb_array_elements_text(c -> 'scoreValues') sv
      where sv::numeric < 0 or sv::numeric > (c ->> 'max')::numeric
    ) then
      raise exception '면접 criterion scoreValues가 max 범위를 벗어납니다: %', c using errcode = '23514';
    end if;
    v_sum_max := v_sum_max + (c ->> 'max')::numeric;
  end loop;

  if v_sum_max <> (v_params ->> 'perEvaluatorMax')::numeric
     or (v_params ->> 'max')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '면접 criteria max 합계 / perEvaluatorMax / max가 일치해야 합니다: %', v_params using errcode = '23514';
  end if;

  if (select count(*) from jsonb_array_elements(v_criteria)) <>
     (select count(distinct x.value ->> 'key') from jsonb_array_elements(v_criteria) x) then
    raise exception '면접 criteria key가 중복되었습니다.' using errcode = '23514';
  end if;

  return v_params;
end;
$$;

create or replace function public._m5c_require_interview_user(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'interview' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '면접 평가 권한이 없습니다 (evaluator + interview 배정 및 scope 필요).' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5c_require_interviewer(
  p_applicant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_active boolean;
  v_team_id uuid;
begin
  select er.year, er.round, er.evaluation_active, er.interview_team_id
    into v_year, v_round, v_active, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5c_require_interview_user(v_year, v_round);

  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;
  if v_team_id is null then
    raise exception '지원자에게 면접조가 배정되지 않았습니다.' using errcode = '55000';
  end if;
  if not exists (
    select 1
    from public.interview_team_plans p
    join public.interview_teams t on t.year = p.year and t.round = p.round
    join public.interview_team_members m on m.team_id = t.id
    where p.year = v_year and p.round = v_round
      and p.status = 'finalized'
      and t.id = v_team_id
      and t.active = true
      and m.evaluator_uid = caller
  ) then
    raise exception '이 지원자는 현재 평가자의 면접조에 배정되지 않았습니다.' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5c_validate_and_total(
  p_revision_id uuid,
  p_section text,
  p_items jsonb,
  p_require_complete boolean
)
returns numeric
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb := public._m5c_interview_params(p_revision_id, p_section);
  v_criteria jsonb := v_params -> 'criteria';
  c jsonb;
  k text;
  raw_value text;
  v numeric;
  total numeric := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'object' then
    raise exception 'items는 JSON object여야 합니다.' using errcode = '22023';
  end if;

  if p_require_complete then
    for c in select value from jsonb_array_elements(v_criteria)
    loop
      if not (p_items ? (c ->> 'key')) then
        raise exception '% 기준 점수가 없습니다. 모든 면접 기준을 입력해야 제출할 수 있습니다.', c ->> 'label' using errcode = '23514';
      end if;
    end loop;
    if (select count(*) from jsonb_object_keys(p_items)) <> jsonb_array_length(v_criteria) then
      raise exception '허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.' using errcode = '23514';
    end if;
  end if;

  for k, raw_value in select key, value from jsonb_each_text(p_items)
  loop
    select value into c
    from jsonb_array_elements(v_criteria)
    where value ->> 'key' = k
    limit 1;

    if not found then
      raise exception '알 수 없는 면접 채점 기준: %', k using errcode = '23514';
    end if;

    begin
      v := raw_value::numeric;
    exception when others then
      raise exception '% 점수는 숫자여야 합니다.', c ->> 'label' using errcode = '22023';
    end;

    if not exists (
      select 1 from jsonb_array_elements_text(c -> 'scoreValues') sv
      where sv::numeric = v
    ) then
      raise exception '% 점수는 허용 단계 % 중 하나여야 합니다 (입력값: %).',
        c ->> 'label', c -> 'scoreValues', v using errcode = '23514';
    end if;
    total := total + v;
  end loop;

  if total > (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '위원별 % 면접 총점은 %점을 초과할 수 없습니다 (입력 합계: %).',
      case when p_section = 'student' then '학생' else '학부모' end,
      v_params ->> 'perEvaluatorMax', total using errcode = '23514';
  end if;

  return total;
end;
$$;

revoke all on function public._m5c_interview_params(uuid, text) from public, anon, authenticated;
revoke all on function public._m5c_require_interview_user(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5c_require_interviewer(uuid) from public, anon, authenticated;
revoke all on function public._m5c_validate_and_total(uuid, text, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 4. 면접조 계획 validator / admin workspace / save / finalize
-- ============================================================

create or replace function public._m5c_validate_interview_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_round record;
  v_plan record;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_candidate_count int := 0;
  v_team_count int := 0;
  v_schedule_count int := 0;
  v_bad_count int;
  v_issues jsonb := '[]'::jsonb;
begin
  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.interview_team_plans
  where year = p_year and round = p_round;

  if not found then
    return jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object(
        'code', 'PLAN_MISSING', 'message', '면접조 계획 draft가 없습니다.'
      )),
      'candidateCount', 0, 'teamCount', 0, 'scheduleCount', 0
    );
  end if;

  if v_round.document_decision_run_id is null then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_FINAL_MISSING', 'message', '확정된 M4 1차 사정 run이 없습니다.'
    ));
  elsif v_plan.document_source_run_id <> v_round.document_decision_run_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_SOURCE_STALE', 'message', '면접조 계획의 1차 합격자 기준 run이 현재 확정 run과 다릅니다. 계획을 다시 저장하세요.'
    ));
  end if;

  if v_plan.config_revision_id <> v_round.config_revision_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CONFIG_SOURCE_STALE', 'message', '면접조 계획의 배점 config revision이 현재 전형 config와 다릅니다. 최종확정 전 계획을 다시 저장하세요.'
    ));
  end if;

  select count(*)::int into v_candidate_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  select count(*)::int into v_team_count
  from public.interview_teams t
  where t.year = p_year and t.round = p_round and t.active = true;

  select count(*)::int into v_schedule_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round;

  if v_team_count = 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'TEAM_MISSING', 'message', '면접조가 1개 이상 필요합니다.'
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_teams t
  left join lateral (
    select count(*)::int as member_count
    from public.interview_team_members m where m.team_id = t.id
  ) mc on true
  where t.year = p_year and t.round = p_round and t.active = true
    and mc.member_count <> 2;
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'TEAM_MEMBER_COUNT', 'message', format('위원이 정확히 2명이 아닌 면접조가 %s개 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_team_members m
  join public.interview_teams t on t.id = m.team_id
  left join public.users u on u.id = m.evaluator_uid
  where t.year = p_year and t.round = p_round
    and (
      u.id is null or u.active = false
      or not ('evaluator' = any(u.roles))
      or not ('interview' = any(u.assigned_areas))
      or not (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      or not (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_TEAM_MEMBER', 'message', format('면접 evaluator 권한·scope가 유효하지 않은 조원이 %s명 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed'
    and not exists (
      select 1 from public.interview_schedules s
      where s.year = p_year and s.round = p_round and s.applicant_id = dr.applicant_id
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CANDIDATE_UNASSIGNED', 'message', format('면접조/시간표 미배정 1차 합격자가 %s명 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and not exists (
      select 1 from public.decision_results dr
      where dr.run_id = v_plan.document_source_run_id
        and dr.outcome = 'passed'
        and dr.applicant_id = s.applicant_id
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'NON_CANDIDATE_ASSIGNED', 'message', format('M4 1차 합격자가 아닌 지원자 %s명이 면접시간표에 포함되어 있습니다.', v_bad_count)
    ));
  end if;

  v_student_params := public._m5c_interview_params(v_round.config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_round.config_revision_id, 'parent');

  select count(*)::int into v_bad_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and (
      extract(epoch from (s.student_ends_at - s.student_starts_at)) / 60 <> (v_student_params ->> 'durationMinutes')::numeric
      or extract(epoch from (s.parent_ends_at - s.parent_starts_at)) / 60 <> (v_parent_params ->> 'durationMinutes')::numeric
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DURATION_MISMATCH', 'message', format('config 기준 학생 %s분·학부모 %s분과 다른 시간표가 %s건 있습니다.',
        v_student_params ->> 'durationMinutes', v_parent_params ->> 'durationMinutes', v_bad_count)
    ));
  end if;

  with slots as (
    select s.id, s.team_id, s.applicant_id, 'student'::text as section,
           s.student_starts_at as starts_at, s.student_ends_at as ends_at
    from public.interview_schedules s
    where s.year = p_year and s.round = p_round
    union all
    select s.id, s.team_id, s.applicant_id, 'parent'::text,
           s.parent_starts_at, s.parent_ends_at
    from public.interview_schedules s
    where s.year = p_year and s.round = p_round
  ), overlapping_slots as (
    select distinct a.team_id, a.id, a.section
    from slots a
    join slots b
      on a.team_id = b.team_id
     and (a.id::text || ':' || a.section) < (b.id::text || ':' || b.section)
     and a.starts_at < b.ends_at
     and b.starts_at < a.ends_at
  )
  select count(*)::int into v_bad_count from overlapping_slots;
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'SCHEDULE_OVERLAP', 'message', format('같은 면접조의 학생/학부모 면접 시간이 겹치는 구간이 %s건 있습니다.', v_bad_count)
    ));
  end if;

  return jsonb_build_object(
    'complete', jsonb_array_length(v_issues) = 0,
    'blockingIssues', v_issues,
    'status', v_plan.status,
    'revision', v_plan.revision,
    'documentSourceRunId', v_plan.document_source_run_id,
    'configRevisionId', v_plan.config_revision_id,
    'candidateCount', v_candidate_count,
    'teamCount', v_team_count,
    'scheduleCount', v_schedule_count
  );
end;
$$;

revoke all on function public._m5c_validate_interview_plan(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5c_interview_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  return public._m5c_validate_interview_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5c_interview_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5c_interview_plan(int, admission_round) to authenticated;

create or replace function public.get_m5c_interview_plan_admin(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_plan jsonb;
  v_validation jsonb;
  v_plan_config_revision_id uuid;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select config_revision_id into v_plan_config_revision_id
  from public.interview_team_plans where year = p_year and round = p_round;

  if found then
    v_validation := public._m5c_validate_interview_plan(p_year, p_round);
  else
    v_validation := jsonb_build_object('complete', false, 'blockingIssues', '[]'::jsonb, 'status', null, 'revision', 0);
  end if;

  select jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'areaOpen', v_round.stage_status = 'open' and 'interview'::evaluation_area = any(v_round.open_evaluation_areas),
    'studentDurationMinutes', case when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null else (public._m5c_interview_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id), 'student') ->> 'durationMinutes')::int end,
    'parentDurationMinutes', case when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null else (public._m5c_interview_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id), 'parent') ->> 'durationMinutes')::int end,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id,
        'displayName', u.display_name,
        'email', u.email
      ) order by u.display_name, u.email)
      from public.users u
      where u.active = true
        and 'evaluator' = any(u.roles)
        and 'interview' = any(u.assigned_areas)
        and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
        and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    ), '[]'::jsonb),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'documentScore', dr.total_score,
        'interviewTeamId', er.interview_team_id
      ) order by dr.rank, er.exam_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb),
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'teamId', t.id,
        'teamCode', t.team_code,
        'location', t.location,
        'sortOrder', t.sort_order,
        'memberUids', coalesce((
          select jsonb_agg(m.evaluator_uid order by m.member_slot)
          from public.interview_team_members m where m.team_id = t.id
        ), '[]'::jsonb),
        'schedule', coalesce((
          select jsonb_agg(jsonb_build_object(
            'scheduleId', s.id,
            'applicantId', s.applicant_id,
            'studentStartsAt', s.student_starts_at,
            'studentEndsAt', s.student_ends_at,
            'parentStartsAt', s.parent_starts_at,
            'parentEndsAt', s.parent_ends_at,
            'sortOrder', s.sort_order
          ) order by s.sort_order, s.student_starts_at)
          from public.interview_schedules s where s.team_id = t.id
        ), '[]'::jsonb)
      ) order by t.sort_order, t.team_code)
      from public.interview_teams t
      where t.year = p_year and t.round = p_round and t.active = true
    ), '[]'::jsonb),
    'validation', v_validation
  ) into v_plan;

  return v_plan;
end;
$$;

revoke all on function public.get_m5c_interview_plan_admin(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_plan_admin(int, admission_round) to authenticated;

create or replace function public.save_m5c_interview_plan(
  p_year int,
  p_round admission_round,
  p_teams jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_existing_status text;
  team_item jsonb;
  member_item jsonb;
  slot_item jsonb;
  v_team_id uuid;
  v_team_code text;
  v_validation jsonb;
  member_ord bigint;
  slot_ord bigint;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5c:plan:%s:%s', p_year, p_round::text), 0));

  if jsonb_typeof(p_teams) is distinct from 'array' then
    raise exception 'teams는 JSON array여야 합니다.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_teams) team
    cross join lateral jsonb_array_elements_text(coalesce(team -> 'memberUids', '[]'::jsonb)) uid
    where length(trim(uid)) > 0
    group by uid
    having count(*) > 1
  ) then
    raise exception '같은 면접위원을 둘 이상의 슬롯/조에 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_teams) team
    cross join lateral jsonb_array_elements(coalesce(team -> 'schedule', '[]'::jsonb)) slot
    group by slot ->> 'applicantId'
    having count(*) > 1
  ) then
    raise exception '같은 지원자를 둘 이상의 면접조/시간표에 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  select status into v_existing_status
  from public.interview_team_plans
  where year = p_year and round = p_round
  for update;
  if found and v_existing_status = 'finalized' then
    raise exception '이미 최종확정된 면접조 계획입니다. 대체위원 지정은 별도 superadmin RPC를 사용하세요.' using errcode = '55000';
  end if;

  insert into public.interview_team_plans
    (year, round, status, document_source_run_id, config_revision_id, revision, created_by, updated_by)
  values
    (p_year, p_round, 'draft', v_round.document_decision_run_id, v_round.config_revision_id, 1, caller::text, caller::text)
  on conflict (year, round) do update set
    status = 'draft',
    document_source_run_id = excluded.document_source_run_id,
    config_revision_id = excluded.config_revision_id,
    revision = public.interview_team_plans.revision + 1,
    updated_at = now(),
    updated_by = caller::text;

  delete from public.interview_teams where year = p_year and round = p_round;

  for team_item in select value from jsonb_array_elements(p_teams)
  loop
    if jsonb_typeof(team_item) is distinct from 'object' then
      raise exception '각 team 항목은 JSON object여야 합니다.' using errcode = '22023';
    end if;

    v_team_id := coalesce(nullif(team_item ->> 'teamId', '')::uuid, gen_random_uuid());
    v_team_code := trim(coalesce(team_item ->> 'teamCode', ''));
    if length(v_team_code) = 0 then
      raise exception 'teamCode는 필수입니다.' using errcode = '23514';
    end if;

    insert into public.interview_teams
      (id, year, round, team_code, location, sort_order, created_by, updated_by)
    values
      (v_team_id, p_year, p_round, v_team_code, nullif(trim(team_item ->> 'location'), ''),
       coalesce((team_item ->> 'sortOrder')::int, 0), caller::text, caller::text);

    if jsonb_typeof(coalesce(team_item -> 'memberUids', '[]'::jsonb)) is distinct from 'array' then
      raise exception '%조 memberUids는 JSON array여야 합니다.', v_team_code using errcode = '22023';
    end if;

    for member_item, member_ord in
      select value, ordinality from jsonb_array_elements(coalesce(team_item -> 'memberUids', '[]'::jsonb)) with ordinality
    loop
      if member_ord > 2 then
        raise exception '%조 면접위원은 최대 2명까지만 저장할 수 있습니다.', v_team_code using errcode = '23514';
      end if;
      insert into public.interview_team_members
        (team_id, year, round, evaluator_uid, member_slot)
      values
        (v_team_id, p_year, p_round, trim(both '"' from member_item::text)::uuid, member_ord::smallint);
    end loop;

    if jsonb_typeof(coalesce(team_item -> 'schedule', '[]'::jsonb)) is distinct from 'array' then
      raise exception '%조 schedule은 JSON array여야 합니다.', v_team_code using errcode = '22023';
    end if;

    for slot_item, slot_ord in
      select value, ordinality from jsonb_array_elements(coalesce(team_item -> 'schedule', '[]'::jsonb)) with ordinality
    loop
      insert into public.interview_schedules
        (team_id, year, round, applicant_id,
         student_starts_at, student_ends_at, parent_starts_at, parent_ends_at, sort_order)
      values
        (v_team_id, p_year, p_round, (slot_item ->> 'applicantId')::uuid,
         (slot_item ->> 'studentStartsAt')::timestamptz,
         (slot_item ->> 'studentEndsAt')::timestamptz,
         (slot_item ->> 'parentStartsAt')::timestamptz,
         (slot_item ->> 'parentEndsAt')::timestamptz,
         coalesce((slot_item ->> 'sortOrder')::int, slot_ord::int - 1));
    end loop;
  end loop;

  v_validation := public._m5c_validate_interview_plan(p_year, p_round);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview_plan.saved', 'interview_team_plans',
     p_year::text || '_' || p_round::text, 'interview',
     jsonb_build_object('teamCount', jsonb_array_length(p_teams), 'complete', v_validation -> 'complete'));

  return v_validation || jsonb_build_object('status', 'draft');
end;
$$;

revoke all on function public.save_m5c_interview_plan(int, admission_round, jsonb) from public, anon;
grant execute on function public.save_m5c_interview_plan(int, admission_round, jsonb) to authenticated;

create or replace function public.finalize_m5c_interview_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_plan_status text;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5c:plan:%s:%s', p_year, p_round::text), 0));

  select status into v_plan_status
  from public.interview_team_plans
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception '최종확정할 면접조 계획 draft가 없습니다.' using errcode = 'P0002';
  end if;
  if v_plan_status = 'finalized' then
    raise exception '이미 최종확정된 면접조 계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5c_validate_interview_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '면접조 계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.evaluation_roster er
  set interview_team_id = s.team_id,
      roster_revision = er.roster_revision + 1,
      updated_at = now()
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and s.applicant_id = er.applicant_id;

  update public.interview_team_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview_plan.finalized', 'interview_team_plans',
     p_year::text || '_' || p_round::text, 'interview',
     jsonb_build_object('candidateCount', v_validation -> 'candidateCount', 'teamCount', v_validation -> 'teamCount'));

  return public._m5c_validate_interview_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5c_interview_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5c_interview_plan(int, admission_round) to authenticated;

-- ============================================================
-- 5. evaluator workspace
-- ============================================================

create or replace function public.get_m5c_interview_workspace(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_team record;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_schedule jsonb;
  v_plan_config_revision_id uuid;
begin
  caller := public._m5c_require_interview_user(p_year, p_round);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select t.* into v_team
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  join public.interview_team_members m on m.team_id = t.id
  where p.year = p_year and p.round = p_round
    and p.status = 'finalized'
    and t.active = true
    and m.evaluator_uid = caller
  limit 1;

  if not found then
    raise exception '현재 평가자에게 최종확정된 면접조 배정이 없습니다.' using errcode = '42501';
  end if;

  select p.config_revision_id into v_plan_config_revision_id
  from public.interview_team_plans p
  where p.year = p_year and p.round = p_round and p.status = 'finalized';

  v_student_params := public._m5c_interview_params(v_plan_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_plan_config_revision_id, 'parent');

  select coalesce(jsonb_agg(jsonb_build_object(
    'scheduleId', s.id,
    'applicantId', er.applicant_id,
    'examNo', er.exam_no,
    'displayName', er.display_name,
    'studentStartsAt', s.student_starts_at,
    'studentEndsAt', s.student_ends_at,
    'parentStartsAt', s.parent_starts_at,
    'parentEndsAt', s.parent_ends_at,
    'sortOrder', s.sort_order,
    'myScore', case when si.id is null then null else jsonb_build_object(
      'scoreId', si.id,
      'student', jsonb_build_object(
        'items', si.student_items,
        'memo', si.student_memo,
        'submissionState', si.student_submission_state,
        'revision', si.student_revision,
        'serverComputed', si.student_server_computed,
        'clientUpdatedAt', si.student_client_updated_at,
        'submittedAt', si.student_submitted_at
      ),
      'parent', jsonb_build_object(
        'items', si.parent_items,
        'memo', si.parent_memo,
        'submissionState', si.parent_submission_state,
        'revision', si.parent_revision,
        'serverComputed', si.parent_server_computed,
        'clientUpdatedAt', si.parent_client_updated_at,
        'submittedAt', si.parent_submitted_at
      )
    ) end
  ) order by s.sort_order, s.student_starts_at), '[]'::jsonb)
  into v_schedule
  from public.interview_schedules s
  join public.evaluation_roster er on er.applicant_id = s.applicant_id
  left join public.scores_interview si
    on si.applicant_id = s.applicant_id and si.evaluator_uid = caller
  where s.team_id = v_team.id;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'serverNow', now(),
    'areaOpen', v_round.stage_status = 'open' and 'interview'::evaluation_area = any(v_round.open_evaluation_areas),
    'team', jsonb_build_object(
      'teamId', v_team.id,
      'teamCode', v_team.team_code,
      'location', v_team.location
    ),
    'student', jsonb_build_object(
      'criteria', v_student_params -> 'criteria',
      'perEvaluatorMax', (v_student_params ->> 'perEvaluatorMax')::numeric,
      'durationMinutes', (v_student_params ->> 'durationMinutes')::int
    ),
    'parent', jsonb_build_object(
      'criteria', v_parent_params -> 'criteria',
      'perEvaluatorMax', (v_parent_params ->> 'perEvaluatorMax')::numeric,
      'durationMinutes', (v_parent_params ->> 'durationMinutes')::int
    ),
    'schedule', v_schedule
  );
end;
$$;

revoke all on function public.get_m5c_interview_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_workspace(int, admission_round) to authenticated;

-- ============================================================
-- 6. section별 draft 저장 — stale replay 차단
-- ============================================================

create or replace function public.save_interview_score_draft(
  p_applicant_id uuid,
  p_section text,
  p_items jsonb,
  p_memo text,
  p_client_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_existing public.scores_interview%rowtype;
  v_total numeric;
  v_accepted boolean := true;
  v_current_total numeric;
  v_current_client_updated_at timestamptz;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '면접 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5c_require_interviewer(p_applicant_id);

  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;

  if not exists (
    select 1 from public.admission_rounds ar
    where ar.year = v_year and ar.round = v_round
      and ar.stage_status = 'open'
      and 'interview'::evaluation_area = any(ar.open_evaluation_areas)
  ) then
    raise exception '면접 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5c:score:%s:%s', p_applicant_id::text, caller::text), 0));

  v_total := public._m5c_validate_and_total(v_config_revision_id, p_section, p_items, false);

  select * into v_existing
  from public.scores_interview
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if p_section = 'student' then
    if v_existing.id is not null and v_existing.student_submission_state = 'submitted' then
      raise exception '이미 제출확정된 학생면접 채점입니다. 수정하려면 superadmin에게 학생면접 재개방을 요청하세요.' using errcode = '55000';
    end if;
    if v_existing.id is not null
       and v_existing.student_client_updated_at is not null
       and v_existing.student_client_updated_at >= p_client_updated_at then
      v_accepted := false;
      v_current_total := (v_existing.student_server_computed ->> 'draftTotal')::numeric;
      v_current_client_updated_at := v_existing.student_client_updated_at;
    else
      insert into public.scores_interview
        (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
         student_items, student_memo, student_server_computed, student_submission_state,
         student_revision, student_client_updated_at)
      values
        (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
         p_items, p_memo, jsonb_build_object('draftTotal', v_total, 'valid', false), 'draft', 1, p_client_updated_at)
      on conflict (applicant_id, evaluator_uid) do update set
        config_revision_id = excluded.config_revision_id,
        team_id = excluded.team_id,
        student_items = excluded.student_items,
        student_memo = excluded.student_memo,
        student_server_computed = excluded.student_server_computed,
        student_submission_state = 'draft',
        student_revision = public.scores_interview.student_revision + 1,
        student_client_updated_at = excluded.student_client_updated_at,
        student_submitted_at = null,
        updated_at = now();
      v_current_total := v_total;
      v_current_client_updated_at := p_client_updated_at;
    end if;
  else
    if v_existing.id is not null and v_existing.parent_submission_state = 'submitted' then
      raise exception '이미 제출확정된 학부모면접 채점입니다. 수정하려면 superadmin에게 학부모면접 재개방을 요청하세요.' using errcode = '55000';
    end if;
    if v_existing.id is not null
       and v_existing.parent_client_updated_at is not null
       and v_existing.parent_client_updated_at >= p_client_updated_at then
      v_accepted := false;
      v_current_total := (v_existing.parent_server_computed ->> 'draftTotal')::numeric;
      v_current_client_updated_at := v_existing.parent_client_updated_at;
    else
      insert into public.scores_interview
        (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
         parent_items, parent_memo, parent_server_computed, parent_submission_state,
         parent_revision, parent_client_updated_at)
      values
        (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
         p_items, p_memo, jsonb_build_object('draftTotal', v_total, 'valid', false), 'draft', 1, p_client_updated_at)
      on conflict (applicant_id, evaluator_uid) do update set
        config_revision_id = excluded.config_revision_id,
        team_id = excluded.team_id,
        parent_items = excluded.parent_items,
        parent_memo = excluded.parent_memo,
        parent_server_computed = excluded.parent_server_computed,
        parent_submission_state = 'draft',
        parent_revision = public.scores_interview.parent_revision + 1,
        parent_client_updated_at = excluded.parent_client_updated_at,
        parent_submitted_at = null,
        updated_at = now();
      v_current_total := v_total;
      v_current_client_updated_at := p_client_updated_at;
    end if;
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'section', p_section,
    'draftTotal', v_current_total,
    'serverClientUpdatedAt', v_current_client_updated_at,
    'submissionState', case
      when p_section = 'student' then coalesce((select student_submission_state from public.scores_interview where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
      else coalesce((select parent_submission_state from public.scores_interview where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
    end
  );
end;
$$;

revoke all on function public.save_interview_score_draft(uuid, text, jsonb, text, timestamptz) from public, anon;
grant execute on function public.save_interview_score_draft(uuid, text, jsonb, text, timestamptz) to authenticated;

-- ============================================================
-- 7. section별 제출확정 — 독립 잠금
-- ============================================================

create or replace function public.submit_interview_score(
  p_applicant_id uuid,
  p_section text,
  p_items jsonb,
  p_memo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_existing public.scores_interview%rowtype;
  v_total numeric;
  v_score_id uuid;
  v_revision int;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '면접 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5c_require_interviewer(p_applicant_id);

  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;

  if not exists (
    select 1 from public.admission_rounds ar
    where ar.year = v_year and ar.round = v_round
      and ar.stage_status = 'open'
      and 'interview'::evaluation_area = any(ar.open_evaluation_areas)
  ) then
    raise exception '면접 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5c:score:%s:%s', p_applicant_id::text, caller::text), 0));

  select * into v_existing
  from public.scores_interview
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if p_section = 'student'
     and v_existing.id is not null
     and v_existing.student_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학생면접 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;
  if p_section = 'parent'
     and v_existing.id is not null
     and v_existing.parent_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학부모면접 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  v_total := public._m5c_validate_and_total(v_config_revision_id, p_section, p_items, true);

  if p_section = 'student' then
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       student_items, student_memo, student_server_computed, student_submission_state,
       student_revision, student_client_updated_at, student_submitted_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id),
       'submitted', coalesce(v_existing.student_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      team_id = excluded.team_id,
      student_items = excluded.student_items,
      student_memo = excluded.student_memo,
      student_server_computed = excluded.student_server_computed,
      student_submission_state = 'submitted',
      student_revision = public.scores_interview.student_revision + 1,
      student_client_updated_at = now(),
      student_submitted_at = now(),
      updated_at = now()
    returning id, student_revision into v_score_id, v_revision;
  else
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       parent_items, parent_memo, parent_server_computed, parent_submission_state,
       parent_revision, parent_client_updated_at, parent_submitted_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id),
       'submitted', coalesce(v_existing.parent_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      team_id = excluded.team_id,
      parent_items = excluded.parent_items,
      parent_memo = excluded.parent_memo,
      parent_server_computed = excluded.parent_server_computed,
      parent_submission_state = 'submitted',
      parent_revision = public.scores_interview.parent_revision + 1,
      parent_client_updated_at = now(),
      parent_submitted_at = now(),
      updated_at = now()
    returning id, parent_revision into v_score_id, v_revision;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_year, v_round, 'user', caller::text,
     case when p_section = 'student' then 'score.interview.student.submitted' else 'score.interview.parent.submitted' end,
     'scores_interview', v_score_id::text, p_applicant_id::text, 'interview',
     jsonb_build_object('section', p_section, 'revision', v_revision));

  return jsonb_build_object(
    'scoreId', v_score_id,
    'section', p_section,
    'total', v_total,
    'submissionState', 'submitted',
    'revision', v_revision
  );
end;
$$;

revoke all on function public.submit_interview_score(uuid, text, jsonb, text) from public, anon;
grant execute on function public.submit_interview_score(uuid, text, jsonb, text) to authenticated;

-- ============================================================
-- 8. 면접 aggregate / trigger / 경보
-- ============================================================

create or replace function public._compute_interview_aggregate(
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_student_required int;
  v_parent_required int;
  v_student_submitted int;
  v_parent_submitted int;
  v_student_average numeric;
  v_parent_average numeric;
  v_student_gap numeric;
  v_parent_gap numeric;
  v_student_score numeric;
  v_parent_score numeric;
  v_student_summary jsonb;
  v_parent_summary jsonb;
begin
  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_team_id is null then
    return jsonb_build_object(
      'student', jsonb_build_object('complete', false, 'score', null, 'required', null, 'submitted', 0, 'gap', null),
      'parent', jsonb_build_object('complete', false, 'score', null, 'required', null, 'submitted', 0, 'gap', null),
      'sourceRevisionSummary', '{}'::jsonb,
      'functionVersion', 'm5c-interview-aggregate-v1'
    );
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;
  v_student_params := public._m5c_interview_params(v_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_config_revision_id, 'parent');
  v_student_required := (v_student_params ->> 'requiredSubmissions')::int;
  v_parent_required := (v_parent_params ->> 'requiredSubmissions')::int;

  select count(*)::int,
         avg((si.student_server_computed ->> 'total')::numeric),
         max((si.student_server_computed ->> 'total')::numeric) - min((si.student_server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', si.id,
           'evaluatorUid', si.evaluator_uid,
           'revision', si.student_revision
         ) order by si.evaluator_uid), '[]'::jsonb)
    into v_student_submitted, v_student_average, v_student_gap, v_student_summary
  from public.scores_interview si
  join public.interview_team_members m
    on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and si.team_id = v_team_id
    and si.student_submission_state = 'submitted'
    and coalesce((si.student_server_computed ->> 'valid')::boolean, false) = true;

  select count(*)::int,
         avg((si.parent_server_computed ->> 'total')::numeric),
         max((si.parent_server_computed ->> 'total')::numeric) - min((si.parent_server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', si.id,
           'evaluatorUid', si.evaluator_uid,
           'revision', si.parent_revision
         ) order by si.evaluator_uid), '[]'::jsonb)
    into v_parent_submitted, v_parent_average, v_parent_gap, v_parent_summary
  from public.scores_interview si
  join public.interview_team_members m
    on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and si.team_id = v_team_id
    and si.parent_submission_state = 'submitted'
    and coalesce((si.parent_server_computed ->> 'valid')::boolean, false) = true;

  if v_student_submitted < v_student_required then
    v_student_score := null;
  else
    v_student_score := least((v_student_params ->> 'max')::numeric, v_student_average);
  end if;
  if v_parent_submitted < v_parent_required then
    v_parent_score := null;
  else
    v_parent_score := least((v_parent_params ->> 'max')::numeric, v_parent_average);
  end if;

  return jsonb_build_object(
    'student', jsonb_build_object(
      'complete', v_student_submitted >= v_student_required,
      'score', v_student_score,
      'required', v_student_required,
      'submitted', v_student_submitted,
      'gap', case when v_student_submitted >= 2 then v_student_gap else null end
    ),
    'parent', jsonb_build_object(
      'complete', v_parent_submitted >= v_parent_required,
      'score', v_parent_score,
      'required', v_parent_required,
      'submitted', v_parent_submitted,
      'gap', case when v_parent_submitted >= 2 then v_parent_gap else null end
    ),
    'sourceRevisionSummary', jsonb_build_object(
      'student', v_student_summary,
      'parent', v_parent_summary
    ),
    'functionVersion', 'm5c-interview-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_interview_aggregate(
  p_applicant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_agg jsonb;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_student_gap numeric;
  v_parent_gap numeric;
  v_gap_summary text;
  v_related uuid[];
begin
  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found or v_team_id is null then
    delete from public.deep_interview_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;

  v_agg := public._compute_interview_aggregate(p_applicant_id);

  insert into public.deep_interview_aggregates
    (applicant_id, year, round, config_revision_id, team_id,
     student_complete, student_score, student_required, student_submitted, student_gap,
     parent_complete, parent_score, parent_required, parent_submitted, parent_gap,
     source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_year, v_round, v_config_revision_id, v_team_id,
     (v_agg #>> '{student,complete}')::boolean,
     nullif(v_agg #>> '{student,score}', '')::numeric,
     (v_agg #>> '{student,required}')::int,
     (v_agg #>> '{student,submitted}')::int,
     nullif(v_agg #>> '{student,gap}', '')::numeric,
     (v_agg #>> '{parent,complete}')::boolean,
     nullif(v_agg #>> '{parent,score}', '')::numeric,
     (v_agg #>> '{parent,required}')::int,
     (v_agg #>> '{parent,submitted}')::int,
     nullif(v_agg #>> '{parent,gap}', '')::numeric,
     v_agg -> 'sourceRevisionSummary', v_agg ->> 'functionVersion', now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    team_id = excluded.team_id,
    student_complete = excluded.student_complete,
    student_score = excluded.student_score,
    student_required = excluded.student_required,
    student_submitted = excluded.student_submitted,
    student_gap = excluded.student_gap,
    parent_complete = excluded.parent_complete,
    parent_score = excluded.parent_score,
    parent_required = excluded.parent_required,
    parent_submitted = excluded.parent_submitted,
    parent_gap = excluded.parent_gap,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = excluded.computed_at;

  v_student_params := public._m5c_interview_params(v_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_config_revision_id, 'parent');
  v_student_gap := nullif(v_agg #>> '{student,gap}', '')::numeric;
  v_parent_gap := nullif(v_agg #>> '{parent,gap}', '')::numeric;

  select coalesce(array_agg(distinct si.evaluator_uid), '{}'::uuid[])
    into v_related
  from public.scores_interview si
  join public.interview_team_members m on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and (si.student_submission_state = 'submitted' or si.parent_submission_state = 'submitted');

  if (v_student_gap is not null and v_student_gap >= (v_student_params ->> 'alertGap')::numeric)
     or (v_parent_gap is not null and v_parent_gap >= (v_parent_params ->> 'alertGap')::numeric) then
    v_gap_summary := concat_ws(' / ',
      case when v_student_gap is not null and v_student_gap >= (v_student_params ->> 'alertGap')::numeric
        then format('학생면접 위원 간 총점 편차 %s점(기준 %s)', v_student_gap, v_student_params ->> 'alertGap') end,
      case when v_parent_gap is not null and v_parent_gap >= (v_parent_params ->> 'alertGap')::numeric
        then format('학부모면접 위원 간 총점 편차 %s점(기준 %s)', v_parent_gap, v_parent_params ->> 'alertGap') end
    );

    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
    values
      (v_year, v_round, p_applicant_id, 'interview', 'scoreGap', 'warning', v_gap_summary, v_related)
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      related_evaluator_uids = excluded.related_evaluator_uids,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5c'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'interview' and alert_type = 'scoreGap' and status <> 'resolved';
  end if;

  if (v_agg #>> '{student,submitted}')::int < (v_agg #>> '{student,required}')::int
     or (v_agg #>> '{parent,submitted}')::int < (v_agg #>> '{parent,required}')::int then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary)
    values
      (v_year, v_round, p_applicant_id, 'interview', 'missingSubmission', 'warning',
       format('학생면접 제출 %s/%s · 학부모면접 제출 %s/%s',
         v_agg #>> '{student,submitted}', v_agg #>> '{student,required}',
         v_agg #>> '{parent,submitted}', v_agg #>> '{parent,required}'))
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5c'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'interview' and alert_type = 'missingSubmission' and status <> 'resolved';
  end if;
end;
$$;

create or replace function public._trg_refresh_interview_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_interview_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_interview_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._compute_interview_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_interview_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_interview_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_interview_aggregate on public.scores_interview;
create trigger trg_refresh_interview_aggregate
  after insert or update or delete on public.scores_interview
  for each row execute function public._trg_refresh_interview_aggregate();

-- ============================================================
-- 9. 관리자 진행현황 — 개별 위원 실제 점수 비노출
-- ============================================================

create or replace function public.get_m5c_interview_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'teamCode', t.team_code,
        'studentComplete', coalesce(a.student_complete, false),
        'studentScore', a.student_score,
        'studentRequired', a.student_required,
        'studentSubmitted', coalesce(a.student_submitted, 0),
        'studentGapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'interview'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
            and ea.summary like '%학생면접%'
        ),
        'parentComplete', coalesce(a.parent_complete, false),
        'parentScore', a.parent_score,
        'parentRequired', a.parent_required,
        'parentSubmitted', coalesce(a.parent_submitted, 0),
        'parentGapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'interview'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
            and ea.summary like '%학부모면접%'
        ),
        'computedAt', a.computed_at
      ) order by t.sort_order, s.sort_order, er.exam_no, er.display_name)
      from public.interview_schedules s
      join public.interview_teams t on t.id = s.team_id
      join public.evaluation_roster er on er.applicant_id = s.applicant_id
      left join public.deep_interview_aggregates a on a.applicant_id = er.applicant_id
      where s.year = p_year and s.round = p_round
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5c_interview_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_progress(int, admission_round) to authenticated;

-- ============================================================
-- 10. 독립 재개방 / 대체 평가위원
-- ============================================================

create or replace function public.reopen_interview_score(
  p_score_id uuid,
  p_section text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_applicant_id uuid;
  v_year int;
  v_round admission_round;
begin
  caller := public._require_superadmin();
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '재개방 사유는 최소 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  if p_section = 'student' then
    update public.scores_interview
    set student_submission_state = 'reopened',
        student_submitted_at = null,
        updated_at = now()
    where id = p_score_id
    returning applicant_id, year, round into v_applicant_id, v_year, v_round;
  else
    update public.scores_interview
    set parent_submission_state = 'reopened',
        parent_submitted_at = null,
        updated_at = now()
    where id = p_score_id
    returning applicant_id, year, round into v_applicant_id, v_year, v_round;
  end if;

  if not found then
    raise exception '해당 면접 채점 문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.interview.reopened', 'scores_interview',
     p_score_id::text, v_applicant_id::text, 'interview', '관리자 재개방',
     jsonb_build_object('section', p_section, 'reason', p_reason));
end;
$$;

revoke all on function public.reopen_interview_score(uuid, text, text) from public, anon;
grant execute on function public.reopen_interview_score(uuid, text, text) to authenticated;

create or replace function public.replace_m5c_interview_team_member(
  p_team_id uuid,
  p_old_evaluator_uid uuid,
  p_new_evaluator_uid uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_team record;
  v_slot smallint;
  r record;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '대체 평가위원 지정 사유는 최소 5자 이상 입력하세요.' using errcode = '23514';
  end if;
  if p_old_evaluator_uid = p_new_evaluator_uid then
    raise exception '기존 위원과 새 위원이 동일합니다.' using errcode = '23514';
  end if;

  select t.* into v_team
  from public.interview_teams t
  join public.interview_team_plans p on p.year = t.year and p.round = t.round
  where t.id = p_team_id and p.status = 'finalized'
  for update;
  if not found then
    raise exception '최종확정된 면접조를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = p_new_evaluator_uid and u.active = true
      and 'evaluator' = any(u.roles)
      and 'interview' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or v_team.year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or v_team.round = any(u.round_scopes))
  ) then
    raise exception '새 위원은 evaluator + interview 권한 및 해당 scope가 필요합니다.' using errcode = '42501';
  end if;

  select member_slot into v_slot
  from public.interview_team_members
  where team_id = p_team_id and evaluator_uid = p_old_evaluator_uid
  for update;
  if not found then
    raise exception '기존 위원이 해당 면접조에 속해 있지 않습니다.' using errcode = 'P0002';
  end if;

  update public.interview_team_members
  set evaluator_uid = p_new_evaluator_uid
  where team_id = p_team_id and member_slot = v_slot;

  for r in select applicant_id from public.interview_schedules where team_id = p_team_id
  loop
    perform public._refresh_interview_aggregate(r.applicant_id);
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, reason_code, metadata)
  values
    (v_team.year, v_team.round, 'user', caller::text, 'interview_team.member_replaced', 'interview_teams',
     p_team_id::text, 'interview', '대체 평가위원 지정',
     jsonb_build_object('oldEvaluatorUid', p_old_evaluator_uid, 'newEvaluatorUid', p_new_evaluator_uid, 'reason', p_reason));

  return jsonb_build_object(
    'teamId', p_team_id,
    'memberSlot', v_slot,
    'oldEvaluatorUid', p_old_evaluator_uid,
    'newEvaluatorUid', p_new_evaluator_uid
  );
end;
$$;

revoke all on function public.replace_m5c_interview_team_member(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.replace_m5c_interview_team_member(uuid, uuid, uuid, text) to authenticated;


-- ============================================================
-- M5c migration self-verification: 핵심 객체가 모두 생성되지 않으면 COMMIT 전 롤백
-- ============================================================
do $m5c_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regclass('public.interview_team_plans') is null then missing_objects := array_append(missing_objects, 'table:interview_team_plans'); end if;
  if to_regclass('public.interview_teams') is null then missing_objects := array_append(missing_objects, 'table:interview_teams'); end if;
  if to_regclass('public.interview_team_members') is null then missing_objects := array_append(missing_objects, 'table:interview_team_members'); end if;
  if to_regclass('public.interview_schedules') is null then missing_objects := array_append(missing_objects, 'table:interview_schedules'); end if;
  if to_regclass('public.scores_interview') is null then missing_objects := array_append(missing_objects, 'table:scores_interview'); end if;
  if to_regclass('public.deep_interview_aggregates') is null then missing_objects := array_append(missing_objects, 'table:deep_interview_aggregates'); end if;

  if to_regprocedure('public._m5c_interview_params(uuid,text)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_interview_params(uuid,text)'); end if;
  if to_regprocedure('public._m5c_require_interview_user(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_require_interview_user(integer,admission_round)'); end if;
  if to_regprocedure('public._m5c_validate_interview_plan(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_validate_interview_plan(integer,admission_round)'); end if;
  if to_regprocedure('public.get_m5c_interview_workspace(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'rpc:get_m5c_interview_workspace(integer,admission_round)'); end if;
  if to_regprocedure('public.save_interview_score_draft(uuid,text,jsonb,text,timestamp with time zone)') is null then missing_objects := array_append(missing_objects, 'rpc:save_interview_score_draft'); end if;
  if to_regprocedure('public.submit_interview_score(uuid,text,jsonb,text)') is null then missing_objects := array_append(missing_objects, 'rpc:submit_interview_score'); end if;
  if to_regprocedure('public._compute_interview_aggregate(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_compute_interview_aggregate(uuid)'); end if;
  if to_regprocedure('public._trg_refresh_interview_aggregate()') is null then missing_objects := array_append(missing_objects, 'function:_trg_refresh_interview_aggregate()'); end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_interview'
      and t.tgname = 'trg_refresh_interview_aggregate'
      and not t.tgisinternal
  ) then
    missing_objects := array_append(missing_objects, 'trigger:trg_refresh_interview_aggregate');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5C_00012_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5c_verify$;

commit;

select
  'M5C_00012_APPLIED'::text as migration_status,
  to_regprocedure('public._m5c_interview_params(uuid,text)') is not null as helper_present,
  to_regclass('public.scores_interview') is not null as score_table_present,
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_interview'
      and t.tgname = 'trg_refresh_interview_aggregate'
      and not t.tgisinternal
  ) as aggregate_trigger_present;
