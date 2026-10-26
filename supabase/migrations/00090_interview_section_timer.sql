-- 새봄고 입학전형 시스템 — 면접실 타이머(면접 시작 시각 공유) (2026-10-14)
--
-- 면접위원 화면에 지원자별 타이머(학생 25분·보호자 20분)를 띄운다. 같은 조 위원 2명이 각자 기기로
-- 보더라도 같은 시각을 기준으로 줄어들도록 '면접 시작' 시각을 서버(interview_queue_state.started_at)에 둔다.
--   - start_interview_section : 시작(다시 누르면 지금 시각으로 다시 시작). 호출 없이 바로 시작도 허용
--     (진행요원이 학생을 데려온 경우). 완료 표시는 지우지 않는다.
--   - cancel_interview_call('now') 는 시작 기록도 함께 지운다.
--   - get_interview_call_queue 가 startedAt 을 함께 돌려준다. 시계 차이는 응답의 serverNow 로 보정한다.

alter table public.interview_queue_state
  add column if not exists started_at timestamptz,
  add column if not exists started_by uuid references public.users (id);

create or replace function public.start_interview_section(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
  p_section text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_team_id uuid;
  v_now timestamptz := now();
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 구분은 student 또는 parent만 가능합니다.';
  end if;

  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select team_id into v_team_id
  from public.interview_schedules
  where year = p_year and round = p_round and applicant_id = p_applicant_id;

  insert into public.interview_queue_state as q
    (year, round, applicant_id, section, team_id, started_at, started_by, updated_at)
  values
    (p_year, p_round, p_applicant_id, p_section, v_team_id, v_now, caller, v_now)
  on conflict (year, round, applicant_id, section) do update set
    started_at = v_now,
    started_by = caller,
    completed_at = null,
    completed_by = null,
    updated_at = v_now;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.section.started',
     'interview_queue_state', p_applicant_id::text, jsonb_build_object('section', p_section));

  return jsonb_build_object('applicantId', p_applicant_id, 'section', p_section, 'startedAt', v_now);
end;
$$;

revoke all on function public.start_interview_section(int, admission_round, uuid, text) from public, anon;
grant execute on function public.start_interview_section(int, admission_round, uuid, text) to authenticated;

-- 호출 취소 시 시작 기록도 지움
create or replace function public.cancel_interview_call(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
  p_section text,
  p_call_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_now timestamptz := now();
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 구분은 student 또는 parent만 가능합니다.';
  end if;
  if p_call_type not in ('advance', 'now') then
    raise exception '호출 종류는 advance 또는 now만 가능합니다.';
  end if;

  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  update public.interview_queue_state
  set advance_called_at = case when p_call_type = 'advance' then null else advance_called_at end,
      advance_called_by = case when p_call_type = 'advance' then null else advance_called_by end,
      called_at = case when p_call_type = 'now' then null else called_at end,
      called_by = case when p_call_type = 'now' then null else called_by end,
      completed_at = case when p_call_type = 'now' then null else completed_at end,
      completed_by = case when p_call_type = 'now' then null else completed_by end,
      started_at = case when p_call_type = 'now' then null else started_at end,
      started_by = case when p_call_type = 'now' then null else started_by end,
      updated_at = v_now
  where year = p_year and round = p_round
    and applicant_id = p_applicant_id and section = p_section;

  if not found then
    raise exception '취소할 호출 기록이 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.cancelled',
     'interview_queue_state', p_applicant_id::text,
     jsonb_build_object('section', p_section, 'callType', p_call_type));

  return jsonb_build_object('applicantId', p_applicant_id, 'section', p_section, 'callType', p_call_type);
end;
$$;

revoke all on function public.cancel_interview_call(int, admission_round, uuid, text, text) from public, anon;
grant execute on function public.cancel_interview_call(int, admission_round, uuid, text, text) to authenticated;

-- 대기열 조회에 startedAt 추가
create or replace function public.get_interview_call_queue(
  p_year int,
  p_round admission_round,
  p_team_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_is_admin boolean;
  v_team_id uuid;
  v_result jsonb;
  v_team jsonb;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users where id = caller and active = true) then
    raise exception '비활성 계정입니다.' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.users
    where id = caller and active = true
      and roles && array['superadmin', 'admin']::app_role[]
  ) into v_is_admin;

  if p_team_id is not null and v_is_admin then
    v_team_id := p_team_id;
  else
    select m.team_id into v_team_id
    from public.interview_team_members m
    join public.interview_teams t on t.id = m.team_id
    where m.evaluator_uid = caller and t.year = p_year and t.round = p_round and t.active = true
    limit 1;
  end if;

  if v_team_id is null then
    return jsonb_build_object('team', null, 'items', '[]'::jsonb, 'serverNow', now());
  end if;

  select jsonb_build_object('teamId', t.id, 'teamCode', t.team_code, 'location', t.location)
  into v_team
  from public.interview_teams t
  where t.id = v_team_id;

  select coalesce(jsonb_agg(item order by sort_order, student_starts_at), '[]'::jsonb)
  into v_result
  from (
    select s.sort_order, s.student_starts_at, jsonb_build_object(
      'applicantId', s.applicant_id,
      'examNo', r.exam_no,
      'displayName', r.display_name,
      'sortOrder', s.sort_order,
      'student', jsonb_build_object(
        'startsAt', s.student_starts_at,
        'endsAt', s.student_ends_at,
        'advanceCalledAt', qs.advance_called_at,
        'calledAt', qs.called_at,
        'startedAt', qs.started_at,
        'completedAt', qs.completed_at,
        'smsAdvanceSent', exists (
          select 1 from public.interview_call_sms_log l
          where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
            and l.section = 'student' and l.call_type = 'advance' and l.sent = true),
        'smsNowSent', exists (
          select 1 from public.interview_call_sms_log l
          where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
            and l.section = 'student' and l.call_type = 'now' and l.sent = true)
      ),
      'parent', jsonb_build_object(
        'startsAt', s.parent_starts_at,
        'endsAt', s.parent_ends_at,
        'advanceCalledAt', qp.advance_called_at,
        'calledAt', qp.called_at,
        'startedAt', qp.started_at,
        'completedAt', qp.completed_at,
        'smsAdvanceSent', exists (
          select 1 from public.interview_call_sms_log l
          where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
            and l.section = 'parent' and l.call_type = 'advance' and l.sent = true),
        'smsNowSent', exists (
          select 1 from public.interview_call_sms_log l
          where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
            and l.section = 'parent' and l.call_type = 'now' and l.sent = true)
      )
    ) as item
    from public.interview_schedules s
    join public.evaluation_roster r on r.applicant_id = s.applicant_id
    left join public.interview_queue_state qs
      on qs.year = s.year and qs.round = s.round
     and qs.applicant_id = s.applicant_id and qs.section = 'student'
    left join public.interview_queue_state qp
      on qp.year = s.year and qp.round = s.round
     and qp.applicant_id = s.applicant_id and qp.section = 'parent'
    where s.year = p_year and s.round = p_round and s.team_id = v_team_id
  ) sub;

  return jsonb_build_object('team', v_team, 'items', v_result, 'serverNow', now());
end;
$$;

revoke all on function public.get_interview_call_queue(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_queue(int, admission_round, uuid) to authenticated;
