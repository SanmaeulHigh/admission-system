-- 새봄고 입학전형 시스템 — 대기실 프로젝터 화면 열쇠 (2026-10-14)
--
-- 배경: 대기실 화면(/display/interview)은 로그인 없이 get_interview_display_board 를 3초마다 부른다.
--       교외(본관)에서는 Cloudflare 터널 앞 Caddy 관문(mfa_gate)이 익명 요청을 막아 403이 났다.
--       Caddy 예외로 이 RPC 하나만 관문을 건너뛰게 하되, 주소를 아는 누구나 당일 명단(수험번호·가린 성명)을
--       볼 수 없도록 "표시 화면 열쇠"를 요구한다. 열쇠는 화면 주소의 ?key= 로 넘긴다.
--
-- - 열쇠는 비밀번호가 아니라 공유용 표시 토큰이다(관리자·면접위원이 화면을 열 때 주소에 붙여 준다).
--   새어 나가면 관리자가 '열쇠 바꾸기'로 즉시 무효화한다.
-- - 열쇠 없이 부르던 예전 함수(get_interview_display_board())는 지운다. 남겨 두면 같은 주소로
--   열쇠 없이 호출할 수 있어 관문 예외가 그대로 뚫린다.
-- - 반환 내용은 00057과 같다(수험번호·가린 성명·조·장소·순서·호출 상태).

create table if not exists public.display_access_keys (
  kind text primary key check (kind in ('interview_board')),
  access_key text not null check (length(access_key) >= 16),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users (id)
);

comment on table public.display_access_keys is
  '로그인 없이 여는 송출 화면(대기실 프로젝터)의 공유 열쇠. RPC로만 읽고 바꾼다.';

alter table public.display_access_keys enable row level security;
revoke all on table public.display_access_keys from anon, authenticated;

-- 처음 한 번 무작위 열쇠를 만들어 둔다
insert into public.display_access_keys (kind, access_key)
values ('interview_board', encode(extensions.gen_random_bytes(12), 'hex'))
on conflict (kind) do nothing;

-- ------------------------------------------------------------
-- 1. 대기실 화면 데이터 (열쇠 필요)
-- ------------------------------------------------------------
drop function if exists public.get_interview_display_board();

create or replace function public.get_interview_display_board(p_key text default null)
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
  if p_key is null
     or not exists (
       select 1 from public.display_access_keys k
       where k.kind = 'interview_board' and k.access_key = btrim(p_key)
     ) then
    return jsonb_build_object('ready', false, 'reason', 'KEY_INVALID', 'serverNow', now());
  end if;

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

revoke all on function public.get_interview_display_board(text) from public;
grant execute on function public.get_interview_display_board(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 2. 열쇠 읽기 — 관리자, 면접 담당 위원 (화면 여는 링크에 붙이기 위해)
-- ------------------------------------------------------------
create or replace function public.get_interview_display_key()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_key record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = caller and u.active
      and (u.roles && array['superadmin', 'admin']::app_role[]
           or ('evaluator' = any(u.roles) and 'interview' = any(u.assigned_areas)))
  ) then
    raise exception '대기실 화면 열쇠를 볼 권한이 없습니다.' using errcode = '42501';
  end if;

  select access_key, updated_at into v_key
  from public.display_access_keys where kind = 'interview_board';

  return jsonb_build_object('key', v_key.access_key, 'updatedAt', v_key.updated_at);
end;
$$;

revoke all on function public.get_interview_display_key() from public, anon;
grant execute on function public.get_interview_display_key() to authenticated;

-- ------------------------------------------------------------
-- 3. 열쇠 바꾸기 — 관리자만. 바꾸면 이전 주소로 열린 화면은 즉시 '열쇠 없음'이 된다.
-- ------------------------------------------------------------
create or replace function public.rotate_interview_display_key()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_new text := encode(extensions.gen_random_bytes(12), 'hex');
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  insert into public.display_access_keys (kind, access_key, updated_at, updated_by)
  values ('interview_board', v_new, now(), caller)
  on conflict (kind) do update
    set access_key = excluded.access_key, updated_at = excluded.updated_at, updated_by = excluded.updated_by;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values ('user', caller::text, 'display_key.rotated', 'display_access_keys', 'interview_board', '{}'::jsonb);

  return jsonb_build_object('key', v_new, 'updatedAt', now());
end;
$$;

revoke all on function public.rotate_interview_display_key() from public, anon;
grant execute on function public.rotate_interview_display_key() to authenticated;
