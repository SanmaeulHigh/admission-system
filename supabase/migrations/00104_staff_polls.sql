-- 새봄고 입학전형 시스템 — 교직원 투표(새 이름 정하기 등) (2026-10-26)
--
-- 로그인한 교직원(활성 계정)이 한 사람 한 표로 투표한다. 마감 전에는 고칠 수 있다.
-- 결과: 투표한 사람과 최고관리자에게 보인다(투표 전에는 안 보여 따라 찍기를 줄인다).
-- 누가 무엇을 골랐는지는 아무에게도 보여 주지 않는다(최고관리자도 표 수만). 참여 인원만 센다.
-- 첫 투표: 시스템 새 이름(SEED / SAMS / NEST).

create table if not exists public.staff_polls (
  id text primary key,
  title text not null,
  description text,
  options jsonb not null,            -- [{key, label, desc}]
  opens_at timestamptz not null default now(),
  closes_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_poll_votes (
  poll_id text not null references public.staff_polls (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  choice text not null,
  comment text,
  voted_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);

alter table public.staff_polls enable row level security;
alter table public.staff_poll_votes enable row level security;
revoke all on public.staff_polls from anon, authenticated;
revoke all on public.staff_poll_votes from anon, authenticated;

-- 1. 지금 열려 있는(또는 막 끝난 7일 이내) 투표 + 내 표 + (투표했거나 최고관리자면) 결과
create or replace function public.get_active_poll()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_poll record;
  v_mine record;
  v_show boolean;
  v_results jsonb;
  v_voters int;
  v_eligible int;
begin
  if not public.is_active_user() then
    return null;
  end if;

  select * into v_poll from public.staff_polls
  where opens_at <= now() and closes_at > now() - interval '7 days'
  order by closes_at desc limit 1;
  if v_poll.id is null then
    return null;
  end if;

  select choice, comment, voted_at into v_mine
  from public.staff_poll_votes where poll_id = v_poll.id and user_id = auth.uid();

  v_show := v_mine.choice is not null or public.has_role('superadmin') or v_poll.closes_at <= now();
  select count(*) into v_voters from public.staff_poll_votes where poll_id = v_poll.id;
  select count(*) into v_eligible from public.users where active = true;

  if v_show then
    select coalesce(jsonb_object_agg(choice, n), '{}'::jsonb) into v_results
    from (select choice, count(*) as n from public.staff_poll_votes where poll_id = v_poll.id group by choice) t;
  end if;

  return jsonb_build_object(
    'id', v_poll.id,
    'title', v_poll.title,
    'description', v_poll.description,
    'options', v_poll.options,
    'closesAt', v_poll.closes_at,
    'closed', v_poll.closes_at <= now(),
    'myChoice', v_mine.choice,
    'myComment', v_mine.comment,
    'voters', v_voters,
    'eligible', v_eligible,
    'results', v_results
  );
end;
$$;

revoke all on function public.get_active_poll() from public, anon;
grant execute on function public.get_active_poll() to authenticated;

-- 2. 투표(마감 전에는 다시 골라도 됨)
create or replace function public.cast_poll_vote(p_poll_id text, p_choice text, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_poll record;
begin
  if not public.is_active_user() then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  select * into v_poll from public.staff_polls where id = p_poll_id;
  if v_poll.id is null then
    raise exception '없는 투표입니다.' using errcode = 'P0002';
  end if;
  if now() < v_poll.opens_at or now() >= v_poll.closes_at then
    raise exception '투표 기간이 아닙니다.' using errcode = '55000';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_poll.options) o where o->>'key' = p_choice) then
    raise exception '없는 선택지입니다.' using errcode = '22023';
  end if;

  insert into public.staff_poll_votes (poll_id, user_id, choice, comment, voted_at)
  values (p_poll_id, auth.uid(), p_choice, nullif(left(btrim(coalesce(p_comment, '')), 300), ''), now())
  on conflict (poll_id, user_id) do update
    set choice = excluded.choice, comment = excluded.comment, voted_at = now();

  return public.get_active_poll();
end;
$$;

revoke all on function public.cast_poll_vote(text, text, text) from public, anon;
grant execute on function public.cast_poll_vote(text, text, text) to authenticated;

-- 3. 투표는 SQL로 staff_polls 에 한 줄 넣어 연다(INSTALL.md '교직원 투표' 참고).
