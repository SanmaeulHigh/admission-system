-- 새봄고 입학전형 시스템 — M5a 심층역량평가 모둠 편성 (Sprint 5 시작)
-- 마스터 스펙 v1.2 섹션 3.14, M5a, 5.4.1 대응.
--
-- 핵심 불변조건
--   1) M5의 서류점수 기준은 "현재 aggregate"가 아니라 확정된 M4 final decisionRun 스냅샷이다.
--   2) 지원자는 해당 document final run의 passed 결과에 포함된 사람만, 정확히 1개 모둠에 배정한다.
--   3) 모둠별 주관찰위원은 정확히 2명이며 evaluator + group 영역 + 연도/차수 scope를 충족한다.
--   4) 순환 segment마다 group evaluator 전원의 관찰대상을 명시하고,
--      각 모둠에는 주관찰위원 최소 1명이 자기 모둠에 남아 있어야 한다.
--   5) 클라이언트 직접 write는 금지한다. draft 저장/최종확정은 SECURITY DEFINER RPC만 사용한다.

-- ============================================================
-- 1. M4 final decisionRun 포인터 — M5 documentCarry 스냅샷의 단일 기준
-- ============================================================

alter table public.admission_rounds
  add column if not exists document_decision_run_id uuid
  references public.decision_runs (id);

comment on column public.admission_rounds.document_decision_run_id is
  '확정된 1차 서류사정(final decisionRun) 포인터. M5 이후 documentCarry/모둠 균형표는 이 run의 decision_results.total_score 스냅샷만 사용한다.';

create or replace function public._capture_document_final_run_pointer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.decision_type = 'document'
     and new.mode = 'final'
     and new.status = 'finalized'
     and old.status is distinct from 'finalized' then
    update public.admission_rounds
    set document_decision_run_id = new.id,
        updated_at = now(),
        updated_by = coalesce(new.finalized_by, new.created_by)
    where year = new.year and round = new.round;
  end if;
  return new;
end;
$$;

revoke all on function public._capture_document_final_run_pointer() from public, anon, authenticated;

drop trigger if exists trg_capture_document_final_run_pointer on public.decision_runs;
create trigger trg_capture_document_final_run_pointer
  after update of status on public.decision_runs
  for each row execute function public._capture_document_final_run_pointer();

-- migration 적용 전에 이미 M4 final을 확정한 dev DB도 최신 finalized run을 연결한다.
with latest_final as (
  select distinct on (dr.year, dr.round)
         dr.year, dr.round, dr.id, dr.finalized_by, dr.created_by
  from public.decision_runs dr
  where dr.decision_type = 'document'
    and dr.mode = 'final'
    and dr.status = 'finalized'
  order by dr.year, dr.round, dr.finalized_at desc nulls last, dr.created_at desc
)
update public.admission_rounds ar
set document_decision_run_id = src.id,
    updated_at = now(),
    updated_by = coalesce(src.finalized_by, src.created_by)
from latest_final src
where ar.year = src.year
  and ar.round = src.round
  and ar.document_decision_run_id is null;

-- ============================================================
-- 2. M5a relational model
-- ============================================================

create type group_plan_status as enum ('draft', 'finalized');

create table public.deep_group_plans (
  year int not null,
  round admission_round not null,
  status group_plan_status not null default 'draft',
  document_source_run_id uuid not null references public.decision_runs (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.deep_groups (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  group_code text not null check (length(trim(group_code)) between 1 and 20),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (year, round, group_code),
  unique (id, year, round),
  foreign key (year, round) references public.deep_group_plans (year, round) on delete cascade
);

create table public.deep_group_members (
  group_id uuid not null,
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.evaluation_roster (applicant_id) on delete cascade,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  primary key (group_id, applicant_id),
  unique (year, round, applicant_id),
  foreign key (group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

create table public.deep_group_primary_observers (
  group_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  observer_slot smallint not null check (observer_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (group_id, observer_slot),
  unique (group_id, evaluator_uid),
  unique (year, round, evaluator_uid),
  foreign key (group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

create table public.deep_group_rotation_segments (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  segment_code text not null check (length(trim(segment_code)) between 1 and 30),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  check (ends_at > starts_at),
  unique (year, round, segment_code),
  unique (id, year, round),
  foreign key (year, round) references public.deep_group_plans (year, round) on delete cascade
);

create table public.deep_group_rotation_assignments (
  segment_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  target_group_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (segment_id, evaluator_uid),
  foreign key (segment_id, year, round)
    references public.deep_group_rotation_segments (id, year, round) on delete cascade,
  foreign key (target_group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

comment on table public.deep_group_plans is
  'M5a 모둠편성 계획 header. document_source_run_id는 계획 생성 시점의 M4 final decisionRun 스냅샷으로 고정한다.';
comment on table public.deep_group_primary_observers is
  '모둠별 주관찰 2인. 동일 evaluator는 같은 연도/차수에서 둘 이상의 home group 주관찰위원이 될 수 없다.';
comment on table public.deep_group_rotation_assignments is
  'segment별 evaluator의 관찰 대상 모둠. final 계획에서는 group evaluator 전원에게 segment별 정확히 1개 target group이 있어야 한다.';

-- ============================================================
-- 3. RLS — group 영역 evaluator는 운영정보 read, write는 RPC 전용
-- ============================================================

alter table public.deep_group_plans enable row level security;
alter table public.deep_groups enable row level security;
alter table public.deep_group_members enable row level security;
alter table public.deep_group_primary_observers enable row level security;
alter table public.deep_group_rotation_segments enable row level security;
alter table public.deep_group_rotation_assignments enable row level security;

create policy deep_group_plans_select_staff
  on public.deep_group_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_plans.round = any(u.round_scopes))
      )
    )
  );

create policy deep_groups_select_staff
  on public.deep_groups for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_groups.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_groups.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_members_select_staff
  on public.deep_group_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_members.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_members.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_primary_observers_select_staff
  on public.deep_group_primary_observers for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_primary_observers.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_primary_observers.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_rotation_segments_select_staff
  on public.deep_group_rotation_segments for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_rotation_segments.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_rotation_segments.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_rotation_assignments_select_staff
  on public.deep_group_rotation_assignments for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_rotation_assignments.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_rotation_assignments.round = any(u.round_scopes))
      )
    )
  );

-- INSERT/UPDATE/DELETE policy 없음 = 클라이언트 직접 write 전면 금지.

-- ============================================================
-- 4. private helpers
-- ============================================================

create or replace function public._m5a_current_document_run_id(
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
  v_run_id uuid;
begin
  select ar.document_decision_run_id
    into v_run_id
  from public.admission_rounds ar
  where ar.year = p_year and ar.round = p_round;

  if v_run_id is null then
    raise exception 'M5a를 시작할 수 없습니다. 먼저 M4 1차 사정을 final로 확정하세요.';
  end if;

  if not exists (
    select 1
    from public.decision_runs dr
    where dr.id = v_run_id
      and dr.year = p_year
      and dr.round = p_round
      and dr.decision_type = 'document'
      and dr.mode = 'final'
      and dr.status = 'finalized'
  ) then
    raise exception 'admission_round의 document_decision_run_id가 유효한 finalized document final run을 가리키지 않습니다.';
  end if;

  return v_run_id;
end;
$$;

revoke all on function public._m5a_current_document_run_id(int, admission_round) from public, anon, authenticated;

create or replace function public._m5a_user_is_group_evaluator(
  p_uid uuid,
  p_year int,
  p_round admission_round
)
returns boolean
language sql
security definer
set search_path = public
volatile
as $$
  select exists (
    select 1
    from public.users u
    where u.id = p_uid
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'group' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  );
$$;

revoke all on function public._m5a_user_is_group_evaluator(uuid, int, admission_round) from public, anon, authenticated;

create or replace function public._m5a_validate_plan(
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
  v_plan record;
  v_current_run_id uuid;
  v_candidate_count int := 0;
  v_assigned_count int := 0;
  v_group_count int := 0;
  v_segment_count int := 0;
  v_group_evaluator_count int := 0;
  v_issue_count int := 0;
  v_items jsonb;
  v_count int;
  v_issues jsonb := '[]'::jsonb;
begin
  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round;

  if v_plan is null then
    return jsonb_build_object(
      'complete', false,
      'status', null,
      'candidateCount', 0,
      'assignedCount', 0,
      'groupCount', 0,
      'segmentCount', 0,
      'groupEvaluatorCount', 0,
      'blockingIssues', jsonb_build_array(
        jsonb_build_object('code', 'PLAN_MISSING', 'message', '저장된 모둠편성 계획이 없습니다.')
      )
    );
  end if;

  begin
    v_current_run_id := public._m5a_current_document_run_id(p_year, p_round);
  exception when others then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'DOCUMENT_SOURCE_INVALID', 'message', sqlerrm)
    );
  end;

  if v_current_run_id is not null and v_current_run_id <> v_plan.document_source_run_id then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'DOCUMENT_SOURCE_STALE',
        'message', '모둠편성 계획의 1차 사정 스냅샷이 현재 확정 run과 다릅니다.',
        'planRunId', v_plan.document_source_run_id,
        'currentRunId', v_current_run_id
      )
    );
  end if;

  select count(*) into v_candidate_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  select count(*) into v_assigned_count
  from public.deep_group_members gm
  where gm.year = p_year and gm.round = p_round;

  select count(*) into v_group_count
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true;

  select count(*) into v_segment_count
  from public.deep_group_rotation_segments s
  where s.year = p_year and s.round = p_round;

  select count(*) into v_group_evaluator_count
  from public.users u
  where u.active = true
    and 'evaluator' = any(u.roles)
    and 'group' = any(u.assigned_areas)
    and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
    and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes));

  if v_group_count = 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'GROUP_MISSING', 'message', '최소 1개 이상의 모둠이 필요합니다.')
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', dr.applicant_id,
      'examNo', er.exam_no,
      'displayName', er.display_name
    ) order by er.exam_no, er.display_name), '[]'::jsonb)
    into v_items
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed'
    and not exists (
      select 1
      from public.deep_group_members gm
      where gm.year = p_year and gm.round = p_round and gm.applicant_id = dr.applicant_id
    );

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'CANDIDATE_UNASSIGNED',
        'message', format('1차 합격자 %s명이 아직 모둠에 배정되지 않았습니다.', jsonb_array_length(v_items)),
        'items', v_items
      )
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', gm.applicant_id,
      'groupId', gm.group_id
    ) order by gm.applicant_id), '[]'::jsonb)
    into v_items
  from public.deep_group_members gm
  where gm.year = p_year and gm.round = p_round
    and not exists (
      select 1
      from public.decision_results dr
      where dr.run_id = v_plan.document_source_run_id
        and dr.applicant_id = gm.applicant_id
        and dr.outcome = 'passed'
    );

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'CANDIDATE_INELIGIBLE',
        'message', 'M4 final passed 결과에 포함되지 않은 지원자가 모둠에 배정되어 있습니다.',
        'items', v_items
      )
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'groupId', g.id,
      'groupCode', g.group_code
    ) order by g.sort_order, g.group_code), '[]'::jsonb)
    into v_items
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true
    and not exists (select 1 from public.deep_group_members gm where gm.group_id = g.id);

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'EMPTY_GROUP', 'message', '지원자가 1명도 없는 모둠이 있습니다.', 'items', v_items)
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'groupId', x.group_id,
      'groupCode', x.group_code,
      'primaryCount', x.primary_count
    ) order by x.sort_order, x.group_code), '[]'::jsonb)
    into v_items
  from (
    select g.id as group_id, g.group_code, g.sort_order, count(po.evaluator_uid) as primary_count
    from public.deep_groups g
    left join public.deep_group_primary_observers po on po.group_id = g.id
    where g.year = p_year and g.round = p_round and g.active = true
    group by g.id, g.group_code, g.sort_order
    having count(po.evaluator_uid) <> 2
  ) x;

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'PRIMARY_OBSERVER_COUNT', 'message', '모든 모둠에 주관찰위원 2인을 배정해야 합니다.', 'items', v_items)
    );
  end if;

  select count(*) into v_count
  from public.deep_group_primary_observers po
  where po.year = p_year and po.round = p_round
    and not public._m5a_user_is_group_evaluator(po.evaluator_uid, p_year, p_round);

  if v_count > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'PRIMARY_OBSERVER_INVALID', 'message', format('주관찰위원 %s건이 현재 group evaluator 권한·scope를 충족하지 않습니다.', v_count))
    );
  end if;

  if v_segment_count = 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'ROTATION_SEGMENT_MISSING', 'message', '순환 관찰 segment를 최소 1개 생성해야 합니다.')
    );
  end if;

  select count(*) into v_count
  from public.deep_group_rotation_segments a
  join public.deep_group_rotation_segments b
    on a.year = b.year and a.round = b.round and a.id < b.id
   and a.starts_at < b.ends_at and b.starts_at < a.ends_at
  where a.year = p_year and a.round = p_round;

  if v_count > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'ROTATION_SEGMENT_OVERLAP', 'message', format('시간이 겹치는 순환 segment 조합이 %s건 있습니다.', v_count))
    );
  end if;

  select count(*) into v_count
  from public.deep_group_rotation_segments s
  cross join public.users u
  where s.year = p_year and s.round = p_round
    and u.active = true
    and 'evaluator' = any(u.roles)
    and 'group' = any(u.assigned_areas)
    and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
    and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    and not exists (
      select 1
      from public.deep_group_rotation_assignments ra
      where ra.segment_id = s.id and ra.evaluator_uid = u.id
    );

  if v_count > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'ROTATION_ASSIGNMENT_MISSING', 'message', format('segment별 group evaluator 관찰대상 미배정이 %s건 있습니다.', v_count))
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'segmentId', x.segment_id,
      'segmentCode', x.segment_code,
      'groupId', x.group_id,
      'groupCode', x.group_code,
      'primaryHomeCount', x.primary_home_count
    ) order by x.segment_sort, x.group_sort), '[]'::jsonb)
    into v_items
  from (
    select s.id as segment_id, s.segment_code, s.sort_order as segment_sort,
           g.id as group_id, g.group_code, g.sort_order as group_sort,
           count(*) filter (where ra.target_group_id = g.id) as primary_home_count
    from public.deep_group_rotation_segments s
    cross join public.deep_groups g
    join public.deep_group_primary_observers po on po.group_id = g.id
    left join public.deep_group_rotation_assignments ra
      on ra.segment_id = s.id and ra.evaluator_uid = po.evaluator_uid
    where s.year = p_year and s.round = p_round
      and g.year = p_year and g.round = p_round and g.active = true
    group by s.id, s.segment_code, s.sort_order, g.id, g.group_code, g.sort_order
    having count(*) filter (where ra.target_group_id = g.id) < 1
  ) x;

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'PRIMARY_OBSERVER_COVERAGE',
        'message', '모든 segment에서 각 모둠 주관찰위원 최소 1인이 자기 모둠에 남아 있어야 합니다.',
        'items', v_items
      )
    );
  end if;

  v_issue_count := jsonb_array_length(v_issues);

  return jsonb_build_object(
    'complete', v_issue_count = 0,
    'status', v_plan.status,
    'revision', v_plan.revision,
    'documentSourceRunId', v_plan.document_source_run_id,
    'currentDocumentSourceRunId', v_current_run_id,
    'candidateCount', v_candidate_count,
    'assignedCount', v_assigned_count,
    'groupCount', v_group_count,
    'segmentCount', v_segment_count,
    'groupEvaluatorCount', v_group_evaluator_count,
    'blockingIssues', v_issues
  );
end;
$$;

revoke all on function public._m5a_validate_plan(int, admission_round) from public, anon, authenticated;

-- ============================================================
-- 5. 관리자 조회 RPC — document final snapshot 점수를 함께 반환
-- ============================================================

create or replace function public.get_m5a_group_plan(
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
  v_current_run_id uuid;
  v_source_run_id uuid;
  v_plan record;
  v_candidates jsonb;
  v_evaluators jsonb;
  v_groups jsonb;
  v_segments jsonb;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  v_current_run_id := public._m5a_current_document_run_id(p_year, p_round);

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round;

  -- 이미 draft/final 계획이 있으면 그 계획에 고정된 document snapshot을 표시한다.
  -- 현재 M4 pointer가 바뀌었더라도 기존 plan 화면의 평균을 조용히 새 점수로 바꾸지 않는다.
  v_source_run_id := coalesce(v_plan.document_source_run_id, v_current_run_id);

  select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', dr.applicant_id,
      'examNo', er.exam_no,
      'displayName', er.display_name,
      'documentScore', dr.total_score,
      'rank', dr.rank
    ) order by dr.rank, er.exam_no, er.display_name), '[]'::jsonb)
    into v_candidates
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  where dr.run_id = v_source_run_id and dr.outcome = 'passed';

  select coalesce(jsonb_agg(jsonb_build_object(
      'uid', u.id,
      'displayName', u.display_name
    ) order by u.display_name, u.id), '[]'::jsonb)
    into v_evaluators
  from public.users u
  where u.active = true
    and 'evaluator' = any(u.roles)
    and 'group' = any(u.assigned_areas)
    and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
    and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes));

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', g.id,
      'groupCode', g.group_code,
      'sortOrder', g.sort_order,
      'members', coalesce((
        select jsonb_agg(gm.applicant_id order by gm.sort_order, gm.applicant_id)
        from public.deep_group_members gm where gm.group_id = g.id
      ), '[]'::jsonb),
      'primaryObservers', coalesce((
        select jsonb_agg(po.evaluator_uid order by po.observer_slot)
        from public.deep_group_primary_observers po where po.group_id = g.id
      ), '[]'::jsonb)
    ) order by g.sort_order, g.group_code), '[]'::jsonb)
    into v_groups
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id,
      'segmentCode', s.segment_code,
      'startsAt', s.starts_at,
      'endsAt', s.ends_at,
      'sortOrder', s.sort_order,
      'assignments', coalesce((
        select jsonb_agg(jsonb_build_object(
          'evaluatorUid', ra.evaluator_uid,
          'targetGroupId', ra.target_group_id
        ) order by ra.evaluator_uid)
        from public.deep_group_rotation_assignments ra where ra.segment_id = s.id
      ), '[]'::jsonb)
    ) order by s.sort_order, s.starts_at), '[]'::jsonb)
    into v_segments
  from public.deep_group_rotation_segments s
  where s.year = p_year and s.round = p_round;

  if v_plan is null then
    v_validation := jsonb_build_object(
      'complete', false,
      'status', null,
      'candidateCount', jsonb_array_length(v_candidates),
      'assignedCount', 0,
      'groupCount', 0,
      'segmentCount', 0,
      'groupEvaluatorCount', jsonb_array_length(v_evaluators),
      'blockingIssues', jsonb_build_array(
        jsonb_build_object('code', 'PLAN_MISSING', 'message', '저장된 모둠편성 계획이 없습니다.')
      )
    );
  else
    v_validation := public._m5a_validate_plan(p_year, p_round);
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentSourceRunId', v_source_run_id,
    'currentDocumentSourceRunId', v_current_run_id,
    'planStatus', v_plan.status,
    'planRevision', v_plan.revision,
    'candidates', v_candidates,
    'groupEvaluators', v_evaluators,
    'groups', v_groups,
    'segments', v_segments,
    'validation', v_validation
  );
end;
$$;

revoke all on function public.get_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.get_m5a_group_plan(int, admission_round) to authenticated;

-- ============================================================
-- 6. draft 저장 RPC — 전체 plan replace, finalized 이후 수정 금지
-- ============================================================

create or replace function public.save_m5a_group_plan(
  p_year int,
  p_round admission_round,
  p_groups jsonb,
  p_segments jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_run_id uuid;
  v_plan record;
  g jsonb;
  m jsonb;
  po jsonb;
  s jsonb;
  a jsonb;
  v_group_id uuid;
  v_segment_id uuid;
  v_applicant_id uuid;
  v_uid uuid;
  v_target_group_id uuid;
  v_slot int;
  v_count int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5a:%s:%s', p_year, p_round::text), 0));
  v_run_id := public._m5a_current_document_run_id(p_year, p_round);

  if jsonb_typeof(p_groups) is distinct from 'array'
     or jsonb_typeof(p_segments) is distinct from 'array' then
    raise exception 'p_groups와 p_segments는 JSON array여야 합니다.';
  end if;

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round
  for update;

  if v_plan is not null and v_plan.status = 'finalized' then
    raise exception '이미 최종확정된 모둠편성 계획입니다. M7 잠금해제 절차 없이 수정할 수 없습니다.' using errcode = '55000';
  end if;

  if v_plan is not null and v_plan.document_source_run_id <> v_run_id then
    raise exception '1차 사정 final run이 변경되어 기존 draft가 stale 상태입니다. 기존 계획을 임의 재사용하지 말고 운영책임자가 재편성 절차를 진행해야 합니다.' using errcode = '55000';
  end if;

  insert into public.deep_group_plans
    (year, round, status, document_source_run_id, revision, created_by, updated_by)
  values
    (p_year, p_round, 'draft', v_run_id, 1, caller::text, caller::text)
  on conflict (year, round) do update set
    revision = public.deep_group_plans.revision + 1,
    updated_at = now(),
    updated_by = caller::text;

  -- replace 순서: assignment → segment → primary/member → group
  delete from public.deep_group_rotation_assignments where year = p_year and round = p_round;
  delete from public.deep_group_rotation_segments where year = p_year and round = p_round;
  delete from public.deep_group_primary_observers where year = p_year and round = p_round;
  delete from public.deep_group_members where year = p_year and round = p_round;
  delete from public.deep_groups where year = p_year and round = p_round;

  for g in select value from jsonb_array_elements(p_groups)
  loop
    begin
      v_group_id := (g ->> 'id')::uuid;
    exception when others then
      raise exception '모둠 id는 UUID여야 합니다: %', g ->> 'id';
    end;

    if nullif(trim(g ->> 'groupCode'), '') is null then
      raise exception '모둠 groupCode는 필수입니다.';
    end if;

    insert into public.deep_groups
      (id, year, round, group_code, sort_order, created_by, updated_by)
    values
      (v_group_id, p_year, p_round, trim(g ->> 'groupCode'), coalesce((g ->> 'sortOrder')::int, 0), caller::text, caller::text);

    if jsonb_typeof(coalesce(g -> 'members', '[]'::jsonb)) is distinct from 'array' then
      raise exception '모둠 members는 JSON array여야 합니다 (%).', g ->> 'groupCode';
    end if;

    v_count := 0;
    for m in select value from jsonb_array_elements(coalesce(g -> 'members', '[]'::jsonb))
    loop
      v_count := v_count + 1;
      v_applicant_id := trim(both '"' from m::text)::uuid;

      if not exists (
        select 1 from public.decision_results dr
        where dr.run_id = v_run_id and dr.applicant_id = v_applicant_id and dr.outcome = 'passed'
      ) then
        raise exception 'M4 final 합격자가 아닌 지원자는 모둠에 배정할 수 없습니다: %', v_applicant_id;
      end if;

      insert into public.deep_group_members (group_id, year, round, applicant_id, sort_order)
      values (v_group_id, p_year, p_round, v_applicant_id, v_count);
    end loop;

    if jsonb_typeof(coalesce(g -> 'primaryObservers', '[]'::jsonb)) is distinct from 'array' then
      raise exception '모둠 primaryObservers는 JSON array여야 합니다 (%).', g ->> 'groupCode';
    end if;

    if jsonb_array_length(coalesce(g -> 'primaryObservers', '[]'::jsonb)) > 2 then
      raise exception '주관찰위원은 모둠당 최대 2명만 draft에 저장할 수 있습니다 (%).', g ->> 'groupCode';
    end if;

    v_slot := 0;
    for po in select value from jsonb_array_elements(coalesce(g -> 'primaryObservers', '[]'::jsonb))
    loop
      v_slot := v_slot + 1;
      v_uid := trim(both '"' from po::text)::uuid;
      if not public._m5a_user_is_group_evaluator(v_uid, p_year, p_round) then
        raise exception '주관찰위원은 활성 evaluator + group 영역 + 연도/차수 scope를 충족해야 합니다: %', v_uid using errcode = '42501';
      end if;

      insert into public.deep_group_primary_observers
        (group_id, year, round, evaluator_uid, observer_slot)
      values
        (v_group_id, p_year, p_round, v_uid, v_slot);
    end loop;
  end loop;

  for s in select value from jsonb_array_elements(p_segments)
  loop
    begin
      v_segment_id := (s ->> 'id')::uuid;
    exception when others then
      raise exception 'segment id는 UUID여야 합니다: %', s ->> 'id';
    end;

    if nullif(trim(s ->> 'segmentCode'), '') is null then
      raise exception 'segmentCode는 필수입니다.';
    end if;

    insert into public.deep_group_rotation_segments
      (id, year, round, segment_code, starts_at, ends_at, sort_order, created_by, updated_by)
    values
      (v_segment_id, p_year, p_round, trim(s ->> 'segmentCode'),
       (s ->> 'startsAt')::timestamptz, (s ->> 'endsAt')::timestamptz,
       coalesce((s ->> 'sortOrder')::int, 0), caller::text, caller::text);

    if jsonb_typeof(coalesce(s -> 'assignments', '[]'::jsonb)) is distinct from 'array' then
      raise exception 'segment assignments는 JSON array여야 합니다 (%).', s ->> 'segmentCode';
    end if;

    for a in select value from jsonb_array_elements(coalesce(s -> 'assignments', '[]'::jsonb))
    loop
      v_uid := (a ->> 'evaluatorUid')::uuid;
      v_target_group_id := (a ->> 'targetGroupId')::uuid;

      if not public._m5a_user_is_group_evaluator(v_uid, p_year, p_round) then
        raise exception '순환계획 대상자는 활성 evaluator + group 영역 + scope를 충족해야 합니다: %', v_uid using errcode = '42501';
      end if;

      if not exists (
        select 1 from public.deep_groups g2
        where g2.id = v_target_group_id and g2.year = p_year and g2.round = p_round and g2.active = true
      ) then
        raise exception 'segment의 targetGroupId가 현재 plan 모둠이 아닙니다: %', v_target_group_id;
      end if;

      insert into public.deep_group_rotation_assignments
        (segment_id, year, round, evaluator_uid, target_group_id)
      values
        (v_segment_id, p_year, p_round, v_uid, v_target_group_id);
    end loop;
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'deep_group_plan.draft_saved', 'deep_group_plans',
     p_year::text || '_' || p_round::text,
     jsonb_build_object(
       'groupCount', jsonb_array_length(p_groups),
       'segmentCount', jsonb_array_length(p_segments),
       'documentSourceRunId', v_run_id
     ));

  return public._m5a_validate_plan(p_year, p_round);
exception
  when unique_violation then
    raise exception '모둠 코드·지원자 배정·주관찰위원 배정·segment 코드 또는 segment별 위원 배정에 중복이 있습니다. 각 값은 계획 안에서 유일해야 합니다.' using errcode = '23505';
end;
$$;

revoke all on function public.save_m5a_group_plan(int, admission_round, jsonb, jsonb) from public, anon;
grant execute on function public.save_m5a_group_plan(int, admission_round, jsonb, jsonb) to authenticated;

-- ============================================================
-- 7. 서버 검증 / final 확정 RPC
-- ============================================================

create or replace function public.validate_m5a_group_plan(
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
  return public._m5a_validate_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5a_group_plan(int, admission_round) to authenticated;

create or replace function public.finalize_m5a_group_plan(
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
  v_plan record;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5a:%s:%s', p_year, p_round::text), 0));

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round
  for update;

  if v_plan is null then
    raise exception '최종확정할 모둠편성 draft가 없습니다.';
  end if;
  if v_plan.status = 'finalized' then
    raise exception '이미 최종확정된 모둠편성 계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5a_validate_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '모둠편성 계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.evaluation_roster er
  set group_id = gm.group_id,
      roster_revision = er.roster_revision + 1,
      updated_at = now()
  from public.deep_group_members gm
  where gm.year = p_year and gm.round = p_round
    and gm.applicant_id = er.applicant_id;

  update public.deep_group_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'deep_group_plan.finalized', 'deep_group_plans',
     p_year::text || '_' || p_round::text,
     jsonb_build_object(
       'documentSourceRunId', v_plan.document_source_run_id,
       'candidateCount', v_validation -> 'candidateCount',
       'groupCount', v_validation -> 'groupCount',
       'segmentCount', v_validation -> 'segmentCount'
     ));

  return public._m5a_validate_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5a_group_plan(int, admission_round) to authenticated;
