-- 새봄고 입학전형 시스템 — 교외 접속 휴대폰 인증 (2026-10-13)
--
-- 접속 구조: 교내·교외 모두 https://ipsi.example.org → Cloudflare 터널 → Caddy(127.0.0.1:8080)
-- Cloudflare는 모든 요청에 실제 접속 IP를 Cf-Connecting-Ip 헤더로 붙인다(사용자가 위조 불가).
--   - 그 IP가 학교 공인 IP(trusted_networks)면 교내 → 지금처럼 로그인만
--   - 아니면 교외 → 로그인 뒤 등록된 휴대폰으로 받은 6자리 인증번호까지 맞혀야 데이터 접근
-- 터널을 거치지 않는 요청(서버 안 Edge Function → API, 교내 비상 주소 local.example.org)에는
-- 이 헤더가 없으므로 교내로 본다(인터넷에서 그 경로로는 들어올 수 없다).
--
-- 실제 차단은 Caddy가 터널 쪽 API 요청마다 mfa_gate()를 먼저 물어보는 방식(forward_auth)으로 한다.
-- 그래서 기존 RLS·RPC를 하나도 고치지 않고 한 곳에서 막는다.
--
-- 인증 유효: 그 로그인 세션 동안, 최대 12시간. 인증번호: 5분 유효, 5번 틀리면 폐기.
-- 휴대폰 번호는 최고관리자만 바꿀 수 있다(본인이 바꿀 수 있으면 비밀번호 탈취자가 자기 번호로 바꿀 수 있음).

-- 1. 사용자 휴대폰 번호
alter table public.users add column if not exists mobile_phone text;

-- 2. 학교 공인 IP 목록(교내로 인정)
create table if not exists public.trusted_networks (
  id uuid primary key default gen_random_uuid(),
  cidr cidr not null unique,
  label text,
  created_at timestamptz not null default now()
);
alter table public.trusted_networks enable row level security;
revoke all on public.trusted_networks from public, anon, authenticated;
insert into public.trusted_networks (cidr, label)
values ('203.0.113.10/32', '학교 공인 IP (본관 서버에서 확인, 2026-10-13)')
on conflict (cidr) do nothing;

-- 3. 인증번호(해시만 저장)·인증된 세션
create table if not exists public.login_otp_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  session_id uuid not null,
  code_hash text not null,
  client_ip text,
  attempts int not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists login_otp_challenges_user_idx on public.login_otp_challenges (user_id, created_at desc);
alter table public.login_otp_challenges enable row level security;
revoke all on public.login_otp_challenges from public, anon, authenticated;

create table if not exists public.mfa_sessions (
  session_id uuid primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  verified_at timestamptz not null default now(),
  expires_at timestamptz not null,
  client_ip text
);
alter table public.mfa_sessions enable row level security;
revoke all on public.mfa_sessions from public, anon, authenticated;

-- 4. 도우미
create or replace function public._request_client_ip()
returns inet
language plpgsql
stable
as $$
declare
  h json;
  v text;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  v := h ->> 'cf-connecting-ip';
  if v is null or btrim(v) = '' then
    return null;
  end if;
  begin
    return btrim(v)::inet;
  exception when others then
    return '0.0.0.0'::inet; -- 이상한 값은 교외로 취급
  end;
end;
$$;

create or replace function public._is_external_request()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ip inet := public._request_client_ip();
begin
  if ip is null then
    return false;
  end if;
  return not exists (select 1 from public.trusted_networks t where ip <<= t.cidr);
end;
$$;

create or replace function public._current_session_id()
returns uuid
language plpgsql
stable
as $$
begin
  return nullif(auth.jwt() ->> 'session_id', '')::uuid;
exception when others then
  return null;
end;
$$;

create or replace function public._mfa_verified()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.mfa_sessions m
    where m.session_id = public._current_session_id()
      and m.user_id = auth.uid()
      and m.expires_at > now()
  );
$$;

revoke execute on function public._is_external_request() from anon;
revoke execute on function public._mfa_verified() from anon;

-- 5. Caddy가 터널 쪽 API 요청마다 먼저 부르는 관문(GET /rest/v1/rpc/mfa_gate)
create or replace function public.mfa_gate()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_external_request() then
    return true;
  end if;
  if auth.uid() is not null and public._mfa_verified() then
    return true;
  end if;
  -- PT403: PostgREST 가 HTTP 403 으로 돌려준다(로그인 여부와 상관없이)
  raise exception '교외에서 접속하셨습니다. 휴대폰 인증을 마친 뒤 이용할 수 있습니다.' using errcode = 'PT403';
end;
$$;
grant execute on function public.mfa_gate() to anon, authenticated;

-- 6. 화면용 상태 조회(관문 예외 경로)
create or replace function public.get_access_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ip inet := public._request_client_ip();
  ext boolean := public._is_external_request();
  ph text;
begin
  select mobile_phone into ph from public.users where id = auth.uid() and active = true;
  return jsonb_build_object(
    'external', ext,
    'clientIp', case when ip is null then null else host(ip) end,
    'mfaRequired', ext,
    'mfaVerified', (not ext) or (auth.uid() is not null and public._mfa_verified()),
    'hasPhone', ph is not null,
    'phoneMasked', case when ph is null then null
                        else regexp_replace(ph, '^(\d{3})-?(\d{3,4})-?(\d{4})$', '\1-****-\3') end
  );
end;
$$;
revoke execute on function public.get_access_status() from anon;
grant execute on function public.get_access_status() to authenticated;

-- 7. 인증번호 확인(관문 예외 경로). 틀리면 예외 대신 ok=false 로 돌려 시도 횟수 기록을 남긴다.
create or replace function public.verify_login_otp(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  sid uuid := public._current_session_id();
  c public.login_otp_challenges%rowtype;
begin
  if uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if sid is null then
    raise exception '로그인 세션을 확인할 수 없습니다. 로그아웃 후 다시 로그인하세요.' using errcode = '28000';
  end if;

  select * into c from public.login_otp_challenges
  where user_id = uid and session_id = sid and consumed_at is null
  order by created_at desc
  limit 1
  for update;

  if not found then
    raise exception '인증번호를 먼저 받아 주세요.' using errcode = 'P0001';
  end if;
  if c.expires_at < now() then
    raise exception '인증번호가 만료되었습니다. 다시 받아 주세요.' using errcode = 'P0001';
  end if;
  if c.attempts >= 5 then
    raise exception '5번 틀려 이 인증번호는 더 쓸 수 없습니다. 다시 받아 주세요.' using errcode = 'P0001';
  end if;

  if encode(sha256(convert_to(btrim(coalesce(p_code, '')) || ':' || uid::text || ':' || sid::text, 'UTF8')), 'hex') <> c.code_hash then
    update public.login_otp_challenges set attempts = attempts + 1 where id = c.id;
    insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values ('user', uid::text, 'auth.mfa.failed', 'users', uid::text,
            jsonb_build_object('ip', host(public._request_client_ip()), 'attempt', c.attempts + 1));
    return jsonb_build_object('ok', false, 'remaining', greatest(0, 4 - c.attempts));
  end if;

  update public.login_otp_challenges set consumed_at = now() where id = c.id;
  insert into public.mfa_sessions (session_id, user_id, verified_at, expires_at, client_ip)
  values (sid, uid, now(), now() + interval '12 hours', host(public._request_client_ip()))
  on conflict (session_id) do update
    set user_id = excluded.user_id, verified_at = excluded.verified_at,
        expires_at = excluded.expires_at, client_ip = excluded.client_ip;
  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values ('user', uid::text, 'auth.mfa.verified', 'users', uid::text,
          jsonb_build_object('ip', host(public._request_client_ip())));
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.verify_login_otp(text) from anon;
grant execute on function public.verify_login_otp(text) to authenticated;

-- 8. 휴대폰 번호 등록(최고관리자만)
create or replace function public.set_user_mobile_phone(p_user_id uuid, p_phone text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  d text;
  v text;
begin
  caller := public._require_superadmin();
  d := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if d = '' then
    v := null;
  elsif d ~ '^01[0-9]{8,9}$' then
    v := case when length(d) = 10 then substr(d,1,3) || '-' || substr(d,4,3) || '-' || substr(d,7)
              else substr(d,1,3) || '-' || substr(d,4,4) || '-' || substr(d,8) end;
  else
    raise exception '휴대전화 번호 형식이 아닙니다 (예: 010-1234-5678).' using errcode = '22023';
  end if;

  update public.users set mobile_phone = v where id = p_user_id;
  if not found then
    raise exception '사용자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  -- 번호를 바꾸면 그 사람의 기존 교외 인증은 모두 무효
  delete from public.mfa_sessions where user_id = p_user_id;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values ('user', caller::text, 'user.mobile_phone_set', 'users', p_user_id::text,
          jsonb_build_object('registered', v is not null));
  return v;
end;
$$;
revoke execute on function public.set_user_mobile_phone(uuid, text) from anon;
grant execute on function public.set_user_mobile_phone(uuid, text) to authenticated;
