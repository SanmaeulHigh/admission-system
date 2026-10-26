-- 새봄고 입학전형 시스템 — 모둠활동 2부제(오전반·오후반) 지원 (2026-10-14)
--
-- 배경: 2027 심층평가는 30명을 오전반(1·2모둠)·오후반(3·4모둠)으로 나눠 운영한다.
--       기존 검증은 ① 모든 순환 구간마다 모든 모둠에 주관찰 잔류 ② 모든 group 위원이 구간마다 배정
--       을 요구해, 오전 구간에 오후 모둠이 없고 오후 구간에 오전 위원(면접 중)이 빠지는 2부제를 막았다.
--
-- 설계: 모둠과 순환 구간에 '반'(shift_code, null 허용)을 둔다. uuid 배열 대신 반을 쓰는 이유는
--       외래키로 묶을 수 없는 배열 대신 운영 개념(오전반·오후반) 하나만 고르면 되게 하기 위해서다.
--   - 구간 반이 null  → 모든 모둠이 대상(기존 1부제와 완전히 같음)
--   - 구간 반이 '오전' → 반이 '오전'이거나 null인 모둠만 대상
--   - PRIMARY_OBSERVER_COVERAGE   : 구간 대상 모둠만 검사
--   - ROTATION_ASSIGNMENT_MISSING : 반 구간은 대상 모둠 주관찰위원에게만 배정 요구(다른 위원은 '관찰 안 함' 허용)
--   - 새 차단 ROTATION_TARGET_OUT_OF_SHIFT : 구간 반 밖 모둠을 관찰 대상으로 잡음
--   - 새 경고 ROVING_OBSERVER_UNUSED      : 반을 쓰는데 어느 구간에도 배정 안 된 비주관찰 위원(확정은 가능)
-- 관찰 채점(_m5b_allowed_segments)·주관찰 home segment 검사·종이 평가표·집계는 실제 배정 행만 따라가므로 바꾸지 않는다.

alter table public.deep_groups
  add column if not exists shift_code text check (shift_code is null or length(trim(shift_code)) between 1 and 20);
alter table public.deep_group_rotation_segments
  add column if not exists shift_code text check (shift_code is null or length(trim(shift_code)) between 1 and 20);

comment on column public.deep_groups.shift_code is '운영 반(예: 오전·오후). null이면 모든 반 구간의 대상.';
comment on column public.deep_group_rotation_segments.shift_code is '이 순환 구간이 다루는 반. null이면 모든 모둠 대상(1부제).';

create or replace function public._m5a_segment_covers_group(p_segment_shift text, p_group_shift text)
returns boolean
language sql
immutable
as $$
  select p_segment_shift is null or p_group_shift is null or p_segment_shift = p_group_shift;
$$;

revoke all on function public._m5a_segment_covers_group(text, text) from public, anon, authenticated;

-- 1. 검증
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
  v_warnings jsonb := '[]'::jsonb;
  v_scoped boolean := false;
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

  -- 2부제(00089): 반이 지정된 구간은 그 반 모둠의 주관찰위원에게만 관찰 배정을 요구한다.
  -- 반이 없는 구간(기존 1부제)은 예전처럼 모든 group 위원에게 배정을 요구한다.
  select count(*) into v_count
  from public.deep_group_rotation_segments s
  cross join public.users u
  where s.year = p_year and s.round = p_round
    and u.active = true
    and 'evaluator' = any(u.roles)
    and 'group' = any(u.assigned_areas)
    and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
    and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    and (
      s.shift_code is null
      or exists (
        select 1
        from public.deep_group_primary_observers po
        join public.deep_groups g on g.id = po.group_id
        where po.evaluator_uid = u.id
          and g.year = p_year and g.round = p_round and g.active = true
          and public._m5a_segment_covers_group(s.shift_code, g.shift_code)
      )
    )
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
      and public._m5a_segment_covers_group(s.shift_code, g.shift_code)
    group by s.id, s.segment_code, s.sort_order, g.id, g.group_code, g.sort_order
    having count(*) filter (where ra.target_group_id = g.id) < 1
  ) x;

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'PRIMARY_OBSERVER_COVERAGE',
        'message', '모든 segment에서 (그 segment 반에 속한) 각 모둠 주관찰위원 최소 1인이 자기 모둠에 남아 있어야 합니다.',
        'items', v_items
      )
    );
  end if;

  -- 구간 반 밖의 모둠을 관찰 대상으로 잡은 배정(저장 함수가 막지만 이전 데이터 방어)
  select count(*) into v_count
  from public.deep_group_rotation_assignments ra
  join public.deep_group_rotation_segments s on s.id = ra.segment_id
  join public.deep_groups g on g.id = ra.target_group_id
  where s.year = p_year and s.round = p_round
    and not public._m5a_segment_covers_group(s.shift_code, g.shift_code);

  if v_count > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object('code', 'ROTATION_TARGET_OUT_OF_SHIFT', 'message', format('순환 구간의 반과 다른 반 모둠을 관찰 대상으로 잡은 배정이 %s건 있습니다.', v_count))
    );
  end if;

  -- 경고(확정은 막지 않음): 반을 쓰는 계획에서 주관찰이 아닌 group 위원이 한 번도 배정되지 않음
  select exists (
    select 1 from public.deep_group_rotation_segments s
    where s.year = p_year and s.round = p_round and s.shift_code is not null
  ) into v_scoped;

  if v_scoped then
    select coalesce(jsonb_agg(jsonb_build_object('evaluatorUid', u.id, 'displayName', u.display_name)
             order by u.display_name), '[]'::jsonb)
      into v_items
    from public.users u
    where u.active = true
      and 'evaluator' = any(u.roles)
      and 'group' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
      and not exists (
        select 1 from public.deep_group_primary_observers po
        where po.year = p_year and po.round = p_round and po.evaluator_uid = u.id
      )
      and not exists (
        select 1 from public.deep_group_rotation_assignments ra
        where ra.year = p_year and ra.round = p_round and ra.evaluator_uid = u.id
      );

    if jsonb_array_length(v_items) > 0 then
      v_warnings := v_warnings || jsonb_build_array(
        jsonb_build_object(
          'code', 'ROVING_OBSERVER_UNUSED',
          'message', format('모둠 담당 위원 %s명이 어느 구간에도 관찰 배정되지 않았습니다(확정은 가능).', jsonb_array_length(v_items)),
          'items', v_items
        )
      );
    end if;
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
    'blockingIssues', v_issues,
    'warnings', v_warnings
  );
end;
$$;

revoke all on function public._m5a_validate_plan(int, admission_round) from public, anon, authenticated;

-- 2. 조회(반 포함)
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
      'shiftCode', g.shift_code,
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
      'shiftCode', s.shift_code,
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

-- 3. 저장(반 저장 + 반 밖 배정 거부)
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
      (id, year, round, group_code, shift_code, sort_order, created_by, updated_by)
    values
      (v_group_id, p_year, p_round, trim(g ->> 'groupCode'), nullif(trim(g ->> 'shiftCode'), ''),
       coalesce((g ->> 'sortOrder')::int, 0), caller::text, caller::text);

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
      (id, year, round, segment_code, shift_code, starts_at, ends_at, sort_order, created_by, updated_by)
    values
      (v_segment_id, p_year, p_round, trim(s ->> 'segmentCode'), nullif(trim(s ->> 'shiftCode'), ''),
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

      if not exists (
        select 1 from public.deep_groups g2
        where g2.id = v_target_group_id
          and public._m5a_segment_covers_group(nullif(trim(s ->> 'shiftCode'), ''), g2.shift_code)
      ) then
        raise exception '%의 관찰 대상 모둠이 그 구간의 반(%)에 속하지 않습니다.', s ->> 'segmentCode', s ->> 'shiftCode'
          using errcode = '23514';
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
