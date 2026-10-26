-- 새봄고 입학전형 시스템 — M5b 심층역량평가 모둠활동 관찰채점
-- 마스터 스펙 v1.2 섹션 2.7, 3.14, 6.12, 9의 불변조건 반영.
--
-- 핵심 불변조건
--   1) group evaluator + 연도/차수 scope + finalized M5a plan만 접근한다.
--   2) observer_role은 서버가 primaryObservers/rotation assignment로 재판정한다.
--   3) 주관찰위원은 자기 home group 전원을 평가하며 최소 1개 home segment 관찰 근거가 필요하다.
--   4) 순환관찰위원은 실제 배정 segment만 observed_segment_ids에 넣을 수 있고
--      observation_confirmed=true인 제출만 유효하다.
--   5) 주관찰 필수 인원(2027: 2인) 모두 제출 전 group aggregate는 null/complete=false다.
--   6) 점수 aggregate는 config revision의 deep.group 구조화 파라미터만 사용한다.
--   7) 클라이언트 total/observerRole/serverComputed는 신뢰하지 않는다.
--   8) 제한적 오프라인 지원은 본인 draft RPC 재시도만 허용한다. 제출확정은 온라인 RPC만 수행한다.

-- ============================================================
-- 1. scores_group + server aggregate
-- ============================================================

create table public.scores_group (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  group_id uuid not null references public.deep_groups (id),
  observer_role text not null check (observer_role in ('primary', 'roving')),
  observation_confirmed boolean not null default false,
  observed_segment_ids uuid[] not null default '{}',
  items jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submission_state text not null default 'draft'
    check (submission_state in ('draft', 'submitted', 'reopened')),
  revision int not null default 1 check (revision >= 1),
  client_updated_at timestamptz not null,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_group_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  group_id uuid not null references public.deep_groups (id),
  complete boolean not null default false,
  score numeric,
  primary_required int not null,
  primary_submitted int not null,
  roving_included int not null,
  evaluator_count int not null,
  raw_average numeric,
  source_revision_summary jsonb not null default '[]'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_group is
  'M5b 모둠활동 본인 관찰채점. observer_role/server_computed는 RPC가 서버 판정하며 타 위원 직접 read를 허용하지 않는다.';
comment on table public.deep_group_aggregates is
  'M5b 서버 집계. 주관찰 필수 제출 미충족 시 score=null, complete=false. 유효 관찰위원 평균 × config scaleFactor.';

alter table public.scores_group enable row level security;
alter table public.deep_group_aggregates enable row level security;

-- 평가 독립성: evaluator는 자기 점수만 읽는다. 관리자도 개별 점수 테이블 직접 select 정책을 두지 않는다.
create policy scores_group_select_own
  on public.scores_group for select
  using (evaluator_uid = auth.uid());

create policy deep_group_aggregates_select_admin_viewer
  on public.deep_group_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. config / 권한 / 관찰관계 private helpers
--    M4의 STABLE snapshot 이슈를 반복하지 않도록 같은 DO/RPC에서 fixture 변경을
--    즉시 읽어야 하는 helper는 VOLATILE로 둔다.
-- ============================================================

create or replace function public._m5b_group_params(p_revision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_criteria jsonb;
begin
  select scoring_params #> '{deep,group}'
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.group 파라미터가 없습니다. M5b 배점 설정을 먼저 반영하세요.' using errcode = '55000';
  end if;

  v_criteria := v_params -> 'criteria';
  if jsonb_typeof(v_criteria) is distinct from 'array'
     or jsonb_array_length(v_criteria) = 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'criterionMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'scoreStep')::numeric, 0) <= 0
     or coalesce((v_params ->> 'scaleFactor')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredPrimaryObservers')::int, 0) <= 0
     or coalesce((v_params ->> 'max')::numeric, 0) <= 0 then
    raise exception 'deep.group 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  return v_params;
end;
$$;

create or replace function public._m5b_require_group_evaluator(
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
    select 1
    from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'group' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '모둠활동 평가 권한이 없습니다 (evaluator + group 배정 및 scope 필요).' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.deep_group_plans p
    where p.year = p_year and p.round = p_round and p.status = 'finalized'
  ) then
    raise exception 'M5a 모둠편성 계획이 아직 최종확정되지 않았습니다.' using errcode = '55000';
  end if;

  return caller;
end;
$$;

create or replace function public._m5b_group_id(p_applicant_id uuid)
returns uuid
language sql
security definer
set search_path = public
volatile
as $$
  select gm.group_id
  from public.deep_group_members gm
  join public.deep_group_plans p on p.year = gm.year and p.round = gm.round
  where gm.applicant_id = p_applicant_id
    and p.status = 'finalized'
  limit 1;
$$;

create or replace function public._m5b_observer_role(
  p_applicant_id uuid,
  p_evaluator_uid uuid
)
returns text
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_group_id uuid;
begin
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    return null;
  end if;

  if exists (
    select 1 from public.deep_group_primary_observers po
    where po.group_id = v_group_id and po.evaluator_uid = p_evaluator_uid
  ) then
    return 'primary';
  end if;

  if exists (
    select 1
    from public.deep_group_rotation_assignments ra
    join public.deep_group_rotation_segments s on s.id = ra.segment_id
    join public.deep_groups g on g.id = v_group_id
    where ra.evaluator_uid = p_evaluator_uid
      and ra.target_group_id = v_group_id
      and s.year = g.year and s.round = g.round
  ) then
    return 'roving';
  end if;

  return null;
end;
$$;

create or replace function public._m5b_allowed_segments(
  p_applicant_id uuid,
  p_evaluator_uid uuid
)
returns uuid[]
language sql
security definer
set search_path = public
volatile
as $$
  select coalesce(array_agg(ra.segment_id order by s.sort_order, s.starts_at), '{}'::uuid[])
  from public.deep_group_members gm
  join public.deep_group_rotation_assignments ra on ra.target_group_id = gm.group_id
  join public.deep_group_rotation_segments s on s.id = ra.segment_id
  where gm.applicant_id = p_applicant_id
    and ra.evaluator_uid = p_evaluator_uid;
$$;

create or replace function public._m5b_validate_and_total(
  p_revision_id uuid,
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
  v_params jsonb := public._m5b_group_params(p_revision_id);
  v_criteria text[];
  v_criterion_max numeric := (v_params ->> 'criterionMax')::numeric;
  v_step numeric := (v_params ->> 'scoreStep')::numeric;
  v_per_max numeric := (v_params ->> 'perEvaluatorMax')::numeric;
  k text;
  raw_value text;
  v numeric;
  total numeric := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'object' then
    raise exception 'items는 JSON object여야 합니다.' using errcode = '22023';
  end if;

  select array_agg(value order by ord)
    into v_criteria
  from jsonb_array_elements_text(v_params -> 'criteria') with ordinality as x(value, ord);

  if p_require_complete then
    foreach k in array v_criteria loop
      if not (p_items ? k) then
        raise exception '% 기준 점수가 없습니다. 모든 모둠활동 기준을 입력해야 제출할 수 있습니다.', k using errcode = '23514';
      end if;
    end loop;
    if (select count(*) from jsonb_object_keys(p_items)) <> array_length(v_criteria, 1) then
      raise exception '허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.' using errcode = '23514';
    end if;
  end if;

  for k, raw_value in select key, value from jsonb_each_text(p_items)
  loop
    if not (k = any(v_criteria)) then
      raise exception '알 수 없는 모둠활동 채점 기준: %', k using errcode = '23514';
    end if;
    begin
      v := raw_value::numeric;
    exception when others then
      raise exception '% 점수는 숫자여야 합니다.', k using errcode = '22023';
    end;
    if v < 0 or v > v_criterion_max or mod(v, v_step) <> 0 then
      raise exception '% 점수는 0~% 범위에서 %점 단위여야 합니다 (입력값: %).', k, v_criterion_max, v_step, v using errcode = '23514';
    end if;
    total := total + v;
  end loop;

  if total > v_per_max then
    raise exception '위원별 모둠활동 총점은 %점을 초과할 수 없습니다 (입력 합계: %).', v_per_max, total using errcode = '23514';
  end if;

  return total;
end;
$$;

revoke all on function public._m5b_group_params(uuid) from public, anon, authenticated;
revoke all on function public._m5b_require_group_evaluator(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5b_group_id(uuid) from public, anon, authenticated;
revoke all on function public._m5b_observer_role(uuid, uuid) from public, anon, authenticated;
revoke all on function public._m5b_allowed_segments(uuid, uuid) from public, anon, authenticated;
revoke all on function public._m5b_validate_and_total(uuid, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 3. M5a final 보강: 주관찰위원 각자 최소 1개 home segment 필요
-- ============================================================

create or replace function public._m5a_primary_home_segment_issues(
  p_year int,
  p_round admission_round
)
returns jsonb
language sql
security definer
set search_path = public
volatile
as $$
  select case
    when count(*) = 0 then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object(
        'code', 'PRIMARY_OBSERVER_HOME_SEGMENT_MISSING',
        'message', format('주관찰위원 %s명이 자기 모둠을 직접 관찰하는 segment가 1개도 없습니다. 주관찰 2인 모두 최소 1개 home segment가 필요합니다.', count(*)),
        'items', coalesce(jsonb_agg(jsonb_build_object(
          'groupId', x.group_id,
          'groupCode', x.group_code,
          'evaluatorUid', x.evaluator_uid
        ) order by x.group_code, x.evaluator_uid), '[]'::jsonb)
      )
    )
  end
  from (
    select po.group_id, g.group_code, po.evaluator_uid
    from public.deep_group_primary_observers po
    join public.deep_groups g on g.id = po.group_id
    where po.year = p_year and po.round = p_round
      and not exists (
        select 1
        from public.deep_group_rotation_assignments ra
        join public.deep_group_rotation_segments s on s.id = ra.segment_id
        where ra.evaluator_uid = po.evaluator_uid
          and ra.target_group_id = po.group_id
          and s.year = p_year and s.round = p_round
      )
  ) x;
$$;

revoke all on function public._m5a_primary_home_segment_issues(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5a_group_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_extra jsonb;
  v_issues jsonb;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  v_base := public._m5a_validate_plan(p_year, p_round);
  v_extra := public._m5a_primary_home_segment_issues(p_year, p_round);
  v_issues := coalesce(v_base -> 'blockingIssues', '[]'::jsonb) || coalesce(v_extra, '[]'::jsonb);

  return jsonb_set(
    jsonb_set(v_base, '{blockingIssues}', v_issues, true),
    '{complete}',
    to_jsonb(jsonb_array_length(v_issues) = 0),
    true
  );
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
  v_primary_home_issues jsonb;
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

  v_primary_home_issues := public._m5a_primary_home_segment_issues(p_year, p_round);
  if jsonb_array_length(v_primary_home_issues) > 0 then
    raise exception '모둠편성 계획에 주관찰 직접관찰 문제가 있어 확정할 수 없습니다: %', v_primary_home_issues using errcode = '23514';
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
       'segmentCount', v_validation -> 'segmentCount',
       'primaryHomeSegmentRule', true
     ));

  return public.validate_m5a_group_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5a_group_plan(int, admission_round) to authenticated;

-- ============================================================
-- 4. evaluator 모바일 workspace
-- ============================================================

create or replace function public.get_m5b_observation_workspace(
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
  v_plan record;
  v_params jsonb;
  v_segments jsonb;
  v_groups jsonb;
begin
  caller := public._m5b_require_group_evaluator(p_year, p_round);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if v_round is null then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round and status = 'finalized';

  v_params := public._m5b_group_params(v_round.config_revision_id);

  select coalesce(jsonb_agg(jsonb_build_object(
      'segmentId', s.id,
      'segmentCode', s.segment_code,
      'startsAt', s.starts_at,
      'endsAt', s.ends_at,
      'targetGroupId', ra.target_group_id
    ) order by s.sort_order, s.starts_at), '[]'::jsonb)
    into v_segments
  from public.deep_group_rotation_segments s
  join public.deep_group_rotation_assignments ra
    on ra.segment_id = s.id and ra.evaluator_uid = caller
  where s.year = p_year and s.round = p_round;

  select coalesce(jsonb_agg(jsonb_build_object(
      'groupId', g.id,
      'groupCode', g.group_code,
      'observerRole', case when exists (
        select 1 from public.deep_group_primary_observers po
        where po.group_id = g.id and po.evaluator_uid = caller
      ) then 'primary' else 'roving' end,
      'allowedSegmentIds', coalesce((
        select jsonb_agg(ra.segment_id order by s.sort_order, s.starts_at)
        from public.deep_group_rotation_assignments ra
        join public.deep_group_rotation_segments s on s.id = ra.segment_id
        where ra.evaluator_uid = caller and ra.target_group_id = g.id
      ), '[]'::jsonb),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'applicantId', er.applicant_id,
          'examNo', er.exam_no,
          'displayName', er.display_name,
          'myScore', case when sg.id is null then null else jsonb_build_object(
            'scoreId', sg.id,
            'observationConfirmed', sg.observation_confirmed,
            'observedSegmentIds', to_jsonb(sg.observed_segment_ids),
            'items', sg.items,
            'observerRole', sg.observer_role,
            'submissionState', sg.submission_state,
            'revision', sg.revision,
            'serverComputed', sg.server_computed,
            'clientUpdatedAt', sg.client_updated_at,
            'submittedAt', sg.submitted_at
          ) end
        ) order by gm.sort_order, er.exam_no, er.display_name)
        from public.deep_group_members gm
        join public.evaluation_roster er on er.applicant_id = gm.applicant_id
        left join public.scores_group sg
          on sg.applicant_id = gm.applicant_id and sg.evaluator_uid = caller
        where gm.group_id = g.id
      ), '[]'::jsonb)
    ) order by g.sort_order, g.group_code), '[]'::jsonb)
    into v_groups
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true
    and (
      exists (
        select 1 from public.deep_group_primary_observers po
        where po.group_id = g.id and po.evaluator_uid = caller
      )
      or exists (
        select 1 from public.deep_group_rotation_assignments ra
        where ra.evaluator_uid = caller and ra.target_group_id = g.id
      )
    );

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'planRevision', v_plan.revision,
    'areaOpen', v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas),
    'criteria', v_params -> 'criteria',
    'criterionMax', (v_params ->> 'criterionMax')::numeric,
    'scoreStep', (v_params ->> 'scoreStep')::numeric,
    'perEvaluatorMax', (v_params ->> 'perEvaluatorMax')::numeric,
    'segments', v_segments,
    'groups', v_groups,
    'offlinePolicy', 'MINIMAL_ROSTER_SELF_DRAFT_24H'
  );
end;
$$;

revoke all on function public.get_m5b_observation_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5b_observation_workspace(int, admission_round) to authenticated;

-- ============================================================
-- 5. draft 저장 — 부분점수 허용 + client_updated_at으로 오래된 offline replay 차단
-- ============================================================

create or replace function public.save_group_score_draft(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb,
  p_client_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_round record;
  v_plan record;
  v_group_id uuid;
  v_role text;
  v_allowed uuid[];
  v_total numeric;
  v_existing record;
  v_accepted boolean := true;
  v_observed uuid[] := coalesce(p_observed_segment_ids, '{}'::uuid[]);
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);
  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  select * into v_plan from public.deep_group_plans where year = v_app.year and round = v_app.round and status = 'finalized';
  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;

  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 observed_segment_ids에 포함할 수 없습니다.' using errcode = '42501';
  end if;
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;

  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, false);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing is not null and v_existing.client_updated_at > p_client_updated_at then
    v_accepted := false;
  else
    insert into public.scores_group
      (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
       observer_role, observation_confirmed, observed_segment_ids, items,
       server_computed, submission_state, revision, client_updated_at)
    values
      (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
       v_role, coalesce(p_observation_confirmed, false), v_observed, p_items,
       jsonb_build_object('draftTotal', v_total, 'validForAggregate', false), 'draft', 1, p_client_updated_at)
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      group_id = excluded.group_id,
      observer_role = excluded.observer_role,
      observation_confirmed = excluded.observation_confirmed,
      observed_segment_ids = excluded.observed_segment_ids,
      items = excluded.items,
      server_computed = excluded.server_computed,
      submission_state = 'draft',
      revision = public.scores_group.revision + 1,
      client_updated_at = excluded.client_updated_at,
      submitted_at = null,
      updated_at = now();
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'observerRole', v_role,
    'draftTotal', v_total,
    'submissionState', coalesce((select submission_state from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
  );
end;
$$;

revoke all on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) from public, anon;
grant execute on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) to authenticated;

-- ============================================================
-- 6. 제출확정 — role/segments/total 서버 재판정
-- ============================================================

create or replace function public.submit_group_score(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_round record;
  v_group_id uuid;
  v_role text;
  v_allowed uuid[];
  v_observed uuid[] := coalesce(p_observed_segment_ids, '{}'::uuid[]);
  v_total numeric;
  v_existing record;
  v_effective_confirmed boolean;
  v_result jsonb;
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);
  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;
  if cardinality(v_observed) = 0 then
    raise exception '최소 1개 이상의 실제 관찰 segment를 선택해야 제출할 수 있습니다.' using errcode = '23514';
  end if;
  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 제출 근거로 사용할 수 없습니다.' using errcode = '42501';
  end if;

  if v_role = 'roving' and coalesce(p_observation_confirmed, false) = false then
    raise exception '순환관찰위원은 충분한 관찰이 이루어졌음을 확인한 경우에만 제출할 수 있습니다.' using errcode = '23514';
  end if;

  v_effective_confirmed := case when v_role = 'primary' then true else coalesce(p_observation_confirmed, false) end;
  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, true);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;
  if v_existing is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  insert into public.scores_group
    (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
     observer_role, observation_confirmed, observed_segment_ids, items,
     server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     v_role, v_effective_confirmed, v_observed, p_items,
     jsonb_build_object(
       'total', v_total,
       'validForAggregate', true,
       'observerRoleServerDetermined', v_role,
       'configRevisionId', v_round.config_revision_id
     ),
     'submitted', coalesce(v_existing.revision, 0) + 1, now(), now())
  on conflict (applicant_id, evaluator_uid) do update set
    config_revision_id = excluded.config_revision_id,
    group_id = excluded.group_id,
    observer_role = excluded.observer_role,
    observation_confirmed = excluded.observation_confirmed,
    observed_segment_ids = excluded.observed_segment_ids,
    items = excluded.items,
    server_computed = excluded.server_computed,
    submission_state = 'submitted',
    revision = public.scores_group.revision + 1,
    client_updated_at = now(),
    submitted_at = now(),
    updated_at = now()
  returning jsonb_build_object(
    'scoreId', id,
    'total', (server_computed ->> 'total')::numeric,
    'observerRole', observer_role,
    'submissionState', submission_state,
    'revision', revision
  ) into v_result;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'score.group.submitted', 'scores_group',
     v_result ->> 'scoreId', p_applicant_id::text, 'group',
     jsonb_build_object(
       'observerRole', v_role,
       'observedSegmentCount', cardinality(v_observed),
       'revision', v_result -> 'revision'
     ));

  return v_result;
end;
$$;

revoke all on function public.submit_group_score(uuid, boolean, uuid[], jsonb) from public, anon;
grant execute on function public.submit_group_score(uuid, boolean, uuid[], jsonb) to authenticated;

-- ============================================================
-- 7. group aggregate — 필수 primary 2인 미충족 시 null
-- ============================================================

create or replace function public._compute_group_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_group_id uuid;
  v_params jsonb;
  v_required_primary int;
  v_scale numeric;
  v_max numeric;
  v_primary_submitted int;
  v_roving_included int;
  v_evaluator_count int;
  v_raw_average numeric;
  v_score numeric;
  v_summary jsonb;
begin
  select er.year, er.round into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    return jsonb_build_object(
      'complete', false, 'score', null, 'primaryRequired', null,
      'primarySubmitted', 0, 'rovingIncluded', 0, 'evaluatorCount', 0,
      'rawAverage', null, 'sourceRevisionSummary', '[]'::jsonb,
      'functionVersion', 'm5b-group-aggregate-v1'
    );
  end if;

  v_params := public._m5b_group_params(v_round.config_revision_id);
  v_required_primary := (v_params ->> 'requiredPrimaryObservers')::int;
  v_scale := (v_params ->> 'scaleFactor')::numeric;
  v_max := (v_params ->> 'max')::numeric;

  with valid_scores as (
    select sg.*,
           case when exists (
             select 1 from public.deep_group_primary_observers po
             where po.group_id = v_group_id and po.evaluator_uid = sg.evaluator_uid
           ) then 'primary' else 'roving' end as actual_role
    from public.scores_group sg
    where sg.applicant_id = p_applicant_id
      and sg.submission_state = 'submitted'
      and sg.group_id = v_group_id
      and (
        exists (
          select 1 from public.deep_group_primary_observers po
          where po.group_id = v_group_id and po.evaluator_uid = sg.evaluator_uid
        )
        or (
          sg.observation_confirmed = true
          and cardinality(sg.observed_segment_ids) > 0
          and not exists (
            select 1
            from unnest(sg.observed_segment_ids) seg_id
            where not exists (
              select 1 from public.deep_group_rotation_assignments ra
              where ra.segment_id = seg_id
                and ra.evaluator_uid = sg.evaluator_uid
                and ra.target_group_id = v_group_id
            )
          )
        )
      )
  )
  select
    count(*) filter (where actual_role = 'primary')::int,
    count(*) filter (where actual_role = 'roving')::int,
    count(*)::int,
    avg((server_computed ->> 'total')::numeric),
    coalesce(jsonb_agg(jsonb_build_object(
      'scoreId', id,
      'evaluatorUid', evaluator_uid,
      'revision', revision,
      'observerRole', actual_role
    ) order by evaluator_uid), '[]'::jsonb)
  into v_primary_submitted, v_roving_included, v_evaluator_count, v_raw_average, v_summary
  from valid_scores;

  if v_primary_submitted < v_required_primary then
    v_score := null;
  else
    v_score := least(v_max, v_raw_average * v_scale);
  end if;

  return jsonb_build_object(
    'complete', v_primary_submitted >= v_required_primary,
    'score', v_score,
    'primaryRequired', v_required_primary,
    'primarySubmitted', v_primary_submitted,
    'rovingIncluded', v_roving_included,
    'evaluatorCount', v_evaluator_count,
    'rawAverage', case when v_primary_submitted >= v_required_primary then v_raw_average else null end,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm5b-group-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_group_aggregate(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_group_id uuid;
  v_agg jsonb;
begin
  select er.year, er.round into v_app
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;
  if v_app is null then
    delete from public.deep_group_aggregates where applicant_id = p_applicant_id;
    return;
  end if;
  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    delete from public.deep_group_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  v_agg := public._compute_group_aggregate(p_applicant_id);

  insert into public.deep_group_aggregates
    (applicant_id, year, round, config_revision_id, group_id, complete, score,
     primary_required, primary_submitted, roving_included, evaluator_count,
     raw_average, source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     (v_agg ->> 'complete')::boolean,
     (v_agg ->> 'score')::numeric,
     (v_agg ->> 'primaryRequired')::int,
     (v_agg ->> 'primarySubmitted')::int,
     (v_agg ->> 'rovingIncluded')::int,
     (v_agg ->> 'evaluatorCount')::int,
     (v_agg ->> 'rawAverage')::numeric,
     v_agg -> 'sourceRevisionSummary',
     v_agg ->> 'functionVersion',
     now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    group_id = excluded.group_id,
    complete = excluded.complete,
    score = excluded.score,
    primary_required = excluded.primary_required,
    primary_submitted = excluded.primary_submitted,
    roving_included = excluded.roving_included,
    evaluator_count = excluded.evaluator_count,
    raw_average = excluded.raw_average,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = now();
end;
$$;

create or replace function public._trg_refresh_group_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    if new.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(new.applicant_id);
    end if;
    return new;
  elsif TG_OP = 'UPDATE' then
    if old.submission_state = 'submitted' or new.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(new.applicant_id);
    end if;
    return new;
  else
    if old.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(old.applicant_id);
    end if;
    return old;
  end if;
end;
$$;

revoke all on function public._compute_group_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_group_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_group_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_group_aggregate on public.scores_group;
create trigger trg_refresh_group_aggregate
  after insert or update or delete on public.scores_group
  for each row execute function public._trg_refresh_group_aggregate();

-- ============================================================
-- 8. 관리자 집계 조회 — 개별 위원 점수는 반환하지 않는다.
-- ============================================================

create or replace function public.get_m5b_group_progress(
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
        'groupCode', g.group_code,
        'complete', coalesce(a.complete, false),
        'score', a.score,
        'primaryRequired', a.primary_required,
        'primarySubmitted', coalesce(a.primary_submitted, 0),
        'rovingIncluded', coalesce(a.roving_included, 0),
        'evaluatorCount', coalesce(a.evaluator_count, 0),
        'computedAt', a.computed_at
      ) order by g.sort_order, gm.sort_order, er.exam_no, er.display_name)
      from public.deep_group_members gm
      join public.deep_groups g on g.id = gm.group_id
      join public.evaluation_roster er on er.applicant_id = gm.applicant_id
      left join public.deep_group_aggregates a on a.applicant_id = gm.applicant_id
      where gm.year = p_year and gm.round = p_round
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5b_group_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5b_group_progress(int, admission_round) to authenticated;

-- ============================================================
-- 9. reopen_score에 scores_group 확장
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

  if p_score_table not in
     ('scores_attendance', 'scores_academic', 'scores_community', 'scores_essay', 'scores_opinion', 'scores_group') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_community' then
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_essay' then
    update public.scores_essay set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_opinion' then
    update public.scores_opinion set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_group set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke all on function public.reopen_score(text, uuid) from public, anon;
grant execute on function public.reopen_score(text, uuid) to authenticated;
