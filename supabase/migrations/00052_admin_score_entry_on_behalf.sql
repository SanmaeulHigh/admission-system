-- 새봄고 입학전형 시스템 — 관리자 대리 채점 입력 (모둠활동/면접/글쓰기)
--
-- 배경(2026-07-14): 본관(모둠활동·면접·글쓰기 평가 장소)은 학교 내부망이
-- 안 닿아 실시간 접속이 어려울 수 있다 — 종이로 채점 후 나중에 시스템에
-- 옮겨 적기로 결정. 원칙적으로는 평가위원 본인이 로그인해서 직접 입력하는
-- 게 가장 안전하지만("본인이 직접 입력" = 지금 있는 submit_* RPC 그대로
-- 재사용, 코드 변경 불필요), 그게 어려운 경우(평가위원이 자리를 뜸,
-- 계정 문제 등)를 대비해 superadmin/admin이 평가위원을 대신해 입력할 수
-- 있는 경로도 추가한다.
--
-- 설계 원칙:
--   * submit_group_score / submit_interview_score / submit_writing_score와
--     완전히 동일한 검증 로직(대상 지원자·평가위원 배정 확인, 문항/기준
--     완결성 검증, 중복제출 차단, 평가영역 오픈 여부)을 그대로 재사용한다
--     (_m5b_*/_m5c_*/_m5d_* 공용 헬퍼가 evaluator_uid를 매개변수로 받으므로
--     caller 대신 p_target_evaluator_uid를 넘기기만 하면 된다).
--   * get_evaluation_score_detail(00007) 패턴을 그대로 따른다: superadmin/
--     admin만 호출 가능, 사유코드(닫힌 목록 + "기타"는 자유서술 필수)를
--     반드시 남기고, audit_logs에 실제 입력한 사람(caller)과 실제 채점자로
--     기록될 대상(target_evaluator_uid)을 모두 남긴다.
--   * 이미 제출확정된 건은 덮어쓰지 않는다 — 먼저 reopen_score/
--     reopen_interview_score/reopen_writing_score로 재개방해야 한다
--     (평가위원 스스로의 실수 정정과 동일한 절차를 강제해 "관리자가 몰래
--     덮어씀"을 방지).

-- ============================================================
-- 1. 모둠활동
-- ============================================================

create or replace function public.admin_submit_group_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb,
  p_reason_code text,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
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
  valid_reasons text[] := array['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code using errcode = '22023';
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 reason_text를 반드시 입력해야 합니다.' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and 'evaluator' = any(u.roles) and 'group' = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 모둠활동 평가위원으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, p_target_evaluator_uid);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, p_target_evaluator_uid);

  if v_group_id is null or v_role is null then
    raise exception '대상 평가위원은 이 지원자를 관찰 배정받지 않았습니다.' using errcode = '42501';
  end if;
  if cardinality(v_observed) = 0 then
    raise exception '최소 1개 이상의 실제 관찰 segment를 선택해야 합니다.' using errcode = '23514';
  end if;
  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '관찰 배정되지 않은 segment를 제출 근거로 사용할 수 없습니다.' using errcode = '42501';
  end if;
  if v_role = 'roving' and coalesce(p_observation_confirmed, false) = false then
    raise exception '순환관찰위원은 충분한 관찰 확인이 있어야 제출할 수 있습니다.' using errcode = '23514';
  end if;

  v_effective_confirmed := case when v_role = 'primary' then true else coalesce(p_observation_confirmed, false) end;
  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, true);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid
  for update;
  if v_existing is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 채점입니다. 먼저 reopen_score로 재개방한 뒤 다시 입력하세요.' using errcode = '55000';
  end if;

  insert into public.scores_group
    (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
     observer_role, observation_confirmed, observed_segment_ids, items,
     server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, p_target_evaluator_uid, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     v_role, v_effective_confirmed, v_observed, p_items,
     jsonb_build_object('total', v_total, 'validForAggregate', true, 'observerRoleServerDetermined', v_role,
       'configRevisionId', v_round.config_revision_id, 'enteredByAdmin', true),
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
    'scoreId', id, 'total', (server_computed ->> 'total')::numeric,
    'observerRole', observer_role, 'submissionState', submission_state, 'revision', revision
  ) into v_result;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'score.group.admin_submitted', 'scores_group',
     v_result ->> 'scoreId', p_applicant_id::text, 'group', p_reason_code,
     jsonb_build_object('targetEvaluatorUid', p_target_evaluator_uid, 'reasonText', p_reason_text,
       'observerRole', v_role, 'revision', v_result -> 'revision'));

  return v_result;
end;
$$;

revoke all on function public.admin_submit_group_score(uuid, uuid, boolean, uuid[], jsonb, text, text) from public, anon;
grant execute on function public.admin_submit_group_score(uuid, uuid, boolean, uuid[], jsonb, text, text) to authenticated;

-- ============================================================
-- 2. 면접 (학생/학부모 공용, section 파라미터로 구분)
-- ============================================================

create or replace function public.admin_submit_interview_score(
  p_applicant_id uuid,
  p_section text,
  p_target_evaluator_uid uuid,
  p_items jsonb,
  p_memo text,
  p_reason_code text,
  p_reason_text text default null
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
  v_active boolean;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_existing public.scores_interview%rowtype;
  v_total numeric;
  v_score_id uuid;
  v_revision int;
  valid_reasons text[] := array['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '면접 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;
  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code using errcode = '22023';
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 reason_text를 반드시 입력해야 합니다.' using errcode = '23514';
  end if;

  select er.year, er.round, er.evaluation_active, er.interview_team_id
    into v_year, v_round, v_active, v_team_id
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;
  if v_team_id is null then
    raise exception '지원자에게 면접조가 배정되지 않았습니다.' using errcode = '55000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and 'evaluator' = any(u.roles) and 'interview' = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 면접 평가위원으로 등록되어 있지 않습니다.' using errcode = '42501';
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
      and m.evaluator_uid = p_target_evaluator_uid
  ) then
    raise exception '대상 평가위원은 이 지원자의 면접조에 배정되지 않았습니다.' using errcode = '42501';
  end if;

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

  perform pg_advisory_xact_lock(hashtextextended(format('m5c:score:%s:%s', p_applicant_id::text, p_target_evaluator_uid::text), 0));

  select * into v_existing
  from public.scores_interview
  where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid
  for update;

  if p_section = 'student' and v_existing.id is not null and v_existing.student_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학생면접 채점입니다. 먼저 reopen_interview_score로 재개방하세요.' using errcode = '55000';
  end if;
  if p_section = 'parent' and v_existing.id is not null and v_existing.parent_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학부모면접 채점입니다. 먼저 reopen_interview_score로 재개방하세요.' using errcode = '55000';
  end if;

  v_total := public._m5c_validate_and_total(v_config_revision_id, p_section, p_items, true);

  if p_section = 'student' then
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       student_items, student_memo, student_server_computed, student_submission_state,
       student_revision, student_client_updated_at, student_submitted_at)
    values
      (p_applicant_id, p_target_evaluator_uid, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id, 'enteredByAdmin', true),
       'submitted', coalesce(v_existing.student_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id, team_id = excluded.team_id,
      student_items = excluded.student_items, student_memo = excluded.student_memo,
      student_server_computed = excluded.student_server_computed,
      student_submission_state = 'submitted',
      student_revision = public.scores_interview.student_revision + 1,
      student_client_updated_at = now(), student_submitted_at = now(), updated_at = now()
    returning id, student_revision into v_score_id, v_revision;
  else
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       parent_items, parent_memo, parent_server_computed, parent_submission_state,
       parent_revision, parent_client_updated_at, parent_submitted_at)
    values
      (p_applicant_id, p_target_evaluator_uid, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id, 'enteredByAdmin', true),
       'submitted', coalesce(v_existing.parent_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id, team_id = excluded.team_id,
      parent_items = excluded.parent_items, parent_memo = excluded.parent_memo,
      parent_server_computed = excluded.parent_server_computed,
      parent_submission_state = 'submitted',
      parent_revision = public.scores_interview.parent_revision + 1,
      parent_client_updated_at = now(), parent_submitted_at = now(), updated_at = now()
    returning id, parent_revision into v_score_id, v_revision;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text,
     case when p_section = 'student' then 'score.interview.student.admin_submitted' else 'score.interview.parent.admin_submitted' end,
     'scores_interview', v_score_id::text, p_applicant_id::text, 'interview', p_reason_code,
     jsonb_build_object('targetEvaluatorUid', p_target_evaluator_uid, 'reasonText', p_reason_text, 'section', p_section, 'revision', v_revision));

  return jsonb_build_object('scoreId', v_score_id, 'section', p_section, 'total', v_total, 'submissionState', 'submitted', 'revision', v_revision);
end;
$$;

revoke all on function public.admin_submit_interview_score(uuid, text, uuid, jsonb, text, text, text) from public, anon;
grant execute on function public.admin_submit_interview_score(uuid, text, uuid, jsonb, text, text, text) to authenticated;

-- ============================================================
-- 3. 글쓰기
-- ============================================================

create or replace function public.admin_submit_writing_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_responses jsonb,
  p_memo text,
  p_reason_code text,
  p_reason_text text default null
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
  v_active boolean;
  v_config_revision_id uuid;
  v_existing public.scores_writing%rowtype;
  v_computed jsonb;
  v_score_id uuid;
  v_revision int;
  valid_reasons text[] := array['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '글쓰기 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;
  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code using errcode = '22023';
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 reason_text를 반드시 입력해야 합니다.' using errcode = '23514';
  end if;

  select er.year, er.round, er.evaluation_active into v_year, v_round, v_active
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and 'evaluator' = any(u.roles) and 'writing' = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 글쓰기 평가위원으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.writing_evaluation_plans p
    join public.writing_plan_members m on m.year = p.year and m.round = p.round
    join public.decision_results dr
      on dr.run_id = p.document_source_run_id
     and dr.applicant_id = p_applicant_id
     and dr.outcome = 'passed'
    where p.year = v_year and p.round = v_round
      and p.status = 'finalized'
      and m.evaluator_uid = p_target_evaluator_uid
  ) then
    raise exception '대상 평가위원은 이 지원자의 글쓰기 채점 대상이 아닙니다.' using errcode = '42501';
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';

  if not exists (
    select 1 from public.admission_rounds ar
    where ar.year = v_year and ar.round = v_round
      and ar.stage_status = 'open'
      and 'writing'::evaluation_area = any(ar.open_evaluation_areas)
  ) then
    raise exception '글쓰기 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:score:%s:%s', p_applicant_id::text, p_target_evaluator_uid::text), 0));

  select * into v_existing
  from public.scores_writing
  where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 글쓰기 채점입니다. 먼저 reopen_writing_score로 재개방하세요.' using errcode = '55000';
  end if;

  v_computed := public._m5d_validate_and_total(v_config_revision_id, p_responses, true);

  insert into public.scores_writing
    (applicant_id, evaluator_uid, year, round, config_revision_id,
     responses, memo, server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, p_target_evaluator_uid, v_year, v_round, v_config_revision_id,
     p_responses, p_memo, v_computed, 'submitted', coalesce(v_existing.revision, 0) + 1, now(), now())
  on conflict (applicant_id, evaluator_uid) do update set
    config_revision_id = excluded.config_revision_id,
    responses = excluded.responses,
    memo = excluded.memo,
    server_computed = excluded.server_computed,
    submission_state = 'submitted',
    revision = public.scores_writing.revision + 1,
    client_updated_at = now(),
    submitted_at = now(),
    updated_at = now()
  returning id, revision into v_score_id, v_revision;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.writing.admin_submitted', 'scores_writing',
     v_score_id::text, p_applicant_id::text, 'writing', p_reason_code,
     jsonb_build_object('targetEvaluatorUid', p_target_evaluator_uid, 'reasonText', p_reason_text, 'revision', v_revision));

  return jsonb_build_object(
    'scoreId', v_score_id, 'total', (v_computed ->> 'total')::numeric,
    'questionTotals', v_computed -> 'questionTotals',
    'submissionState', 'submitted', 'revision', v_revision
  );
end;
$$;

revoke all on function public.admin_submit_writing_score(uuid, uuid, jsonb, text, text, text) from public, anon;
grant execute on function public.admin_submit_writing_score(uuid, uuid, jsonb, text, text, text) to authenticated;
