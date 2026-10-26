-- 새봄고 입학전형 시스템 — M5b stale draft / 동시 저장 hotfix
--
-- 원인
--   SELECT ... INTO record 후 `record IS NOT NULL`로 행 존재 여부를 판정했다.
--   scores_group draft는 submitted_at=NULL이므로 composite IS NOT NULL 판정이
--   기대와 달라 stale client_updated_at 비교가 건너뛰어질 수 있었다.
--
-- 수정
--   1) NOT NULL PK인 v_existing.id로 행 존재 여부를 판정한다.
--   2) 동일 timestamp도 replay로 보아 >= 조건으로 거부한다.
--   3) applicant+evaluator advisory xact lock으로 최초 INSERT 경쟁까지 직렬화한다.
--   4) stale 거부 응답의 draftTotal은 현재 서버 draft 값을 돌려준다.

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

  -- 같은 평가자/지원자의 draft·submit 경쟁을 직렬화한다.
  -- 행이 아직 없는 최초 저장 경쟁에서도 오래된 replay가 나중에 덮어쓰지 못하게 한다.
  perform pg_advisory_xact_lock(
    hashtextextended(format('m5b-score:%s:%s', p_applicant_id, caller), 0)
  );

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

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing.id is not null and v_existing.client_updated_at >= p_client_updated_at then
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
    'draftTotal', case
      when v_accepted then v_total
      else coalesce(
        (select (server_computed ->> 'draftTotal')::numeric
         from public.scores_group
         where applicant_id = p_applicant_id and evaluator_uid = caller),
        v_total
      )
    end,
    'submissionState', coalesce((select submission_state from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft'),
    'serverClientUpdatedAt', (select client_updated_at from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller)
  );
end;
$$;

revoke all on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) from public, anon;
grant execute on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) to authenticated;

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

  -- draft 저장과 제출확정이 동시에 들어와도 같은 지원자/평가자 단위로 직렬화한다.
  perform pg_advisory_xact_lock(
    hashtextextended(format('m5b-score:%s:%s', p_applicant_id, caller), 0)
  );

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
  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
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
