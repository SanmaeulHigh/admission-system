-- 새봄고 입학전형 시스템 — 면접 실시간 호출·대기열 (2026-07-31 추가)
--
-- 배경: 면접 당일 본관 2층에 대기실을 운영하고, 1층(또는 면접실)에서
-- 면접위원이 "다음 지원자 호출"을 누르면 (1) 대기실 프로젝터 화면에 즉시
-- 표시되고 (2) 해당 지원자·보호자에게 문자가 나가는 구조.
--
-- 호출 종류는 두 가지다.
--   advance : 한 팀 앞서 미리 예고("곧 순서입니다") — 이동 시간 확보용
--   now     : 지금 내려오세요
-- 그리고 면접이 끝나면 completed로 표시해 대기실 화면에서 내린다.
--
-- 설계 원칙:
-- 1) 기존 M5c 면접 배정(interview_schedules)을 그대로 쓴다. 새 배정 개념을
--    만들지 않는다 — 최종확정(finalized)된 면접 계획이 있어야만 동작한다.
-- 2) 호출 권한은 "그 지원자가 배정된 면접조의 위원" 또는 superadmin/admin.
--    남의 조 지원자를 실수로 호출하는 것을 서버에서 막는다.
-- 3) 대기실 프로젝터는 로그인 없이 띄운다(종일 송출 + 세션 만료 걱정 제거).
--    대신 익명으로 열리는 RPC는 수험번호 + 마스킹된 성명만 반환하고,
--    연락처·점수·전형구분은 절대 내보내지 않는다. 대기실에는 다른 지원자와
--    학부모가 함께 있으므로 화면 노출 정보를 최소화하는 것이 원칙이다.

-- ============================================================
-- 0. 성명 마스킹 (홍길동 → 홍*동, 김철 → 김*)
-- ============================================================

create or replace function public._mask_display_name(p_name text)
returns text
language sql
immutable
as $$
  select case
    when p_name is null or length(btrim(p_name)) = 0 then '-'
    when length(btrim(p_name)) <= 2 then left(btrim(p_name), 1) || '*'
    else left(btrim(p_name), 1)
         || repeat('*', length(btrim(p_name)) - 2)
         || right(btrim(p_name), 1)
  end;
$$;

comment on function public._mask_display_name(text) is
  '대기실 프로젝터 등 불특정 다수가 보는 화면에서 성명을 부분 가림 처리한다.';

-- ============================================================
-- 1. 대기열 상태 — (year, round, applicant_id)당 1행
-- ============================================================

create table public.interview_queue_state (
  year int not null,
  round admission_round not null,
  applicant_id uuid not null,
  team_id uuid not null references public.interview_teams (id) on delete cascade,
  advance_called_at timestamptz,
  advance_called_by uuid references public.users (id),
  called_at timestamptz,
  called_by uuid references public.users (id),
  completed_at timestamptz,
  completed_by uuid references public.users (id),
  updated_at timestamptz not null default now(),
  primary key (year, round, applicant_id)
);

comment on table public.interview_queue_state is
  '면접 당일 호출 진행 상태. 배정 자체는 interview_schedules가 원본이고 이 테이블은 "언제 예고/호출/완료했는가"만 기록한다.';

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

-- ============================================================
-- 3. RLS — 클라이언트 직접 읽기/쓰기 전면 차단, RPC로만 접근
-- ============================================================

alter table public.interview_queue_state enable row level security;
alter table public.interview_call_sms_log enable row level security;

revoke all on public.interview_queue_state from anon, authenticated;
revoke all on public.interview_call_sms_log from anon, authenticated;

-- ============================================================
-- 4. 내부 헬퍼 — 호출 권한 확인
--    "그 지원자가 배정된 조의 면접위원" 또는 superadmin/admin만 허용.
-- ============================================================

create or replace function public._require_interview_call_permission(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_team_id uuid;
  v_plan_status text;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users where id = caller and active = true) then
    raise exception '비활성 계정입니다.' using errcode = '42501';
  end if;

  select status into v_plan_status
  from public.interview_team_plans
  where year = p_year and round = p_round;

  if v_plan_status is distinct from 'finalized' then
    raise exception '면접 배정이 아직 최종확정되지 않아 호출할 수 없습니다.' using errcode = '42501';
  end if;

  select s.team_id into v_team_id
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round and s.applicant_id = p_applicant_id;

  if v_team_id is null then
    raise exception '이 지원자의 면접 배정을 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  -- superadmin/admin은 전 조 호출 가능
  if exists (
    select 1 from public.users
    where id = caller and active = true
      and roles && array['superadmin', 'admin']::app_role[]
  ) then
    return caller;
  end if;

  -- 그 외에는 해당 조의 면접위원만
  if not exists (
    select 1 from public.interview_team_members m
    where m.team_id = v_team_id and m.evaluator_uid = caller
  ) then
    raise exception '본인이 배정된 면접조의 지원자만 호출할 수 있습니다.' using errcode = '42501';
  end if;

  return caller;
end;
$$;

revoke execute on function public._require_interview_call_permission(int, admission_round, uuid)
  from anon, authenticated;

-- ============================================================
-- 5. 호출 / 예고 / 완료 / 취소 RPC
-- ============================================================

create or replace function public.call_interview_applicant(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
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
  if p_call_type not in ('advance', 'now') then
    raise exception '호출 종류는 advance 또는 now만 가능합니다.';
  end if;

  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select team_id into v_team_id
  from public.interview_schedules
  where year = p_year and round = p_round and applicant_id = p_applicant_id;

  insert into public.interview_queue_state as q
    (year, round, applicant_id, team_id,
     advance_called_at, advance_called_by, called_at, called_by, updated_at)
  values
    (p_year, p_round, p_applicant_id, v_team_id,
     case when p_call_type = 'advance' then v_now end,
     case when p_call_type = 'advance' then caller end,
     case when p_call_type = 'now' then v_now end,
     case when p_call_type = 'now' then caller end,
     v_now)
  on conflict (year, round, applicant_id) do update set
    team_id = excluded.team_id,
    advance_called_at = case when p_call_type = 'advance' then v_now else q.advance_called_at end,
    advance_called_by = case when p_call_type = 'advance' then caller else q.advance_called_by end,
    called_at = case when p_call_type = 'now' then v_now else q.called_at end,
    called_by = case when p_call_type = 'now' then caller else q.called_by end,
    -- 다시 호출하면 완료 표시는 해제한다(잘못 완료 처리한 경우 복구 경로)
    completed_at = case when p_call_type = 'now' then null else q.completed_at end,
    completed_by = case when p_call_type = 'now' then null else q.completed_by end,
    updated_at = v_now;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when p_call_type = 'advance' then 'interview.call.advance' else 'interview.call.now' end,
     'interview_queue_state', p_applicant_id::text,
     jsonb_build_object('callType', p_call_type));

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'callType', p_call_type,
    'calledAt', v_now
  );
end;
$$;

revoke all on function public.call_interview_applicant(int, admission_round, uuid, text) from public, anon;
grant execute on function public.call_interview_applicant(int, admission_round, uuid, text) to authenticated;

create or replace function public.complete_interview_applicant(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid
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
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  update public.interview_queue_state
  set completed_at = v_now, completed_by = caller, updated_at = v_now
  where year = p_year and round = p_round and applicant_id = p_applicant_id;

  if not found then
    raise exception '아직 호출된 적이 없는 지원자입니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.completed',
     'interview_queue_state', p_applicant_id::text);

  return jsonb_build_object('applicantId', p_applicant_id, 'completedAt', v_now);
end;
$$;

revoke all on function public.complete_interview_applicant(int, admission_round, uuid) from public, anon;
grant execute on function public.complete_interview_applicant(int, admission_round, uuid) to authenticated;

-- 잘못 누른 호출 되돌리기 (기록은 audit_logs에 남는다)
create or replace function public.cancel_interview_call(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
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
  where year = p_year and round = p_round and applicant_id = p_applicant_id;

  if not found then
    raise exception '취소할 호출 기록이 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.cancelled',
     'interview_queue_state', p_applicant_id::text,
     jsonb_build_object('callType', p_call_type));

  return jsonb_build_object('applicantId', p_applicant_id, 'callType', p_call_type);
end;
$$;

revoke all on function public.cancel_interview_call(int, admission_round, uuid, text) from public, anon;
grant execute on function public.cancel_interview_call(int, admission_round, uuid, text) to authenticated;

-- ============================================================
-- 6. 면접위원용 대기열 조회
--    본인 조의 지원자만. 관리자는 p_team_id로 특정 조를 지정해 볼 수 있다.
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
      'studentStartsAt', s.student_starts_at,
      'studentEndsAt', s.student_ends_at,
      'parentStartsAt', s.parent_starts_at,
      'parentEndsAt', s.parent_ends_at,
      'advanceCalledAt', q.advance_called_at,
      'calledAt', q.called_at,
      'completedAt', q.completed_at,
      'smsAdvanceApplicant', exists (
        select 1 from public.interview_call_sms_log l
        where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
          and l.call_type = 'advance' and l.target = 'applicant' and l.sent = true),
      'smsAdvanceGuardian', exists (
        select 1 from public.interview_call_sms_log l
        where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
          and l.call_type = 'advance' and l.target = 'guardian' and l.sent = true),
      'smsNowApplicant', exists (
        select 1 from public.interview_call_sms_log l
        where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
          and l.call_type = 'now' and l.target = 'applicant' and l.sent = true),
      'smsNowGuardian', exists (
        select 1 from public.interview_call_sms_log l
        where l.year = p_year and l.round = p_round and l.applicant_id = s.applicant_id
          and l.call_type = 'now' and l.target = 'guardian' and l.sent = true)
    ) as item
    from public.interview_schedules s
    join public.evaluation_roster r on r.applicant_id = s.applicant_id
    left join public.interview_queue_state q
      on q.year = s.year and q.round = s.round and q.applicant_id = s.applicant_id
    where s.year = p_year and s.round = p_round and s.team_id = v_team_id
  ) sub;

  return jsonb_build_object('team', v_team, 'items', v_result, 'serverNow', now());
end;
$$;

revoke all on function public.get_interview_call_queue(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_queue(int, admission_round, uuid) to authenticated;

-- ============================================================
-- 7. 대기실 프로젝터 송출용 — 로그인 없이(anon) 열린다
--    반환 정보는 수험번호 + 마스킹 성명 + 조 코드/장소 + 호출 상태뿐.
--    연락처·점수·전형구분·실명은 어떤 경로로도 나가지 않는다.
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
            'advanceCalledAt', q.advance_called_at,
            'calledAt', q.called_at,
            'completedAt', q.completed_at
          ) order by s.sort_order, s.student_starts_at
        ), '[]'::jsonb)
        from public.interview_schedules s
        join public.evaluation_roster r on r.applicant_id = s.applicant_id
        left join public.interview_queue_state q
          on q.year = s.year and q.round = s.round and q.applicant_id = s.applicant_id
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

comment on function public.get_interview_display_board() is
  '대기실 프로젝터 전용. 로그인 없이 호출 가능하므로 수험번호와 마스킹된 성명 외의 개인정보는 반환하지 않는다.';

revoke all on function public.get_interview_display_board() from public;
grant execute on function public.get_interview_display_board() to anon, authenticated;

-- ============================================================
-- 8. 호출 문자 발송 대상 조회 / 발송 결과 기록
--    (Edge Function send-interview-call-sms에서 사용)
-- ============================================================

create or replace function public.get_interview_call_sms_recipient(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select a.name, a.receipt_no, p.applicant_phone, p.guardian_name, p.guardian_phone
  into v_row
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  where a.id = p_applicant_id;

  if v_row is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'name', v_row.name,
    'receiptNo', v_row.receipt_no,
    'applicantPhone', v_row.applicant_phone,
    'guardianName', v_row.guardian_name,
    'guardianPhone', v_row.guardian_phone
  );
end;
$$;

revoke all on function public.get_interview_call_sms_recipient(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_sms_recipient(int, admission_round, uuid) to authenticated;

create or replace function public.record_interview_call_sms_sent(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
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
    (year, round, applicant_id, call_type, target, sent, provider_code, provider_message, sent_by)
  values
    (p_year, p_round, p_applicant_id, p_call_type, p_target, p_sent,
     p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.sms_sent',
     'interview_call_sms_log', p_applicant_id::text,
     jsonb_build_object('callType', p_call_type, 'target', p_target, 'sent', p_sent));
end;
$$;

revoke all on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, boolean, text, text)
  from public, anon;
grant execute on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, boolean, text, text)
  to authenticated;
