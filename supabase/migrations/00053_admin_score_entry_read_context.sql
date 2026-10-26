-- 새봄고 입학전형 시스템 — 관리자 대리 채점 입력 화면용 조회 RPC
-- 00052(admin_submit_*_score)의 짝 — 관리자가 "누구를, 어떤 지원자를"
-- 입력할지 고르려면 평가위원 목록과 그 평가위원 기준 명단/기존 입력 상태를
-- 봐야 한다. get_m5b/c/d_*_workspace와 쿼리 로직은 동일하고, auth.uid()
-- 대신 관리자가 지정한 p_target_evaluator_uid를 쓴다는 점만 다르다.

-- ============================================================
-- 0. 평가위원 선택 목록
-- ============================================================

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
  v_result jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email
  ) order by display_name), '[]'::jsonb)
  into v_result
  from public.users
  where active = true
    and 'evaluator' = any(roles)
    and p_area = any(assigned_areas);

  return v_result;
end;
$$;

revoke all on function public.admin_list_score_entry_evaluators(evaluation_area) from public, anon;
grant execute on function public.admin_list_score_entry_evaluators(evaluation_area) to authenticated;

-- ============================================================
-- 1. 모둠활동 — get_m5b_observation_workspace를 caller 대신
--    p_target_evaluator_uid 기준으로 그대로 재구성
-- ============================================================

create or replace function public.admin_get_group_score_entry_context(
  p_year int,
  p_round admission_round,
  p_target_evaluator_uid uuid
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
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

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
      'segmentId', s.id, 'segmentCode', s.segment_code,
      'startsAt', s.starts_at, 'endsAt', s.ends_at,
      'targetGroupId', ra.target_group_id
    ) order by s.sort_order, s.starts_at), '[]'::jsonb)
    into v_segments
  from public.deep_group_rotation_segments s
  join public.deep_group_rotation_assignments ra
    on ra.segment_id = s.id and ra.evaluator_uid = p_target_evaluator_uid
  where s.year = p_year and s.round = p_round;

  select coalesce(jsonb_agg(jsonb_build_object(
      'groupId', g.id, 'groupCode', g.group_code,
      'observerRole', case when exists (
        select 1 from public.deep_group_primary_observers po
        where po.group_id = g.id and po.evaluator_uid = p_target_evaluator_uid
      ) then 'primary' else 'roving' end,
      'allowedSegmentIds', coalesce((
        select jsonb_agg(ra.segment_id order by s.sort_order, s.starts_at)
        from public.deep_group_rotation_assignments ra
        join public.deep_group_rotation_segments s on s.id = ra.segment_id
        where ra.evaluator_uid = p_target_evaluator_uid and ra.target_group_id = g.id
      ), '[]'::jsonb),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'applicantId', er.applicant_id, 'examNo', er.exam_no, 'displayName', er.display_name,
          'myScore', case when sg.id is null then null else jsonb_build_object(
            'scoreId', sg.id, 'observationConfirmed', sg.observation_confirmed,
            'observedSegmentIds', to_jsonb(sg.observed_segment_ids), 'items', sg.items,
            'observerRole', sg.observer_role, 'submissionState', sg.submission_state,
            'revision', sg.revision, 'serverComputed', sg.server_computed,
            'clientUpdatedAt', sg.client_updated_at, 'submittedAt', sg.submitted_at
          ) end
        ) order by gm.sort_order, er.exam_no, er.display_name)
        from public.deep_group_members gm
        join public.evaluation_roster er on er.applicant_id = gm.applicant_id
        left join public.scores_group sg
          on sg.applicant_id = gm.applicant_id and sg.evaluator_uid = p_target_evaluator_uid
        where gm.group_id = g.id
      ), '[]'::jsonb)
    ) order by g.sort_order, g.group_code), '[]'::jsonb)
    into v_groups
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true
    and (
      exists (select 1 from public.deep_group_primary_observers po where po.group_id = g.id and po.evaluator_uid = p_target_evaluator_uid)
      or exists (select 1 from public.deep_group_rotation_assignments ra where ra.evaluator_uid = p_target_evaluator_uid and ra.target_group_id = g.id)
    );

  return jsonb_build_object(
    'year', p_year, 'round', p_round, 'planRevision', v_plan.revision,
    'areaOpen', v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas),
    'criteria', v_params -> 'criteria',
    'criterionMax', (v_params ->> 'criterionMax')::numeric,
    'scoreStep', (v_params ->> 'scoreStep')::numeric,
    'perEvaluatorMax', (v_params ->> 'perEvaluatorMax')::numeric,
    'segments', v_segments, 'groups', v_groups
  );
end;
$$;

revoke all on function public.admin_get_group_score_entry_context(int, admission_round, uuid) from public, anon;
grant execute on function public.admin_get_group_score_entry_context(int, admission_round, uuid) to authenticated;

-- ============================================================
-- 2. 면접
-- ============================================================

create or replace function public.admin_get_interview_score_entry_context(
  p_year int,
  p_round admission_round,
  p_target_evaluator_uid uuid
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
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

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
    and m.evaluator_uid = p_target_evaluator_uid
  limit 1;

  if not found then
    raise exception '이 평가위원에게 최종확정된 면접조 배정이 없습니다.' using errcode = '42501';
  end if;

  select p.config_revision_id into v_plan_config_revision_id
  from public.interview_team_plans p
  where p.year = p_year and p.round = p_round and p.status = 'finalized';

  v_student_params := public._m5c_interview_params(v_plan_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_plan_config_revision_id, 'parent');

  select coalesce(jsonb_agg(jsonb_build_object(
    'scheduleId', s.id, 'applicantId', er.applicant_id, 'examNo', er.exam_no, 'displayName', er.display_name,
    'studentStartsAt', s.student_starts_at, 'studentEndsAt', s.student_ends_at,
    'parentStartsAt', s.parent_starts_at, 'parentEndsAt', s.parent_ends_at,
    'sortOrder', s.sort_order,
    'myScore', case when si.id is null then null else jsonb_build_object(
      'scoreId', si.id,
      'student', jsonb_build_object(
        'items', si.student_items, 'memo', si.student_memo,
        'submissionState', si.student_submission_state, 'revision', si.student_revision,
        'serverComputed', si.student_server_computed,
        'clientUpdatedAt', si.student_client_updated_at, 'submittedAt', si.student_submitted_at
      ),
      'parent', jsonb_build_object(
        'items', si.parent_items, 'memo', si.parent_memo,
        'submissionState', si.parent_submission_state, 'revision', si.parent_revision,
        'serverComputed', si.parent_server_computed,
        'clientUpdatedAt', si.parent_client_updated_at, 'submittedAt', si.parent_submitted_at
      )
    ) end
  ) order by s.sort_order, s.student_starts_at), '[]'::jsonb)
  into v_schedule
  from public.interview_schedules s
  join public.evaluation_roster er on er.applicant_id = s.applicant_id
  left join public.scores_interview si
    on si.applicant_id = s.applicant_id and si.evaluator_uid = p_target_evaluator_uid
  where s.team_id = v_team.id;

  return jsonb_build_object(
    'year', p_year, 'round', p_round,
    'areaOpen', v_round.stage_status = 'open' and 'interview'::evaluation_area = any(v_round.open_evaluation_areas),
    'team', jsonb_build_object('teamId', v_team.id, 'teamCode', v_team.team_code, 'location', v_team.location),
    'student', jsonb_build_object(
      'criteria', v_student_params -> 'criteria',
      'perEvaluatorMax', (v_student_params ->> 'perEvaluatorMax')::numeric
    ),
    'parent', jsonb_build_object(
      'criteria', v_parent_params -> 'criteria',
      'perEvaluatorMax', (v_parent_params ->> 'perEvaluatorMax')::numeric
    ),
    'schedule', v_schedule
  );
end;
$$;

revoke all on function public.admin_get_interview_score_entry_context(int, admission_round, uuid) from public, anon;
grant execute on function public.admin_get_interview_score_entry_context(int, admission_round, uuid) to authenticated;

-- ============================================================
-- 3. 글쓰기
-- ============================================================

create or replace function public.admin_get_writing_score_entry_context(
  p_year int,
  p_round admission_round,
  p_target_evaluator_uid uuid
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
  v_config jsonb;
  v_candidates jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if not found then raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002'; end if;

  select p.* into v_plan
  from public.writing_evaluation_plans p
  join public.writing_plan_members m on m.year = p.year and m.round = p.round
  where p.year = p_year and p.round = p_round and p.status = 'finalized' and m.evaluator_uid = p_target_evaluator_uid;
  if not found then
    raise exception '이 평가위원에게 최종확정된 글쓰기 평가 배정이 없습니다.' using errcode = '42501';
  end if;

  v_config := public._m5d_writing_params(v_plan.config_revision_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', er.applicant_id, 'examNo', er.exam_no, 'displayName', er.display_name,
    'rankOrder', dr.rank,
    'myScore', case when sw.id is null then null else jsonb_build_object(
      'scoreId', sw.id, 'responses', sw.responses, 'memo', sw.memo,
      'submissionState', sw.submission_state, 'revision', sw.revision,
      'serverComputed', sw.server_computed,
      'clientUpdatedAt', sw.client_updated_at, 'submittedAt', sw.submitted_at
    ) end
  ) order by dr.rank, er.exam_no, er.display_name), '[]'::jsonb)
  into v_candidates
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  left join public.scores_writing sw on sw.applicant_id = dr.applicant_id and sw.evaluator_uid = p_target_evaluator_uid
  where dr.run_id = v_plan.document_source_run_id and dr.outcome = 'passed';

  return jsonb_build_object(
    'year', p_year, 'round', p_round,
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'configRevisionId', v_plan.config_revision_id,
    'config', v_config,
    'candidates', v_candidates
  );
end;
$$;

revoke all on function public.admin_get_writing_score_entry_context(int, admission_round, uuid) from public, anon;
grant execute on function public.admin_get_writing_score_entry_context(int, admission_round, uuid) to authenticated;
