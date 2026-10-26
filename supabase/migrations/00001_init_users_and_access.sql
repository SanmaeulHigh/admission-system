-- 새봄고 입학전형 시스템 — 초기 마이그레이션 (Sprint 0 범위)
-- 마스터 스펙 v1.2 섹션 2(권한), 6(접근통제), 3.22(감사로그)의 Firebase 구현을
-- Supabase(Postgres + RLS)로 대체한 것. 2026-07-06 결정.
--
-- 핵심 설계 이전 사항:
--   * Firestore Security Rules      → Row Level Security(RLS) 정책
--   * Custom Claims + accessRevision → 폐기. RLS가 매 쿼리마다 users 테이블을
--     직접 조회하므로 "낡은 토큰에 남은 권한" 문제 자체가 없다 (섹션 2.11의
--     revision 메커니즘이 불필요해짐 — 단순화).
--   * Cloud Functions(계정관리)      → SECURITY DEFINER RPC 함수
--   * 서버 전용 컬렉션              → RLS 활성화 + 정책 없음 = 전면 거부
--
-- 금지 패턴(스펙 섹션 9.2)은 동일하게 유지: UI 숨김만으로 권한 통제 금지,
-- 클라이언트가 자기 권한을 스스로 쓰는 경로 금지.

-- ============================================================
-- 1. 역할·영역 enum
-- ============================================================

create type app_role as enum
  ('superadmin', 'admin', 'reception', 'quant', 'evaluator', 'viewer');

create type evaluation_area as enum
  ('attendance', 'academic', 'community', 'essay', 'opinion',
   'group', 'interview', 'writing');

create type admission_round as enum ('main', 'extra1', 'extra2');

-- ============================================================
-- 2. users (프로필·권한) — 스펙 섹션 2.10의 users 컬렉션 대응
-- ============================================================

create table public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  email text not null,
  active boolean not null default true,
  roles app_role[] not null default '{}',
  assigned_areas evaluation_area[] not null default '{}',
  year_scopes int[] not null default '{}',
  round_scopes admission_round[] not null default '{}',
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null
);

comment on table public.users is
  '위원·행정 계정의 역할과 배정. auth.users에 행이 있어도 여기 행이 없으면 미승인 계정 (스펙 섹션 2.2).';

-- ============================================================
-- 3. audit_logs — 스펙 섹션 3.22 / 6.11
-- ============================================================

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  year int,
  round admission_round,
  actor_type text not null check (actor_type in ('user', 'system')),
  actor_uid text not null,
  action text not null,
  resource_type text not null,
  resource_id text,
  applicant_id text,
  area evaluation_area,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb,
  source_event_id text unique,
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  '감사 로그. 클라이언트 직접 기록 금지 — SECURITY DEFINER 함수 내부에서만 기록. metadata에 학생부·자소서·평가메모·연락처 원문 복제 금지 (스펙 6.11).';

-- ============================================================
-- 4. RLS helper 함수 — 스펙 섹션 6.2의 helper 대응
--    (SECURITY DEFINER: RLS를 우회해 users를 조회해야 하므로)
-- ============================================================

create or replace function public.is_active_user()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid() and active = true
  );
$$;

create or replace function public.has_role(required_role app_role)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid()
      and active = true
      and required_role = any (roles)
  );
$$;

create or replace function public.has_area(required_area evaluation_area)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid()
      and active = true
      and required_area = any (assigned_areas)
  );
$$;

-- helper 함수는 인증된 사용자만 실행 가능하면 충분
revoke execute on function public.is_active_user() from anon;
revoke execute on function public.has_role(app_role) from anon;
revoke execute on function public.has_area(evaluation_area) from anon;

-- ============================================================
-- 5. RLS 정책
-- ============================================================

alter table public.users enable row level security;
alter table public.audit_logs enable row level security;

-- users: 본인 행 조회 가능(승인 대기 화면·권한 확인용), superadmin은 전체 조회.
-- 어떤 클라이언트 write도 불가 — 변경은 아래 RPC로만.
create policy users_select_own
  on public.users for select
  using (id = auth.uid());

create policy users_select_superadmin
  on public.users for select
  using (public.has_role('superadmin'));

-- insert/update/delete 정책 없음 = 전면 거부 (스펙 2.12)

-- audit_logs: superadmin/admin만 조회. 클라이언트 write 불가.
create policy audit_logs_select_admins
  on public.audit_logs for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- ============================================================
-- 6. 계정 관리 RPC — Cloud Functions(userAccess.js) 대체
--    스펙 섹션 2.12: 역할 부여/변경은 서버 검증 경로로만.
-- ============================================================

-- 공통: 호출자가 활성 superadmin인지 검증
create or replace function public._require_superadmin()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.users
    where id = caller and active = true and 'superadmin' = any (roles)
  ) then
    raise exception '이 작업은 superadmin만 수행할 수 있습니다.' using errcode = '42501';
  end if;
  return caller;
end;
$$;

revoke execute on function public._require_superadmin() from anon, authenticated;

-- 계정 권한 부여/변경.
-- 전제: 대상자가 먼저 앱에서 Google 로그인해 auth.users에 행이 존재해야 한다
-- (Firebase 때와 동일한 온보딩 순서 — 이메일만으로 선등록하지 않는다).
create or replace function public.upsert_user_access(
  target_email text,
  new_display_name text,
  new_roles app_role[],
  new_assigned_areas evaluation_area[] default '{}',
  new_year_scopes int[] default '{2027}',
  new_round_scopes admission_round[] default '{main}'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  target uuid;
  was_new boolean;
begin
  caller := public._require_superadmin();

  if new_display_name is null or length(trim(new_display_name)) = 0 then
    raise exception 'display_name은 필수입니다.';
  end if;
  if new_roles is null or array_length(new_roles, 1) is null then
    raise exception '최소 1개 이상의 역할이 필요합니다.';
  end if;

  select id into target from auth.users where lower(email) = lower(target_email);
  if target is null then
    raise exception '% 계정이 아직 Google로 로그인한 적이 없습니다. 대상자가 먼저 앱에서 Google 로그인을 1회 진행한 뒤 다시 시도하세요.', target_email;
  end if;

  was_new := not exists (select 1 from public.users where id = target);

  insert into public.users
    (id, display_name, email, active, roles, assigned_areas, year_scopes, round_scopes,
     created_by, updated_by)
  values
    (target, new_display_name, lower(target_email), true, new_roles, new_assigned_areas,
     new_year_scopes, new_round_scopes, caller::text, caller::text)
  on conflict (id) do update set
    display_name = excluded.display_name,
    active = true,
    roles = excluded.roles,
    assigned_areas = excluded.assigned_areas,
    year_scopes = excluded.year_scopes,
    round_scopes = excluded.round_scopes,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    ('user', caller::text,
     case when was_new then 'user.access.created' else 'user.access.updated' end,
     'users', target::text,
     json_build_object(
       'roles', new_roles, 'assignedAreas', new_assigned_areas,
       'yearScopes', new_year_scopes, 'roundScopes', new_round_scopes
     )::jsonb);

  return json_build_object('uid', target, 'isNewUser', was_new);
end;
$$;

-- 계정 활성/비활성 전환.
-- RLS가 매 쿼리마다 active를 확인하므로, 비활성화 즉시 모든 데이터 접근이
-- 끊긴다 — Firebase 때 필요했던 refresh token 폐기 절차가 불필요하다.
create or replace function public.set_user_active_status(
  target_uid uuid,
  new_active boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_superadmin();

  if target_uid = caller and new_active = false then
    raise exception '본인 계정은 스스로 비활성화할 수 없습니다.';
  end if;
  if not exists (select 1 from public.users where id = target_uid) then
    raise exception '대상 사용자를 찾을 수 없습니다.';
  end if;

  update public.users
  set active = new_active, updated_at = now(), updated_by = caller::text
  where id = target_uid;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id)
  values
    ('user', caller::text,
     case when new_active then 'user.access.reactivated' else 'user.access.deactivated' end,
     'users', target_uid::text);

  return json_build_object('uid', target_uid, 'active', new_active);
end;
$$;

-- RPC는 로그인 사용자만 호출 가능 (내부에서 superadmin 재검증)
revoke execute on function public.upsert_user_access(text, text, app_role[], evaluation_area[], int[], admission_round[]) from anon;
revoke execute on function public.set_user_active_status(uuid, boolean) from anon;

-- ============================================================
-- 7. Realtime: 본인 users 행 변경 구독 허용
--    (승인 대기 화면 → 승인 즉시 자동 전환용. RLS가 그대로 적용됨)
-- ============================================================

alter publication supabase_realtime add table public.users;

-- ============================================================
-- 8. 이후 스프린트 테이블 자리 표시
-- ============================================================
-- applicants / applicants_private / applicants_admin  → Sprint 1 마이그레이션
-- scores_* 8종, aggregates(뷰로 대체 검토), evaluation_alerts → Sprint 2
-- decision_runs, decision_results, committee_decisions → Sprint 3
-- pre_applications 4종 (M8, service_role 전용)         → Sprint 1
-- 원칙: 모든 신규 테이블은 생성 즉시 RLS enable, 정책은 최소권한으로만 추가.
