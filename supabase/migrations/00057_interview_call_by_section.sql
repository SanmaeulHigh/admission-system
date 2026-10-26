-- 새봄고 입학전형 시스템 — 면접 호출 단위를 "학생면접 / 학부모면접"으로 분리
-- (2026-07-31, 00056 직후 설계 정정)
--
-- 00056은 호출 단위를 "지원자 1명"으로 잡았는데 이는 실제 운영과 다르다.
-- 실제 면접은 한 지원자당 두 번, 순차로 진행된다.
--
--   ① 지원자(학생) 호출 → 학생면접 → 종료
--   ② 보호자 호출        → 학부모면접 → 종료
--   ③ 다음 지원자 학생 호출 → …
--
-- 즉 지원자와 보호자는 함께 움직이지 않는다. 그래서 대기열의 단위는
-- (지원자, 면접구분)이어야 한다. interview_schedules가 이미 student_starts_at /
-- parent_starts_at을 따로 갖고 있는 것도 같은 이유다.
--
-- 00056의 두 테이블은 아직 실제 전형에 쓰이기 전(면접일 2026-11-14)이라
-- 보존할 데이터가 없다. 컬럼을 덧붙여 어정쩡하게 두는 것보다 올바른 키로
-- 다시 만드는 편이 명확해서 drop 후 재생성한다.

drop table if exists public.interview_queue_state;
drop table if exists public.interview_call_sms_log;

-- ============================================================
-- 1. 대기열 상태 — (year, round, applicant_id, section)당 1행
-- ============================================================

create table public.interview_queue_state (
  year int not null,
  round admission_round not null,
  applicant_id uuid not null,
  section text not null check (section in ('student', 'parent')),
  team_id uuid not null references public.interview_teams (id) on delete cascade,
  advance_called_at timestamptz,
  advance_called_by uuid references public.users (id),
  called_at timestamptz,
  called_by uuid references public.users (id),
  completed_at timestamptz,
  completed_by uuid references public.users (id),
  updated_at timestamptz not null default now(),
  primary key (year, round, applicant_id, section)
);

comment on table public.interview_queue_state is
  '면접 호출 진행 상태. 단위는 (지원자, 면접구분) — 학생면접과 학부모면접은 각각 따로 호출·완료된다.';

create index interview_queue_state_team_idx
  on public.interview_queue_state (year, round, team_id);

-- ============================================================
-- 2. 호출 문자 발송 로그 (연락처는 저장하지 않는다)
-- ============================================================

create table public.interview_call_sms_log (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null,
  section text not null check (section in ('student', 'parent')),
  call_type text not null check (call_type in ('advance', 'now')),
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid references public.users (id),
  created_at timestamptz not null default now()
);

create index interview_call_sms_log_applicant_idx
  on public.interview_call_sms_log (year, round, applicant_id);

alter table public.interview_queue_state enable row level security;
alter table public.interview_call_sms_log enable row level security;

revoke all on public.interview_queue_state from anon, authenticated;
revoke all on public.interview_call_sms_log from anon, authenticated;

-- ============================================================
-- 3. 호출 / 예고 / 완료 / 취소 — 모두 section 인자를 받는다
--    (00056의 동명 함수는 인자 개수가 달라 그대로 남으므로 명시적으로 제거)
-- ============================================================

drop function if exists public.call_interview_applicant(int, admission_round, uuid, text);
drop function if exists public.complete_interview_applicant(int, admission_round, uuid);
drop function if exists public.cancel_interview_call(int, admission_round, uuid, text);
drop function if exists public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, boolean, text, text);

create or replace function public.call_interview_applicant(
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
  v_team_id uuid;
  v_now timestamptz := now();
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 구분은 student 또는 parent만 가능합니다.';
  end if;
  if p_call_type not in ('advance', 'now') then
    raise exception '호출 종류는 advance 또는 now만 가능합니다.';
  end if;

  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select team_id into v_team_id
  from public.interview_schedules
  where year = p_year and round = p_round and applicant_id = p_applicant_id;

  insert into public.interview_queue_state as q
    (year, round, applicant_id, section, team_id,
     advance_called_at, advance_called_by, called_at, called_by, updated_at)
  values
    (p_year, p_round, p_applicant_id, p_section, v_team_id,
     case when p_call_type = 'advance' then v_now end,
     case when p_call_type = 'advance' then caller end,
     case when p_call_type = 'now' then v_now end,
     case when p_call_type = 'now' then caller end,
     v_now)
  on conflict (year, round, applicant_id, section) do update set
    team_id = excluded.team_id,
    advance_called_at = case when p_call_type = 'advance' then v_now else q.advance_called_at end,
    advance_called_by = case when p_call_type = 'advance' then caller else q.advance_called_by end,
    called_at = case when p_call_type = 'now' then v_now else q.called_at end,
    called_by = case when p_call_type = 'now' then caller else q.called_by end,
    -- 다시 호출하면 완료 표시는 해제한다(잘못 완료 처리한 경우의 복구 경로)
    completed_at = case when p_call_type = 'now' then null else q.completed_at end,
    completed_by = case when p_call_type = 'now' then null else q.completed_by end,
    updated_at = v_now;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when p_call_type = 'advance' then 'interview.call.advance' else 'interview.call.now' end,
     'interview_queue_state', p_applicant_id::text,
     jsonb_build_object('section', p_section, 'callType', p_call_type));

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'section', p_section,
    'callType', p_call_type,
    'calledAt', v_now
  );
end;
$$;

revoke all on function public.call_interview_applicant(int, admission_round, uuid, text, text) from public, anon;
grant execute on function public.call_interview_applicant(int, admission_round, uuid, text, text) to authenticated;

create or replace function public.complete_interview_applicant(
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
  v_now timestamptz := now();
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 구분은 student 또는 parent만 가능합니다.';
  end if;

  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  update public.interview_queue_state
  set completed_at = v_now, completed_by = caller, updated_at = v_now
  where year = p_year and round = p_round
    and applicant_id = p_applicant_id and section = p_section;

  if not found then
    raise exception '아직 호출된 적이 없는 순서입니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.completed',
     'interview_queue_state', p_applicant_id::text,
     jsonb_build_object('section', p_section));

  return jsonb_build_object('applicantId', p_applicant_id, 'section', p_section, 'completedAt', v_now);
end;
$$;

revoke all on function public.complete_interview_applicant(int, admission_round, uuid, text) from public, anon;
grant execute on function public.complete_interview_applicant(int, admission_round, uuid, text) to authenticated;

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

-- ============================================================
-- 4. 면접위원용 대기열 조회 — 지원자별로 student/parent 두 순서를 함께 반환
-- ============================================================

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

-- ============================================================
-- 5. 대기실 프로젝터 송출용 (익명 접근) — 마스킹된 정보만
-- ============================================================

create or replace function public.get_interview_display_board()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int;
  v_round admission_round;
  v_plan_status text;
  v_teams jsonb;
begin
  select year, round into v_year, v_round
  from public.admission_rounds
  where is_current = true
  limit 1;

  if v_year is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_CURRENT_CYCLE', 'serverNow', now());
  end if;

  select status into v_plan_status
  from public.interview_team_plans
  where year = v_year and round = v_round;

  if v_plan_status is distinct from 'finalized' then
    return jsonb_build_object(
      'ready', false, 'reason', 'PLAN_NOT_FINALIZED',
      'year', v_year, 'round', v_round, 'serverNow', now());
  end if;

  select coalesce(jsonb_agg(team order by team_sort, team_code), '[]'::jsonb)
  into v_teams
  from (
    select t.sort_order as team_sort, t.team_code, jsonb_build_object(
      'teamId', t.id,
      'teamCode', t.team_code,
      'location', t.location,
      'items', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'examNo', r.exam_no,
            'maskedName', public._mask_display_name(r.display_name),
            'sortOrder', s.sort_order,
            'student', jsonb_build_object(
              'advanceCalledAt', qs.advance_called_at,
              'calledAt', qs.called_at,
              'completedAt', qs.completed_at
            ),
            'parent', jsonb_build_object(
              'advanceCalledAt', qp.advance_called_at,
              'calledAt', qp.called_at,
              'completedAt', qp.completed_at
            )
          ) order by s.sort_order, s.student_starts_at
        ), '[]'::jsonb)
        from public.interview_schedules s
        join public.evaluation_roster r on r.applicant_id = s.applicant_id
        left join public.interview_queue_state qs
          on qs.year = s.year and qs.round = s.round
         and qs.applicant_id = s.applicant_id and qs.section = 'student'
        left join public.interview_queue_state qp
          on qp.year = s.year and qp.round = s.round
         and qp.applicant_id = s.applicant_id and qp.section = 'parent'
        where s.year = v_year and s.round = v_round and s.team_id = t.id
      )
    ) as team
    from public.interview_teams t
    where t.year = v_year and t.round = v_round and t.active = true
  ) sub;

  return jsonb_build_object(
    'ready', true,
    'year', v_year,
    'round', v_round,
    'teams', v_teams,
    'serverNow', now()
  );
end;
$$;

revoke all on function public.get_interview_display_board() from public;
grant execute on function public.get_interview_display_board() to anon, authenticated;

-- ============================================================
-- 6. 문자 발송 결과 기록 (section 포함)
-- ============================================================

create or replace function public.record_interview_call_sms_sent(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
  p_section text,
  p_call_type text,
  p_target text,
  p_sent boolean,
  p_provider_code text default null,
  p_provider_message text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  insert into public.interview_call_sms_log
    (year, round, applicant_id, section, call_type, target, sent,
     provider_code, provider_message, sent_by)
  values
    (p_year, p_round, p_applicant_id, p_section, p_call_type, p_target, p_sent,
     p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.sms_sent',
     'interview_call_sms_log', p_applicant_id::text,
     jsonb_build_object('section', p_section, 'callType', p_call_type,
                        'target', p_target, 'sent', p_sent));
end;
$$;

revoke all on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text)
  from public, anon;
grant execute on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text)
  to authenticated;
