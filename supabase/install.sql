-- 입학전형관리시스템 — 한 번에 설치하는 SQL
--
-- supabase/migrations/ 의 파일 104개(00001_init_users_and_access.sql ~ 00104_staff_polls.sql)를 번호 순서대로 이어 붙인 것이다.
-- 새 Supabase 프로젝트에서 딱 한 번 실행한다(이미 설치한 곳에 다시 실행하지 말 것).
--   · Supabase 클라우드: SQL Editor 에 붙여 넣어 실행(길어서 몇십 초 걸린다)
--   · 셀프 호스팅(Docker): docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres < supabase/install.sql
-- 실행 후: NOTIFY pgrst, 'reload schema';  → 이어서 supabase/setup/ (INSTALL.md 참고)
--
-- 업데이트할 때는 이 파일 말고, 새로 생긴 migrations/ 파일만 번호 순서대로 실행한다.
-- 중간에 만들었다가 뒤에서 지우는 기능(사전 원서 M8, 00023~00049)도 그대로 들어 있다 — 기록을 바꾸지 않으려는 것으로, 실행 결과에는 남지 않는다.
-- 이 파일은 자동으로 만든다. 고칠 일이 있으면 migrations/ 를 고친다.


-- ======================================================================
-- 00001_init_users_and_access.sql
-- ======================================================================

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

-- ======================================================================
-- 00002_config_revisions_and_rounds.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — config revision + admission_rounds (Sprint 0 마무리)
-- 마스터 스펙 v1.2 섹션 3.2(config revision), 6(admissionRounds) 대응.
--
-- 핵심 설계: config_revisions는 "생성 후 절대 수정 불가"다 (스펙의 config
-- revision 불변 원칙 — Firestore에서 revisions 서브컬렉션 문서를 생성만
-- 하고 수정하지 않던 것과 동일). 변경이 필요하면 새 revision을 만든다.
-- 이 불변성은 애플리케이션 코드가 아니라 트리거로 DB 레벨에서 강제한다.

-- ============================================================
-- 1. config_revisions — 연도별 설정의 불변 스냅샷
-- ============================================================

create table public.config_revisions (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  revision_number int not null,
  status text not null default 'draft' check (status in ('draft', 'locked')),
  schedule jsonb not null default '{}'::jsonb,
  -- schedule 예시 키: receiptStart, receiptEnd, documentReviewStart,
  -- documentReviewEnd, deepEvaluationDate, resultAnnounceDate,
  -- preApplicationStart (검토메모 지적사항 3 반영)
  scoring_params jsonb not null default '{}'::jsonb,
  -- scoring_params: 배점·가산점 등 구조화된 파라미터만 (문자열 수식 금지 — 섹션 9.2)
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  created_by text not null,
  unique (year, revision_number)
);

comment on table public.config_revisions is
  'draft 상태에서만 자유롭게 만들고 지울 수 있다. locked 전환 후에는 트리거가 모든 update/delete를 차단한다 (불변 스냅샷).';

-- 불변성 강제 트리거
create or replace function public._prevent_locked_revision_mutation()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' then
    if OLD.status = 'locked' then
      raise exception 'locked revision은 삭제할 수 없습니다 (revision %.%)', OLD.year, OLD.revision_number;
    end if;
    return OLD;
  end if;

  -- UPDATE: 잠긴 행은 그 어떤 컬럼 변경도 금지 (draft → locked 전환 자체는 허용)
  if OLD.status = 'locked' then
    raise exception 'locked revision은 수정할 수 없습니다 (revision %.%). 변경이 필요하면 새 revision을 만드세요.', OLD.year, OLD.revision_number;
  end if;
  return NEW;
end;
$$;

create trigger trg_config_revisions_immutable
  before update or delete on public.config_revisions
  for each row execute function public._prevent_locked_revision_mutation();

-- ============================================================
-- 2. configs — 연도별 "현재 활성 revision" 포인터
-- ============================================================

create table public.configs (
  year int primary key,
  active_revision_id uuid references public.config_revisions (id),
  updated_at timestamptz not null default now(),
  updated_by text not null
);

comment on table public.configs is
  '연도당 1행. active_revision_id는 반드시 status=locked인 revision만 가리킨다 (RPC에서 강제).';

-- ============================================================
-- 3. admission_rounds — 스펙 섹션 6의 admissionRounds 대응
-- ============================================================

create table public.admission_rounds (
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  stage text not null default 'pre_receipt'
    check (stage in ('pre_receipt', 'receipt', 'document_review', 'deep_evaluation', 'decision', 'closed')),
  stage_status text not null default 'closed' check (stage_status in ('closed', 'open', 'frozen')),
  open_evaluation_areas evaluation_area[] not null default '{}',
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

comment on table public.admission_rounds is
  'stage/stage_status/open_evaluation_areas는 운영 중 계속 바뀌는 필드라 config_revisions와 달리 수정 가능. config_revision_id로 어떤 잠긴 설정을 쓰는지만 고정.';

-- ============================================================
-- 4. RLS
-- ============================================================

alter table public.config_revisions enable row level security;
alter table public.configs enable row level security;
alter table public.admission_rounds enable row level security;

create policy config_revisions_select_active_users
  on public.config_revisions for select
  using (public.is_active_user());

create policy configs_select_active_users
  on public.configs for select
  using (public.is_active_user());

create policy admission_rounds_select_active_users
  on public.admission_rounds for select
  using (public.is_active_user());

-- insert/update/delete 정책 없음 = 클라이언트 직접 쓰기 전면 거부.
-- 아래 RPC(SECURITY DEFINER)를 통해서만 변경한다 (스펙 섹션 2.12).

-- ============================================================
-- 5. RPC — 초안 생성 / 잠금 / 차수 초기화 / 단계 전환
-- ============================================================

create or replace function public.create_config_draft(
  target_year int,
  new_schedule jsonb default '{}'::jsonb,
  new_scoring_params jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  next_revision_number int;
  new_id uuid;
begin
  caller := public._require_superadmin();

  select coalesce(max(revision_number), 0) + 1 into next_revision_number
  from public.config_revisions where year = target_year;

  insert into public.config_revisions
    (year, revision_number, status, schedule, scoring_params, created_by)
  values
    (target_year, next_revision_number, 'draft', new_schedule, new_scoring_params, caller::text)
  returning id into new_id;

  insert into public.audit_logs (year, actor_type, actor_uid, action, resource_type, resource_id)
  values (target_year, 'user', caller::text, 'config.revision.draft_created', 'config_revisions', new_id::text);

  return new_id;
end;
$$;

create or replace function public.lock_config_revision(revision_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev record;
begin
  caller := public._require_superadmin();

  select * into rev from public.config_revisions where id = revision_id;
  if rev is null then
    raise exception 'revision을 찾을 수 없습니다.';
  end if;
  if rev.status = 'locked' then
    raise exception '이미 잠긴 revision입니다.';
  end if;

  update public.config_revisions
  set status = 'locked', locked_at = now()
  where id = revision_id;

  insert into public.configs (year, active_revision_id, updated_by)
  values (rev.year, revision_id, caller::text)
  on conflict (year) do update set
    active_revision_id = excluded.active_revision_id,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs (year, actor_type, actor_uid, action, resource_type, resource_id)
  values (rev.year, 'user', caller::text, 'config.revision.locked', 'config_revisions', revision_id::text);

  return json_build_object('revisionId', revision_id, 'year', rev.year, 'revisionNumber', rev.revision_number);
end;
$$;

create or replace function public.init_admission_round(
  target_year int,
  target_round admission_round,
  revision_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev record;
begin
  caller := public._require_superadmin();

  select * into rev from public.config_revisions where id = revision_id;
  if rev is null or rev.status <> 'locked' then
    raise exception 'admissionRound은 locked 상태의 revision에만 연결할 수 있습니다.';
  end if;
  if rev.year <> target_year then
    raise exception 'revision의 year(%)가 target_year(%)와 일치하지 않습니다.', rev.year, target_year;
  end if;

  insert into public.admission_rounds
    (year, round, config_revision_id, stage, stage_status, created_by, updated_by)
  values
    (target_year, target_round, revision_id, 'pre_receipt', 'closed', caller::text, caller::text)
  on conflict (year, round) do update set
    config_revision_id = excluded.config_revision_id,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (target_year, target_round, 'user', caller::text, 'admission_round.initialized', 'admission_rounds',
          target_year::text || '_' || target_round::text);
end;
$$;

create or replace function public.set_round_stage(
  target_year int,
  target_round admission_round,
  new_stage text,
  new_stage_status text,
  new_open_areas evaluation_area[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_superadmin();

  update public.admission_rounds
  set stage = new_stage,
      stage_status = new_stage_status,
      open_evaluation_areas = new_open_areas,
      updated_at = now(),
      updated_by = caller::text
  where year = target_year and round = target_round;

  if not found then
    raise exception 'admission_round(%, %)를 찾을 수 없습니다. init_admission_round를 먼저 호출하세요.', target_year, target_round;
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (target_year, target_round, 'user', caller::text, 'admission_round.stage_changed', 'admission_rounds',
          target_year::text || '_' || target_round::text,
          json_build_object('stage', new_stage, 'stageStatus', new_stage_status, 'openAreas', new_open_areas)::jsonb);
end;
$$;

revoke execute on function public.create_config_draft(int, jsonb, jsonb) from anon;
revoke execute on function public.lock_config_revision(uuid) from anon;
revoke execute on function public.init_admission_round(int, admission_round, uuid) from anon;
revoke execute on function public.set_round_stage(int, admission_round, text, text, evaluation_area[]) from anon;

-- ======================================================================
-- 00003_applicants_m1.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M1 접수대장 (Sprint 1)
-- 마스터 스펙 v1.2 섹션 3.5(지원자 데이터·개인정보 경계), 3.6(평가용 최소
-- 데이터), 1226행 M1 요구사항 대응.
--
-- 권한 경계 (섹션 3.1 원칙 1: 접근권한이 다른 정보는 다른 테이블에):
--   applicants         → superadmin/admin/reception 조회
--   applicants_private → superadmin/admin/reception 조회 (연락처·보호자·생년월일)
--   applicants_admin   → superadmin/admin만 (학폭·부적합·사정제외)
--   evaluation_roster  → 전 역할 조회 가능한 최소 식별정보만
-- 모든 write는 RPC를 통해서만 (클라이언트 직접 write 금지 — 섹션 2381행).
--
-- 접수번호: 'YYMMDD' + 방법('M' 우편 | 'V' 방문) + 3자리 일련번호.
-- (년,차수,일자,방법)별 카운터 행을 FOR UPDATE 잠금으로 증가시켜
-- 동시 접수에서도 중복이 발생하지 않는다 (스펙 리스크 18, 1093행).
--
-- 스펙 갭 처리(검토메모 기록): M1 폼 요구사항의 성별·생년월일이 3.5 스키마에
-- 없음 → 개인정보이므로 applicants_private에 배치.

-- ============================================================
-- 1. helper: 다중 역할 검증 (00001의 _require_superadmin 일반화)
-- ============================================================

create or replace function public._require_any_role(required app_role[])
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
    where id = caller and active = true and roles && required
  ) then
    raise exception '이 작업을 수행할 권한이 없습니다 (필요 역할: %).', required
      using errcode = '42501';
  end if;
  return caller;
end;
$$;

revoke execute on function public._require_any_role(app_role[]) from anon, authenticated;

-- ============================================================
-- 2. 테이블
-- ============================================================

create table public.applicants (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  receipt_no text not null,
  exam_no text,
  name text not null,
  tracks text[] not null default '{general}'
    check (tracks in (array['general'], array['general','incheon'], array['general','social'])),
  academic_status text not null
    check (academic_status in ('졸업예정', '졸업', '검정고시', '기타')),
  school text,
  grade_class_no text,
  semester_choice text,
  receipt_method text not null check (receipt_method in ('M', 'V')),
  receipt_date timestamptz not null default now(),
  bonus_eligible boolean,          -- null = 미확인 (null≠false, 스펙 null≠0 원칙)
  bonus_reason text,
  bonus_verified_at timestamptz,
  bonus_verified_by text,
  application_status text not null default 'received'
    check (application_status in ('received', 'incomplete', 'complete', 'withdrawn', 'excluded')),
  evaluation_stage text not null default 'none'
    check (evaluation_stage in ('none', 'document', 'documentPassed', 'documentFailed',
                                'deep', 'finalPassed', 'finalFailed')),
  registration_status text not null default 'none'
    check (registration_status in ('none', 'registered', 'waived')),
  source_pre_application_id uuid,   -- M8 전환 시 연결 (Sprint 1 후반)
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (year, round, receipt_no)
);

comment on table public.applicants is
  '정식 지원자. 단일 status enum 대신 접수/평가/등록 상태를 별도 축으로 관리 (섹션 3.5). evaluator/quant는 이 테이블을 직접 읽지 않고 evaluation_roster를 사용.';

create table public.applicants_private (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  gender text check (gender in ('남', '여')),   -- 스펙 갭 해결: M1 폼 요구 필드
  birth_date date,                              -- 스펙 갭 해결: M1 폼 요구 필드
  applicant_phone text,
  applicant_landline text,
  email text,
  address text,
  guardian_name text,
  guardian_relation text,
  guardian_phone text,
  guardian_address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.applicants_admin (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  flag_violence boolean not null default false,
  flag_unfit boolean not null default false,
  violence_review jsonb not null default '{}'::jsonb,
  exclusion_status text not null default 'none'
    check (exclusion_status in ('none', 'reviewPending', 'excluded', 'cleared')),
  admin_note text,
  updated_at timestamptz not null default now(),
  updated_by text
);

create table public.evaluation_roster (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  receipt_no text not null,
  exam_no text,
  display_name text not null,
  evaluation_stage text not null default 'none',
  group_id uuid,
  interview_team_id uuid,
  evaluation_active boolean not null default true,
  roster_revision int not null default 1,
  updated_at timestamptz not null default now()
);

comment on table public.evaluation_roster is
  '평가위원에게 제공되는 최소 식별정보 (섹션 3.6). 지원 전형·가산점·개인정보·관리자 플래그는 절대 포함하지 않는다.';

-- 접수번호 카운터 (년, 차수, 일자, 방법별)
create table public.receipt_counters (
  year int not null,
  round admission_round not null,
  date_key text not null,           -- 'YYMMDD'
  method text not null check (method in ('M', 'V')),
  last_seq int not null default 0,
  primary key (year, round, date_key, method)
);

-- ============================================================
-- 3. RLS
-- ============================================================

alter table public.applicants enable row level security;
alter table public.applicants_private enable row level security;
alter table public.applicants_admin enable row level security;
alter table public.evaluation_roster enable row level security;
alter table public.receipt_counters enable row level security;

create policy applicants_select_reception
  on public.applicants for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

create policy applicants_private_select_reception
  on public.applicants_private for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

create policy applicants_admin_select_admins
  on public.applicants_admin for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
  );

create policy evaluation_roster_select_staff
  on public.evaluation_roster for select
  using (public.is_active_user());

-- receipt_counters: 클라이언트 read/write 전면 금지 (정책 없음)
-- 모든 테이블 write: 정책 없음 = RPC로만

-- ============================================================
-- 4. 접수번호 채번 (내부 함수 — RPC에서만 호출)
-- ============================================================

create or replace function public._allocate_receipt_no(
  target_year int,
  target_round admission_round,
  p_method text,
  at_time timestamptz default now()
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dk text := to_char(at_time at time zone 'Asia/Seoul', 'YYMMDD');
  seq int;
begin
  -- upsert 후 행 잠금으로 증가: 동시 호출에서도 중복 없음
  insert into public.receipt_counters (year, round, date_key, method, last_seq)
  values (target_year, target_round, dk, p_method, 0)
  on conflict (year, round, date_key, method) do nothing;

  update public.receipt_counters
  set last_seq = last_seq + 1
  where year = target_year and round = target_round
    and date_key = dk and receipt_counters.method = p_method
  returning last_seq into seq;

  if seq > 999 then
    raise exception '일일 접수번호 한도(999)를 초과했습니다.';
  end if;

  return dk || p_method || lpad(seq::text, 3, '0');
end;
$$;

revoke execute on function public._allocate_receipt_no(int, admission_round, text, timestamptz) from anon, authenticated;

-- ============================================================
-- 5. register_applicant RPC — M1 수기등록
-- ============================================================

create or replace function public.register_applicant(
  p_year int,
  p_round admission_round,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_applicant_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  -- 차수가 초기화되어 있고 접수 가능한 상태인지 확인
  if not exists (
    select 1 from public.admission_rounds
    where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다. init_admission_round를 먼저 실행하세요.', p_year, p_round;
  end if;

  new_receipt_no := public._allocate_receipt_no(p_year, p_round, p_receipt_method);

  insert into public.applicants
    (year, round, receipt_no, name, tracks, academic_status, school, grade_class_no,
     semester_choice, receipt_method, created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, trim(p_name), p_tracks, p_academic_status,
     p_school, p_grade_class_no, p_semester_choice, p_receipt_method,
     caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone, guardian_address)
  values
    (new_applicant_id, p_gender, p_birth_date, p_applicant_phone, p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_guardian_address);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, trim(p_name));

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_applicant(
  int, admission_round, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text
) from anon;

-- ============================================================
-- 6. update_application_status RPC — 접수 상태 변경 (철회 등)
-- ============================================================

create or replace function public.update_application_status(
  p_applicant_id uuid,
  p_new_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  update public.applicants
  set application_status = p_new_status,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code)
  values
    ('user', caller::text, 'applicant.status_changed:' || p_new_status, 'applicants',
     p_applicant_id::text, p_applicant_id::text, p_reason);
end;
$$;

revoke execute on function public.update_application_status(uuid, text, text) from anon;

-- ============================================================
-- 7. Realtime: 접수 현황판 실시간 갱신용
-- ============================================================

alter publication supabase_realtime add table public.applicants;

-- ======================================================================
-- 00004_admission_documents_m2.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M2 평가서류 열람 (Sprint 2)
-- 마스터 스펙 v1.2 섹션 3.8(admissionDocuments), 6.6(접근통제) 대응.
--
-- 핵심 설계:
--   - admission_documents: 메타데이터만. 실제 바이너리는 Supabase Storage.
--   - classification 3단계 + evaluation은 accessAreas ∩ assignedAreas 교집합.
--   - "장시간 공개 URL 금지" → 파일은 항상 createSignedUrl(단시간)로만 접근.
--     그 서명 URL 발급 자체가 storage.objects의 SELECT RLS를 통과해야
--     하므로 (Supabase 표준 동작), Storage 레벨에서도 동일한 접근규칙을
--     강제한다 — 메타데이터만 막고 파일은 못 막는 구멍을 없앤다.
--   - "열람 감사 로그": 서명 URL 발급 전 클라이언트가 log_document_view
--     RPC를 먼저 호출해 감사 기록을 남기고 storage_path를 받는다.
--     (Storage API 호출 자체는 Postgres RPC를 거치지 않아 자동 로깅이
--     안 되므로, 이 순서를 프론트엔드 계약으로 강제한다.)

-- ============================================================
-- 1. document_type, classification 값 집합 (섹션 3.8)
-- ============================================================

create type document_type as enum (
  'applicationForm', 'studentRecordSource', 'studentRecordAttendanceView',
  'studentRecordAcademicView', 'studentRecordCommunityView', 'essay',
  'opinion', 'portfolio', 'writingAnswer', 'trackEvidence', 'consent'
);

create type document_classification as enum ('adminOnly', 'reception', 'evaluation');

-- ============================================================
-- 2. admission_documents (메타데이터)
-- ============================================================

create table public.admission_documents (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  document_type document_type not null,
  storage_path text not null unique,
  mime_type text not null default 'application/pdf',
  file_size int,
  checksum text,
  version int not null default 1,
  active boolean not null default true,
  classification document_classification not null,
  access_areas evaluation_area[] not null default '{}',
  source_document_id uuid references public.admission_documents (id),
  replaced_by_document_id uuid references public.admission_documents (id),
  uploaded_at timestamptz not null default now(),
  uploaded_by text not null
);

comment on table public.admission_documents is
  '평가서류 메타데이터. classification=evaluation인 문서만 access_areas 교집합으로 evaluator/quant에게 노출된다 (섹션 6.6). 학생부 전체 원본(studentRecordSource)은 항상 adminOnly.';

create index idx_admission_documents_applicant on public.admission_documents (applicant_id);

-- ============================================================
-- 3. 접근 판정 helper (admission_documents RLS와 Storage RLS 양쪽에서 재사용)
-- ============================================================

create or replace function public._can_access_document(
  doc_classification document_classification,
  doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if doc_classification = 'adminOnly' then
    return false;
  end if;
  if doc_classification = 'reception' then
    return public.has_role('reception');
  end if;
  -- classification = 'evaluation'
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;
  return exists (
    select 1 from public.users
    where id = auth.uid() and assigned_areas && doc_access_areas
  );
end;
$$;

revoke execute on function public._can_access_document(document_classification, evaluation_area[]) from anon;

-- ============================================================
-- 4. admission_documents RLS
-- ============================================================

alter table public.admission_documents enable row level security;

create policy admission_documents_select_by_classification
  on public.admission_documents for select
  using (public._can_access_document(classification, access_areas));

-- write는 정책 없음 = 아래 RPC로만 (섹션 2.12)

-- ============================================================
-- 5. 열람 감사로그 RPC — 파일 접근 직전에 클라이언트가 반드시 호출
-- ============================================================

create or replace function public.log_document_view(p_document_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  doc record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into doc from public.admission_documents where id = p_document_id and active = true;
  if doc is null then
    raise exception '문서를 찾을 수 없습니다.';
  end if;

  if not public._can_access_document(doc.classification, doc.access_areas) then
    raise exception '이 문서에 접근할 권한이 없습니다.';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.viewed', 'admission_documents',
     doc.id::text, doc.applicant_id::text,
     case when array_length(doc.access_areas, 1) = 1 then doc.access_areas[1] else null end);

  return json_build_object('storagePath', doc.storage_path, 'documentType', doc.document_type);
end;
$$;

revoke execute on function public.log_document_view(uuid) from anon;

-- ============================================================
-- 6. 문서 메타데이터 등록 RPC (실제 바이트는 Storage에 별도 업로드)
-- ============================================================

create or replace function public.register_admission_document(
  p_applicant_id uuid,
  p_document_type document_type,
  p_storage_path text,
  p_classification document_classification,
  p_access_areas evaluation_area[] default '{}',
  p_mime_type text default 'application/pdf',
  p_file_size int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
  new_id uuid;
begin
  -- 문서 등록은 접수 담당 이상 (섹션 6.6 reception 이상이 업로드 주체)
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  -- 학생부 전체 원본은 반드시 adminOnly (섹션 3.8 불변조건)
  if p_document_type = 'studentRecordSource' and p_classification <> 'adminOnly' then
    raise exception 'studentRecordSource는 반드시 classification=adminOnly 이어야 합니다.';
  end if;

  insert into public.admission_documents
    (applicant_id, year, round, document_type, storage_path, mime_type, file_size,
     classification, access_areas, uploaded_by)
  values
    (p_applicant_id, app.year, app.round, p_document_type, p_storage_path, p_mime_type,
     p_file_size, p_classification, p_access_areas, caller::text)
  returning id into new_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (app.year, app.round, 'user', caller::text, 'document.registered', 'admission_documents',
     new_id::text, p_applicant_id::text);

  return new_id;
end;
$$;

revoke execute on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) from anon;

-- ============================================================
-- 7. Storage 버킷 + RLS (실제 파일 접근 통제)
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('admission-documents', 'admission-documents', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

-- SELECT: admission_documents 메타데이터와 동일한 규칙으로만 서명URL 발급 허용.
-- (storage.objects.name이 admission_documents.storage_path와 일치하는 행을 찾아 판정)
create policy admission_documents_storage_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'admission-documents'
    and exists (
      select 1 from public.admission_documents d
      where d.storage_path = storage.objects.name
        and d.active = true
        and public._can_access_document(d.classification, d.access_areas)
    )
  );

-- INSERT: reception 이상만 업로드 가능 (evaluator/quant는 절대 업로드 불가)
-- 주의: INSERT 전용 정책은 WITH CHECK만 허용된다 (USING은 INSERT에 쓸 수 없음).
create policy admission_documents_storage_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'admission-documents'
    and (public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception'))
  );

-- UPDATE/DELETE: 정책 없음 = 전면 거부. 문서 교체는 새 버전 업로드 +
-- register_admission_document로 새 행 생성 + 이전 행에 replaced_by 연결
-- (Function으로 확장 예정, 원본 삭제는 하지 않는 append-only 원칙).

-- ======================================================================
-- 00005_scores_m3abc.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M3a/b/c 서류평가 채점 (Sprint 3)
-- 마스터 스펙 v1.2 섹션 1246행(M3), 5.1(공통 계산 원칙), 6.7~6.8(Rules) 대응.
--
-- 이번 마이그레이션 범위: 출결(quant)·학업성실도(quant)·공동체생활적합성
-- (evaluator). 자소서·소견서(M3d/e)는 루브릭 확보 후 별도 마이그레이션.
--
-- 핵심 원칙(5.1 그대로 적용):
--   - 서버(RPC)만 점수를 계산한다. 클라이언트가 계산한 합계는 미리보기일 뿐.
--   - 미채점·미제출은 숫자 0이 아니라 값 자체가 없는 상태로 남긴다
--     (submission_state로 구분 — 여기서는 제출 즉시 확정되는 단순 흐름이라
--     draft 단계 없이 submitted로 직접 기록한다. 자동저장이 필요한
--     자소서(M3d)는 별도 마이그레이션에서 draft 상태를 추가한다).
--   - 실제 배점 파라미터는 config_revisions.scoring_params에서만 읽는다
--     (하드코딩 금지 — 섹션 9.2).
--   - 평가문서는 반드시 해당 라운드의 "현재 잠긴 revision"을 사용해야 하며,
--     클라이언트가 configRevisionId를 지정하지 않고 서버가 admission_rounds
--     에서 조회해 채운다 (클라이언트 위조 방지).

-- ============================================================
-- 1. 영역 open 여부 helper (스펙: "날짜만이 아니라 stage/stageStatus/
--    openEvaluationAreas를 함께 검증")
-- ============================================================

create or replace function public._is_area_open(
  target_year int, target_round admission_round, target_area evaluation_area
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.admission_rounds
    where year = target_year and round = target_round
      and stage_status = 'open'
      and target_area = any(open_evaluation_areas)
  );
$$;

revoke execute on function public._is_area_open(int, admission_round, evaluation_area) from anon;

-- 현재 라운드의 활성 config_revision_id 조회 (RPC 내부 전용)
create or replace function public._current_config_revision_id(target_year int, target_round admission_round)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select config_revision_id from public.admission_rounds
  where year = target_year and round = target_round;
$$;

revoke execute on function public._current_config_revision_id(int, admission_round) from anon, authenticated;

-- 지원자가 평가 활성 상태인지 (evaluation_roster 기준)
create or replace function public._is_evaluation_active(p_applicant_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select evaluation_active from public.evaluation_roster where applicant_id = p_applicant_id),
    false
  );
$$;

revoke execute on function public._is_evaluation_active(uuid) from anon;

-- ============================================================
-- 2. 테이블 (공통 형태: inputs 원본 입력값 / server_computed 서버 산출값)
-- ============================================================

create table public.scores_attendance (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_academic (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_community (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'submitted' check (submission_state in ('submitted', 'reopened')),
  inputs jsonb not null,
  server_computed jsonb not null,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

comment on table public.scores_attendance is 'M3a. role=quant, area=attendance. requiredSubmissions=1 (config).';
comment on table public.scores_academic is 'M3b. role=quant, area=academic. requiredSubmissions=1 (config).';
comment on table public.scores_community is 'M3c. role=evaluator, area=community. requiredSubmissions=2, combine=avg (config) — 집계는 M4/aggregate에서.';

-- ============================================================
-- 3. RLS — 6.7 공통검증(본인만 read/write) + 6.8 영역별 role/area
-- ============================================================

alter table public.scores_attendance enable row level security;
alter table public.scores_academic enable row level security;
alter table public.scores_community enable row level security;

create policy scores_attendance_select_own_or_admin
  on public.scores_attendance for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_academic_select_own_or_admin
  on public.scores_academic for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_community_select_own_or_admin
  on public.scores_community for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = 아래 RPC로만 (섹션 2.12, 6.7 "서버만 계산")

-- ============================================================
-- 4. submit_attendance_score RPC
--    inputs: 미인정결석 일수, 지각·조퇴·결과 합산 횟수(3회=1일 환산),
--    학생부 자체가 없는 경우(검정고시 등) p_no_record=true → noRecordScore
-- ============================================================

create or replace function public.submit_attendance_score(
  p_applicant_id uuid,
  p_unexcused_absences int,
  p_tardy_early_result_count int,
  p_no_record boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  params jsonb;
  effective_days int;
  computed_score numeric;
  used_no_record boolean := p_no_record;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('quant') and public.has_area('attendance')) then
    raise exception '출결 평가 권한이 없습니다 (quant + attendance 배정 필요).';
  end if;

  select * into existing from public.scores_attendance
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'attendance') then
    raise exception '출결 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'attendance' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 attendance 배점 파라미터가 없습니다.';
  end if;

  if used_no_record then
    computed_score := (params ->> 'noRecordScore')::numeric;
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_tardy_early_result_count is null or p_tardy_early_result_count < 0 then
      raise exception '입력값은 0 이상의 정수여야 합니다.';
    end if;
    effective_days := p_unexcused_absences
      + floor(p_tardy_early_result_count::numeric / (params ->> 'attendanceEventPerAbsence')::numeric);
    computed_score := greatest(
      0,
      least(
        (params ->> 'max')::numeric,
        (params ->> 'max')::numeric - (params ->> 'perDayDeduction')::numeric * effective_days
      )
    );
  end if;

  insert into public.scores_attendance
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'tardyEarlyResultCount', p_tardy_early_result_count,
       'noRecord', used_no_record
     ),
     jsonb_build_object(
       'effectiveAbsenceDays', effective_days,
       'score', computed_score,
       'usedNoRecordScore', used_no_record,
       'configRevisionId', rev_id
     ))
  on conflict (applicant_id, evaluator_uid) do update set
    inputs = excluded.inputs,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.attendance.submitted', 'scores_attendance',
     p_applicant_id::text, p_applicant_id::text, 'attendance');

  return jsonb_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days)::json;
end;
$$;

revoke execute on function public.submit_attendance_score(uuid, int, int, boolean) from anon;

-- ============================================================
-- 5. submit_academic_score RPC
--    p_input_type: 'regular'(성취도) | 'ged'(검정고시 원점수)
--    p_subjects: [{"subject":"국어","achievement":"A"}, ...] 또는
--                [{"subject":"국어","rawScore":85}, ...]
--    서버가 상위 5과목 선정. 증빙 자체 없음 = p_no_document=true
-- ============================================================

create or replace function public.submit_academic_score(
  p_applicant_id uuid,
  p_input_type text,
  p_subjects jsonb default '[]'::jsonb,
  p_no_document boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  params jsonb;
  grade_map jsonb;
  ged_bands jsonb;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('quant') and public.has_area('academic')) then
    raise exception '학업성실도 평가 권한이 없습니다 (quant + academic 배정 필요).';
  end if;
  if p_input_type not in ('regular', 'ged') then
    raise exception 'p_input_type은 regular 또는 ged여야 합니다.';
  end if;

  select * into existing from public.scores_academic
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'academic') then
    raise exception '학업성실도 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'academic' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 academic 배점 파라미터가 없습니다.';
  end if;

  if p_no_document then
    computed_score := (params ->> 'noDocumentScore')::numeric;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    grade_map := params -> 'gradeMap';
    ged_bands := params -> 'gedBands';

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_input_type = 'regular' then
        points := (grade_map ->> (subj ->> 'achievement'))::numeric;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
          band jsonb;
          matched boolean := false;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception 'GED 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          for band in select * from jsonb_array_elements(ged_bands)
          loop
            if raw >= (band ->> 0)::numeric and raw <= (band ->> 1)::numeric then
              points := (band ->> 2)::numeric;
              matched := true;
              exit;
            end if;
          end loop;
          if not matched then
            raise exception 'GED 원점수 %에 해당하는 구간을 찾지 못했습니다.', raw;
          end if;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    -- 상위 5과목 선정·합산 (서버만 수행 — 클라이언트가 고르지 않음)
    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, (params ->> 'max')::numeric);
  end if;

  insert into public.scores_academic
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object('inputType', p_input_type, 'subjects', p_subjects, 'noDocument', p_no_document),
     jsonb_build_object('score', computed_score, 'usedNoDocumentScore', p_no_document, 'configRevisionId', rev_id))
  on conflict (applicant_id, evaluator_uid) do update set
    inputs = excluded.inputs,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.academic.submitted', 'scores_academic',
     p_applicant_id::text, p_applicant_id::text, 'academic');

  return jsonb_build_object('score', computed_score)::json;
end;
$$;

revoke execute on function public.submit_academic_score(uuid, text, jsonb, boolean) from anon;

-- ============================================================
-- 6. submit_community_score RPC — evaluator, 1~5등급 + 근거메모 필수
-- ============================================================

create or replace function public.submit_community_score(
  p_applicant_id uuid,
  p_grade int,
  p_evidence_memo text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  params jsonb;
  computed_score numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('community')) then
    raise exception '공동체 평가 권한이 없습니다 (evaluator + community 배정 필요).';
  end if;

  select * into existing from public.scores_community
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;
  if p_grade is null or p_grade < 1 or p_grade > 5 then
    raise exception '등급은 1~5 사이여야 합니다.';
  end if;
  if p_evidence_memo is null or length(trim(p_evidence_memo)) < 10 then
    raise exception '근거 메모는 최소 10자 이상 입력해야 합니다.';
  end if;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'community') then
    raise exception '공동체 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'community' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 community 배점 파라미터가 없습니다.';
  end if;

  computed_score := ((params -> 'grades') ->> p_grade::text)::numeric;
  if computed_score is null then
    raise exception '등급 %에 대한 배점이 config에 없습니다.', p_grade;
  end if;

  insert into public.scores_community
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object('grade', p_grade, 'evidenceMemo', p_evidence_memo),
     jsonb_build_object('score', computed_score, 'configRevisionId', rev_id))
  on conflict (applicant_id, evaluator_uid) do update set
    inputs = excluded.inputs,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.community.submitted', 'scores_community',
     p_applicant_id::text, p_applicant_id::text, 'community');

  return jsonb_build_object('score', computed_score)::json;
end;
$$;

revoke execute on function public.submit_community_score(uuid, int, text) from anon;

-- ============================================================
-- 7. 재개방 RPC (superadmin/admin 전용) — 제출된 점수 재수정 허용
-- ============================================================

create or replace function public.reopen_score(
  p_score_table text,
  p_score_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_score_table not in ('scores_attendance', 'scores_academic', 'scores_community') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke execute on function public.reopen_score(text, uuid) from anon;

-- ======================================================================
-- 00006_scores_m3de_essay_opinion.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M3d/e 자기소개서·학부모 소견서 채점 (Sprint 3 계속)
-- 근거: 2026학년도 새봄고 신입생 입학전형 서류평가 업무 진행 지침
-- (2025.11.3.) 4.(4)(5)항. 배점표는 이 문서를 그대로 반영했다.
--
-- 자기소개서: 10개 기준, 기준당 0~10점 정수, 5인 독립채점 합산(최대 500).
--   "형식적 서술이라도 관련성 있으면 최소 3점" — 사람 판단 영역이라
--   서버에서 강제하지 않고 채점 화면에 안내 문구로만 표시한다.
-- 학부모 소견서: 5개 기준, 기준당 0~5점 0.5단위, 4인 독립채점 합산(최대 100).
--   deductionFlags(모순 발견/건강·약물정보 누락)는 참고용 boolean 플래그로
--   기록하되, 실제 감점 반영은 위원이 최종 점수에 직접 반영한다(사람 판단).
--
-- 자소서는 "자동저장" 요구가 명시돼 있어(스펙 1251행) draft 상태를 둔다.
-- 소견서도 동일 패턴으로 일관되게 draft를 둔다.

-- ============================================================
-- 1. 테이블
-- ============================================================

create table public.scores_essay (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'draft' check (submission_state in ('draft', 'submitted', 'reopened')),
  items jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_opinion (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'draft' check (submission_state in ('draft', 'submitted', 'reopened')),
  items jsonb not null default '{}'::jsonb,
  deduction_flags jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

comment on table public.scores_essay is
  'M3d. role=evaluator, area=essay. 기준 10개(각 0~10, 정수), 5인 합산 최대 500. items key는 config criteria 키셋과 정확히 일치해야 함.';
comment on table public.scores_opinion is
  'M3e. role=evaluator, area=opinion. 기준 5개(각 0~5, 0.5단위), 4인 합산 최대 100.';

-- ============================================================
-- 2. RLS (M3a~c와 동일 패턴: 본인 또는 관리자만 read, write는 RPC로만)
-- ============================================================

alter table public.scores_essay enable row level security;
alter table public.scores_opinion enable row level security;

create policy scores_essay_select_own_or_admin
  on public.scores_essay for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_opinion_select_own_or_admin
  on public.scores_opinion for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

-- ============================================================
-- 3. 자기소개서 기준 키셋 (10개, 0~10점 정수)
-- ============================================================

create or replace function public._essay_criteria_keys()
returns text[]
language sql
immutable
as $$
  select array[
    'admissionWill', 'selfUnderstanding', 'schoolUnderstanding', 'schoolAdaptation',
    'learningWill', 'serviceWill', 'communityLife', 'careerConnection',
    'sincerity', 'feasibility'
  ];
$$;

-- ============================================================
-- 4. save_essay_draft — 자동저장 (제출확정 아님, 여러 번 호출 가능)
-- ============================================================

create or replace function public.save_essay_draft(
  p_applicant_id uuid,
  p_items jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  v numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('essay')) then
    raise exception '자기소개서 평가 권한이 없습니다 (evaluator + essay 배정 필요).';
  end if;

  select * into existing from public.scores_essay
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  -- 부분 저장 허용: 채워진 키만 0~10 정수인지 검증 (전체 키 필수는 제출 시점에)
  for k, v in select key, value::text::numeric from jsonb_each(p_items)
  loop
    if not (k = any(public._essay_criteria_keys())) then
      raise exception '알 수 없는 채점 기준: %', k;
    end if;
    if v < 0 or v > 10 or v != trunc(v) then
      raise exception '% 점수는 0~10 사이의 정수여야 합니다 (입력값: %)', k, v;
    end if;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_essay
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, submission_state)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items, 'draft')
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    submission_state = 'draft',
    updated_at = now();
end;
$$;

revoke execute on function public.save_essay_draft(uuid, jsonb) from anon;

-- ============================================================
-- 5. submit_essay_score — 제출확정 (10개 키 전부 필수, 서버가 합산)
-- ============================================================

create or replace function public.submit_essay_score(
  p_applicant_id uuid,
  p_items jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  total numeric := 0;
  existing record;
  required_keys text[] := public._essay_criteria_keys();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('essay')) then
    raise exception '자기소개서 평가 권한이 없습니다 (evaluator + essay 배정 필요).';
  end if;

  select * into existing from public.scores_essay
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  -- 10개 키 전부 존재해야 제출 가능 (draft는 부분 허용, 제출은 완전해야 함)
  foreach k in array required_keys loop
    if not (p_items ? k) then
      raise exception '% 기준 점수가 없습니다. 10개 기준을 모두 입력해야 제출할 수 있습니다.', k;
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(p_items)) <> array_length(required_keys, 1) then
    raise exception '허용되지 않은 추가 기준이 있습니다.';
  end if;

  for k in select jsonb_object_keys(p_items) loop
    declare v numeric := (p_items ->> k)::numeric;
    begin
      if v < 0 or v > 10 or v != trunc(v) then
        raise exception '% 점수는 0~10 사이의 정수여야 합니다 (입력값: %)', k, v;
      end if;
      total := total + v;
    end;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'essay') then
    raise exception '자기소개서 평가가 현재 열려있지 않습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_essay
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, server_computed,
     submission_state, submitted_at)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items,
     jsonb_build_object('total', total), 'submitted', now())
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.essay.submitted', 'scores_essay',
     p_applicant_id::text, p_applicant_id::text, 'essay');

  return jsonb_build_object('total', total)::json;
end;
$$;

revoke execute on function public.submit_essay_score(uuid, jsonb) from anon;

-- ============================================================
-- 6. 학부모 소견서 기준 키셋 (5개, 0~5점 0.5단위)
-- ============================================================

create or replace function public._opinion_criteria_keys()
returns text[]
language sql
immutable
as $$
  select array[
    'altEducationUnderstanding', 'schoolUnderstanding', 'childUnderstanding',
    'childCareerView', 'admissionWillParticipation'
  ];
$$;

-- ============================================================
-- 7. submit_opinion_score — 제출확정 (0.5단위 검증 포함)
-- ============================================================

create or replace function public.submit_opinion_score(
  p_applicant_id uuid,
  p_items jsonb,
  p_deduction_flags jsonb default '{}'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  total numeric := 0;
  existing record;
  required_keys text[] := public._opinion_criteria_keys();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('opinion')) then
    raise exception '학부모 소견서 평가 권한이 없습니다 (evaluator + opinion 배정 필요).';
  end if;

  select * into existing from public.scores_opinion
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  foreach k in array required_keys loop
    if not (p_items ? k) then
      raise exception '% 기준 점수가 없습니다. 5개 기준을 모두 입력해야 제출할 수 있습니다.', k;
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(p_items)) <> array_length(required_keys, 1) then
    raise exception '허용되지 않은 추가 기준이 있습니다.';
  end if;

  for k in select jsonb_object_keys(p_items) loop
    declare v numeric := (p_items ->> k)::numeric;
    begin
      if v < 0 or v > 5 or mod(v * 10, 5) <> 0 then
        raise exception '% 점수는 0~5 사이의 0.5 단위여야 합니다 (입력값: %)', k, v;
      end if;
      total := total + v;
    end;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'opinion') then
    raise exception '학부모 소견서 평가가 현재 열려있지 않습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_opinion
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, deduction_flags,
     server_computed, submission_state, submitted_at)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items, p_deduction_flags,
     jsonb_build_object('total', total), 'submitted', now())
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    deduction_flags = excluded.deduction_flags,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.opinion.submitted', 'scores_opinion',
     p_applicant_id::text, p_applicant_id::text, 'opinion');

  return jsonb_build_object('total', total)::json;
end;
$$;

revoke execute on function public.submit_opinion_score(uuid, jsonb, jsonb) from anon;

-- ============================================================
-- 8. reopen_score 확장 (기존 함수에 essay/opinion 테이블 추가)
-- ============================================================

create or replace function public.reopen_score(
  p_score_table text,
  p_score_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_score_table not in
     ('scores_attendance', 'scores_academic', 'scores_community', 'scores_essay', 'scores_opinion') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_community' then
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_essay' then
    update public.scores_essay set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_opinion set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke execute on function public.reopen_score(text, uuid) from anon;

-- ======================================================================
-- 00007_m3f_admin_monitor.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M3f 관리자 모니터 (Sprint 3 마무리)
-- 마스터 스펙 v1.2 섹션 3.18(evaluationAlerts), 6.10(개별점수 상세조회) 대응.
--
-- 이번 마이그레이션에서 바로잡는 것: Sprint 3 앞부분(00005/00006)에서
-- scoresXxx 테이블에 superadmin/admin의 SELECT를 그냥 열어뒀는데, 스펙은
-- "관리자 기본 UI는 aggregate/alert만 사용, 개별점수는 사유기록+감사로그
-- 후 별도 Function으로만" (2463행, 2592행)이라고 명시한다. 여기서
-- 정책을 교체해 admin의 직접 테이블 조회를 막고, 사유 기반 Function으로만
-- 개별점수를 볼 수 있게 한다.

-- ============================================================
-- 1. evaluation_alerts (섹션 3.18)
-- ============================================================

create type alert_type as enum
  ('scoreGap', 'missingSubmission', 'primaryObserverMissing', 'invalidScore', 'aggregationBlocked');
create type alert_severity as enum ('info', 'warning', 'blocking');
create type alert_status as enum ('open', 'acknowledged', 'resolved');

create table public.evaluation_alerts (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  area evaluation_area not null,
  alert_type alert_type not null,
  severity alert_severity not null default 'warning',
  summary text not null,
  related_evaluator_uids uuid[] not null default '{}',
  status alert_status not null default 'open',
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolved_by text,
  unique (year, round, applicant_id, area, alert_type)
);

comment on table public.evaluation_alerts is
  '평가위원은 절대 읽을 수 없다 (섹션 3.18). 관리자 대시보드는 개별점수보다 이 경보·제출상태를 우선 표시한다.';

alter table public.evaluation_alerts enable row level security;

create policy evaluation_alerts_select_admins
  on public.evaluation_alerts for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = 아래 recompute RPC로만

-- ============================================================
-- 2. scoresXxx 관리자 blanket SELECT 제거 — 개별점수 비노출 원칙 강화
--    (Sprint 3 앞부분에서 admin에게 그냥 열어뒀던 것을 여기서 좁힌다)
-- ============================================================

drop policy if exists scores_attendance_select_own_or_admin on public.scores_attendance;
drop policy if exists scores_academic_select_own_or_admin on public.scores_academic;
drop policy if exists scores_community_select_own_or_admin on public.scores_community;
drop policy if exists scores_essay_select_own_or_admin on public.scores_essay;
drop policy if exists scores_opinion_select_own_or_admin on public.scores_opinion;

create policy scores_attendance_select_own on public.scores_attendance for select using (evaluator_uid = auth.uid());
create policy scores_academic_select_own on public.scores_academic for select using (evaluator_uid = auth.uid());
create policy scores_community_select_own on public.scores_community for select using (evaluator_uid = auth.uid());
create policy scores_essay_select_own on public.scores_essay for select using (evaluator_uid = auth.uid());
create policy scores_opinion_select_own on public.scores_opinion for select using (evaluator_uid = auth.uid());

-- 이제 admin/superadmin이 개별점수를 보려면 반드시 아래
-- get_evaluation_score_detail (사유기록 + 감사로그)을 거쳐야 한다.
-- reopen_score 등 기존 RPC는 SECURITY DEFINER라 이 RLS 강화와 무관하게 계속 동작한다.

-- ============================================================
-- 3. get_evaluation_score_detail — 사유 기반 개별점수 상세조회 (섹션 6.10)
-- ============================================================

create or replace function public.get_evaluation_score_detail(
  p_applicant_id uuid,
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  caller_doc record;
  score_row record;
  result jsonb;
  valid_reasons text[] := array['편차 경보 확인', '입력 오류 확인', '입학전형위원회 협의', '이의·감사 대응', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code;
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 reason_text를 반드시 입력해야 합니다.';
  end if;

  select * into caller_doc from public.users where id = caller;

  -- 관리자 자신이 동일영역 evaluator이고 본인 미제출이면 타 위원 점수 열람 거부.
  -- 반드시 요청한 p_area 하나만 확인한다 (다른 영역 제출 여부로 착각하면 안 됨).
  if p_area = any(caller_doc.assigned_areas) and (caller_doc.roles && array['evaluator','quant']::app_role[]) then
    declare
      already_submitted boolean := false;
    begin
      if p_area = 'attendance' then
        select exists(select 1 from public.scores_attendance
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'academic' then
        select exists(select 1 from public.scores_academic
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'community' then
        select exists(select 1 from public.scores_community
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'essay' then
        select exists(select 1 from public.scores_essay
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'opinion' then
        select exists(select 1 from public.scores_opinion
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      end if;

      if not already_submitted then
        raise exception '본인 평가를 제출하기 전에는 같은 영역의 다른 위원 점수를 열람할 수 없습니다.';
      end if;
    end;
  end if;

  if p_area = 'attendance' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_attendance
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'academic' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_academic
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'community' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_community
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'essay' then
    select applicant_id, evaluator_uid, items as inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_essay
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'opinion' then
    select applicant_id, evaluator_uid, items as inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_opinion
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  else
    raise exception '개별점수 상세조회를 지원하지 않는 영역입니다: %', p_area;
  end if;

  if score_row is null then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  result := jsonb_build_object(
    'applicantId', score_row.applicant_id,
    'evaluatorUid', score_row.evaluator_uid,
    'inputs', score_row.inputs,
    'serverComputed', score_row.server_computed,
    'submissionState', score_row.submission_state,
    'submittedAt', score_row.submitted_at
  );

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    ('user', caller::text, 'score.detail_viewed', 'scores_' || p_area::text, p_target_evaluator_uid::text,
     p_applicant_id::text, p_area, p_reason_code,
     jsonb_build_object('reasonText', p_reason_text));

  return result::json;
end;
$$;

revoke execute on function public.get_evaluation_score_detail(uuid, evaluation_area, uuid, text, text) from anon;

-- ============================================================
-- 4. recompute_evaluation_alerts — 경보 재계산 (superadmin/admin 트리거)
--    scoreGap(essay/opinion), missingSubmission(전 영역) 감지.
--    이미 open인 동일 경보는 유지, 더 이상 유효하지 않으면 자동 resolved.
-- ============================================================

create or replace function public.recompute_evaluation_alerts(
  target_year int,
  target_round admission_round
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
  created_count int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- ── scoreGap: essay ──────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_essay
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'essay' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'essay', 'scoreGap', 'warning',
         format('자소서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'essay' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'essay' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── scoreGap: opinion ────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_opinion
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'opinion' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'opinion', 'scoreGap', 'warning',
         format('소견서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'opinion' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'opinion' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── missingSubmission: 5개 영역 전부, 평가활성 지원자 기준 ──
  for r in
    select er.applicant_id, area_key.area,
           (params -> area_key.area ->> 'requiredSubmissions')::int as required,
           coalesce(cnt.submitted, 0) as submitted
    from public.evaluation_roster er
    cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
    left join lateral (
      select count(*) as submitted from (
        select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
        union all
        select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
        union all
        select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
        union all
        select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
        union all
        select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
      ) x
    ) cnt on true
    where er.year = target_year and er.round = target_round and er.evaluation_active = true
  loop
    if r.required is not null and r.submitted < r.required then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary)
      values
        (target_year, target_round, r.applicant_id, r.area::evaluation_area, 'missingSubmission', 'warning',
         format('%s 영역 제출 %s/%s건', r.area, r.submitted, r.required))
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = r.area::evaluation_area and alert_type = 'missingSubmission' and status != 'resolved';
    end if;
  end loop;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type)
  values (target_year, target_round, 'user', caller::text, 'evaluation_alerts.recomputed', 'evaluation_alerts');

  return jsonb_build_object('processed', created_count)::json;
end;
$$;

revoke execute on function public.recompute_evaluation_alerts(int, admission_round) from anon;

-- ============================================================
-- 5. get_evaluation_progress — 위원별 진행률 (개별점수 노출 없이 카운트만)
-- ============================================================

create or replace function public.get_evaluation_progress(
  target_year int,
  target_round admission_round
)
returns table (
  applicant_id uuid,
  receipt_no text,
  display_name text,
  area text,
  required int,
  submitted int,
  complete boolean,
  open_alerts int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  return query
  select
    er.applicant_id,
    er.receipt_no,
    er.display_name,
    area_key.area,
    (params -> area_key.area ->> 'requiredSubmissions')::int as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= coalesce((params -> area_key.area ->> 'requiredSubmissions')::int, 0) as complete,
    (select count(*)::int from public.evaluation_alerts ea
      where ea.applicant_id = er.applicant_id and ea.area::text = area_key.area and ea.status = 'open') as open_alerts
  from public.evaluation_roster er
  cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
  left join lateral (
    select count(*) as submitted from (
      select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
      union all
      select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
      union all
      select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
      union all
      select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
      union all
      select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
    ) x
  ) cnt on true
  where er.year = target_year and er.round = target_round and er.evaluation_active = true
  order by er.receipt_no, area_key.area;
end;
$$;

revoke execute on function public.get_evaluation_progress(int, admission_round) from anon;

-- ======================================================================
-- 00008_m4_document_decision.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M4 1차 사정 (Sprint 4)
-- 마스터 스펙 v1.2 섹션 3.19(decisionRuns/decisionResults/committeeDecisions),
-- 5.2(집계), 5.3(사정로직), 5.6(decisionRuns 실행원칙) 대응.
--
-- 단순화(문서화): 스펙은 aggregates/{applicantId}를 트리거로 반응형 유지하는
-- 컬렉션으로 설계했지만, 이 구현은 사정 실행(run_document_decision) 시점에
-- _compute_document_aggregate로 즉석 계산한다. 이 학교 규모(지원자 수십 명)
-- 에서는 트리거 기반 상시 집계 인프라 없이도 충분히 빠르고, source-of-truth
-- (scoresXxx 제출값)만 보고 항상 최신값을 계산하므로 staleness 문제 자체가
-- 없다. 성능이 실제로 문제가 되면 그때 캐시 테이블+트리거로 전환한다.

-- ============================================================
-- 1. decision_runs / decision_results / committee_decisions
-- ============================================================

create type decision_type as enum ('document', 'final');
create type decision_mode as enum ('simulation', 'final');
create type decision_run_status as enum ('running', 'completed', 'finalized', 'failed');
create type decision_outcome as enum ('passed', 'failed', 'excluded', 'manualDecisionRequired');

create table public.decision_runs (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  decision_type decision_type not null,
  mode decision_mode not null,
  status decision_run_status not null default 'running',
  config_revision_id uuid not null references public.config_revisions (id),
  aggregate_snapshot_at timestamptz not null default now(),
  candidate_count int not null default 0,
  result_count int not null default 0,
  unresolved_tie_count int not null default 0,
  blocking_alert_count int not null default 0,
  created_at timestamptz not null default now(),
  created_by text not null,
  finalized_at timestamptz,
  finalized_by text
);

create table public.decision_results (
  run_id uuid not null references public.decision_runs (id) on delete cascade,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  decision_type decision_type not null,
  total_score numeric,
  rank int,
  tiebreak_values jsonb not null default '{}'::jsonb,
  track_result jsonb not null default '{}'::jsonb,
  outcome decision_outcome not null,
  committee_decision_applied boolean not null default false,
  committee_decision_code text,
  created_at timestamptz not null default now(),
  primary key (run_id, applicant_id)
);

create table public.committee_decisions (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  decision_type text not null check (decision_type in
    ('violenceReview', 'exclusion', 'unresolvedTie', 'evaluationOverride', 'other')),
  outcome_code text not null,
  meeting_date date,
  rationale text not null,
  evidence_document_ids uuid[] not null default '{}',
  recorded_at timestamptz not null default now(),
  recorded_by text not null,
  related_decision_run_id uuid references public.decision_runs (id)
);

comment on table public.decision_runs is
  'simulation은 몇 번이든 실행 가능하며 발표·상태변경 근거로 쓸 수 없다. final은 검증 통과 시에만 applicants/evaluation_roster를 실제로 변경한다.';
comment on table public.committee_decisions is
  '학폭·부적합·동점 등 사람이 결정해야 하는 사안의 기록. 시스템은 자동 감점·자동 제외하지 않는다 (섹션 5.3.4).';

alter table public.decision_runs enable row level security;
alter table public.decision_results enable row level security;
alter table public.committee_decisions enable row level security;

create policy decision_runs_select_admins
  on public.decision_runs for select
  using (public.has_role('superadmin') or public.has_role('admin') or public.has_role('viewer'));

create policy decision_results_select_admins
  on public.decision_results for select
  using (public.has_role('superadmin') or public.has_role('admin') or public.has_role('viewer'));

create policy committee_decisions_select_admins
  on public.committee_decisions for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = RPC로만

-- ============================================================
-- 2. 문서평가 집계 (섹션 5.2 산식 그대로, 즉석 계산)
-- ============================================================

create or replace function public._compute_document_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  app record;
  rev_id uuid;
  params jsonb;
  attendance_score numeric;
  academic_score numeric;
  community_score numeric;
  community_count int;
  essay_score numeric;
  essay_count int;
  opinion_score numeric;
  opinion_count int;
  raw_total numeric;
  final_total numeric;
  is_complete boolean;
  bonus_applied boolean := false;
  bonus_amount numeric := 0;
begin
  select id, year, round, tracks, bonus_eligible, bonus_reason
    into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- 출결 (5.2.1): 필수 1건, 없으면 null/미확정
  select (server_computed ->> 'score')::numeric into attendance_score
    from public.scores_attendance
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 학업성실도 (5.2.2)
  select (server_computed ->> 'score')::numeric into academic_score
    from public.scores_academic
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 공동체 (5.2.3): 정확히 2인 제출 필요, 아니면 미확정
  select count(*), avg((server_computed ->> 'score')::numeric)
    into community_count, community_score
    from public.scores_community
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if community_count <> 2 then
    community_score := null;
  end if;

  -- 자소서 (5.2.4): 정확히 5인 제출 필요
  select count(*), sum((server_computed ->> 'total')::numeric)
    into essay_count, essay_score
    from public.scores_essay
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if essay_count <> 5 then
    essay_score := null;
  end if;

  -- 소견서 (5.2.5): 정확히 4인 제출 필요
  select count(*), sum((server_computed ->> 'total')::numeric)
    into opinion_count, opinion_score
    from public.scores_opinion
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if opinion_count <> 4 then
    opinion_score := null;
  end if;

  -- 서류평가 원점수 (5.2.6): 5개 영역 전부 확정일 때만
  is_complete := attendance_score is not null and academic_score is not null
    and community_score is not null and essay_score is not null and opinion_score is not null;

  if is_complete then
    raw_total := attendance_score + academic_score + community_score + essay_score + opinion_score;

    -- 가산점 (5.2.7, applyLevel='total' 기본값 — 섹션 5.8 D 확인 전까지 이 값 사용)
    -- config에 bonus 파라미터가 아직 없으면(설정 전 단계) 안전하게 가산점 미적용으로 처리.
    if params -> 'bonus' is not null
       and 'incheon' = any(app.tracks)
       and app.bonus_eligible = true
       and app.bonus_reason = any(
         array(select jsonb_array_elements_text(coalesce(params -> 'bonus' -> 'eligibleReasons', '[]'::jsonb)))
       )
    then
      bonus_applied := true;
      final_total := least(
        coalesce((params -> 'bonus' ->> 'cap')::numeric, raw_total),
        raw_total * (1 + coalesce((params -> 'bonus' ->> 'rate')::numeric, 0))
      );
      bonus_amount := final_total - raw_total;
    else
      final_total := raw_total;
    end if;
  end if;

  return jsonb_build_object(
    'attendance', attendance_score,
    'academic', academic_score,
    'community', community_score,
    'essay', essay_score,
    'opinion', opinion_score,
    'complete', is_complete,
    'rawTotal', raw_total,
    'bonusApplied', bonus_applied,
    'bonusAmount', bonus_amount,
    'finalTotal', final_total
  );
end;
$$;

revoke execute on function public._compute_document_aggregate(uuid) from anon, authenticated;

-- ============================================================
-- 3. run_document_decision — 1차 사정 실행 (simulation | final)
--    섹션 5.3(정렬·동점), 5.6(실행 원칙) 그대로 구현.
-- ============================================================

create or replace function public.run_document_decision(
  p_year int,
  p_round admission_round,
  p_mode decision_mode
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  quota jsonb;
  pass_limit int;
  v_run_id uuid;
  blocking_count int;
  applicant_row record;
  agg jsonb;
  boundary_rank int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  next_exam_seq int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(p_year, p_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'quota' into quota from public.config_revisions where id = rev_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다. setup 스크립트를 먼저 실행하세요.';
  end if;
  pass_limit := floor((quota ->> 'total')::numeric * (quota ->> 'screeningMultiple')::numeric);

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'document', p_mode, 'running', rev_id, caller::text)
  returning id into v_run_id;

  -- 후보군: 접수완료 + 사정제외 아님 (섹션 5.3.1 — evaluationStage 게이트는
  -- 아직 별도 전환 단계를 만들지 않아 이번 구현에서는 생략, 검토메모 기록)
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    document_final numeric,
    community numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  for applicant_row in
    select a.id from public.applicants a
    left join public.applicants_admin aa on aa.applicant_id = a.id
    where a.year = p_year and a.round = p_round and a.application_status = 'complete'
      and coalesce(aa.exclusion_status, 'none') <> 'excluded'
  loop
    agg := public._compute_document_aggregate(applicant_row.id);
    if (agg ->> 'complete')::boolean then
      insert into tmp_candidates values (
        applicant_row.id,
        (agg ->> 'finalTotal')::numeric,
        (agg ->> 'community')::numeric,
        (agg ->> 'essay')::numeric,
        (agg ->> 'attendance')::numeric,
        (agg ->> 'academic')::numeric
      );
      v_candidate_count := v_candidate_count + 1;
    end if;
  end loop;

  -- 순위 산정 (섹션 5.3.3 정렬 기준 그대로) + 동점 경계 판정
  create temp table tmp_ranked on commit drop as
  select *,
    rank() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rn
  from tmp_candidates;

  select rnk into boundary_rank from tmp_ranked where rn = pass_limit;

  -- decision_results 기록
  for applicant_row in select * from tmp_ranked loop
    declare
      this_outcome decision_outcome;
    begin
      if boundary_rank is not null and applicant_row.rnk = boundary_rank
         and (select count(*) from tmp_ranked where rnk = boundary_rank and rn > pass_limit) > 0 then
        this_outcome := 'manualDecisionRequired';
        unresolved_count := unresolved_count + 1;
      elsif applicant_row.rnk <= coalesce(boundary_rank, pass_limit) then
        this_outcome := 'passed';
      else
        this_outcome := 'failed';
      end if;

      insert into public.decision_results
        (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values, outcome)
      values
        (v_run_id, applicant_row.applicant_id, p_year, p_round, 'document', applicant_row.document_final,
         applicant_row.rnk,
         jsonb_build_object(
           'community', applicant_row.community, 'essay', applicant_row.essay,
           'attendance', applicant_row.attendance, 'academic', applicant_row.academic
         ),
         this_outcome);
      v_result_count := v_result_count + 1;
    end;
  end loop;

  update public.decision_runs
  set candidate_count = v_candidate_count, result_count = v_result_count,
      unresolved_tie_count = unresolved_count, blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 실제 반영 ──────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;

    -- 합격자 수험번호 채번 (섹션 5.6 — 서버 transaction 일괄 발급)
    select coalesce(max(substring(exam_no from '\d+$')::int), 0) into next_exam_seq
      from public.evaluation_roster where year = p_year and round = p_round and exam_no is not null;

    for applicant_row in
      select dr.applicant_id from public.decision_results dr
      where dr.run_id = v_run_id and dr.outcome = 'passed'
      order by dr.rank
    loop
      next_exam_seq := next_exam_seq + 1;
      update public.applicants set evaluation_stage = 'documentPassed', updated_at = now(), updated_by = caller::text
        where id = applicant_row.applicant_id;
      update public.evaluation_roster
        set exam_no = p_year::text || '-' || lpad(next_exam_seq::text, 3, '0'),
            evaluation_stage = 'documentPassed', updated_at = now()
        where applicant_id = applicant_row.applicant_id;
    end loop;

    update public.applicants set evaluation_stage = 'documentFailed', updated_at = now(), updated_by = caller::text
      where id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');
    update public.evaluation_roster set evaluation_stage = 'documentFailed', updated_at = now()
      where applicant_id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;

revoke execute on function public.run_document_decision(int, admission_round, decision_mode) from anon;

-- ============================================================
-- 4. record_committee_decision — 위원회 결정 기록 (사정제외·동점 등)
-- ============================================================

create or replace function public.record_committee_decision(
  p_applicant_id uuid,
  p_decision_type text,
  p_outcome_code text,
  p_rationale text,
  p_meeting_date date default null,
  p_related_decision_run_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
  new_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_rationale is null or length(trim(p_rationale)) < 5 then
    raise exception '결정 사유(rationale)는 최소 5자 이상 입력해야 합니다.';
  end if;

  select year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.committee_decisions
    (year, round, applicant_id, decision_type, outcome_code, meeting_date, rationale,
     related_decision_run_id, recorded_by)
  values
    (app.year, app.round, p_applicant_id, p_decision_type, p_outcome_code, p_meeting_date, p_rationale,
     p_related_decision_run_id, caller::text)
  returning id into new_id;

  -- exclusion 결정이면 applicantsAdmin에 즉시 반영 (시스템 자동판단 아님 — 위원회 결정 기록만 반영)
  if p_decision_type = 'exclusion' and p_outcome_code = 'excluded' then
    update public.applicants_admin
    set exclusion_status = 'excluded', updated_at = now(), updated_by = caller::text
    where applicant_id = p_applicant_id;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (app.year, app.round, 'user', caller::text, 'committee_decision.recorded', 'committee_decisions',
     new_id::text, p_applicant_id::text);

  return new_id;
end;
$$;

revoke execute on function public.record_committee_decision(uuid, text, text, text, date, uuid) from anon;

-- ======================================================================
-- 00009_m5a_group_planning.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M5a 심층역량평가 모둠 편성 (Sprint 5 시작)
-- 마스터 스펙 v1.2 섹션 3.14, M5a, 5.4.1 대응.
--
-- 핵심 불변조건
--   1) M5의 서류점수 기준은 "현재 aggregate"가 아니라 확정된 M4 final decisionRun 스냅샷이다.
--   2) 지원자는 해당 document final run의 passed 결과에 포함된 사람만, 정확히 1개 모둠에 배정한다.
--   3) 모둠별 주관찰위원은 정확히 2명이며 evaluator + group 영역 + 연도/차수 scope를 충족한다.
--   4) 순환 segment마다 group evaluator 전원의 관찰대상을 명시하고,
--      각 모둠에는 주관찰위원 최소 1명이 자기 모둠에 남아 있어야 한다.
--   5) 클라이언트 직접 write는 금지한다. draft 저장/최종확정은 SECURITY DEFINER RPC만 사용한다.

-- ============================================================
-- 1. M4 final decisionRun 포인터 — M5 documentCarry 스냅샷의 단일 기준
-- ============================================================

alter table public.admission_rounds
  add column if not exists document_decision_run_id uuid
  references public.decision_runs (id);

comment on column public.admission_rounds.document_decision_run_id is
  '확정된 1차 서류사정(final decisionRun) 포인터. M5 이후 documentCarry/모둠 균형표는 이 run의 decision_results.total_score 스냅샷만 사용한다.';

create or replace function public._capture_document_final_run_pointer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.decision_type = 'document'
     and new.mode = 'final'
     and new.status = 'finalized'
     and old.status is distinct from 'finalized' then
    update public.admission_rounds
    set document_decision_run_id = new.id,
        updated_at = now(),
        updated_by = coalesce(new.finalized_by, new.created_by)
    where year = new.year and round = new.round;
  end if;
  return new;
end;
$$;

revoke all on function public._capture_document_final_run_pointer() from public, anon, authenticated;

drop trigger if exists trg_capture_document_final_run_pointer on public.decision_runs;
create trigger trg_capture_document_final_run_pointer
  after update of status on public.decision_runs
  for each row execute function public._capture_document_final_run_pointer();

-- migration 적용 전에 이미 M4 final을 확정한 dev DB도 최신 finalized run을 연결한다.
with latest_final as (
  select distinct on (dr.year, dr.round)
         dr.year, dr.round, dr.id, dr.finalized_by, dr.created_by
  from public.decision_runs dr
  where dr.decision_type = 'document'
    and dr.mode = 'final'
    and dr.status = 'finalized'
  order by dr.year, dr.round, dr.finalized_at desc nulls last, dr.created_at desc
)
update public.admission_rounds ar
set document_decision_run_id = src.id,
    updated_at = now(),
    updated_by = coalesce(src.finalized_by, src.created_by)
from latest_final src
where ar.year = src.year
  and ar.round = src.round
  and ar.document_decision_run_id is null;

-- ============================================================
-- 2. M5a relational model
-- ============================================================

create type group_plan_status as enum ('draft', 'finalized');

create table public.deep_group_plans (
  year int not null,
  round admission_round not null,
  status group_plan_status not null default 'draft',
  document_source_run_id uuid not null references public.decision_runs (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.deep_groups (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  group_code text not null check (length(trim(group_code)) between 1 and 20),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (year, round, group_code),
  unique (id, year, round),
  foreign key (year, round) references public.deep_group_plans (year, round) on delete cascade
);

create table public.deep_group_members (
  group_id uuid not null,
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.evaluation_roster (applicant_id) on delete cascade,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  primary key (group_id, applicant_id),
  unique (year, round, applicant_id),
  foreign key (group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

create table public.deep_group_primary_observers (
  group_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  observer_slot smallint not null check (observer_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (group_id, observer_slot),
  unique (group_id, evaluator_uid),
  unique (year, round, evaluator_uid),
  foreign key (group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

create table public.deep_group_rotation_segments (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  segment_code text not null check (length(trim(segment_code)) between 1 and 30),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  check (ends_at > starts_at),
  unique (year, round, segment_code),
  unique (id, year, round),
  foreign key (year, round) references public.deep_group_plans (year, round) on delete cascade
);

create table public.deep_group_rotation_assignments (
  segment_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  target_group_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (segment_id, evaluator_uid),
  foreign key (segment_id, year, round)
    references public.deep_group_rotation_segments (id, year, round) on delete cascade,
  foreign key (target_group_id, year, round)
    references public.deep_groups (id, year, round) on delete cascade
);

comment on table public.deep_group_plans is
  'M5a 모둠편성 계획 header. document_source_run_id는 계획 생성 시점의 M4 final decisionRun 스냅샷으로 고정한다.';
comment on table public.deep_group_primary_observers is
  '모둠별 주관찰 2인. 동일 evaluator는 같은 연도/차수에서 둘 이상의 home group 주관찰위원이 될 수 없다.';
comment on table public.deep_group_rotation_assignments is
  'segment별 evaluator의 관찰 대상 모둠. final 계획에서는 group evaluator 전원에게 segment별 정확히 1개 target group이 있어야 한다.';

-- ============================================================
-- 3. RLS — group 영역 evaluator는 운영정보 read, write는 RPC 전용
-- ============================================================

alter table public.deep_group_plans enable row level security;
alter table public.deep_groups enable row level security;
alter table public.deep_group_members enable row level security;
alter table public.deep_group_primary_observers enable row level security;
alter table public.deep_group_rotation_segments enable row level security;
alter table public.deep_group_rotation_assignments enable row level security;

create policy deep_group_plans_select_staff
  on public.deep_group_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_plans.round = any(u.round_scopes))
      )
    )
  );

create policy deep_groups_select_staff
  on public.deep_groups for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_groups.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_groups.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_members_select_staff
  on public.deep_group_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_members.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_members.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_primary_observers_select_staff
  on public.deep_group_primary_observers for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_primary_observers.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_primary_observers.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_rotation_segments_select_staff
  on public.deep_group_rotation_segments for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_rotation_segments.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_rotation_segments.round = any(u.round_scopes))
      )
    )
  );

create policy deep_group_rotation_assignments_select_staff
  on public.deep_group_rotation_assignments for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('group')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or deep_group_rotation_assignments.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or deep_group_rotation_assignments.round = any(u.round_scopes))
      )
    )
  );

-- INSERT/UPDATE/DELETE policy 없음 = 클라이언트 직접 write 전면 금지.

-- ============================================================
-- 4. private helpers
-- ============================================================

create or replace function public._m5a_current_document_run_id(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_run_id uuid;
begin
  select ar.document_decision_run_id
    into v_run_id
  from public.admission_rounds ar
  where ar.year = p_year and ar.round = p_round;

  if v_run_id is null then
    raise exception 'M5a를 시작할 수 없습니다. 먼저 M4 1차 사정을 final로 확정하세요.';
  end if;

  if not exists (
    select 1
    from public.decision_runs dr
    where dr.id = v_run_id
      and dr.year = p_year
      and dr.round = p_round
      and dr.decision_type = 'document'
      and dr.mode = 'final'
      and dr.status = 'finalized'
  ) then
    raise exception 'admission_round의 document_decision_run_id가 유효한 finalized document final run을 가리키지 않습니다.';
  end if;

  return v_run_id;
end;
$$;

revoke all on function public._m5a_current_document_run_id(int, admission_round) from public, anon, authenticated;

create or replace function public._m5a_user_is_group_evaluator(
  p_uid uuid,
  p_year int,
  p_round admission_round
)
returns boolean
language sql
security definer
set search_path = public
volatile
as $$
  select exists (
    select 1
    from public.users u
    where u.id = p_uid
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'group' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  );
$$;

revoke all on function public._m5a_user_is_group_evaluator(uuid, int, admission_round) from public, anon, authenticated;

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

  select count(*) into v_count
  from public.deep_group_rotation_segments s
  cross join public.users u
  where s.year = p_year and s.round = p_round
    and u.active = true
    and 'evaluator' = any(u.roles)
    and 'group' = any(u.assigned_areas)
    and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
    and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
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
    group by s.id, s.segment_code, s.sort_order, g.id, g.group_code, g.sort_order
    having count(*) filter (where ra.target_group_id = g.id) < 1
  ) x;

  if jsonb_array_length(v_items) > 0 then
    v_issues := v_issues || jsonb_build_array(
      jsonb_build_object(
        'code', 'PRIMARY_OBSERVER_COVERAGE',
        'message', '모든 segment에서 각 모둠 주관찰위원 최소 1인이 자기 모둠에 남아 있어야 합니다.',
        'items', v_items
      )
    );
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
    'blockingIssues', v_issues
  );
end;
$$;

revoke all on function public._m5a_validate_plan(int, admission_round) from public, anon, authenticated;

-- ============================================================
-- 5. 관리자 조회 RPC — document final snapshot 점수를 함께 반환
-- ============================================================

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

-- ============================================================
-- 6. draft 저장 RPC — 전체 plan replace, finalized 이후 수정 금지
-- ============================================================

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
      (id, year, round, group_code, sort_order, created_by, updated_by)
    values
      (v_group_id, p_year, p_round, trim(g ->> 'groupCode'), coalesce((g ->> 'sortOrder')::int, 0), caller::text, caller::text);

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
      (id, year, round, segment_code, starts_at, ends_at, sort_order, created_by, updated_by)
    values
      (v_segment_id, p_year, p_round, trim(s ->> 'segmentCode'),
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

-- ============================================================
-- 7. 서버 검증 / final 확정 RPC
-- ============================================================

create or replace function public.validate_m5a_group_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  return public._m5a_validate_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5a_group_plan(int, admission_round) to authenticated;

create or replace function public.finalize_m5a_group_plan(
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
  v_plan record;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5a:%s:%s', p_year, p_round::text), 0));

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round
  for update;

  if v_plan is null then
    raise exception '최종확정할 모둠편성 draft가 없습니다.';
  end if;
  if v_plan.status = 'finalized' then
    raise exception '이미 최종확정된 모둠편성 계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5a_validate_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '모둠편성 계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.evaluation_roster er
  set group_id = gm.group_id,
      roster_revision = er.roster_revision + 1,
      updated_at = now()
  from public.deep_group_members gm
  where gm.year = p_year and gm.round = p_round
    and gm.applicant_id = er.applicant_id;

  update public.deep_group_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'deep_group_plan.finalized', 'deep_group_plans',
     p_year::text || '_' || p_round::text,
     jsonb_build_object(
       'documentSourceRunId', v_plan.document_source_run_id,
       'candidateCount', v_validation -> 'candidateCount',
       'groupCount', v_validation -> 'groupCount',
       'segmentCount', v_validation -> 'segmentCount'
     ));

  return public._m5a_validate_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5a_group_plan(int, admission_round) to authenticated;

-- ======================================================================
-- 00010_m5b_group_observation.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M5b 심층역량평가 모둠활동 관찰채점
-- 마스터 스펙 v1.2 섹션 2.7, 3.14, 6.12, 9의 불변조건 반영.
--
-- 핵심 불변조건
--   1) group evaluator + 연도/차수 scope + finalized M5a plan만 접근한다.
--   2) observer_role은 서버가 primaryObservers/rotation assignment로 재판정한다.
--   3) 주관찰위원은 자기 home group 전원을 평가하며 최소 1개 home segment 관찰 근거가 필요하다.
--   4) 순환관찰위원은 실제 배정 segment만 observed_segment_ids에 넣을 수 있고
--      observation_confirmed=true인 제출만 유효하다.
--   5) 주관찰 필수 인원(2027: 2인) 모두 제출 전 group aggregate는 null/complete=false다.
--   6) 점수 aggregate는 config revision의 deep.group 구조화 파라미터만 사용한다.
--   7) 클라이언트 total/observerRole/serverComputed는 신뢰하지 않는다.
--   8) 제한적 오프라인 지원은 본인 draft RPC 재시도만 허용한다. 제출확정은 온라인 RPC만 수행한다.

-- ============================================================
-- 1. scores_group + server aggregate
-- ============================================================

create table public.scores_group (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  group_id uuid not null references public.deep_groups (id),
  observer_role text not null check (observer_role in ('primary', 'roving')),
  observation_confirmed boolean not null default false,
  observed_segment_ids uuid[] not null default '{}',
  items jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submission_state text not null default 'draft'
    check (submission_state in ('draft', 'submitted', 'reopened')),
  revision int not null default 1 check (revision >= 1),
  client_updated_at timestamptz not null,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_group_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  group_id uuid not null references public.deep_groups (id),
  complete boolean not null default false,
  score numeric,
  primary_required int not null,
  primary_submitted int not null,
  roving_included int not null,
  evaluator_count int not null,
  raw_average numeric,
  source_revision_summary jsonb not null default '[]'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_group is
  'M5b 모둠활동 본인 관찰채점. observer_role/server_computed는 RPC가 서버 판정하며 타 위원 직접 read를 허용하지 않는다.';
comment on table public.deep_group_aggregates is
  'M5b 서버 집계. 주관찰 필수 제출 미충족 시 score=null, complete=false. 유효 관찰위원 평균 × config scaleFactor.';

alter table public.scores_group enable row level security;
alter table public.deep_group_aggregates enable row level security;

-- 평가 독립성: evaluator는 자기 점수만 읽는다. 관리자도 개별 점수 테이블 직접 select 정책을 두지 않는다.
create policy scores_group_select_own
  on public.scores_group for select
  using (evaluator_uid = auth.uid());

create policy deep_group_aggregates_select_admin_viewer
  on public.deep_group_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. config / 권한 / 관찰관계 private helpers
--    M4의 STABLE snapshot 이슈를 반복하지 않도록 같은 DO/RPC에서 fixture 변경을
--    즉시 읽어야 하는 helper는 VOLATILE로 둔다.
-- ============================================================

create or replace function public._m5b_group_params(p_revision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_criteria jsonb;
begin
  select scoring_params #> '{deep,group}'
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.group 파라미터가 없습니다. M5b 배점 설정을 먼저 반영하세요.' using errcode = '55000';
  end if;

  v_criteria := v_params -> 'criteria';
  if jsonb_typeof(v_criteria) is distinct from 'array'
     or jsonb_array_length(v_criteria) = 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'criterionMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'scoreStep')::numeric, 0) <= 0
     or coalesce((v_params ->> 'scaleFactor')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredPrimaryObservers')::int, 0) <= 0
     or coalesce((v_params ->> 'max')::numeric, 0) <= 0 then
    raise exception 'deep.group 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  return v_params;
end;
$$;

create or replace function public._m5b_require_group_evaluator(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1
    from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'group' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '모둠활동 평가 권한이 없습니다 (evaluator + group 배정 및 scope 필요).' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.deep_group_plans p
    where p.year = p_year and p.round = p_round and p.status = 'finalized'
  ) then
    raise exception 'M5a 모둠편성 계획이 아직 최종확정되지 않았습니다.' using errcode = '55000';
  end if;

  return caller;
end;
$$;

create or replace function public._m5b_group_id(p_applicant_id uuid)
returns uuid
language sql
security definer
set search_path = public
volatile
as $$
  select gm.group_id
  from public.deep_group_members gm
  join public.deep_group_plans p on p.year = gm.year and p.round = gm.round
  where gm.applicant_id = p_applicant_id
    and p.status = 'finalized'
  limit 1;
$$;

create or replace function public._m5b_observer_role(
  p_applicant_id uuid,
  p_evaluator_uid uuid
)
returns text
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_group_id uuid;
begin
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    return null;
  end if;

  if exists (
    select 1 from public.deep_group_primary_observers po
    where po.group_id = v_group_id and po.evaluator_uid = p_evaluator_uid
  ) then
    return 'primary';
  end if;

  if exists (
    select 1
    from public.deep_group_rotation_assignments ra
    join public.deep_group_rotation_segments s on s.id = ra.segment_id
    join public.deep_groups g on g.id = v_group_id
    where ra.evaluator_uid = p_evaluator_uid
      and ra.target_group_id = v_group_id
      and s.year = g.year and s.round = g.round
  ) then
    return 'roving';
  end if;

  return null;
end;
$$;

create or replace function public._m5b_allowed_segments(
  p_applicant_id uuid,
  p_evaluator_uid uuid
)
returns uuid[]
language sql
security definer
set search_path = public
volatile
as $$
  select coalesce(array_agg(ra.segment_id order by s.sort_order, s.starts_at), '{}'::uuid[])
  from public.deep_group_members gm
  join public.deep_group_rotation_assignments ra on ra.target_group_id = gm.group_id
  join public.deep_group_rotation_segments s on s.id = ra.segment_id
  where gm.applicant_id = p_applicant_id
    and ra.evaluator_uid = p_evaluator_uid;
$$;

create or replace function public._m5b_validate_and_total(
  p_revision_id uuid,
  p_items jsonb,
  p_require_complete boolean
)
returns numeric
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb := public._m5b_group_params(p_revision_id);
  v_criteria text[];
  v_criterion_max numeric := (v_params ->> 'criterionMax')::numeric;
  v_step numeric := (v_params ->> 'scoreStep')::numeric;
  v_per_max numeric := (v_params ->> 'perEvaluatorMax')::numeric;
  k text;
  raw_value text;
  v numeric;
  total numeric := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'object' then
    raise exception 'items는 JSON object여야 합니다.' using errcode = '22023';
  end if;

  select array_agg(value order by ord)
    into v_criteria
  from jsonb_array_elements_text(v_params -> 'criteria') with ordinality as x(value, ord);

  if p_require_complete then
    foreach k in array v_criteria loop
      if not (p_items ? k) then
        raise exception '% 기준 점수가 없습니다. 모든 모둠활동 기준을 입력해야 제출할 수 있습니다.', k using errcode = '23514';
      end if;
    end loop;
    if (select count(*) from jsonb_object_keys(p_items)) <> array_length(v_criteria, 1) then
      raise exception '허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.' using errcode = '23514';
    end if;
  end if;

  for k, raw_value in select key, value from jsonb_each_text(p_items)
  loop
    if not (k = any(v_criteria)) then
      raise exception '알 수 없는 모둠활동 채점 기준: %', k using errcode = '23514';
    end if;
    begin
      v := raw_value::numeric;
    exception when others then
      raise exception '% 점수는 숫자여야 합니다.', k using errcode = '22023';
    end;
    if v < 0 or v > v_criterion_max or mod(v, v_step) <> 0 then
      raise exception '% 점수는 0~% 범위에서 %점 단위여야 합니다 (입력값: %).', k, v_criterion_max, v_step, v using errcode = '23514';
    end if;
    total := total + v;
  end loop;

  if total > v_per_max then
    raise exception '위원별 모둠활동 총점은 %점을 초과할 수 없습니다 (입력 합계: %).', v_per_max, total using errcode = '23514';
  end if;

  return total;
end;
$$;

revoke all on function public._m5b_group_params(uuid) from public, anon, authenticated;
revoke all on function public._m5b_require_group_evaluator(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5b_group_id(uuid) from public, anon, authenticated;
revoke all on function public._m5b_observer_role(uuid, uuid) from public, anon, authenticated;
revoke all on function public._m5b_allowed_segments(uuid, uuid) from public, anon, authenticated;
revoke all on function public._m5b_validate_and_total(uuid, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 3. M5a final 보강: 주관찰위원 각자 최소 1개 home segment 필요
-- ============================================================

create or replace function public._m5a_primary_home_segment_issues(
  p_year int,
  p_round admission_round
)
returns jsonb
language sql
security definer
set search_path = public
volatile
as $$
  select case
    when count(*) = 0 then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object(
        'code', 'PRIMARY_OBSERVER_HOME_SEGMENT_MISSING',
        'message', format('주관찰위원 %s명이 자기 모둠을 직접 관찰하는 segment가 1개도 없습니다. 주관찰 2인 모두 최소 1개 home segment가 필요합니다.', count(*)),
        'items', coalesce(jsonb_agg(jsonb_build_object(
          'groupId', x.group_id,
          'groupCode', x.group_code,
          'evaluatorUid', x.evaluator_uid
        ) order by x.group_code, x.evaluator_uid), '[]'::jsonb)
      )
    )
  end
  from (
    select po.group_id, g.group_code, po.evaluator_uid
    from public.deep_group_primary_observers po
    join public.deep_groups g on g.id = po.group_id
    where po.year = p_year and po.round = p_round
      and not exists (
        select 1
        from public.deep_group_rotation_assignments ra
        join public.deep_group_rotation_segments s on s.id = ra.segment_id
        where ra.evaluator_uid = po.evaluator_uid
          and ra.target_group_id = po.group_id
          and s.year = p_year and s.round = p_round
      )
  ) x;
$$;

revoke all on function public._m5a_primary_home_segment_issues(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5a_group_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_extra jsonb;
  v_issues jsonb;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  v_base := public._m5a_validate_plan(p_year, p_round);
  v_extra := public._m5a_primary_home_segment_issues(p_year, p_round);
  v_issues := coalesce(v_base -> 'blockingIssues', '[]'::jsonb) || coalesce(v_extra, '[]'::jsonb);

  return jsonb_set(
    jsonb_set(v_base, '{blockingIssues}', v_issues, true),
    '{complete}',
    to_jsonb(jsonb_array_length(v_issues) = 0),
    true
  );
end;
$$;

revoke all on function public.validate_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5a_group_plan(int, admission_round) to authenticated;

create or replace function public.finalize_m5a_group_plan(
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
  v_plan record;
  v_validation jsonb;
  v_primary_home_issues jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5a:%s:%s', p_year, p_round::text), 0));

  select * into v_plan
  from public.deep_group_plans
  where year = p_year and round = p_round
  for update;

  if v_plan is null then
    raise exception '최종확정할 모둠편성 draft가 없습니다.';
  end if;
  if v_plan.status = 'finalized' then
    raise exception '이미 최종확정된 모둠편성 계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5a_validate_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '모둠편성 계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  v_primary_home_issues := public._m5a_primary_home_segment_issues(p_year, p_round);
  if jsonb_array_length(v_primary_home_issues) > 0 then
    raise exception '모둠편성 계획에 주관찰 직접관찰 문제가 있어 확정할 수 없습니다: %', v_primary_home_issues using errcode = '23514';
  end if;

  update public.evaluation_roster er
  set group_id = gm.group_id,
      roster_revision = er.roster_revision + 1,
      updated_at = now()
  from public.deep_group_members gm
  where gm.year = p_year and gm.round = p_round
    and gm.applicant_id = er.applicant_id;

  update public.deep_group_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'deep_group_plan.finalized', 'deep_group_plans',
     p_year::text || '_' || p_round::text,
     jsonb_build_object(
       'documentSourceRunId', v_plan.document_source_run_id,
       'candidateCount', v_validation -> 'candidateCount',
       'groupCount', v_validation -> 'groupCount',
       'segmentCount', v_validation -> 'segmentCount',
       'primaryHomeSegmentRule', true
     ));

  return public.validate_m5a_group_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5a_group_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5a_group_plan(int, admission_round) to authenticated;

-- ============================================================
-- 4. evaluator 모바일 workspace
-- ============================================================

create or replace function public.get_m5b_observation_workspace(
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
  v_round record;
  v_plan record;
  v_params jsonb;
  v_segments jsonb;
  v_groups jsonb;
begin
  caller := public._m5b_require_group_evaluator(p_year, p_round);

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
      'segmentId', s.id,
      'segmentCode', s.segment_code,
      'startsAt', s.starts_at,
      'endsAt', s.ends_at,
      'targetGroupId', ra.target_group_id
    ) order by s.sort_order, s.starts_at), '[]'::jsonb)
    into v_segments
  from public.deep_group_rotation_segments s
  join public.deep_group_rotation_assignments ra
    on ra.segment_id = s.id and ra.evaluator_uid = caller
  where s.year = p_year and s.round = p_round;

  select coalesce(jsonb_agg(jsonb_build_object(
      'groupId', g.id,
      'groupCode', g.group_code,
      'observerRole', case when exists (
        select 1 from public.deep_group_primary_observers po
        where po.group_id = g.id and po.evaluator_uid = caller
      ) then 'primary' else 'roving' end,
      'allowedSegmentIds', coalesce((
        select jsonb_agg(ra.segment_id order by s.sort_order, s.starts_at)
        from public.deep_group_rotation_assignments ra
        join public.deep_group_rotation_segments s on s.id = ra.segment_id
        where ra.evaluator_uid = caller and ra.target_group_id = g.id
      ), '[]'::jsonb),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'applicantId', er.applicant_id,
          'examNo', er.exam_no,
          'displayName', er.display_name,
          'myScore', case when sg.id is null then null else jsonb_build_object(
            'scoreId', sg.id,
            'observationConfirmed', sg.observation_confirmed,
            'observedSegmentIds', to_jsonb(sg.observed_segment_ids),
            'items', sg.items,
            'observerRole', sg.observer_role,
            'submissionState', sg.submission_state,
            'revision', sg.revision,
            'serverComputed', sg.server_computed,
            'clientUpdatedAt', sg.client_updated_at,
            'submittedAt', sg.submitted_at
          ) end
        ) order by gm.sort_order, er.exam_no, er.display_name)
        from public.deep_group_members gm
        join public.evaluation_roster er on er.applicant_id = gm.applicant_id
        left join public.scores_group sg
          on sg.applicant_id = gm.applicant_id and sg.evaluator_uid = caller
        where gm.group_id = g.id
      ), '[]'::jsonb)
    ) order by g.sort_order, g.group_code), '[]'::jsonb)
    into v_groups
  from public.deep_groups g
  where g.year = p_year and g.round = p_round and g.active = true
    and (
      exists (
        select 1 from public.deep_group_primary_observers po
        where po.group_id = g.id and po.evaluator_uid = caller
      )
      or exists (
        select 1 from public.deep_group_rotation_assignments ra
        where ra.evaluator_uid = caller and ra.target_group_id = g.id
      )
    );

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'planRevision', v_plan.revision,
    'areaOpen', v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas),
    'criteria', v_params -> 'criteria',
    'criterionMax', (v_params ->> 'criterionMax')::numeric,
    'scoreStep', (v_params ->> 'scoreStep')::numeric,
    'perEvaluatorMax', (v_params ->> 'perEvaluatorMax')::numeric,
    'segments', v_segments,
    'groups', v_groups,
    'offlinePolicy', 'MINIMAL_ROSTER_SELF_DRAFT_24H'
  );
end;
$$;

revoke all on function public.get_m5b_observation_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5b_observation_workspace(int, admission_round) to authenticated;

-- ============================================================
-- 5. draft 저장 — 부분점수 허용 + client_updated_at으로 오래된 offline replay 차단
-- ============================================================

create or replace function public.save_group_score_draft(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb,
  p_client_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_round record;
  v_plan record;
  v_group_id uuid;
  v_role text;
  v_allowed uuid[];
  v_total numeric;
  v_existing record;
  v_accepted boolean := true;
  v_observed uuid[] := coalesce(p_observed_segment_ids, '{}'::uuid[]);
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);
  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  select * into v_plan from public.deep_group_plans where year = v_app.year and round = v_app.round and status = 'finalized';
  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;

  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 observed_segment_ids에 포함할 수 없습니다.' using errcode = '42501';
  end if;
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;

  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, false);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing is not null and v_existing.client_updated_at > p_client_updated_at then
    v_accepted := false;
  else
    insert into public.scores_group
      (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
       observer_role, observation_confirmed, observed_segment_ids, items,
       server_computed, submission_state, revision, client_updated_at)
    values
      (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
       v_role, coalesce(p_observation_confirmed, false), v_observed, p_items,
       jsonb_build_object('draftTotal', v_total, 'validForAggregate', false), 'draft', 1, p_client_updated_at)
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      group_id = excluded.group_id,
      observer_role = excluded.observer_role,
      observation_confirmed = excluded.observation_confirmed,
      observed_segment_ids = excluded.observed_segment_ids,
      items = excluded.items,
      server_computed = excluded.server_computed,
      submission_state = 'draft',
      revision = public.scores_group.revision + 1,
      client_updated_at = excluded.client_updated_at,
      submitted_at = null,
      updated_at = now();
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'observerRole', v_role,
    'draftTotal', v_total,
    'submissionState', coalesce((select submission_state from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
  );
end;
$$;

revoke all on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) from public, anon;
grant execute on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) to authenticated;

-- ============================================================
-- 6. 제출확정 — role/segments/total 서버 재판정
-- ============================================================

create or replace function public.submit_group_score(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
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
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);
  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;
  if cardinality(v_observed) = 0 then
    raise exception '최소 1개 이상의 실제 관찰 segment를 선택해야 제출할 수 있습니다.' using errcode = '23514';
  end if;
  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 제출 근거로 사용할 수 없습니다.' using errcode = '42501';
  end if;

  if v_role = 'roving' and coalesce(p_observation_confirmed, false) = false then
    raise exception '순환관찰위원은 충분한 관찰이 이루어졌음을 확인한 경우에만 제출할 수 있습니다.' using errcode = '23514';
  end if;

  v_effective_confirmed := case when v_role = 'primary' then true else coalesce(p_observation_confirmed, false) end;
  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, true);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;
  if v_existing is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  insert into public.scores_group
    (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
     observer_role, observation_confirmed, observed_segment_ids, items,
     server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     v_role, v_effective_confirmed, v_observed, p_items,
     jsonb_build_object(
       'total', v_total,
       'validForAggregate', true,
       'observerRoleServerDetermined', v_role,
       'configRevisionId', v_round.config_revision_id
     ),
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
    'scoreId', id,
    'total', (server_computed ->> 'total')::numeric,
    'observerRole', observer_role,
    'submissionState', submission_state,
    'revision', revision
  ) into v_result;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'score.group.submitted', 'scores_group',
     v_result ->> 'scoreId', p_applicant_id::text, 'group',
     jsonb_build_object(
       'observerRole', v_role,
       'observedSegmentCount', cardinality(v_observed),
       'revision', v_result -> 'revision'
     ));

  return v_result;
end;
$$;

revoke all on function public.submit_group_score(uuid, boolean, uuid[], jsonb) from public, anon;
grant execute on function public.submit_group_score(uuid, boolean, uuid[], jsonb) to authenticated;

-- ============================================================
-- 7. group aggregate — 필수 primary 2인 미충족 시 null
-- ============================================================

create or replace function public._compute_group_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_group_id uuid;
  v_params jsonb;
  v_required_primary int;
  v_scale numeric;
  v_max numeric;
  v_primary_submitted int;
  v_roving_included int;
  v_evaluator_count int;
  v_raw_average numeric;
  v_score numeric;
  v_summary jsonb;
begin
  select er.year, er.round into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    return jsonb_build_object(
      'complete', false, 'score', null, 'primaryRequired', null,
      'primarySubmitted', 0, 'rovingIncluded', 0, 'evaluatorCount', 0,
      'rawAverage', null, 'sourceRevisionSummary', '[]'::jsonb,
      'functionVersion', 'm5b-group-aggregate-v1'
    );
  end if;

  v_params := public._m5b_group_params(v_round.config_revision_id);
  v_required_primary := (v_params ->> 'requiredPrimaryObservers')::int;
  v_scale := (v_params ->> 'scaleFactor')::numeric;
  v_max := (v_params ->> 'max')::numeric;

  with valid_scores as (
    select sg.*,
           case when exists (
             select 1 from public.deep_group_primary_observers po
             where po.group_id = v_group_id and po.evaluator_uid = sg.evaluator_uid
           ) then 'primary' else 'roving' end as actual_role
    from public.scores_group sg
    where sg.applicant_id = p_applicant_id
      and sg.submission_state = 'submitted'
      and sg.group_id = v_group_id
      and (
        exists (
          select 1 from public.deep_group_primary_observers po
          where po.group_id = v_group_id and po.evaluator_uid = sg.evaluator_uid
        )
        or (
          sg.observation_confirmed = true
          and cardinality(sg.observed_segment_ids) > 0
          and not exists (
            select 1
            from unnest(sg.observed_segment_ids) seg_id
            where not exists (
              select 1 from public.deep_group_rotation_assignments ra
              where ra.segment_id = seg_id
                and ra.evaluator_uid = sg.evaluator_uid
                and ra.target_group_id = v_group_id
            )
          )
        )
      )
  )
  select
    count(*) filter (where actual_role = 'primary')::int,
    count(*) filter (where actual_role = 'roving')::int,
    count(*)::int,
    avg((server_computed ->> 'total')::numeric),
    coalesce(jsonb_agg(jsonb_build_object(
      'scoreId', id,
      'evaluatorUid', evaluator_uid,
      'revision', revision,
      'observerRole', actual_role
    ) order by evaluator_uid), '[]'::jsonb)
  into v_primary_submitted, v_roving_included, v_evaluator_count, v_raw_average, v_summary
  from valid_scores;

  if v_primary_submitted < v_required_primary then
    v_score := null;
  else
    v_score := least(v_max, v_raw_average * v_scale);
  end if;

  return jsonb_build_object(
    'complete', v_primary_submitted >= v_required_primary,
    'score', v_score,
    'primaryRequired', v_required_primary,
    'primarySubmitted', v_primary_submitted,
    'rovingIncluded', v_roving_included,
    'evaluatorCount', v_evaluator_count,
    'rawAverage', case when v_primary_submitted >= v_required_primary then v_raw_average else null end,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm5b-group-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_group_aggregate(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_group_id uuid;
  v_agg jsonb;
begin
  select er.year, er.round into v_app
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;
  if v_app is null then
    delete from public.deep_group_aggregates where applicant_id = p_applicant_id;
    return;
  end if;
  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  v_group_id := public._m5b_group_id(p_applicant_id);
  if v_group_id is null then
    delete from public.deep_group_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  v_agg := public._compute_group_aggregate(p_applicant_id);

  insert into public.deep_group_aggregates
    (applicant_id, year, round, config_revision_id, group_id, complete, score,
     primary_required, primary_submitted, roving_included, evaluator_count,
     raw_average, source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     (v_agg ->> 'complete')::boolean,
     (v_agg ->> 'score')::numeric,
     (v_agg ->> 'primaryRequired')::int,
     (v_agg ->> 'primarySubmitted')::int,
     (v_agg ->> 'rovingIncluded')::int,
     (v_agg ->> 'evaluatorCount')::int,
     (v_agg ->> 'rawAverage')::numeric,
     v_agg -> 'sourceRevisionSummary',
     v_agg ->> 'functionVersion',
     now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    group_id = excluded.group_id,
    complete = excluded.complete,
    score = excluded.score,
    primary_required = excluded.primary_required,
    primary_submitted = excluded.primary_submitted,
    roving_included = excluded.roving_included,
    evaluator_count = excluded.evaluator_count,
    raw_average = excluded.raw_average,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = now();
end;
$$;

create or replace function public._trg_refresh_group_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    if new.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(new.applicant_id);
    end if;
    return new;
  elsif TG_OP = 'UPDATE' then
    if old.submission_state = 'submitted' or new.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(new.applicant_id);
    end if;
    return new;
  else
    if old.submission_state = 'submitted' then
      perform public._refresh_group_aggregate(old.applicant_id);
    end if;
    return old;
  end if;
end;
$$;

revoke all on function public._compute_group_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_group_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_group_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_group_aggregate on public.scores_group;
create trigger trg_refresh_group_aggregate
  after insert or update or delete on public.scores_group
  for each row execute function public._trg_refresh_group_aggregate();

-- ============================================================
-- 8. 관리자 집계 조회 — 개별 위원 점수는 반환하지 않는다.
-- ============================================================

create or replace function public.get_m5b_group_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'groupCode', g.group_code,
        'complete', coalesce(a.complete, false),
        'score', a.score,
        'primaryRequired', a.primary_required,
        'primarySubmitted', coalesce(a.primary_submitted, 0),
        'rovingIncluded', coalesce(a.roving_included, 0),
        'evaluatorCount', coalesce(a.evaluator_count, 0),
        'computedAt', a.computed_at
      ) order by g.sort_order, gm.sort_order, er.exam_no, er.display_name)
      from public.deep_group_members gm
      join public.deep_groups g on g.id = gm.group_id
      join public.evaluation_roster er on er.applicant_id = gm.applicant_id
      left join public.deep_group_aggregates a on a.applicant_id = gm.applicant_id
      where gm.year = p_year and gm.round = p_round
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5b_group_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5b_group_progress(int, admission_round) to authenticated;

-- ============================================================
-- 9. reopen_score에 scores_group 확장
-- ============================================================

create or replace function public.reopen_score(
  p_score_table text,
  p_score_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_score_table not in
     ('scores_attendance', 'scores_academic', 'scores_community', 'scores_essay', 'scores_opinion', 'scores_group') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_community' then
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_essay' then
    update public.scores_essay set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_opinion' then
    update public.scores_opinion set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_group set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke all on function public.reopen_score(text, uuid) from public, anon;
grant execute on function public.reopen_score(text, uuid) to authenticated;

-- ======================================================================
-- 00011_hotfix_m5b_stale_draft_guard.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M5b stale draft / 동시 저장 hotfix
--
-- 원인
--   SELECT ... INTO record 후 `record IS NOT NULL`로 행 존재 여부를 판정했다.
--   scores_group draft는 submitted_at=NULL이므로 composite IS NOT NULL 판정이
--   기대와 달라 stale client_updated_at 비교가 건너뛰어질 수 있었다.
--
-- 수정
--   1) NOT NULL PK인 v_existing.id로 행 존재 여부를 판정한다.
--   2) 동일 timestamp도 replay로 보아 >= 조건으로 거부한다.
--   3) applicant+evaluator advisory xact lock으로 최초 INSERT 경쟁까지 직렬화한다.
--   4) stale 거부 응답의 draftTotal은 현재 서버 draft 값을 돌려준다.

create or replace function public.save_group_score_draft(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb,
  p_client_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_round record;
  v_plan record;
  v_group_id uuid;
  v_role text;
  v_allowed uuid[];
  v_total numeric;
  v_existing record;
  v_accepted boolean := true;
  v_observed uuid[] := coalesce(p_observed_segment_ids, '{}'::uuid[]);
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);

  -- 같은 평가자/지원자의 draft·submit 경쟁을 직렬화한다.
  -- 행이 아직 없는 최초 저장 경쟁에서도 오래된 replay가 나중에 덮어쓰지 못하게 한다.
  perform pg_advisory_xact_lock(
    hashtextextended(format('m5b-score:%s:%s', p_applicant_id, caller), 0)
  );

  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  select * into v_plan from public.deep_group_plans where year = v_app.year and round = v_app.round and status = 'finalized';
  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;

  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 observed_segment_ids에 포함할 수 없습니다.' using errcode = '42501';
  end if;
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;

  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, false);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing.id is not null and v_existing.client_updated_at >= p_client_updated_at then
    v_accepted := false;
  else
    insert into public.scores_group
      (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
       observer_role, observation_confirmed, observed_segment_ids, items,
       server_computed, submission_state, revision, client_updated_at)
    values
      (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
       v_role, coalesce(p_observation_confirmed, false), v_observed, p_items,
       jsonb_build_object('draftTotal', v_total, 'validForAggregate', false), 'draft', 1, p_client_updated_at)
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      group_id = excluded.group_id,
      observer_role = excluded.observer_role,
      observation_confirmed = excluded.observation_confirmed,
      observed_segment_ids = excluded.observed_segment_ids,
      items = excluded.items,
      server_computed = excluded.server_computed,
      submission_state = 'draft',
      revision = public.scores_group.revision + 1,
      client_updated_at = excluded.client_updated_at,
      submitted_at = null,
      updated_at = now();
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'observerRole', v_role,
    'draftTotal', case
      when v_accepted then v_total
      else coalesce(
        (select (server_computed ->> 'draftTotal')::numeric
         from public.scores_group
         where applicant_id = p_applicant_id and evaluator_uid = caller),
        v_total
      )
    end,
    'submissionState', coalesce((select submission_state from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft'),
    'serverClientUpdatedAt', (select client_updated_at from public.scores_group where applicant_id = p_applicant_id and evaluator_uid = caller)
  );
end;
$$;

revoke all on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) from public, anon;
grant execute on function public.save_group_score_draft(uuid, boolean, uuid[], jsonb, timestamptz) to authenticated;

create or replace function public.submit_group_score(
  p_applicant_id uuid,
  p_observation_confirmed boolean,
  p_observed_segment_ids uuid[],
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
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
begin
  select er.applicant_id, er.year, er.round, er.evaluation_active
    into v_app
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5b_require_group_evaluator(v_app.year, v_app.round);

  -- draft 저장과 제출확정이 동시에 들어와도 같은 지원자/평가자 단위로 직렬화한다.
  perform pg_advisory_xact_lock(
    hashtextextended(format('m5b-score:%s:%s', p_applicant_id, caller), 0)
  );

  if not v_app.evaluation_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  select * into v_round from public.admission_rounds where year = v_app.year and round = v_app.round;
  if not (v_round.stage_status = 'open' and 'group'::evaluation_area = any(v_round.open_evaluation_areas)) then
    raise exception '모둠활동 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  v_group_id := public._m5b_group_id(p_applicant_id);
  v_role := public._m5b_observer_role(p_applicant_id, caller);
  v_allowed := public._m5b_allowed_segments(p_applicant_id, caller);

  if v_group_id is null or v_role is null then
    raise exception '이 지원자는 현재 평가자에게 관찰 배정되지 않았습니다.' using errcode = '42501';
  end if;
  if cardinality(v_observed) = 0 then
    raise exception '최소 1개 이상의 실제 관찰 segment를 선택해야 제출할 수 있습니다.' using errcode = '23514';
  end if;
  if cardinality(v_observed) <> (select count(distinct x) from unnest(v_observed) x) then
    raise exception 'observed_segment_ids에 중복 segment가 있습니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_observed) x where not (x = any(v_allowed))) then
    raise exception '실제 관찰 배정되지 않은 segment를 제출 근거로 사용할 수 없습니다.' using errcode = '42501';
  end if;

  if v_role = 'roving' and coalesce(p_observation_confirmed, false) = false then
    raise exception '순환관찰위원은 충분한 관찰이 이루어졌음을 확인한 경우에만 제출할 수 있습니다.' using errcode = '23514';
  end if;

  v_effective_confirmed := case when v_role = 'primary' then true else coalesce(p_observation_confirmed, false) end;
  v_total := public._m5b_validate_and_total(v_round.config_revision_id, p_items, true);

  select * into v_existing
  from public.scores_group
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;
  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 모둠활동 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  insert into public.scores_group
    (applicant_id, evaluator_uid, year, round, config_revision_id, group_id,
     observer_role, observation_confirmed, observed_segment_ids, items,
     server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, caller, v_app.year, v_app.round, v_round.config_revision_id, v_group_id,
     v_role, v_effective_confirmed, v_observed, p_items,
     jsonb_build_object(
       'total', v_total,
       'validForAggregate', true,
       'observerRoleServerDetermined', v_role,
       'configRevisionId', v_round.config_revision_id
     ),
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
    'scoreId', id,
    'total', (server_computed ->> 'total')::numeric,
    'observerRole', observer_role,
    'submissionState', submission_state,
    'revision', revision
  ) into v_result;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'score.group.submitted', 'scores_group',
     v_result ->> 'scoreId', p_applicant_id::text, 'group',
     jsonb_build_object(
       'observerRole', v_role,
       'observedSegmentCount', cardinality(v_observed),
       'revision', v_result -> 'revision'
     ));

  return v_result;
end;
$$;

revoke all on function public.submit_group_score(uuid, boolean, uuid[], jsonb) from public, anon;
grant execute on function public.submit_group_score(uuid, boolean, uuid[], jsonb) to authenticated;

-- ======================================================================
-- 00012_m5c_interview.sql
-- ======================================================================

begin;

-- 새봄고 입학전형 시스템 — M5c 학생·학부모면접 독립 채점
-- 마스터 스펙 v1.2 섹션 2.8, 3.15, 5.4.3~5.4.4, M5c 대응.
--
-- 핵심 불변조건
--   1) evaluator + interview 영역 + scope + finalized interview team membership + 지원자 team 배정이 모두 필요하다.
--   2) 같은 조 2인은 독립 채점하며 evaluator는 자기 점수만 읽는다.
--   3) 학생면접과 학부모면접은 별도 draft/submitted/reopened/revision/lock 상태를 갖는다.
--   4) 2인 모두 제출 전 해당 면접 aggregate는 score=null, complete=false다.
--   5) 점수 기준·허용 단계값·만점·편차경보·소요시간은 immutable config revision에서 읽는다.
--   6) draft stale replay와 동시 저장/제출은 applicant+evaluator 단위 advisory lock으로 직렬화한다.
--   7) 대체 평가위원 지정은 superadmin 전용 RPC + 사유·감사로그로만 수행한다.

-- ============================================================
-- 1. 면접조 계획 / 조 / 조원 / 시간표
-- ============================================================

create table public.interview_team_plans (
  year int not null,
  round admission_round not null,
  status text not null default 'draft' check (status in ('draft', 'finalized')),
  document_source_run_id uuid not null references public.decision_runs (id),
  config_revision_id uuid not null references public.config_revisions (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.interview_teams (
  id uuid primary key,
  year int not null,
  round admission_round not null,
  team_code text not null check (length(trim(team_code)) between 1 and 20),
  location text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (year, round, team_code),
  unique (id, year, round),
  foreign key (year, round)
    references public.interview_team_plans (year, round) on delete cascade
);

create table public.interview_team_members (
  team_id uuid not null,
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  member_slot smallint not null check (member_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (team_id, member_slot),
  unique (team_id, evaluator_uid),
  unique (year, round, evaluator_uid),
  foreign key (team_id, year, round)
    references public.interview_teams (id, year, round) on delete cascade
);

create table public.interview_schedules (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null,
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.evaluation_roster (applicant_id) on delete cascade,
  student_starts_at timestamptz not null,
  student_ends_at timestamptz not null,
  parent_starts_at timestamptz not null,
  parent_ends_at timestamptz not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check (student_ends_at > student_starts_at),
  check (parent_ends_at > parent_starts_at),
  unique (year, round, applicant_id),
  foreign key (team_id, year, round)
    references public.interview_teams (id, year, round) on delete cascade
);

comment on table public.interview_team_plans is
  'M5c 면접조 편성 계획. document_source_run_id는 M4 final 합격자 스냅샷, config_revision_id는 면접 배점 스냅샷 기준이며 final 이후 일반 수정 금지.';
comment on table public.interview_team_members is
  '면접조 위원 2인. 동일 evaluator는 같은 연도/차수에서 하나의 면접조에만 소속된다.';
comment on table public.interview_schedules is
  '학생 25분·학부모 20분 등 실제 시간표. duration은 해당 config revision의 deep.interview* 파라미터로 검증한다.';

alter table public.interview_team_plans enable row level security;
alter table public.interview_teams enable row level security;
alter table public.interview_team_members enable row level security;
alter table public.interview_schedules enable row level security;

create policy interview_team_plans_select_staff
  on public.interview_team_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('interview')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or interview_team_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or interview_team_plans.round = any(u.round_scopes))
      )
    )
  );

create policy interview_teams_select_member_or_admin
  on public.interview_teams for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or exists (
      select 1 from public.interview_team_members m
      where m.team_id = interview_teams.id
        and m.evaluator_uid = auth.uid()
        and public.has_role('evaluator')
        and public.has_area('interview')
    )
  );

create policy interview_team_members_select_member_or_admin
  on public.interview_team_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      evaluator_uid = auth.uid()
      and public.has_role('evaluator')
      and public.has_area('interview')
    )
  );

create policy interview_schedules_select_member_or_admin
  on public.interview_schedules for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or exists (
      select 1 from public.interview_team_members m
      where m.team_id = interview_schedules.team_id
        and m.evaluator_uid = auth.uid()
        and public.has_role('evaluator')
        and public.has_area('interview')
    )
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. 개별 점수 / 서버 집계
-- ============================================================

create table public.scores_interview (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  team_id uuid not null references public.interview_teams (id),

  student_items jsonb not null default '{}'::jsonb,
  student_memo text,
  student_server_computed jsonb,
  student_submission_state text not null default 'draft'
    check (student_submission_state in ('draft', 'submitted', 'reopened')),
  student_revision int not null default 0 check (student_revision >= 0),
  student_client_updated_at timestamptz,
  student_submitted_at timestamptz,

  parent_items jsonb not null default '{}'::jsonb,
  parent_memo text,
  parent_server_computed jsonb,
  parent_submission_state text not null default 'draft'
    check (parent_submission_state in ('draft', 'submitted', 'reopened')),
  parent_revision int not null default 0 check (parent_revision >= 0),
  parent_client_updated_at timestamptz,
  parent_submitted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_interview_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  team_id uuid not null references public.interview_teams (id),

  student_complete boolean not null default false,
  student_score numeric,
  student_required int not null,
  student_submitted int not null,
  student_gap numeric,

  parent_complete boolean not null default false,
  parent_score numeric,
  parent_required int not null,
  parent_submitted int not null,
  parent_gap numeric,

  source_revision_summary jsonb not null default '{}'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_interview is
  'M5c 면접위원 본인 채점. 학생/학부모 section별 draft·submitted·reopened·revision·잠금을 완전히 분리한다.';
comment on table public.deep_interview_aggregates is
  'M5c 서버 집계. 학생/학부모 각각 requiredSubmissions 충족 전 score=null/complete=false, 충족 후 2인 평균.';

alter table public.scores_interview enable row level security;
alter table public.deep_interview_aggregates enable row level security;

create policy scores_interview_select_own
  on public.scores_interview for select
  using (evaluator_uid = auth.uid());

create policy deep_interview_aggregates_select_admin_viewer
  on public.deep_interview_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- ============================================================
-- 3. private config / 권한 / 점수 검증 helpers
-- ============================================================

create or replace function public._m5c_interview_params(
  p_revision_id uuid,
  p_section text
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_criteria jsonb;
  v_sum_max numeric;
  c jsonb;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다: %', p_section using errcode = '22023';
  end if;

  select case
           when p_section = 'student' then scoring_params #> '{deep,interviewStudent}'
           else scoring_params #> '{deep,interviewParent}'
         end
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.interview%s 파라미터가 없습니다. M5c 배점 설정을 먼저 반영하세요.',
      case when p_section = 'student' then 'Student' else 'Parent' end
      using errcode = '55000';
  end if;

  v_criteria := v_params -> 'criteria';
  if jsonb_typeof(v_criteria) is distinct from 'array'
     or jsonb_array_length(v_criteria) = 0
     or coalesce((v_params ->> 'max')::numeric, 0) <= 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredSubmissions')::int, 0) <= 0
     or v_params ->> 'combine' <> 'avg'
     or coalesce((v_params ->> 'durationMinutes')::int, 0) <= 0
     or coalesce((v_params ->> 'alertGap')::numeric, -1) < 0 then
    raise exception 'deep interview 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  v_sum_max := 0;
  for c in select value from jsonb_array_elements(v_criteria)
  loop
    if jsonb_typeof(c) is distinct from 'object'
       or coalesce(length(trim(c ->> 'key')), 0) = 0
       or coalesce(length(trim(c ->> 'label')), 0) = 0
       or coalesce((c ->> 'max')::numeric, 0) <= 0
       or jsonb_typeof(c -> 'scoreValues') is distinct from 'array'
       or jsonb_array_length(c -> 'scoreValues') = 0 then
      raise exception '면접 criterion 구조가 올바르지 않습니다: %', c using errcode = '23514';
    end if;
    if exists (
      select 1
      from jsonb_array_elements_text(c -> 'scoreValues') sv
      where sv::numeric < 0 or sv::numeric > (c ->> 'max')::numeric
    ) then
      raise exception '면접 criterion scoreValues가 max 범위를 벗어납니다: %', c using errcode = '23514';
    end if;
    v_sum_max := v_sum_max + (c ->> 'max')::numeric;
  end loop;

  if v_sum_max <> (v_params ->> 'perEvaluatorMax')::numeric
     or (v_params ->> 'max')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '면접 criteria max 합계 / perEvaluatorMax / max가 일치해야 합니다: %', v_params using errcode = '23514';
  end if;

  if (select count(*) from jsonb_array_elements(v_criteria)) <>
     (select count(distinct x.value ->> 'key') from jsonb_array_elements(v_criteria) x) then
    raise exception '면접 criteria key가 중복되었습니다.' using errcode = '23514';
  end if;

  return v_params;
end;
$$;

create or replace function public._m5c_require_interview_user(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'interview' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '면접 평가 권한이 없습니다 (evaluator + interview 배정 및 scope 필요).' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5c_require_interviewer(
  p_applicant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_active boolean;
  v_team_id uuid;
begin
  select er.year, er.round, er.evaluation_active, er.interview_team_id
    into v_year, v_round, v_active, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5c_require_interview_user(v_year, v_round);

  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;
  if v_team_id is null then
    raise exception '지원자에게 면접조가 배정되지 않았습니다.' using errcode = '55000';
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
      and m.evaluator_uid = caller
  ) then
    raise exception '이 지원자는 현재 평가자의 면접조에 배정되지 않았습니다.' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5c_validate_and_total(
  p_revision_id uuid,
  p_section text,
  p_items jsonb,
  p_require_complete boolean
)
returns numeric
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb := public._m5c_interview_params(p_revision_id, p_section);
  v_criteria jsonb := v_params -> 'criteria';
  c jsonb;
  k text;
  raw_value text;
  v numeric;
  total numeric := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'object' then
    raise exception 'items는 JSON object여야 합니다.' using errcode = '22023';
  end if;

  if p_require_complete then
    for c in select value from jsonb_array_elements(v_criteria)
    loop
      if not (p_items ? (c ->> 'key')) then
        raise exception '% 기준 점수가 없습니다. 모든 면접 기준을 입력해야 제출할 수 있습니다.', c ->> 'label' using errcode = '23514';
      end if;
    end loop;
    if (select count(*) from jsonb_object_keys(p_items)) <> jsonb_array_length(v_criteria) then
      raise exception '허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.' using errcode = '23514';
    end if;
  end if;

  for k, raw_value in select key, value from jsonb_each_text(p_items)
  loop
    select value into c
    from jsonb_array_elements(v_criteria)
    where value ->> 'key' = k
    limit 1;

    if not found then
      raise exception '알 수 없는 면접 채점 기준: %', k using errcode = '23514';
    end if;

    begin
      v := raw_value::numeric;
    exception when others then
      raise exception '% 점수는 숫자여야 합니다.', c ->> 'label' using errcode = '22023';
    end;

    if not exists (
      select 1 from jsonb_array_elements_text(c -> 'scoreValues') sv
      where sv::numeric = v
    ) then
      raise exception '% 점수는 허용 단계 % 중 하나여야 합니다 (입력값: %).',
        c ->> 'label', c -> 'scoreValues', v using errcode = '23514';
    end if;
    total := total + v;
  end loop;

  if total > (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '위원별 % 면접 총점은 %점을 초과할 수 없습니다 (입력 합계: %).',
      case when p_section = 'student' then '학생' else '학부모' end,
      v_params ->> 'perEvaluatorMax', total using errcode = '23514';
  end if;

  return total;
end;
$$;

revoke all on function public._m5c_interview_params(uuid, text) from public, anon, authenticated;
revoke all on function public._m5c_require_interview_user(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5c_require_interviewer(uuid) from public, anon, authenticated;
revoke all on function public._m5c_validate_and_total(uuid, text, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 4. 면접조 계획 validator / admin workspace / save / finalize
-- ============================================================

create or replace function public._m5c_validate_interview_plan(
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
  v_round record;
  v_plan record;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_candidate_count int := 0;
  v_team_count int := 0;
  v_schedule_count int := 0;
  v_bad_count int;
  v_issues jsonb := '[]'::jsonb;
begin
  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.interview_team_plans
  where year = p_year and round = p_round;

  if not found then
    return jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object(
        'code', 'PLAN_MISSING', 'message', '면접조 계획 draft가 없습니다.'
      )),
      'candidateCount', 0, 'teamCount', 0, 'scheduleCount', 0
    );
  end if;

  if v_round.document_decision_run_id is null then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_FINAL_MISSING', 'message', '확정된 M4 1차 사정 run이 없습니다.'
    ));
  elsif v_plan.document_source_run_id <> v_round.document_decision_run_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_SOURCE_STALE', 'message', '면접조 계획의 1차 합격자 기준 run이 현재 확정 run과 다릅니다. 계획을 다시 저장하세요.'
    ));
  end if;

  if v_plan.config_revision_id <> v_round.config_revision_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CONFIG_SOURCE_STALE', 'message', '면접조 계획의 배점 config revision이 현재 전형 config와 다릅니다. 최종확정 전 계획을 다시 저장하세요.'
    ));
  end if;

  select count(*)::int into v_candidate_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  select count(*)::int into v_team_count
  from public.interview_teams t
  where t.year = p_year and t.round = p_round and t.active = true;

  select count(*)::int into v_schedule_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round;

  if v_team_count = 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'TEAM_MISSING', 'message', '면접조가 1개 이상 필요합니다.'
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_teams t
  left join lateral (
    select count(*)::int as member_count
    from public.interview_team_members m where m.team_id = t.id
  ) mc on true
  where t.year = p_year and t.round = p_round and t.active = true
    and mc.member_count <> 2;
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'TEAM_MEMBER_COUNT', 'message', format('위원이 정확히 2명이 아닌 면접조가 %s개 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_team_members m
  join public.interview_teams t on t.id = m.team_id
  left join public.users u on u.id = m.evaluator_uid
  where t.year = p_year and t.round = p_round
    and (
      u.id is null or u.active = false
      or not ('evaluator' = any(u.roles))
      or not ('interview' = any(u.assigned_areas))
      or not (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      or not (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_TEAM_MEMBER', 'message', format('면접 evaluator 권한·scope가 유효하지 않은 조원이 %s명 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed'
    and not exists (
      select 1 from public.interview_schedules s
      where s.year = p_year and s.round = p_round and s.applicant_id = dr.applicant_id
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CANDIDATE_UNASSIGNED', 'message', format('면접조/시간표 미배정 1차 합격자가 %s명 있습니다.', v_bad_count)
    ));
  end if;

  select count(*)::int into v_bad_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and not exists (
      select 1 from public.decision_results dr
      where dr.run_id = v_plan.document_source_run_id
        and dr.outcome = 'passed'
        and dr.applicant_id = s.applicant_id
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'NON_CANDIDATE_ASSIGNED', 'message', format('M4 1차 합격자가 아닌 지원자 %s명이 면접시간표에 포함되어 있습니다.', v_bad_count)
    ));
  end if;

  v_student_params := public._m5c_interview_params(v_round.config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_round.config_revision_id, 'parent');

  select count(*)::int into v_bad_count
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and (
      extract(epoch from (s.student_ends_at - s.student_starts_at)) / 60 <> (v_student_params ->> 'durationMinutes')::numeric
      or extract(epoch from (s.parent_ends_at - s.parent_starts_at)) / 60 <> (v_parent_params ->> 'durationMinutes')::numeric
    );
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DURATION_MISMATCH', 'message', format('config 기준 학생 %s분·학부모 %s분과 다른 시간표가 %s건 있습니다.',
        v_student_params ->> 'durationMinutes', v_parent_params ->> 'durationMinutes', v_bad_count)
    ));
  end if;

  with slots as (
    select s.id, s.team_id, s.applicant_id, 'student'::text as section,
           s.student_starts_at as starts_at, s.student_ends_at as ends_at
    from public.interview_schedules s
    where s.year = p_year and s.round = p_round
    union all
    select s.id, s.team_id, s.applicant_id, 'parent'::text,
           s.parent_starts_at, s.parent_ends_at
    from public.interview_schedules s
    where s.year = p_year and s.round = p_round
  ), overlapping_slots as (
    select distinct a.team_id, a.id, a.section
    from slots a
    join slots b
      on a.team_id = b.team_id
     and (a.id::text || ':' || a.section) < (b.id::text || ':' || b.section)
     and a.starts_at < b.ends_at
     and b.starts_at < a.ends_at
  )
  select count(*)::int into v_bad_count from overlapping_slots;
  if v_bad_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'SCHEDULE_OVERLAP', 'message', format('같은 면접조의 학생/학부모 면접 시간이 겹치는 구간이 %s건 있습니다.', v_bad_count)
    ));
  end if;

  return jsonb_build_object(
    'complete', jsonb_array_length(v_issues) = 0,
    'blockingIssues', v_issues,
    'status', v_plan.status,
    'revision', v_plan.revision,
    'documentSourceRunId', v_plan.document_source_run_id,
    'configRevisionId', v_plan.config_revision_id,
    'candidateCount', v_candidate_count,
    'teamCount', v_team_count,
    'scheduleCount', v_schedule_count
  );
end;
$$;

revoke all on function public._m5c_validate_interview_plan(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5c_interview_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  return public._m5c_validate_interview_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5c_interview_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5c_interview_plan(int, admission_round) to authenticated;

create or replace function public.get_m5c_interview_plan_admin(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_plan jsonb;
  v_validation jsonb;
  v_plan_config_revision_id uuid;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select config_revision_id into v_plan_config_revision_id
  from public.interview_team_plans where year = p_year and round = p_round;

  if found then
    v_validation := public._m5c_validate_interview_plan(p_year, p_round);
  else
    v_validation := jsonb_build_object('complete', false, 'blockingIssues', '[]'::jsonb, 'status', null, 'revision', 0);
  end if;

  select jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'areaOpen', v_round.stage_status = 'open' and 'interview'::evaluation_area = any(v_round.open_evaluation_areas),
    'studentDurationMinutes', case when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null else (public._m5c_interview_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id), 'student') ->> 'durationMinutes')::int end,
    'parentDurationMinutes', case when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null else (public._m5c_interview_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id), 'parent') ->> 'durationMinutes')::int end,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id,
        'displayName', u.display_name,
        'email', u.email
      ) order by u.display_name, u.email)
      from public.users u
      where u.active = true
        and 'evaluator' = any(u.roles)
        and 'interview' = any(u.assigned_areas)
        and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
        and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    ), '[]'::jsonb),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'documentScore', dr.total_score,
        'interviewTeamId', er.interview_team_id
      ) order by dr.rank, er.exam_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb),
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'teamId', t.id,
        'teamCode', t.team_code,
        'location', t.location,
        'sortOrder', t.sort_order,
        'memberUids', coalesce((
          select jsonb_agg(m.evaluator_uid order by m.member_slot)
          from public.interview_team_members m where m.team_id = t.id
        ), '[]'::jsonb),
        'schedule', coalesce((
          select jsonb_agg(jsonb_build_object(
            'scheduleId', s.id,
            'applicantId', s.applicant_id,
            'studentStartsAt', s.student_starts_at,
            'studentEndsAt', s.student_ends_at,
            'parentStartsAt', s.parent_starts_at,
            'parentEndsAt', s.parent_ends_at,
            'sortOrder', s.sort_order
          ) order by s.sort_order, s.student_starts_at)
          from public.interview_schedules s where s.team_id = t.id
        ), '[]'::jsonb)
      ) order by t.sort_order, t.team_code)
      from public.interview_teams t
      where t.year = p_year and t.round = p_round and t.active = true
    ), '[]'::jsonb),
    'validation', v_validation
  ) into v_plan;

  return v_plan;
end;
$$;

revoke all on function public.get_m5c_interview_plan_admin(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_plan_admin(int, admission_round) to authenticated;

create or replace function public.save_m5c_interview_plan(
  p_year int,
  p_round admission_round,
  p_teams jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_existing_status text;
  team_item jsonb;
  member_item jsonb;
  slot_item jsonb;
  v_team_id uuid;
  v_team_code text;
  v_validation jsonb;
  member_ord bigint;
  slot_ord bigint;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5c:plan:%s:%s', p_year, p_round::text), 0));

  if jsonb_typeof(p_teams) is distinct from 'array' then
    raise exception 'teams는 JSON array여야 합니다.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_teams) team
    cross join lateral jsonb_array_elements_text(coalesce(team -> 'memberUids', '[]'::jsonb)) uid
    where length(trim(uid)) > 0
    group by uid
    having count(*) > 1
  ) then
    raise exception '같은 면접위원을 둘 이상의 슬롯/조에 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_teams) team
    cross join lateral jsonb_array_elements(coalesce(team -> 'schedule', '[]'::jsonb)) slot
    group by slot ->> 'applicantId'
    having count(*) > 1
  ) then
    raise exception '같은 지원자를 둘 이상의 면접조/시간표에 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  select status into v_existing_status
  from public.interview_team_plans
  where year = p_year and round = p_round
  for update;
  if found and v_existing_status = 'finalized' then
    raise exception '이미 최종확정된 면접조 계획입니다. 대체위원 지정은 별도 superadmin RPC를 사용하세요.' using errcode = '55000';
  end if;

  insert into public.interview_team_plans
    (year, round, status, document_source_run_id, config_revision_id, revision, created_by, updated_by)
  values
    (p_year, p_round, 'draft', v_round.document_decision_run_id, v_round.config_revision_id, 1, caller::text, caller::text)
  on conflict (year, round) do update set
    status = 'draft',
    document_source_run_id = excluded.document_source_run_id,
    config_revision_id = excluded.config_revision_id,
    revision = public.interview_team_plans.revision + 1,
    updated_at = now(),
    updated_by = caller::text;

  delete from public.interview_teams where year = p_year and round = p_round;

  for team_item in select value from jsonb_array_elements(p_teams)
  loop
    if jsonb_typeof(team_item) is distinct from 'object' then
      raise exception '각 team 항목은 JSON object여야 합니다.' using errcode = '22023';
    end if;

    v_team_id := coalesce(nullif(team_item ->> 'teamId', '')::uuid, gen_random_uuid());
    v_team_code := trim(coalesce(team_item ->> 'teamCode', ''));
    if length(v_team_code) = 0 then
      raise exception 'teamCode는 필수입니다.' using errcode = '23514';
    end if;

    insert into public.interview_teams
      (id, year, round, team_code, location, sort_order, created_by, updated_by)
    values
      (v_team_id, p_year, p_round, v_team_code, nullif(trim(team_item ->> 'location'), ''),
       coalesce((team_item ->> 'sortOrder')::int, 0), caller::text, caller::text);

    if jsonb_typeof(coalesce(team_item -> 'memberUids', '[]'::jsonb)) is distinct from 'array' then
      raise exception '%조 memberUids는 JSON array여야 합니다.', v_team_code using errcode = '22023';
    end if;

    for member_item, member_ord in
      select value, ordinality from jsonb_array_elements(coalesce(team_item -> 'memberUids', '[]'::jsonb)) with ordinality
    loop
      if member_ord > 2 then
        raise exception '%조 면접위원은 최대 2명까지만 저장할 수 있습니다.', v_team_code using errcode = '23514';
      end if;
      insert into public.interview_team_members
        (team_id, year, round, evaluator_uid, member_slot)
      values
        (v_team_id, p_year, p_round, trim(both '"' from member_item::text)::uuid, member_ord::smallint);
    end loop;

    if jsonb_typeof(coalesce(team_item -> 'schedule', '[]'::jsonb)) is distinct from 'array' then
      raise exception '%조 schedule은 JSON array여야 합니다.', v_team_code using errcode = '22023';
    end if;

    for slot_item, slot_ord in
      select value, ordinality from jsonb_array_elements(coalesce(team_item -> 'schedule', '[]'::jsonb)) with ordinality
    loop
      insert into public.interview_schedules
        (team_id, year, round, applicant_id,
         student_starts_at, student_ends_at, parent_starts_at, parent_ends_at, sort_order)
      values
        (v_team_id, p_year, p_round, (slot_item ->> 'applicantId')::uuid,
         (slot_item ->> 'studentStartsAt')::timestamptz,
         (slot_item ->> 'studentEndsAt')::timestamptz,
         (slot_item ->> 'parentStartsAt')::timestamptz,
         (slot_item ->> 'parentEndsAt')::timestamptz,
         coalesce((slot_item ->> 'sortOrder')::int, slot_ord::int - 1));
    end loop;
  end loop;

  v_validation := public._m5c_validate_interview_plan(p_year, p_round);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview_plan.saved', 'interview_team_plans',
     p_year::text || '_' || p_round::text, 'interview',
     jsonb_build_object('teamCount', jsonb_array_length(p_teams), 'complete', v_validation -> 'complete'));

  return v_validation || jsonb_build_object('status', 'draft');
end;
$$;

revoke all on function public.save_m5c_interview_plan(int, admission_round, jsonb) from public, anon;
grant execute on function public.save_m5c_interview_plan(int, admission_round, jsonb) to authenticated;

create or replace function public.finalize_m5c_interview_plan(
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
  v_plan_status text;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5c:plan:%s:%s', p_year, p_round::text), 0));

  select status into v_plan_status
  from public.interview_team_plans
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception '최종확정할 면접조 계획 draft가 없습니다.' using errcode = 'P0002';
  end if;
  if v_plan_status = 'finalized' then
    raise exception '이미 최종확정된 면접조 계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5c_validate_interview_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '면접조 계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.evaluation_roster er
  set interview_team_id = s.team_id,
      roster_revision = er.roster_revision + 1,
      updated_at = now()
  from public.interview_schedules s
  where s.year = p_year and s.round = p_round
    and s.applicant_id = er.applicant_id;

  update public.interview_team_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview_plan.finalized', 'interview_team_plans',
     p_year::text || '_' || p_round::text, 'interview',
     jsonb_build_object('candidateCount', v_validation -> 'candidateCount', 'teamCount', v_validation -> 'teamCount'));

  return public._m5c_validate_interview_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5c_interview_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5c_interview_plan(int, admission_round) to authenticated;

-- ============================================================
-- 5. evaluator workspace
-- ============================================================

create or replace function public.get_m5c_interview_workspace(
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
  v_round record;
  v_team record;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_schedule jsonb;
  v_plan_config_revision_id uuid;
begin
  caller := public._m5c_require_interview_user(p_year, p_round);

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
    and m.evaluator_uid = caller
  limit 1;

  if not found then
    raise exception '현재 평가자에게 최종확정된 면접조 배정이 없습니다.' using errcode = '42501';
  end if;

  select p.config_revision_id into v_plan_config_revision_id
  from public.interview_team_plans p
  where p.year = p_year and p.round = p_round and p.status = 'finalized';

  v_student_params := public._m5c_interview_params(v_plan_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_plan_config_revision_id, 'parent');

  select coalesce(jsonb_agg(jsonb_build_object(
    'scheduleId', s.id,
    'applicantId', er.applicant_id,
    'examNo', er.exam_no,
    'displayName', er.display_name,
    'studentStartsAt', s.student_starts_at,
    'studentEndsAt', s.student_ends_at,
    'parentStartsAt', s.parent_starts_at,
    'parentEndsAt', s.parent_ends_at,
    'sortOrder', s.sort_order,
    'myScore', case when si.id is null then null else jsonb_build_object(
      'scoreId', si.id,
      'student', jsonb_build_object(
        'items', si.student_items,
        'memo', si.student_memo,
        'submissionState', si.student_submission_state,
        'revision', si.student_revision,
        'serverComputed', si.student_server_computed,
        'clientUpdatedAt', si.student_client_updated_at,
        'submittedAt', si.student_submitted_at
      ),
      'parent', jsonb_build_object(
        'items', si.parent_items,
        'memo', si.parent_memo,
        'submissionState', si.parent_submission_state,
        'revision', si.parent_revision,
        'serverComputed', si.parent_server_computed,
        'clientUpdatedAt', si.parent_client_updated_at,
        'submittedAt', si.parent_submitted_at
      )
    ) end
  ) order by s.sort_order, s.student_starts_at), '[]'::jsonb)
  into v_schedule
  from public.interview_schedules s
  join public.evaluation_roster er on er.applicant_id = s.applicant_id
  left join public.scores_interview si
    on si.applicant_id = s.applicant_id and si.evaluator_uid = caller
  where s.team_id = v_team.id;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'serverNow', now(),
    'areaOpen', v_round.stage_status = 'open' and 'interview'::evaluation_area = any(v_round.open_evaluation_areas),
    'team', jsonb_build_object(
      'teamId', v_team.id,
      'teamCode', v_team.team_code,
      'location', v_team.location
    ),
    'student', jsonb_build_object(
      'criteria', v_student_params -> 'criteria',
      'perEvaluatorMax', (v_student_params ->> 'perEvaluatorMax')::numeric,
      'durationMinutes', (v_student_params ->> 'durationMinutes')::int
    ),
    'parent', jsonb_build_object(
      'criteria', v_parent_params -> 'criteria',
      'perEvaluatorMax', (v_parent_params ->> 'perEvaluatorMax')::numeric,
      'durationMinutes', (v_parent_params ->> 'durationMinutes')::int
    ),
    'schedule', v_schedule
  );
end;
$$;

revoke all on function public.get_m5c_interview_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_workspace(int, admission_round) to authenticated;

-- ============================================================
-- 6. section별 draft 저장 — stale replay 차단
-- ============================================================

create or replace function public.save_interview_score_draft(
  p_applicant_id uuid,
  p_section text,
  p_items jsonb,
  p_memo text,
  p_client_updated_at timestamptz
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
  v_team_id uuid;
  v_config_revision_id uuid;
  v_existing public.scores_interview%rowtype;
  v_total numeric;
  v_accepted boolean := true;
  v_current_total numeric;
  v_current_client_updated_at timestamptz;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '면접 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5c_require_interviewer(p_applicant_id);

  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;

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

  perform pg_advisory_xact_lock(hashtextextended(format('m5c:score:%s:%s', p_applicant_id::text, caller::text), 0));

  v_total := public._m5c_validate_and_total(v_config_revision_id, p_section, p_items, false);

  select * into v_existing
  from public.scores_interview
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if p_section = 'student' then
    if v_existing.id is not null and v_existing.student_submission_state = 'submitted' then
      raise exception '이미 제출확정된 학생면접 채점입니다. 수정하려면 superadmin에게 학생면접 재개방을 요청하세요.' using errcode = '55000';
    end if;
    if v_existing.id is not null
       and v_existing.student_client_updated_at is not null
       and v_existing.student_client_updated_at >= p_client_updated_at then
      v_accepted := false;
      v_current_total := (v_existing.student_server_computed ->> 'draftTotal')::numeric;
      v_current_client_updated_at := v_existing.student_client_updated_at;
    else
      insert into public.scores_interview
        (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
         student_items, student_memo, student_server_computed, student_submission_state,
         student_revision, student_client_updated_at)
      values
        (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
         p_items, p_memo, jsonb_build_object('draftTotal', v_total, 'valid', false), 'draft', 1, p_client_updated_at)
      on conflict (applicant_id, evaluator_uid) do update set
        config_revision_id = excluded.config_revision_id,
        team_id = excluded.team_id,
        student_items = excluded.student_items,
        student_memo = excluded.student_memo,
        student_server_computed = excluded.student_server_computed,
        student_submission_state = 'draft',
        student_revision = public.scores_interview.student_revision + 1,
        student_client_updated_at = excluded.student_client_updated_at,
        student_submitted_at = null,
        updated_at = now();
      v_current_total := v_total;
      v_current_client_updated_at := p_client_updated_at;
    end if;
  else
    if v_existing.id is not null and v_existing.parent_submission_state = 'submitted' then
      raise exception '이미 제출확정된 학부모면접 채점입니다. 수정하려면 superadmin에게 학부모면접 재개방을 요청하세요.' using errcode = '55000';
    end if;
    if v_existing.id is not null
       and v_existing.parent_client_updated_at is not null
       and v_existing.parent_client_updated_at >= p_client_updated_at then
      v_accepted := false;
      v_current_total := (v_existing.parent_server_computed ->> 'draftTotal')::numeric;
      v_current_client_updated_at := v_existing.parent_client_updated_at;
    else
      insert into public.scores_interview
        (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
         parent_items, parent_memo, parent_server_computed, parent_submission_state,
         parent_revision, parent_client_updated_at)
      values
        (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
         p_items, p_memo, jsonb_build_object('draftTotal', v_total, 'valid', false), 'draft', 1, p_client_updated_at)
      on conflict (applicant_id, evaluator_uid) do update set
        config_revision_id = excluded.config_revision_id,
        team_id = excluded.team_id,
        parent_items = excluded.parent_items,
        parent_memo = excluded.parent_memo,
        parent_server_computed = excluded.parent_server_computed,
        parent_submission_state = 'draft',
        parent_revision = public.scores_interview.parent_revision + 1,
        parent_client_updated_at = excluded.parent_client_updated_at,
        parent_submitted_at = null,
        updated_at = now();
      v_current_total := v_total;
      v_current_client_updated_at := p_client_updated_at;
    end if;
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'section', p_section,
    'draftTotal', v_current_total,
    'serverClientUpdatedAt', v_current_client_updated_at,
    'submissionState', case
      when p_section = 'student' then coalesce((select student_submission_state from public.scores_interview where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
      else coalesce((select parent_submission_state from public.scores_interview where applicant_id = p_applicant_id and evaluator_uid = caller), 'draft')
    end
  );
end;
$$;

revoke all on function public.save_interview_score_draft(uuid, text, jsonb, text, timestamptz) from public, anon;
grant execute on function public.save_interview_score_draft(uuid, text, jsonb, text, timestamptz) to authenticated;

-- ============================================================
-- 7. section별 제출확정 — 독립 잠금
-- ============================================================

create or replace function public.submit_interview_score(
  p_applicant_id uuid,
  p_section text,
  p_items jsonb,
  p_memo text
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
  v_team_id uuid;
  v_config_revision_id uuid;
  v_existing public.scores_interview%rowtype;
  v_total numeric;
  v_score_id uuid;
  v_revision int;
begin
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '면접 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5c_require_interviewer(p_applicant_id);

  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er where er.applicant_id = p_applicant_id;

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

  perform pg_advisory_xact_lock(hashtextextended(format('m5c:score:%s:%s', p_applicant_id::text, caller::text), 0));

  select * into v_existing
  from public.scores_interview
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if p_section = 'student'
     and v_existing.id is not null
     and v_existing.student_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학생면접 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;
  if p_section = 'parent'
     and v_existing.id is not null
     and v_existing.parent_submission_state = 'submitted' then
    raise exception '이미 제출확정된 학부모면접 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  v_total := public._m5c_validate_and_total(v_config_revision_id, p_section, p_items, true);

  if p_section = 'student' then
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       student_items, student_memo, student_server_computed, student_submission_state,
       student_revision, student_client_updated_at, student_submitted_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id),
       'submitted', coalesce(v_existing.student_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      team_id = excluded.team_id,
      student_items = excluded.student_items,
      student_memo = excluded.student_memo,
      student_server_computed = excluded.student_server_computed,
      student_submission_state = 'submitted',
      student_revision = public.scores_interview.student_revision + 1,
      student_client_updated_at = now(),
      student_submitted_at = now(),
      updated_at = now()
    returning id, student_revision into v_score_id, v_revision;
  else
    insert into public.scores_interview
      (applicant_id, evaluator_uid, year, round, config_revision_id, team_id,
       parent_items, parent_memo, parent_server_computed, parent_submission_state,
       parent_revision, parent_client_updated_at, parent_submitted_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id, v_team_id,
       p_items, p_memo,
       jsonb_build_object('total', v_total, 'valid', true, 'configRevisionId', v_config_revision_id),
       'submitted', coalesce(v_existing.parent_revision, 0) + 1, now(), now())
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      team_id = excluded.team_id,
      parent_items = excluded.parent_items,
      parent_memo = excluded.parent_memo,
      parent_server_computed = excluded.parent_server_computed,
      parent_submission_state = 'submitted',
      parent_revision = public.scores_interview.parent_revision + 1,
      parent_client_updated_at = now(),
      parent_submitted_at = now(),
      updated_at = now()
    returning id, parent_revision into v_score_id, v_revision;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_year, v_round, 'user', caller::text,
     case when p_section = 'student' then 'score.interview.student.submitted' else 'score.interview.parent.submitted' end,
     'scores_interview', v_score_id::text, p_applicant_id::text, 'interview',
     jsonb_build_object('section', p_section, 'revision', v_revision));

  return jsonb_build_object(
    'scoreId', v_score_id,
    'section', p_section,
    'total', v_total,
    'submissionState', 'submitted',
    'revision', v_revision
  );
end;
$$;

revoke all on function public.submit_interview_score(uuid, text, jsonb, text) from public, anon;
grant execute on function public.submit_interview_score(uuid, text, jsonb, text) to authenticated;

-- ============================================================
-- 8. 면접 aggregate / trigger / 경보
-- ============================================================

create or replace function public._compute_interview_aggregate(
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_student_required int;
  v_parent_required int;
  v_student_submitted int;
  v_parent_submitted int;
  v_student_average numeric;
  v_parent_average numeric;
  v_student_gap numeric;
  v_parent_gap numeric;
  v_student_score numeric;
  v_parent_score numeric;
  v_student_summary jsonb;
  v_parent_summary jsonb;
begin
  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_team_id is null then
    return jsonb_build_object(
      'student', jsonb_build_object('complete', false, 'score', null, 'required', null, 'submitted', 0, 'gap', null),
      'parent', jsonb_build_object('complete', false, 'score', null, 'required', null, 'submitted', 0, 'gap', null),
      'sourceRevisionSummary', '{}'::jsonb,
      'functionVersion', 'm5c-interview-aggregate-v1'
    );
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;
  v_student_params := public._m5c_interview_params(v_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_config_revision_id, 'parent');
  v_student_required := (v_student_params ->> 'requiredSubmissions')::int;
  v_parent_required := (v_parent_params ->> 'requiredSubmissions')::int;

  select count(*)::int,
         avg((si.student_server_computed ->> 'total')::numeric),
         max((si.student_server_computed ->> 'total')::numeric) - min((si.student_server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', si.id,
           'evaluatorUid', si.evaluator_uid,
           'revision', si.student_revision
         ) order by si.evaluator_uid), '[]'::jsonb)
    into v_student_submitted, v_student_average, v_student_gap, v_student_summary
  from public.scores_interview si
  join public.interview_team_members m
    on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and si.team_id = v_team_id
    and si.student_submission_state = 'submitted'
    and coalesce((si.student_server_computed ->> 'valid')::boolean, false) = true;

  select count(*)::int,
         avg((si.parent_server_computed ->> 'total')::numeric),
         max((si.parent_server_computed ->> 'total')::numeric) - min((si.parent_server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', si.id,
           'evaluatorUid', si.evaluator_uid,
           'revision', si.parent_revision
         ) order by si.evaluator_uid), '[]'::jsonb)
    into v_parent_submitted, v_parent_average, v_parent_gap, v_parent_summary
  from public.scores_interview si
  join public.interview_team_members m
    on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and si.team_id = v_team_id
    and si.parent_submission_state = 'submitted'
    and coalesce((si.parent_server_computed ->> 'valid')::boolean, false) = true;

  if v_student_submitted < v_student_required then
    v_student_score := null;
  else
    v_student_score := least((v_student_params ->> 'max')::numeric, v_student_average);
  end if;
  if v_parent_submitted < v_parent_required then
    v_parent_score := null;
  else
    v_parent_score := least((v_parent_params ->> 'max')::numeric, v_parent_average);
  end if;

  return jsonb_build_object(
    'student', jsonb_build_object(
      'complete', v_student_submitted >= v_student_required,
      'score', v_student_score,
      'required', v_student_required,
      'submitted', v_student_submitted,
      'gap', case when v_student_submitted >= 2 then v_student_gap else null end
    ),
    'parent', jsonb_build_object(
      'complete', v_parent_submitted >= v_parent_required,
      'score', v_parent_score,
      'required', v_parent_required,
      'submitted', v_parent_submitted,
      'gap', case when v_parent_submitted >= 2 then v_parent_gap else null end
    ),
    'sourceRevisionSummary', jsonb_build_object(
      'student', v_student_summary,
      'parent', v_parent_summary
    ),
    'functionVersion', 'm5c-interview-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_interview_aggregate(
  p_applicant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_team_id uuid;
  v_config_revision_id uuid;
  v_agg jsonb;
  v_student_params jsonb;
  v_parent_params jsonb;
  v_student_gap numeric;
  v_parent_gap numeric;
  v_gap_summary text;
  v_related uuid[];
begin
  select er.year, er.round, er.interview_team_id
    into v_year, v_round, v_team_id
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found or v_team_id is null then
    delete from public.deep_interview_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.interview_team_plans p
  join public.interview_teams t on t.year = p.year and t.round = p.round
  where p.year = v_year and p.round = v_round and p.status = 'finalized' and t.id = v_team_id;

  v_agg := public._compute_interview_aggregate(p_applicant_id);

  insert into public.deep_interview_aggregates
    (applicant_id, year, round, config_revision_id, team_id,
     student_complete, student_score, student_required, student_submitted, student_gap,
     parent_complete, parent_score, parent_required, parent_submitted, parent_gap,
     source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_year, v_round, v_config_revision_id, v_team_id,
     (v_agg #>> '{student,complete}')::boolean,
     nullif(v_agg #>> '{student,score}', '')::numeric,
     (v_agg #>> '{student,required}')::int,
     (v_agg #>> '{student,submitted}')::int,
     nullif(v_agg #>> '{student,gap}', '')::numeric,
     (v_agg #>> '{parent,complete}')::boolean,
     nullif(v_agg #>> '{parent,score}', '')::numeric,
     (v_agg #>> '{parent,required}')::int,
     (v_agg #>> '{parent,submitted}')::int,
     nullif(v_agg #>> '{parent,gap}', '')::numeric,
     v_agg -> 'sourceRevisionSummary', v_agg ->> 'functionVersion', now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    team_id = excluded.team_id,
    student_complete = excluded.student_complete,
    student_score = excluded.student_score,
    student_required = excluded.student_required,
    student_submitted = excluded.student_submitted,
    student_gap = excluded.student_gap,
    parent_complete = excluded.parent_complete,
    parent_score = excluded.parent_score,
    parent_required = excluded.parent_required,
    parent_submitted = excluded.parent_submitted,
    parent_gap = excluded.parent_gap,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = excluded.computed_at;

  v_student_params := public._m5c_interview_params(v_config_revision_id, 'student');
  v_parent_params := public._m5c_interview_params(v_config_revision_id, 'parent');
  v_student_gap := nullif(v_agg #>> '{student,gap}', '')::numeric;
  v_parent_gap := nullif(v_agg #>> '{parent,gap}', '')::numeric;

  select coalesce(array_agg(distinct si.evaluator_uid), '{}'::uuid[])
    into v_related
  from public.scores_interview si
  join public.interview_team_members m on m.team_id = v_team_id and m.evaluator_uid = si.evaluator_uid
  where si.applicant_id = p_applicant_id
    and (si.student_submission_state = 'submitted' or si.parent_submission_state = 'submitted');

  if (v_student_gap is not null and v_student_gap >= (v_student_params ->> 'alertGap')::numeric)
     or (v_parent_gap is not null and v_parent_gap >= (v_parent_params ->> 'alertGap')::numeric) then
    v_gap_summary := concat_ws(' / ',
      case when v_student_gap is not null and v_student_gap >= (v_student_params ->> 'alertGap')::numeric
        then format('학생면접 위원 간 총점 편차 %s점(기준 %s)', v_student_gap, v_student_params ->> 'alertGap') end,
      case when v_parent_gap is not null and v_parent_gap >= (v_parent_params ->> 'alertGap')::numeric
        then format('학부모면접 위원 간 총점 편차 %s점(기준 %s)', v_parent_gap, v_parent_params ->> 'alertGap') end
    );

    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
    values
      (v_year, v_round, p_applicant_id, 'interview', 'scoreGap', 'warning', v_gap_summary, v_related)
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      related_evaluator_uids = excluded.related_evaluator_uids,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5c'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'interview' and alert_type = 'scoreGap' and status <> 'resolved';
  end if;

  if (v_agg #>> '{student,submitted}')::int < (v_agg #>> '{student,required}')::int
     or (v_agg #>> '{parent,submitted}')::int < (v_agg #>> '{parent,required}')::int then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary)
    values
      (v_year, v_round, p_applicant_id, 'interview', 'missingSubmission', 'warning',
       format('학생면접 제출 %s/%s · 학부모면접 제출 %s/%s',
         v_agg #>> '{student,submitted}', v_agg #>> '{student,required}',
         v_agg #>> '{parent,submitted}', v_agg #>> '{parent,required}'))
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5c'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'interview' and alert_type = 'missingSubmission' and status <> 'resolved';
  end if;
end;
$$;

create or replace function public._trg_refresh_interview_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_interview_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_interview_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._compute_interview_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_interview_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_interview_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_interview_aggregate on public.scores_interview;
create trigger trg_refresh_interview_aggregate
  after insert or update or delete on public.scores_interview
  for each row execute function public._trg_refresh_interview_aggregate();

-- ============================================================
-- 9. 관리자 진행현황 — 개별 위원 실제 점수 비노출
-- ============================================================

create or replace function public.get_m5c_interview_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'teamCode', t.team_code,
        'studentComplete', coalesce(a.student_complete, false),
        'studentScore', a.student_score,
        'studentRequired', a.student_required,
        'studentSubmitted', coalesce(a.student_submitted, 0),
        'studentGapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'interview'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
            and ea.summary like '%학생면접%'
        ),
        'parentComplete', coalesce(a.parent_complete, false),
        'parentScore', a.parent_score,
        'parentRequired', a.parent_required,
        'parentSubmitted', coalesce(a.parent_submitted, 0),
        'parentGapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'interview'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
            and ea.summary like '%학부모면접%'
        ),
        'computedAt', a.computed_at
      ) order by t.sort_order, s.sort_order, er.exam_no, er.display_name)
      from public.interview_schedules s
      join public.interview_teams t on t.id = s.team_id
      join public.evaluation_roster er on er.applicant_id = s.applicant_id
      left join public.deep_interview_aggregates a on a.applicant_id = er.applicant_id
      where s.year = p_year and s.round = p_round
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5c_interview_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5c_interview_progress(int, admission_round) to authenticated;

-- ============================================================
-- 10. 독립 재개방 / 대체 평가위원
-- ============================================================

create or replace function public.reopen_interview_score(
  p_score_id uuid,
  p_section text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_applicant_id uuid;
  v_year int;
  v_round admission_round;
begin
  caller := public._require_superadmin();
  if p_section not in ('student', 'parent') then
    raise exception '면접 section은 student 또는 parent여야 합니다.' using errcode = '22023';
  end if;
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '재개방 사유는 최소 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  if p_section = 'student' then
    update public.scores_interview
    set student_submission_state = 'reopened',
        student_submitted_at = null,
        updated_at = now()
    where id = p_score_id
    returning applicant_id, year, round into v_applicant_id, v_year, v_round;
  else
    update public.scores_interview
    set parent_submission_state = 'reopened',
        parent_submitted_at = null,
        updated_at = now()
    where id = p_score_id
    returning applicant_id, year, round into v_applicant_id, v_year, v_round;
  end if;

  if not found then
    raise exception '해당 면접 채점 문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.interview.reopened', 'scores_interview',
     p_score_id::text, v_applicant_id::text, 'interview', '관리자 재개방',
     jsonb_build_object('section', p_section, 'reason', p_reason));
end;
$$;

revoke all on function public.reopen_interview_score(uuid, text, text) from public, anon;
grant execute on function public.reopen_interview_score(uuid, text, text) to authenticated;

create or replace function public.replace_m5c_interview_team_member(
  p_team_id uuid,
  p_old_evaluator_uid uuid,
  p_new_evaluator_uid uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_team record;
  v_slot smallint;
  r record;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '대체 평가위원 지정 사유는 최소 5자 이상 입력하세요.' using errcode = '23514';
  end if;
  if p_old_evaluator_uid = p_new_evaluator_uid then
    raise exception '기존 위원과 새 위원이 동일합니다.' using errcode = '23514';
  end if;

  select t.* into v_team
  from public.interview_teams t
  join public.interview_team_plans p on p.year = t.year and p.round = t.round
  where t.id = p_team_id and p.status = 'finalized'
  for update;
  if not found then
    raise exception '최종확정된 면접조를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = p_new_evaluator_uid and u.active = true
      and 'evaluator' = any(u.roles)
      and 'interview' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or v_team.year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or v_team.round = any(u.round_scopes))
  ) then
    raise exception '새 위원은 evaluator + interview 권한 및 해당 scope가 필요합니다.' using errcode = '42501';
  end if;

  select member_slot into v_slot
  from public.interview_team_members
  where team_id = p_team_id and evaluator_uid = p_old_evaluator_uid
  for update;
  if not found then
    raise exception '기존 위원이 해당 면접조에 속해 있지 않습니다.' using errcode = 'P0002';
  end if;

  update public.interview_team_members
  set evaluator_uid = p_new_evaluator_uid
  where team_id = p_team_id and member_slot = v_slot;

  for r in select applicant_id from public.interview_schedules where team_id = p_team_id
  loop
    perform public._refresh_interview_aggregate(r.applicant_id);
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, reason_code, metadata)
  values
    (v_team.year, v_team.round, 'user', caller::text, 'interview_team.member_replaced', 'interview_teams',
     p_team_id::text, 'interview', '대체 평가위원 지정',
     jsonb_build_object('oldEvaluatorUid', p_old_evaluator_uid, 'newEvaluatorUid', p_new_evaluator_uid, 'reason', p_reason));

  return jsonb_build_object(
    'teamId', p_team_id,
    'memberSlot', v_slot,
    'oldEvaluatorUid', p_old_evaluator_uid,
    'newEvaluatorUid', p_new_evaluator_uid
  );
end;
$$;

revoke all on function public.replace_m5c_interview_team_member(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.replace_m5c_interview_team_member(uuid, uuid, uuid, text) to authenticated;


-- ============================================================
-- M5c migration self-verification: 핵심 객체가 모두 생성되지 않으면 COMMIT 전 롤백
-- ============================================================
do $m5c_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regclass('public.interview_team_plans') is null then missing_objects := array_append(missing_objects, 'table:interview_team_plans'); end if;
  if to_regclass('public.interview_teams') is null then missing_objects := array_append(missing_objects, 'table:interview_teams'); end if;
  if to_regclass('public.interview_team_members') is null then missing_objects := array_append(missing_objects, 'table:interview_team_members'); end if;
  if to_regclass('public.interview_schedules') is null then missing_objects := array_append(missing_objects, 'table:interview_schedules'); end if;
  if to_regclass('public.scores_interview') is null then missing_objects := array_append(missing_objects, 'table:scores_interview'); end if;
  if to_regclass('public.deep_interview_aggregates') is null then missing_objects := array_append(missing_objects, 'table:deep_interview_aggregates'); end if;

  if to_regprocedure('public._m5c_interview_params(uuid,text)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_interview_params(uuid,text)'); end if;
  if to_regprocedure('public._m5c_require_interview_user(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_require_interview_user(integer,admission_round)'); end if;
  if to_regprocedure('public._m5c_validate_interview_plan(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5c_validate_interview_plan(integer,admission_round)'); end if;
  if to_regprocedure('public.get_m5c_interview_workspace(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'rpc:get_m5c_interview_workspace(integer,admission_round)'); end if;
  if to_regprocedure('public.save_interview_score_draft(uuid,text,jsonb,text,timestamp with time zone)') is null then missing_objects := array_append(missing_objects, 'rpc:save_interview_score_draft'); end if;
  if to_regprocedure('public.submit_interview_score(uuid,text,jsonb,text)') is null then missing_objects := array_append(missing_objects, 'rpc:submit_interview_score'); end if;
  if to_regprocedure('public._compute_interview_aggregate(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_compute_interview_aggregate(uuid)'); end if;
  if to_regprocedure('public._trg_refresh_interview_aggregate()') is null then missing_objects := array_append(missing_objects, 'function:_trg_refresh_interview_aggregate()'); end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_interview'
      and t.tgname = 'trg_refresh_interview_aggregate'
      and not t.tgisinternal
  ) then
    missing_objects := array_append(missing_objects, 'trigger:trg_refresh_interview_aggregate');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5C_00012_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5c_verify$;

commit;

select
  'M5C_00012_APPLIED'::text as migration_status,
  to_regprocedure('public._m5c_interview_params(uuid,text)') is not null as helper_present,
  to_regclass('public.scores_interview') is not null as score_table_present,
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_interview'
      and t.tgname = 'trg_refresh_interview_aggregate'
      and not t.tgisinternal
  ) as aggregate_trigger_present;

-- ======================================================================
-- 00013_m5d_writing.sql
-- ======================================================================

begin;

-- 새봄고 입학전형 시스템 — M5d 지원자 글쓰기 독립채점
-- 마스터 스펙 v1.2 섹션 2.6, 3.16, 5.4.5, 6.8, M5d 대응.
--
-- 핵심 불변조건
--   1) writing evaluator + area + scope + finalized writing plan membership이 모두 필요하다.
--   2) 글쓰기 위원 2인은 동일한 M4 final 합격자 풀을 각자 독립 채점하며 서로의 점수는 읽지 못한다.
--   3) 지원자는 config에 정의된 3문항 중 정확히 2문항을 선택하고, 각 문항의 필수 4영역을 모두 채점한다.
--   4) 서버가 questionId 중복·criterion key·허용 단계값·문항/위원 상한을 검증하고 총점을 재계산한다.
--   5) 2인 모두 제출 전 writing aggregate는 score=null, complete=false다.
--   6) plan의 document decision run/config revision을 snapshot으로 고정해 재현성을 보장한다.
--   7) writingAnswer 문서는 finalized writing plan의 실제 위원만 열람할 수 있도록 M2 문서 RLS를 보강한다.

-- ============================================================
-- 1. 글쓰기 평가계획 / 위원 2인
-- ============================================================

create table public.writing_evaluation_plans (
  year int not null,
  round admission_round not null,
  status text not null default 'draft' check (status in ('draft', 'finalized')),
  document_source_run_id uuid not null references public.decision_runs (id),
  config_revision_id uuid not null references public.config_revisions (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.writing_plan_members (
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  member_slot smallint not null check (member_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (year, round, member_slot),
  unique (year, round, evaluator_uid),
  foreign key (year, round)
    references public.writing_evaluation_plans (year, round) on delete cascade
);

comment on table public.writing_evaluation_plans is
  'M5d 글쓰기 2인 독립채점 계획. M4 final passed 풀과 config revision을 snapshot으로 고정한다.';
comment on table public.writing_plan_members is
  '해당 연도/차수의 글쓰기 답안 전체를 독립 채점하는 위원 2인. slot 1/2 고정.';

alter table public.writing_evaluation_plans enable row level security;
alter table public.writing_plan_members enable row level security;

create policy writing_evaluation_plans_select_staff
  on public.writing_evaluation_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('writing')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or writing_evaluation_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or writing_evaluation_plans.round = any(u.round_scopes))
      )
    )
  );

create policy writing_plan_members_select_own_or_admin
  on public.writing_plan_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      evaluator_uid = auth.uid()
      and public.has_role('evaluator')
      and public.has_area('writing')
    )
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. 개별 점수 / 서버 집계
-- ============================================================

create table public.scores_writing (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  responses jsonb not null default '[]'::jsonb,
  memo text,
  server_computed jsonb,
  submission_state text not null default 'draft'
    check (submission_state in ('draft', 'submitted', 'reopened')),
  revision int not null default 0 check (revision >= 0),
  client_updated_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_writing_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  complete boolean not null default false,
  score numeric,
  required int not null,
  submitted int not null,
  gap numeric,
  source_revision_summary jsonb not null default '[]'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_writing is
  'M5d 위원별 독립 글쓰기 채점. responses는 선택문항 2개와 문항별 criterion 점수만 보관하고 총점은 서버 재계산.';
comment on table public.deep_writing_aggregates is
  'M5d 서버 집계. 필수 2인 제출 전 score=null/complete=false, 충족 후 위원별 200점 총점 평균.';

alter table public.scores_writing enable row level security;
alter table public.deep_writing_aggregates enable row level security;

create policy scores_writing_select_own
  on public.scores_writing for select
  using (evaluator_uid = auth.uid());

create policy deep_writing_aggregates_select_admin_viewer
  on public.deep_writing_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- ============================================================
-- 3. config / 권한 / 점수 검증 private helpers
-- ============================================================

create or replace function public._m5d_writing_params(
  p_revision_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_rule jsonb;
  v_questions jsonb;
  v_question jsonb;
  v_criteria jsonb;
  v_criterion jsonb;
  v_sum_max numeric;
begin
  select scoring_params #> '{deep,writing}'
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.writing 파라미터가 없습니다. M5d 배점 설정을 먼저 반영하세요.'
      using errcode = '55000';
  end if;

  v_rule := v_params -> 'questionRule';
  v_questions := v_params -> 'questions';

  if coalesce((v_params ->> 'max')::numeric, 0) <= 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredSubmissions')::int, 0) <= 0
     or v_params ->> 'combine' <> 'avg'
     or coalesce((v_params ->> 'alertGap')::numeric, -1) < 0
     or jsonb_typeof(v_rule) is distinct from 'object'
     or coalesce((v_rule ->> 'pick')::int, 0) <= 0
     or coalesce((v_rule ->> 'of')::int, 0) <= 0
     or coalesce((v_rule ->> 'each')::numeric, 0) <= 0
     or coalesce((v_rule ->> 'criteriaPerQuestion')::int, 0) <= 0
     or jsonb_typeof(v_questions) is distinct from 'array'
     or jsonb_array_length(v_questions) = 0 then
    raise exception 'deep.writing 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  if (v_rule ->> 'pick')::int > (v_rule ->> 'of')::int
     or jsonb_array_length(v_questions) <> (v_rule ->> 'of')::int
     or (v_rule ->> 'pick')::numeric * (v_rule ->> 'each')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric
     or (v_params ->> 'max')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception 'writing questionRule / perEvaluatorMax / max 관계가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  if (select count(*) from jsonb_array_elements(v_questions)) <>
     (select count(distinct q.value ->> 'id') from jsonb_array_elements(v_questions) q) then
    raise exception 'writing question id가 중복되었습니다.' using errcode = '23514';
  end if;

  for v_question in select value from jsonb_array_elements(v_questions)
  loop
    v_criteria := v_question -> 'criteria';
    if jsonb_typeof(v_question) is distinct from 'object'
       or coalesce(length(trim(v_question ->> 'id')), 0) = 0
       or coalesce(length(trim(v_question ->> 'label')), 0) = 0
       or jsonb_typeof(v_criteria) is distinct from 'array'
       or jsonb_array_length(v_criteria) <> (v_rule ->> 'criteriaPerQuestion')::int then
      raise exception 'writing question 구조가 올바르지 않습니다: %', v_question using errcode = '23514';
    end if;

    if (select count(*) from jsonb_array_elements(v_criteria)) <>
       (select count(distinct c.value ->> 'key') from jsonb_array_elements(v_criteria) c) then
      raise exception 'writing criterion key가 중복되었습니다: %', v_question ->> 'id' using errcode = '23514';
    end if;

    v_sum_max := 0;
    for v_criterion in select value from jsonb_array_elements(v_criteria)
    loop
      if jsonb_typeof(v_criterion) is distinct from 'object'
         or coalesce(length(trim(v_criterion ->> 'key')), 0) = 0
         or coalesce(length(trim(v_criterion ->> 'label')), 0) = 0
         or coalesce((v_criterion ->> 'max')::numeric, 0) <= 0
         or jsonb_typeof(v_criterion -> 'scoreValues') is distinct from 'array'
         or jsonb_array_length(v_criterion -> 'scoreValues') = 0 then
        raise exception 'writing criterion 구조가 올바르지 않습니다: %', v_criterion using errcode = '23514';
      end if;
      if exists (
        select 1
        from jsonb_array_elements_text(v_criterion -> 'scoreValues') score_value
        where score_value::numeric < 0
           or score_value::numeric > (v_criterion ->> 'max')::numeric
      ) then
        raise exception 'writing criterion scoreValues가 max 범위를 벗어납니다: %', v_criterion using errcode = '23514';
      end if;
      v_sum_max := v_sum_max + (v_criterion ->> 'max')::numeric;
    end loop;

    if v_sum_max <> (v_rule ->> 'each')::numeric then
      raise exception '문항 %의 criterion max 합계가 문항당 상한 %와 일치하지 않습니다.',
        v_question ->> 'id', v_rule ->> 'each' using errcode = '23514';
    end if;
  end loop;

  return v_params;
end;
$$;

create or replace function public._m5d_require_writing_user(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'writing' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '글쓰기 평가 권한이 없습니다 (evaluator + writing 배정 및 scope 필요).' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5d_require_writer(
  p_applicant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_active boolean;
begin
  select er.year, er.round, er.evaluation_active
    into v_year, v_round, v_active
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5d_require_writing_user(v_year, v_round);

  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  if not exists (
    select 1
    from public.writing_evaluation_plans p
    join public.writing_plan_members m
      on m.year = p.year and m.round = p.round
    join public.decision_results dr
      on dr.run_id = p.document_source_run_id
     and dr.applicant_id = p_applicant_id
     and dr.outcome = 'passed'
    where p.year = v_year and p.round = v_round
      and p.status = 'finalized'
      and m.evaluator_uid = caller
  ) then
    raise exception '이 지원자는 현재 평가자의 글쓰기 채점 대상이 아닙니다.' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.admission_documents d
    where d.applicant_id = p_applicant_id
      and d.document_type = 'writingAnswer'
      and d.active = true
      and d.classification = 'evaluation'
      and 'writing'::evaluation_area = any(d.access_areas)
  ) then
    raise exception '지원자의 글쓰기 답안 평가문서가 준비되지 않았습니다.' using errcode = '55000';
  end if;

  return caller;
end;
$$;

create or replace function public._m5d_validate_and_total(
  p_revision_id uuid,
  p_responses jsonb,
  p_require_complete boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb := public._m5d_writing_params(p_revision_id);
  v_rule jsonb := v_params -> 'questionRule';
  v_questions jsonb := v_params -> 'questions';
  v_response jsonb;
  v_question jsonb;
  v_criterion jsonb;
  v_items jsonb;
  v_question_id text;
  v_key text;
  v_raw_value text;
  v_value numeric;
  v_question_total numeric;
  v_total numeric := 0;
  v_question_totals jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_responses) is distinct from 'array' then
    raise exception 'responses는 JSON array여야 합니다.' using errcode = '22023';
  end if;

  if jsonb_array_length(p_responses) > (v_rule ->> 'pick')::int then
    raise exception '글쓰기 응답은 최대 %개 문항까지만 입력할 수 있습니다.', v_rule ->> 'pick' using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_responses) response_item
    group by response_item ->> 'questionId'
    having count(*) > 1
  ) then
    raise exception '동일 questionId를 중복 선택할 수 없습니다.' using errcode = '23514';
  end if;

  if p_require_complete and jsonb_array_length(p_responses) <> (v_rule ->> 'pick')::int then
    raise exception '글쓰기 제출은 %개 문항을 정확히 선택해야 합니다.', v_rule ->> 'pick' using errcode = '23514';
  end if;

  for v_response in select value from jsonb_array_elements(p_responses)
  loop
    if jsonb_typeof(v_response) is distinct from 'object' then
      raise exception '각 response는 JSON object여야 합니다.' using errcode = '22023';
    end if;

    v_question_id := trim(coalesce(v_response ->> 'questionId', ''));
    select value into v_question
    from jsonb_array_elements(v_questions)
    where value ->> 'id' = v_question_id
    limit 1;
    if not found then
      raise exception '허용되지 않은 writing questionId입니다: %', v_question_id using errcode = '23514';
    end if;

    v_items := coalesce(v_response -> 'items', '{}'::jsonb);
    if jsonb_typeof(v_items) is distinct from 'object' then
      raise exception '% items는 JSON object여야 합니다.', v_question_id using errcode = '22023';
    end if;

    if p_require_complete then
      for v_criterion in select value from jsonb_array_elements(v_question -> 'criteria')
      loop
        if not (v_items ? (v_criterion ->> 'key')) then
          raise exception '% · % 점수가 없습니다. 모든 글쓰기 기준을 입력해야 제출할 수 있습니다.',
            v_question ->> 'label', v_criterion ->> 'label' using errcode = '23514';
        end if;
      end loop;
      if (select count(*) from jsonb_object_keys(v_items)) <> jsonb_array_length(v_question -> 'criteria') then
        raise exception '%의 허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.',
          v_question ->> 'label' using errcode = '23514';
      end if;
    end if;

    v_question_total := 0;
    for v_key, v_raw_value in select key, value from jsonb_each_text(v_items)
    loop
      select value into v_criterion
      from jsonb_array_elements(v_question -> 'criteria')
      where value ->> 'key' = v_key
      limit 1;
      if not found then
        raise exception '%에서 알 수 없는 글쓰기 채점 기준: %', v_question ->> 'label', v_key using errcode = '23514';
      end if;

      begin
        v_value := v_raw_value::numeric;
      exception when others then
        raise exception '% · % 점수는 숫자여야 합니다.', v_question ->> 'label', v_criterion ->> 'label' using errcode = '22023';
      end;

      if not exists (
        select 1
        from jsonb_array_elements_text(v_criterion -> 'scoreValues') score_value
        where score_value::numeric = v_value
      ) then
        raise exception '% · % 점수는 허용 단계 % 중 하나여야 합니다 (입력값: %).',
          v_question ->> 'label', v_criterion ->> 'label', v_criterion -> 'scoreValues', v_value
          using errcode = '23514';
      end if;

      v_question_total := v_question_total + v_value;
    end loop;

    if v_question_total > (v_rule ->> 'each')::numeric then
      raise exception '% 총점은 문항당 %점을 초과할 수 없습니다 (입력 합계: %).',
        v_question ->> 'label', v_rule ->> 'each', v_question_total using errcode = '23514';
    end if;

    v_question_totals := v_question_totals || jsonb_build_object(v_question_id, v_question_total);
    v_total := v_total + v_question_total;
  end loop;

  if v_total > (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '위원별 글쓰기 총점은 %점을 초과할 수 없습니다 (입력 합계: %).',
      v_params ->> 'perEvaluatorMax', v_total using errcode = '23514';
  end if;

  return jsonb_build_object(
    'total', v_total,
    'questionTotals', v_question_totals,
    'valid', p_require_complete
  );
end;
$$;

revoke all on function public._m5d_writing_params(uuid) from public, anon, authenticated;
revoke all on function public._m5d_require_writing_user(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5d_require_writer(uuid) from public, anon, authenticated;
revoke all on function public._m5d_validate_and_total(uuid, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 4. 글쓰기 계획 validator / admin RPC
-- ============================================================

create or replace function public._m5d_validate_writing_plan(
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
  v_round record;
  v_plan record;
  v_candidate_count int := 0;
  v_member_count int := 0;
  v_missing_answer_count int := 0;
  v_invalid_member_count int := 0;
  v_issues jsonb := '[]'::jsonb;
begin
  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;
  if not found then
    return jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object(
        'code', 'PLAN_MISSING', 'message', '글쓰기 평가계획 draft가 없습니다.'
      )),
      'candidateCount', 0, 'memberCount', 0, 'missingAnswerCount', 0
    );
  end if;

  if v_round.document_decision_run_id is null then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_FINAL_MISSING', 'message', '확정된 M4 1차 사정 run이 없습니다.'
    ));
  elsif v_plan.document_source_run_id <> v_round.document_decision_run_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_SOURCE_STALE', 'message', '글쓰기 계획의 1차 합격자 기준 run이 현재 확정 run과 다릅니다. 계획을 다시 저장하세요.'
    ));
  end if;

  if v_plan.config_revision_id <> v_round.config_revision_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CONFIG_SOURCE_STALE', 'message', '글쓰기 계획의 배점 config revision이 현재 전형 config와 다릅니다. 최종확정 전 계획을 다시 저장하세요.'
    ));
  end if;

  perform public._m5d_writing_params(v_plan.config_revision_id);

  select count(*)::int into v_candidate_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  if v_candidate_count = 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CANDIDATE_MISSING', 'message', 'M4 final 합격자가 없어 글쓰기 평가계획을 확정할 수 없습니다.'
    ));
  end if;

  select count(*)::int into v_member_count
  from public.writing_plan_members m
  where m.year = p_year and m.round = p_round;
  if v_member_count <> 2 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'WRITING_MEMBER_COUNT', 'message', format('글쓰기 평가위원은 정확히 2명이어야 합니다 (현재 %s명).', v_member_count)
    ));
  end if;

  select count(*)::int into v_invalid_member_count
  from public.writing_plan_members m
  left join public.users u on u.id = m.evaluator_uid
  where m.year = p_year and m.round = p_round
    and (
      u.id is null or u.active = false
      or not ('evaluator' = any(u.roles))
      or not ('writing' = any(u.assigned_areas))
      or not (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      or not (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    );
  if v_invalid_member_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_WRITING_MEMBER', 'message', format('writing evaluator 권한·scope가 유효하지 않은 위원이 %s명 있습니다.', v_invalid_member_count)
    ));
  end if;

  select count(*)::int into v_missing_answer_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed'
    and not exists (
      select 1 from public.admission_documents d
      where d.applicant_id = dr.applicant_id
        and d.document_type = 'writingAnswer'
        and d.active = true
        and d.classification = 'evaluation'
        and 'writing'::evaluation_area = any(d.access_areas)
    );
  if v_missing_answer_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'WRITING_ANSWER_MISSING', 'message', format('평가용 글쓰기 답안이 준비되지 않은 1차 합격자가 %s명 있습니다.', v_missing_answer_count)
    ));
  end if;

  return jsonb_build_object(
    'complete', jsonb_array_length(v_issues) = 0,
    'blockingIssues', v_issues,
    'status', v_plan.status,
    'revision', v_plan.revision,
    'documentSourceRunId', v_plan.document_source_run_id,
    'configRevisionId', v_plan.config_revision_id,
    'candidateCount', v_candidate_count,
    'memberCount', v_member_count,
    'missingAnswerCount', v_missing_answer_count
  );
end;
$$;

revoke all on function public._m5d_validate_writing_plan(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5d_writing_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  return public._m5d_validate_writing_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5d_writing_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5d_writing_plan(int, admission_round) to authenticated;

create or replace function public.get_m5d_writing_plan_admin(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_plan_config_revision_id uuid;
  v_validation jsonb;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select config_revision_id into v_plan_config_revision_id
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;

  if found then
    v_validation := public._m5d_validate_writing_plan(p_year, p_round);
  else
    v_validation := jsonb_build_object('complete', false, 'blockingIssues', '[]'::jsonb, 'status', null, 'revision', 0);
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'config', case
      when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null
      else public._m5d_writing_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id))
    end,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id,
        'displayName', u.display_name,
        'email', u.email
      ) order by u.display_name, u.email)
      from public.users u
      where u.active = true
        and 'evaluator' = any(u.roles)
        and 'writing' = any(u.assigned_areas)
        and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
        and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    ), '[]'::jsonb),
    'memberUids', coalesce((
      select jsonb_agg(m.evaluator_uid order by m.member_slot)
      from public.writing_plan_members m
      where m.year = p_year and m.round = p_round
    ), '[]'::jsonb),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'documentScore', dr.total_score,
        'answerDocumentId', answer_doc.id,
        'answerVersion', answer_doc.version
      ) order by dr.rank, er.exam_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      left join lateral (
        select d.id, d.version
        from public.admission_documents d
        where d.applicant_id = dr.applicant_id
          and d.document_type = 'writingAnswer'
          and d.active = true
          and d.classification = 'evaluation'
          and 'writing'::evaluation_area = any(d.access_areas)
        order by d.version desc, d.uploaded_at desc
        limit 1
      ) answer_doc on true
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb),
    'validation', v_validation
  );
end;
$$;

revoke all on function public.get_m5d_writing_plan_admin(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_plan_admin(int, admission_round) to authenticated;

create or replace function public.save_m5d_writing_plan(
  p_year int,
  p_round admission_round,
  p_member_uids jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_existing_status text;
  v_member_text text;
  v_member_order bigint;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  if jsonb_typeof(p_member_uids) is distinct from 'array' then
    raise exception 'memberUids는 JSON array여야 합니다.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_member_uids) > 2 then
    raise exception '글쓰기 평가위원은 최대 2명까지만 저장할 수 있습니다.' using errcode = '23514';
  end if;
  if (select count(*) from jsonb_array_elements_text(p_member_uids)) <>
     (select count(distinct value) from jsonb_array_elements_text(p_member_uids)) then
    raise exception '같은 글쓰기 평가위원을 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  perform public._m5d_writing_params(v_round.config_revision_id);

  select status into v_existing_status
  from public.writing_evaluation_plans
  where year = p_year and round = p_round
  for update;
  if found and v_existing_status = 'finalized' then
    raise exception '이미 최종확정된 글쓰기 평가계획입니다. 대체위원 지정은 별도 superadmin RPC를 사용하세요.' using errcode = '55000';
  end if;

  insert into public.writing_evaluation_plans
    (year, round, status, document_source_run_id, config_revision_id, revision, created_by, updated_by)
  values
    (p_year, p_round, 'draft', v_round.document_decision_run_id, v_round.config_revision_id, 1, caller::text, caller::text)
  on conflict (year, round) do update set
    status = 'draft',
    document_source_run_id = excluded.document_source_run_id,
    config_revision_id = excluded.config_revision_id,
    revision = public.writing_evaluation_plans.revision + 1,
    updated_at = now(),
    updated_by = caller::text;

  delete from public.writing_plan_members
  where year = p_year and round = p_round;

  for v_member_text, v_member_order in
    select value, ordinality
    from jsonb_array_elements_text(p_member_uids) with ordinality
  loop
    insert into public.writing_plan_members
      (year, round, evaluator_uid, member_slot)
    values
      (p_year, p_round, trim(v_member_text)::uuid, v_member_order::smallint);
  end loop;

  v_validation := public._m5d_validate_writing_plan(p_year, p_round);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.saved', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing',
     jsonb_build_object('memberCount', jsonb_array_length(p_member_uids), 'complete', v_validation -> 'complete'));

  return v_validation || jsonb_build_object('status', 'draft');
end;
$$;

revoke all on function public.save_m5d_writing_plan(int, admission_round, jsonb) from public, anon;
grant execute on function public.save_m5d_writing_plan(int, admission_round, jsonb) to authenticated;

create or replace function public.finalize_m5d_writing_plan(
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
  v_plan_status text;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  select status into v_plan_status
  from public.writing_evaluation_plans
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception '최종확정할 글쓰기 평가계획 draft가 없습니다.' using errcode = 'P0002';
  end if;
  if v_plan_status = 'finalized' then
    raise exception '이미 최종확정된 글쓰기 평가계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5d_validate_writing_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '글쓰기 평가계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.writing_evaluation_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.finalized', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing',
     jsonb_build_object('candidateCount', v_validation -> 'candidateCount', 'memberCount', v_validation -> 'memberCount'));

  return public._m5d_validate_writing_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5d_writing_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5d_writing_plan(int, admission_round) to authenticated;

-- ============================================================
-- 5. writingAnswer 문서 접근을 finalized plan membership까지 제한
-- ============================================================

create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' then
    return public.has_role('reception');
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = auth.uid() and u.assigned_areas && p_doc_access_areas
  ) then
    return false;
  end if;

  if p_document_type = 'writingAnswer' then
    return public.has_role('evaluator')
      and public.has_area('writing')
      and exists (
        select 1
        from public.evaluation_roster er
        join public.writing_evaluation_plans p
          on p.year = er.year and p.round = er.round and p.status = 'finalized'
        join public.writing_plan_members m
          on m.year = p.year and m.round = p.round and m.evaluator_uid = auth.uid()
        join public.decision_results dr
          on dr.run_id = p.document_source_run_id
         and dr.applicant_id = er.applicant_id
         and dr.outcome = 'passed'
        where er.applicant_id = p_applicant_id
      );
  end if;

  return true;
end;
$$;

revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

drop policy if exists admission_documents_select_by_classification on public.admission_documents;
create policy admission_documents_select_by_classification
  on public.admission_documents for select
  using (public._can_access_document_v2(applicant_id, document_type, classification, access_areas));

drop policy if exists admission_documents_storage_select on storage.objects;
create policy admission_documents_storage_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'admission-documents'
    and exists (
      select 1 from public.admission_documents d
      where d.storage_path = storage.objects.name
        and d.active = true
        and public._can_access_document_v2(d.applicant_id, d.document_type, d.classification, d.access_areas)
    )
  );

create or replace function public.log_document_view(p_document_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  doc record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select * into doc
  from public.admission_documents
  where id = p_document_id and active = true;
  if not found then
    raise exception '문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if not public._can_access_document_v2(doc.applicant_id, doc.document_type, doc.classification, doc.access_areas) then
    raise exception '이 문서에 접근할 권한이 없습니다.' using errcode = '42501';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.viewed', 'admission_documents',
     doc.id::text, doc.applicant_id::text,
     case when array_length(doc.access_areas, 1) = 1 then doc.access_areas[1] else null end);

  return json_build_object('storagePath', doc.storage_path, 'documentType', doc.document_type);
end;
$$;

revoke execute on function public.log_document_view(uuid) from anon;

-- ============================================================
-- 6. evaluator workspace / draft / submit
-- ============================================================

create or replace function public.get_m5d_writing_workspace(
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
  v_round record;
  v_plan record;
  v_config jsonb;
  v_candidates jsonb;
begin
  caller := public._m5d_require_writing_user(p_year, p_round);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select p.* into v_plan
  from public.writing_evaluation_plans p
  join public.writing_plan_members m
    on m.year = p.year and m.round = p.round
  where p.year = p_year and p.round = p_round
    and p.status = 'finalized'
    and m.evaluator_uid = caller;
  if not found then
    raise exception '현재 평가자에게 최종확정된 글쓰기 평가 배정이 없습니다.' using errcode = '42501';
  end if;

  v_config := public._m5d_writing_params(v_plan.config_revision_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', er.applicant_id,
    'examNo', er.exam_no,
    'displayName', er.display_name,
    'rankOrder', dr.rank,
    'answerDocument', case when answer_doc.id is null then null else jsonb_build_object(
      'documentId', answer_doc.id,
      'version', answer_doc.version,
      'mimeType', answer_doc.mime_type
    ) end,
    'myScore', case when sw.id is null then null else jsonb_build_object(
      'scoreId', sw.id,
      'responses', sw.responses,
      'memo', sw.memo,
      'submissionState', sw.submission_state,
      'revision', sw.revision,
      'serverComputed', sw.server_computed,
      'clientUpdatedAt', sw.client_updated_at,
      'submittedAt', sw.submitted_at
    ) end
  ) order by dr.rank, er.exam_no, er.display_name), '[]'::jsonb)
  into v_candidates
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  left join lateral (
    select d.id, d.version, d.mime_type
    from public.admission_documents d
    where d.applicant_id = dr.applicant_id
      and d.document_type = 'writingAnswer'
      and d.active = true
      and d.classification = 'evaluation'
      and 'writing'::evaluation_area = any(d.access_areas)
    order by d.version desc, d.uploaded_at desc
    limit 1
  ) answer_doc on true
  left join public.scores_writing sw
    on sw.applicant_id = dr.applicant_id and sw.evaluator_uid = caller
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'serverNow', now(),
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'configRevisionId', v_plan.config_revision_id,
    'config', v_config,
    'candidates', v_candidates
  );
end;
$$;

revoke all on function public.get_m5d_writing_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_workspace(int, admission_round) to authenticated;

create or replace function public.save_writing_score_draft(
  p_applicant_id uuid,
  p_responses jsonb,
  p_memo text,
  p_client_updated_at timestamptz
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
  v_config_revision_id uuid;
  v_existing public.scores_writing%rowtype;
  v_computed jsonb;
  v_accepted boolean := true;
  v_current_total numeric;
  v_current_client_updated_at timestamptz;
begin
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '글쓰기 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5d_require_writer(p_applicant_id);

  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

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

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:score:%s:%s', p_applicant_id::text, caller::text), 0));
  v_computed := public._m5d_validate_and_total(v_config_revision_id, p_responses, false);

  select * into v_existing
  from public.scores_writing
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 글쓰기 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing.id is not null
     and v_existing.client_updated_at is not null
     and v_existing.client_updated_at >= p_client_updated_at then
    v_accepted := false;
    v_current_total := (v_existing.server_computed ->> 'total')::numeric;
    v_current_client_updated_at := v_existing.client_updated_at;
  else
    insert into public.scores_writing
      (applicant_id, evaluator_uid, year, round, config_revision_id,
       responses, memo, server_computed, submission_state, revision, client_updated_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id,
       p_responses, p_memo, v_computed, 'draft', 1, p_client_updated_at)
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      responses = excluded.responses,
      memo = excluded.memo,
      server_computed = excluded.server_computed,
      submission_state = 'draft',
      revision = public.scores_writing.revision + 1,
      client_updated_at = excluded.client_updated_at,
      submitted_at = null,
      updated_at = now();
    v_current_total := (v_computed ->> 'total')::numeric;
    v_current_client_updated_at := p_client_updated_at;
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'draftTotal', v_current_total,
    'serverClientUpdatedAt', v_current_client_updated_at,
    'submissionState', coalesce((
      select submission_state from public.scores_writing
      where applicant_id = p_applicant_id and evaluator_uid = caller
    ), 'draft'),
    'serverDraft', jsonb_build_object(
      'responses', coalesce((
        select responses from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ), '[]'::jsonb),
      'memo', (
        select memo from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ),
      'revision', coalesce((
        select revision from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ), 0)
    )
  );
end;
$$;

revoke all on function public.save_writing_score_draft(uuid, jsonb, text, timestamptz) from public, anon;
grant execute on function public.save_writing_score_draft(uuid, jsonb, text, timestamptz) to authenticated;

create or replace function public.submit_writing_score(
  p_applicant_id uuid,
  p_responses jsonb,
  p_memo text
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
  v_config_revision_id uuid;
  v_existing public.scores_writing%rowtype;
  v_computed jsonb;
  v_score_id uuid;
  v_revision int;
begin
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '글쓰기 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5d_require_writer(p_applicant_id);

  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

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

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:score:%s:%s', p_applicant_id::text, caller::text), 0));

  select * into v_existing
  from public.scores_writing
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 글쓰기 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  v_computed := public._m5d_validate_and_total(v_config_revision_id, p_responses, true);

  insert into public.scores_writing
    (applicant_id, evaluator_uid, year, round, config_revision_id,
     responses, memo, server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, caller, v_year, v_round, v_config_revision_id,
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
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.writing.submitted', 'scores_writing',
     v_score_id::text, p_applicant_id::text, 'writing', jsonb_build_object('revision', v_revision));

  return jsonb_build_object(
    'scoreId', v_score_id,
    'total', (v_computed ->> 'total')::numeric,
    'questionTotals', v_computed -> 'questionTotals',
    'submissionState', 'submitted',
    'revision', v_revision
  );
end;
$$;

revoke all on function public.submit_writing_score(uuid, jsonb, text) from public, anon;
grant execute on function public.submit_writing_score(uuid, jsonb, text) to authenticated;

-- ============================================================
-- 7. aggregate / trigger / alerts
-- ============================================================

create or replace function public._compute_writing_aggregate(
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_params jsonb;
  v_required int;
  v_submitted int;
  v_average numeric;
  v_gap numeric;
  v_score numeric;
  v_summary jsonb;
begin
  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';

  if v_config_revision_id is null then
    return jsonb_build_object(
      'complete', false, 'score', null, 'required', null, 'submitted', 0,
      'gap', null, 'sourceRevisionSummary', '[]'::jsonb,
      'functionVersion', 'm5d-writing-aggregate-v1'
    );
  end if;

  v_params := public._m5d_writing_params(v_config_revision_id);
  v_required := (v_params ->> 'requiredSubmissions')::int;

  select count(*)::int,
         avg((sw.server_computed ->> 'total')::numeric),
         max((sw.server_computed ->> 'total')::numeric) - min((sw.server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', sw.id,
           'evaluatorUid', sw.evaluator_uid,
           'revision', sw.revision
         ) order by sw.evaluator_uid), '[]'::jsonb)
    into v_submitted, v_average, v_gap, v_summary
  from public.scores_writing sw
  join public.writing_plan_members m
    on m.year = v_year and m.round = v_round and m.evaluator_uid = sw.evaluator_uid
  where sw.applicant_id = p_applicant_id
    and sw.submission_state = 'submitted'
    and coalesce((sw.server_computed ->> 'valid')::boolean, false) = true
    and sw.config_revision_id = v_config_revision_id;

  if v_submitted < v_required then
    v_score := null;
  else
    v_score := least((v_params ->> 'max')::numeric, v_average);
  end if;

  return jsonb_build_object(
    'complete', v_submitted >= v_required,
    'score', v_score,
    'required', v_required,
    'submitted', v_submitted,
    'gap', case when v_submitted >= 2 then v_gap else null end,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm5d-writing-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_writing_aggregate(
  p_applicant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_agg jsonb;
  v_params jsonb;
  v_gap numeric;
  v_related uuid[];
begin
  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    delete from public.deep_writing_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';
  if v_config_revision_id is null then
    delete from public.deep_writing_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  v_agg := public._compute_writing_aggregate(p_applicant_id);

  insert into public.deep_writing_aggregates
    (applicant_id, year, round, config_revision_id, complete, score, required, submitted, gap,
     source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_year, v_round, v_config_revision_id,
     (v_agg ->> 'complete')::boolean,
     nullif(v_agg ->> 'score', '')::numeric,
     (v_agg ->> 'required')::int,
     (v_agg ->> 'submitted')::int,
     nullif(v_agg ->> 'gap', '')::numeric,
     v_agg -> 'sourceRevisionSummary', v_agg ->> 'functionVersion', now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    complete = excluded.complete,
    score = excluded.score,
    required = excluded.required,
    submitted = excluded.submitted,
    gap = excluded.gap,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = excluded.computed_at;

  v_params := public._m5d_writing_params(v_config_revision_id);
  v_gap := nullif(v_agg ->> 'gap', '')::numeric;

  select coalesce(array_agg(distinct sw.evaluator_uid), '{}'::uuid[])
    into v_related
  from public.scores_writing sw
  join public.writing_plan_members m
    on m.year = v_year and m.round = v_round and m.evaluator_uid = sw.evaluator_uid
  where sw.applicant_id = p_applicant_id and sw.submission_state = 'submitted';

  if v_gap is not null and v_gap >= (v_params ->> 'alertGap')::numeric then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
    values
      (v_year, v_round, p_applicant_id, 'writing', 'scoreGap', 'warning',
       format('글쓰기 위원 간 총점 편차 %s점(기준 %s)', v_gap, v_params ->> 'alertGap'), v_related)
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      related_evaluator_uids = excluded.related_evaluator_uids,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5d'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'writing' and alert_type = 'scoreGap' and status <> 'resolved';
  end if;

  if (v_agg ->> 'submitted')::int < (v_agg ->> 'required')::int then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary)
    values
      (v_year, v_round, p_applicant_id, 'writing', 'missingSubmission', 'warning',
       format('글쓰기 제출 %s/%s', v_agg ->> 'submitted', v_agg ->> 'required'))
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5d'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'writing' and alert_type = 'missingSubmission' and status <> 'resolved';
  end if;
end;
$$;

create or replace function public._trg_refresh_writing_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_writing_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_writing_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._compute_writing_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_writing_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_writing_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_writing_aggregate on public.scores_writing;
create trigger trg_refresh_writing_aggregate
  after insert or update or delete on public.scores_writing
  for each row execute function public._trg_refresh_writing_aggregate();

-- ============================================================
-- 8. 관리자 진행현황 / 재개방 / 대체위원
-- ============================================================

create or replace function public.get_m5d_writing_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'complete', coalesce(a.complete, false),
        'score', a.score,
        'required', a.required,
        'submitted', coalesce(a.submitted, 0),
        'gapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'writing'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
        ),
        'computedAt', a.computed_at
      ) order by dr.rank, er.exam_no, er.display_name)
      from public.writing_evaluation_plans p
      join public.decision_results dr
        on dr.run_id = p.document_source_run_id and dr.outcome = 'passed'
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      left join public.deep_writing_aggregates a on a.applicant_id = er.applicant_id
      where p.year = p_year and p.round = p_round and p.status = 'finalized'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5d_writing_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_progress(int, admission_round) to authenticated;

create or replace function public.reopen_writing_score(
  p_score_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_score public.scores_writing%rowtype;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '재개방 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  select * into v_score
  from public.scores_writing
  where id = p_score_id
  for update;
  if not found then
    raise exception '글쓰기 채점 문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_score.submission_state <> 'submitted' then
    raise exception 'submitted 상태의 글쓰기 채점만 재개방할 수 있습니다.' using errcode = '55000';
  end if;

  update public.scores_writing
  set submission_state = 'reopened',
      revision = revision + 1,
      submitted_at = null,
      updated_at = now()
  where id = p_score_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_score.year, v_score.round, 'user', caller::text, 'score.writing.reopened', 'scores_writing',
     p_score_id::text, v_score.applicant_id::text, 'writing', '관리자 재개방',
     jsonb_build_object('reason', p_reason, 'evaluatorUid', v_score.evaluator_uid));

  return jsonb_build_object('scoreId', p_score_id, 'submissionState', 'reopened');
end;
$$;

revoke all on function public.reopen_writing_score(uuid, text) from public, anon;
grant execute on function public.reopen_writing_score(uuid, text) to authenticated;

create or replace function public.replace_m5d_writing_evaluator(
  p_old_evaluator_uid uuid,
  p_new_evaluator_uid uuid,
  p_year int,
  p_round admission_round,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_slot smallint;
  v_applicant_id uuid;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '대체위원 지정 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  if not exists (
    select 1 from public.writing_evaluation_plans p
    where p.year = p_year and p.round = p_round and p.status = 'finalized'
  ) then
    raise exception '최종확정된 글쓰기 평가계획이 없습니다.' using errcode = '55000';
  end if;

  select member_slot into v_slot
  from public.writing_plan_members
  where year = p_year and round = p_round and evaluator_uid = p_old_evaluator_uid
  for update;
  if not found then
    raise exception '기존 글쓰기 평가위원을 계획에서 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if p_old_evaluator_uid = p_new_evaluator_uid then
    raise exception '기존 위원과 대체 위원이 같습니다.' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.writing_plan_members
    where year = p_year and round = p_round and evaluator_uid = p_new_evaluator_uid
  ) then
    raise exception '대체 위원은 이미 해당 글쓰기 계획에 배정되어 있습니다.' using errcode = '23514';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_new_evaluator_uid
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'writing' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '대체 평가위원의 evaluator/writing/scope 권한이 유효하지 않습니다.' using errcode = '42501';
  end if;

  update public.writing_plan_members
  set evaluator_uid = p_new_evaluator_uid
  where year = p_year and round = p_round and member_slot = v_slot;

  for v_applicant_id in
    select dr.applicant_id
    from public.writing_evaluation_plans p
    join public.decision_results dr
      on dr.run_id = p.document_source_run_id and dr.outcome = 'passed'
    where p.year = p_year and p.round = p_round
  loop
    perform public._refresh_writing_aggregate(v_applicant_id);
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, reason_code, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.member_replaced', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing', '대체 평가위원 지정',
     jsonb_build_object('oldEvaluatorUid', p_old_evaluator_uid, 'newEvaluatorUid', p_new_evaluator_uid, 'slot', v_slot, 'reason', p_reason));

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'memberSlot', v_slot,
    'oldEvaluatorUid', p_old_evaluator_uid,
    'newEvaluatorUid', p_new_evaluator_uid
  );
end;
$$;

revoke all on function public.replace_m5d_writing_evaluator(uuid, uuid, int, admission_round, text) from public, anon;
grant execute on function public.replace_m5d_writing_evaluator(uuid, uuid, int, admission_round, text) to authenticated;

-- ============================================================
-- 9. migration self-verification
-- ============================================================

do $m5d_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regclass('public.writing_evaluation_plans') is null then missing_objects := array_append(missing_objects, 'table:writing_evaluation_plans'); end if;
  if to_regclass('public.writing_plan_members') is null then missing_objects := array_append(missing_objects, 'table:writing_plan_members'); end if;
  if to_regclass('public.scores_writing') is null then missing_objects := array_append(missing_objects, 'table:scores_writing'); end if;
  if to_regclass('public.deep_writing_aggregates') is null then missing_objects := array_append(missing_objects, 'table:deep_writing_aggregates'); end if;

  if to_regprocedure('public._m5d_writing_params(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_writing_params(uuid)'); end if;
  if to_regprocedure('public._m5d_validate_and_total(uuid,jsonb,boolean)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_validate_and_total(uuid,jsonb,boolean)'); end if;
  if to_regprocedure('public._m5d_validate_writing_plan(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_validate_writing_plan'); end if;
  if to_regprocedure('public.get_m5d_writing_workspace(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'rpc:get_m5d_writing_workspace'); end if;
  if to_regprocedure('public.save_writing_score_draft(uuid,jsonb,text,timestamp with time zone)') is null then missing_objects := array_append(missing_objects, 'rpc:save_writing_score_draft'); end if;
  if to_regprocedure('public.submit_writing_score(uuid,jsonb,text)') is null then missing_objects := array_append(missing_objects, 'rpc:submit_writing_score'); end if;
  if to_regprocedure('public._compute_writing_aggregate(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_compute_writing_aggregate'); end if;
  if to_regprocedure('public._trg_refresh_writing_aggregate()') is null then missing_objects := array_append(missing_objects, 'function:_trg_refresh_writing_aggregate'); end if;
  if to_regprocedure('public._can_access_document_v2(uuid,document_type,document_classification,evaluation_area[])') is null then missing_objects := array_append(missing_objects, 'function:_can_access_document_v2'); end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_writing'
      and t.tgname = 'trg_refresh_writing_aggregate'
      and not t.tgisinternal
  ) then
    missing_objects := array_append(missing_objects, 'trigger:trg_refresh_writing_aggregate');
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'admission_documents'
      and policyname = 'admission_documents_select_by_classification'
      and qual like '%_can_access_document_v2%'
  ) then
    missing_objects := array_append(missing_objects, 'policy:admission_documents_select_by_classification:v2');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5D_00013_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5d_verify$;

commit;

select
  'M5D_00013_APPLIED'::text as migration_status,
  to_regprocedure('public._m5d_writing_params(uuid)') is not null as helper_present,
  to_regclass('public.scores_writing') is not null as score_table_present,
  exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_writing'
      and t.tgname = 'trg_refresh_writing_aggregate'
      and not t.tgisinternal
  ) as aggregate_trigger_present,
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'admission_documents'
      and policyname = 'admission_documents_select_by_classification'
      and qual like '%_can_access_document_v2%'
  ) as writing_document_rls_hardened;

-- ======================================================================
-- 00014_m5e_paper_backup.sql
-- ======================================================================

begin;

-- 새봄고 입학전형 시스템 — M5e 심층역량평가 종이 백업/인쇄 패킷
-- 마스터 스펙 v1.2 섹션 1.3, M5e 대응.
--
-- 핵심 불변조건
--   1) 종이 백업 패킷은 superadmin/admin만 생성한다.
--   2) M4 final passed snapshot의 수험번호·성명만 사용하고 연락처/주소/사정점수/개별 평가점수는 포함하지 않는다.
--   3) 모둠·면접·글쓰기 계획의 finalized/source snapshot 상태를 서버가 ready로 판정한다.
--   4) 미확정 계획도 관리자 레이아웃 미리보기용 packet은 조회할 수 있으나, 운영용 print logging은 ready=true에서만 허용한다.
--   5) 평가 기준은 실제 채점 서버가 사용하는 config revision에서 읽어 종이표와 전자 채점 기준의 drift를 막는다.
--   6) packet 조회/운영용 인쇄 요청은 audit_logs에 원문 평가자료 없이 최소 메타데이터만 기록한다.

-- ============================================================
-- 1. 백업 준비상태 조회
-- ============================================================

create or replace function public.get_m5e_paper_backup_status(
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
  v_round public.admission_rounds%rowtype;
  v_group_plan public.deep_group_plans%rowtype;
  v_interview_plan public.interview_team_plans%rowtype;
  v_writing_plan public.writing_evaluation_plans%rowtype;
  v_group_validation jsonb;
  v_interview_validation jsonb;
  v_writing_validation jsonb;
  v_candidate_count int := 0;
  v_group_ready boolean := false;
  v_interview_ready boolean := false;
  v_writing_ready boolean := false;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_round.document_decision_run_id is not null then
    select count(*)::int into v_candidate_count
    from public.decision_results dr
    where dr.run_id = v_round.document_decision_run_id
      and dr.outcome = 'passed';
  end if;

  select * into v_group_plan
  from public.deep_group_plans
  where year = p_year and round = p_round;
  if found then
    v_group_validation := public.validate_m5a_group_plan(p_year, p_round);
    v_group_ready := v_group_plan.status = 'finalized'
      and v_group_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_group_validation ->> 'complete')::boolean, false);
  else
    v_group_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '모둠편성 계획이 없습니다.'))
    );
  end if;

  select * into v_interview_plan
  from public.interview_team_plans
  where year = p_year and round = p_round;
  if found then
    v_interview_validation := public.validate_m5c_interview_plan(p_year, p_round);
    v_interview_ready := v_interview_plan.status = 'finalized'
      and v_interview_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_interview_validation ->> 'complete')::boolean, false);
  else
    v_interview_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '면접조 계획이 없습니다.'))
    );
  end if;

  select * into v_writing_plan
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;
  if found then
    v_writing_validation := public.validate_m5d_writing_plan(p_year, p_round);
    v_writing_ready := v_writing_plan.status = 'finalized'
      and v_writing_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_writing_validation ->> 'complete')::boolean, false);
  else
    v_writing_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '글쓰기 평가계획이 없습니다.'))
    );
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', v_candidate_count,
    'group', jsonb_build_object(
      'ready', v_group_ready,
      'status', v_group_plan.status,
      'planRevision', v_group_plan.revision,
      'documentSourceRunId', v_group_plan.document_source_run_id,
      'sourceMatches', v_group_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_group_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'interview', jsonb_build_object(
      'ready', v_interview_ready,
      'status', v_interview_plan.status,
      'planRevision', v_interview_plan.revision,
      'documentSourceRunId', v_interview_plan.document_source_run_id,
      'configRevisionId', v_interview_plan.config_revision_id,
      'sourceMatches', v_interview_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_interview_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'writing', jsonb_build_object(
      'ready', v_writing_ready,
      'status', v_writing_plan.status,
      'planRevision', v_writing_plan.revision,
      'documentSourceRunId', v_writing_plan.document_source_run_id,
      'configRevisionId', v_writing_plan.config_revision_id,
      'sourceMatches', v_writing_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_writing_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'allReady', v_group_ready and v_interview_ready and v_writing_ready,
    'checkedAt', now()
  );
end;
$$;

revoke all on function public.get_m5e_paper_backup_status(int, admission_round) from public, anon;
grant execute on function public.get_m5e_paper_backup_status(int, admission_round) to authenticated;

-- ============================================================
-- 2. 영역별 인쇄 패킷 조회
-- ============================================================

create or replace function public.get_m5e_paper_backup_packet(
  p_year int,
  p_round admission_round,
  p_area text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round public.admission_rounds%rowtype;
  v_status jsonb;
  v_area_status jsonb;
  v_payload jsonb;
  v_group_params jsonb;
  v_plan_config_revision_id uuid;
  v_candidate_count int := 0;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('group', 'interview', 'writing') then
    raise exception 'paper backup area는 group, interview, writing 중 하나여야 합니다: %', p_area using errcode = '22023';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정 run이 없습니다. 종이 백업 대상 명단을 확정할 수 없습니다.' using errcode = '55000';
  end if;

  v_status := public.get_m5e_paper_backup_status(p_year, p_round);
  v_area_status := v_status -> p_area;
  v_candidate_count := coalesce((v_status ->> 'candidateCount')::int, 0);

  if p_area = 'group' then
    v_group_params := public._m5b_group_params(v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_round.config_revision_id,
      'config', v_group_params,
      'evaluators', coalesce(jsonb_agg(evaluator_packet order by evaluator_packet ->> 'displayName', evaluator_packet ->> 'evaluatorUid'), '[]'::jsonb)
    ) into v_payload
    from (
      select jsonb_build_object(
        'evaluatorUid', u.id,
        'displayName', u.display_name,
        'email', u.email,
        'groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'groupId', g.id,
            'groupCode', g.group_code,
            'sortOrder', g.sort_order,
            'observerRole', case when exists (
              select 1 from public.deep_group_primary_observers po
              where po.group_id = g.id and po.evaluator_uid = u.id
            ) then 'primary' else 'roving' end,
            'plannedSegments', coalesce((
              select jsonb_agg(jsonb_build_object(
                'segmentId', s.id,
                'segmentCode', s.segment_code,
                'startsAt', s.starts_at,
                'endsAt', s.ends_at,
                'sortOrder', s.sort_order
              ) order by s.sort_order, s.starts_at)
              from public.deep_group_rotation_assignments ra
              join public.deep_group_rotation_segments s on s.id = ra.segment_id
              where ra.evaluator_uid = u.id
                and ra.target_group_id = g.id
                and ra.year = p_year and ra.round = p_round
            ), '[]'::jsonb),
            'members', coalesce((
              select jsonb_agg(jsonb_build_object(
                'applicantId', er.applicant_id,
                'examNo', er.exam_no,
                'displayName', er.display_name,
                'sortOrder', gm.sort_order
              ) order by gm.sort_order, er.exam_no, er.display_name)
              from public.deep_group_members gm
              join public.evaluation_roster er on er.applicant_id = gm.applicant_id
              where gm.group_id = g.id
            ), '[]'::jsonb)
          ) order by g.sort_order, g.group_code)
          from public.deep_groups g
          where g.year = p_year and g.round = p_round and g.active = true
            and (
              exists (
                select 1 from public.deep_group_primary_observers po
                where po.group_id = g.id and po.evaluator_uid = u.id
              )
              or exists (
                select 1 from public.deep_group_rotation_assignments ra
                where ra.year = p_year and ra.round = p_round
                  and ra.evaluator_uid = u.id and ra.target_group_id = g.id
              )
            )
        ), '[]'::jsonb)
      ) as evaluator_packet
      from public.users u
      where u.id in (
        select po.evaluator_uid
        from public.deep_group_primary_observers po
        where po.year = p_year and po.round = p_round
        union
        select ra.evaluator_uid
        from public.deep_group_rotation_assignments ra
        where ra.year = p_year and ra.round = p_round
      )
    ) packets;

  elsif p_area = 'interview' then
    select config_revision_id into v_plan_config_revision_id
    from public.interview_team_plans
    where year = p_year and round = p_round;
    v_plan_config_revision_id := coalesce(v_plan_config_revision_id, v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_plan_config_revision_id,
      'student', public._m5c_interview_params(v_plan_config_revision_id, 'student'::text),
      'parent', public._m5c_interview_params(v_plan_config_revision_id, 'parent'::text),
      'teams', coalesce(jsonb_agg(jsonb_build_object(
        'teamId', t.id,
        'teamCode', t.team_code,
        'location', t.location,
        'sortOrder', t.sort_order,
        'members', coalesce((
          select jsonb_agg(jsonb_build_object(
            'evaluatorUid', m.evaluator_uid,
            'displayName', u.display_name,
            'email', u.email,
            'memberSlot', m.member_slot
          ) order by m.member_slot)
          from public.interview_team_members m
          join public.users u on u.id = m.evaluator_uid
          where m.team_id = t.id
        ), '[]'::jsonb),
        'schedule', coalesce((
          select jsonb_agg(jsonb_build_object(
            'scheduleId', s.id,
            'applicantId', er.applicant_id,
            'examNo', er.exam_no,
            'displayName', er.display_name,
            'studentStartsAt', s.student_starts_at,
            'studentEndsAt', s.student_ends_at,
            'parentStartsAt', s.parent_starts_at,
            'parentEndsAt', s.parent_ends_at,
            'sortOrder', s.sort_order
          ) order by s.sort_order, s.student_starts_at, er.exam_no)
          from public.interview_schedules s
          join public.evaluation_roster er on er.applicant_id = s.applicant_id
          where s.team_id = t.id
        ), '[]'::jsonb)
      ) order by t.sort_order, t.team_code), '[]'::jsonb)
    ) into v_payload
    from public.interview_teams t
    where t.year = p_year and t.round = p_round and t.active = true;

  else
    select config_revision_id into v_plan_config_revision_id
    from public.writing_evaluation_plans
    where year = p_year and round = p_round;
    v_plan_config_revision_id := coalesce(v_plan_config_revision_id, v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_plan_config_revision_id,
      'config', public._m5d_writing_params(v_plan_config_revision_id),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'evaluatorUid', m.evaluator_uid,
          'displayName', u.display_name,
          'email', u.email,
          'memberSlot', m.member_slot
        ) order by m.member_slot)
        from public.writing_plan_members m
        join public.users u on u.id = m.evaluator_uid
        where m.year = p_year and m.round = p_round
      ), '[]'::jsonb),
      'candidates', coalesce((
        select jsonb_agg(jsonb_build_object(
          'applicantId', er.applicant_id,
          'examNo', er.exam_no,
          'displayName', er.display_name,
          'rank', dr.rank
        ) order by dr.rank, er.exam_no, er.display_name)
        from public.decision_results dr
        join public.evaluation_roster er on er.applicant_id = dr.applicant_id
        where dr.run_id = v_round.document_decision_run_id
          and dr.outcome = 'passed'
      ), '[]'::jsonb)
    ) into v_payload;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'paper_backup.packet_viewed', 'paper_backup',
     p_year::text || '_' || p_round::text || '_' || p_area,
     p_area::evaluation_area,
     jsonb_build_object(
       'area', p_area,
       'ready', coalesce((v_area_status ->> 'ready')::boolean, false),
       'candidateCount', v_candidate_count,
       'planRevision', v_area_status -> 'planRevision',
       'documentDecisionRunId', v_round.document_decision_run_id
     ));

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'generatedAt', now(),
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', v_candidate_count,
    'ready', coalesce((v_area_status ->> 'ready')::boolean, false),
    'planStatus', v_area_status ->> 'status',
    'planRevision', v_area_status -> 'planRevision',
    'blockingIssues', coalesce(v_area_status -> 'blockingIssues', '[]'::jsonb),
    'payload', coalesce(v_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5e_paper_backup_packet(int, admission_round, text) from public, anon;
grant execute on function public.get_m5e_paper_backup_packet(int, admission_round, text) to authenticated;

-- ============================================================
-- 3. 운영용 인쇄/PDF 저장 요청 감사로그
-- ============================================================

create or replace function public.log_m5e_paper_backup_print(
  p_year int,
  p_round admission_round,
  p_area text,
  p_page_count int,
  p_copy_count int default 1,
  p_mode text default 'print_dialog'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_status jsonb;
  v_area_status jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('group', 'interview', 'writing') then
    raise exception 'paper backup area는 group, interview, writing 중 하나여야 합니다: %', p_area using errcode = '22023';
  end if;
  if coalesce(p_page_count, 0) <= 0 or coalesce(p_copy_count, 0) <= 0 then
    raise exception 'pageCount와 copyCount는 1 이상이어야 합니다.' using errcode = '22023';
  end if;
  if p_mode not in ('print_dialog', 'pdf_save') then
    raise exception 'mode는 print_dialog 또는 pdf_save여야 합니다.' using errcode = '22023';
  end if;

  v_status := public.get_m5e_paper_backup_status(p_year, p_round);
  v_area_status := v_status -> p_area;
  if not coalesce((v_area_status ->> 'ready')::boolean, false) then
    raise exception 'M5E_PAPER_BACKUP_NOT_READY: % 영역 계획이 최종확정·검증 완료 상태가 아닙니다: %',
      p_area, v_area_status -> 'blockingIssues' using errcode = '55000';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'paper_backup.print_requested', 'paper_backup',
     p_year::text || '_' || p_round::text || '_' || p_area,
     p_area::evaluation_area,
     jsonb_build_object(
       'area', p_area,
       'pageCount', p_page_count,
       'copyCount', p_copy_count,
       'mode', p_mode,
       'candidateCount', v_status -> 'candidateCount',
       'planRevision', v_area_status -> 'planRevision',
       'documentDecisionRunId', v_status -> 'documentDecisionRunId'
     ));

  return jsonb_build_object(
    'logged', true,
    'area', p_area,
    'pageCount', p_page_count,
    'copyCount', p_copy_count,
    'mode', p_mode,
    'loggedAt', now()
  );
end;
$$;

revoke all on function public.log_m5e_paper_backup_print(int, admission_round, text, int, int, text) from public, anon;
grant execute on function public.log_m5e_paper_backup_print(int, admission_round, text, int, int, text) to authenticated;

-- ============================================================
-- 4. migration self-verification
-- ============================================================

do $m5e_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regprocedure('public.get_m5e_paper_backup_status(integer,admission_round)') is null then
    missing_objects := array_append(missing_objects, 'rpc:get_m5e_paper_backup_status');
  end if;
  if to_regprocedure('public.get_m5e_paper_backup_packet(integer,admission_round,text)') is null then
    missing_objects := array_append(missing_objects, 'rpc:get_m5e_paper_backup_packet');
  end if;
  if to_regprocedure('public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)') is null then
    missing_objects := array_append(missing_objects, 'rpc:log_m5e_paper_backup_print');
  end if;

  if not has_function_privilege('authenticated', 'public.get_m5e_paper_backup_status(integer,admission_round)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:status:authenticated');
  end if;
  if not has_function_privilege('authenticated', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:packet:authenticated');
  end if;
  if not has_function_privilege('authenticated', 'public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:print:authenticated');
  end if;
  if has_function_privilege('anon', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:packet:anon_should_be_revoked');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5E_00014_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5e_verify$;

commit;

select
  'M5E_00014_APPLIED'::text as migration_status,
  to_regprocedure('public.get_m5e_paper_backup_status(integer,admission_round)') is not null as status_rpc_present,
  to_regprocedure('public.get_m5e_paper_backup_packet(integer,admission_round,text)') is not null as packet_rpc_present,
  to_regprocedure('public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)') is not null as print_audit_rpc_present,
  not has_function_privilege('anon', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') as anon_packet_revoked;

-- ======================================================================
-- 00015_m6a_final_aggregate.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M6a 심층역량평가 최종 집계 (Sprint 6 시작)
-- 마스터 스펙 v1.2 섹션 5.4.1(서류평가 400점 환산), 5.4.6(최종 총점) 대응.
-- 요강 승인본(새봄고 공고 제2026-42호, 2026.7.6) "(2) 2차 심층역량평가 ① 1차 서류평가
-- 획득 점수(400점 만점): 1차 서류평가 획득 점수(1,000점 만점)의 4/10를 반영함" 근거로,
-- documentCarry는 가산점 포함·1,000점 cap 적용 후의 "1차 서류평가 점수"
-- (= decision_results.total_score, 요강이 1차 합불 판정에도 그대로 쓰는 바로 그 값)를
-- 그대로 0.4배 환산해 사용한다 (담당 교사 확인, 2026-07-08). 가산 전 원점수 별도 이월 아님.
--
-- 핵심 불변조건
--   1) documentCarry의 근거는 admission_rounds.document_decision_run_id가 가리키는
--      M4 final decisionRun의 decision_results.total_score 스냅샷만 사용한다(재계산 금지).
--   2) 심층 4영역(group/interviewStudent/interviewParent/writing) 중 하나라도 미완료면
--      finalTotal은 null이다. 미채점을 0점으로 치환하지 않는다.
--   3) 이 마이그레이션이 만드는 트리거는 scores_group/scores_interview/scores_writing
--      "제출"이라는 무관한 작업의 부작용으로 실행된다. deep.documentCarry config가
--      아직 없다는 이유로 예외를 던지면 그 무관한 제출 자체가 실패한다 — 그래서
--      config 부재는 예외가 아니라 "documentCarry 영역 자체가 미확정"으로 완만하게
--      처리한다(fail-soft). 강제 예외는 관리자가 명시적으로 호출하는
--      recompute_final_aggregates에서도 던지지 않는다 — 동일한 이유.
--   4) 클라이언트는 finalTotal을 계산하지 않는다. 이 집계는 캐시 테이블(트리거 갱신)
--      이며 M5b deep_group_aggregates와 동일한 패턴을 따른다.

-- ============================================================
-- 1. deep_final_aggregates
-- ============================================================

create table public.deep_final_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  document_decision_run_id uuid not null references public.decision_runs (id),

  document_score numeric not null,
  document_carry numeric,

  group_score numeric,
  group_complete boolean not null default false,

  interview_student_score numeric,
  interview_student_complete boolean not null default false,

  interview_parent_score numeric,
  interview_parent_complete boolean not null default false,

  writing_score numeric,
  writing_complete boolean not null default false,

  missing_areas text[] not null default '{}',
  complete boolean not null default false,
  final_total numeric,

  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.deep_final_aggregates is
  'M6a 서버 집계 캐시. documentCarry는 decision_results(document, final, finalized) 스냅샷 기준.
   group/interviewStudent/interviewParent/writing 4영역 전부 complete=true이고
   deep.documentCarry config가 존재할 때만 complete=true, final_total 확정.
   하나라도 미충족이면 complete=false, final_total=null, missing_areas에 사유 기록.';

alter table public.deep_final_aggregates enable row level security;

create policy deep_final_aggregates_select_admin_viewer
  on public.deep_final_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- write 정책 없음: 트리거·RPC 전용.

-- ============================================================
-- 2. _compute_final_aggregate — 즉석 계산 (내부 전용)
-- ============================================================

create or replace function public._compute_final_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_carry_params jsonb;
  v_multiplier numeric;
  v_max numeric;
  v_doc_score numeric;
  v_doc_carry numeric;
  v_group_complete boolean;
  v_group_score numeric;
  v_int_student_complete boolean;
  v_int_student_score numeric;
  v_int_parent_complete boolean;
  v_int_parent_score numeric;
  v_writing_complete boolean;
  v_writing_score numeric;
  v_missing text[] := '{}';
  v_complete boolean;
  v_final_total numeric;
  v_summary jsonb;
begin
  select a.id, a.year, a.round into v_app
  from public.applicants a
  where a.id = p_applicant_id;

  if v_app is null then
    return jsonb_build_object('applicable', false, 'reason', 'APPLICANT_NOT_FOUND');
  end if;

  select * into v_round
  from public.admission_rounds
  where year = v_app.year and round = v_app.round;

  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('applicable', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  -- documentCarry의 유일한 근거: 확정된 M4 final decisionRun 스냅샷.
  -- 현재 aggregate/원자료를 다시 계산하지 않는다.
  select dr.total_score into v_doc_score
  from public.decision_results dr
  where dr.run_id = v_round.document_decision_run_id
    and dr.applicant_id = p_applicant_id
    and dr.outcome = 'passed';

  if v_doc_score is null then
    return jsonb_build_object('applicable', false, 'reason', 'NOT_DOCUMENT_PASSED');
  end if;

  select scoring_params #> '{deep,documentCarry}' into v_carry_params
  from public.config_revisions
  where id = v_round.config_revision_id;

  v_missing := '{}';

  if v_carry_params is null
     or coalesce((v_carry_params ->> 'multiplier')::numeric, 0) <= 0
     or coalesce((v_carry_params ->> 'max')::numeric, 0) <= 0 then
    -- fail-soft: config 부재/불완전은 예외가 아니라 documentCarry 영역 자체를
    -- 미확정으로 표시한다 (주석 3번 참조).
    v_doc_carry := null;
    v_missing := array_append(v_missing, 'documentCarry');
  else
    v_multiplier := (v_carry_params ->> 'multiplier')::numeric;
    v_max := (v_carry_params ->> 'max')::numeric;
    v_doc_carry := least(v_max, v_doc_score * v_multiplier);
  end if;

  select complete, score into v_group_complete, v_group_score
  from public.deep_group_aggregates
  where applicant_id = p_applicant_id;

  select student_complete, student_score, parent_complete, parent_score
    into v_int_student_complete, v_int_student_score, v_int_parent_complete, v_int_parent_score
  from public.deep_interview_aggregates
  where applicant_id = p_applicant_id;

  select complete, score into v_writing_complete, v_writing_score
  from public.deep_writing_aggregates
  where applicant_id = p_applicant_id;

  if not coalesce(v_group_complete, false) then
    v_missing := array_append(v_missing, 'group');
  end if;
  if not coalesce(v_int_student_complete, false) then
    v_missing := array_append(v_missing, 'interviewStudent');
  end if;
  if not coalesce(v_int_parent_complete, false) then
    v_missing := array_append(v_missing, 'interviewParent');
  end if;
  if not coalesce(v_writing_complete, false) then
    v_missing := array_append(v_missing, 'writing');
  end if;

  v_complete := (array_length(v_missing, 1) is null);

  if v_complete then
    v_final_total := v_doc_carry + v_group_score + v_int_student_score
      + v_int_parent_score + v_writing_score;
  else
    v_final_total := null;
  end if;

  v_summary := jsonb_build_object(
    'documentDecisionRunId', v_round.document_decision_run_id,
    'configRevisionId', v_round.config_revision_id,
    'groupComputedAt', (select computed_at from public.deep_group_aggregates where applicant_id = p_applicant_id),
    'interviewComputedAt', (select computed_at from public.deep_interview_aggregates where applicant_id = p_applicant_id),
    'writingComputedAt', (select computed_at from public.deep_writing_aggregates where applicant_id = p_applicant_id)
  );

  return jsonb_build_object(
    'applicable', true,
    'documentScore', v_doc_score,
    'documentCarry', v_doc_carry,
    'groupScore', v_group_score,
    'groupComplete', coalesce(v_group_complete, false),
    'interviewStudentScore', v_int_student_score,
    'interviewStudentComplete', coalesce(v_int_student_complete, false),
    'interviewParentScore', v_int_parent_score,
    'interviewParentComplete', coalesce(v_int_parent_complete, false),
    'writingScore', v_writing_score,
    'writingComplete', coalesce(v_writing_complete, false),
    'missingAreas', to_jsonb(v_missing),
    'complete', v_complete,
    'finalTotal', v_final_total,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm6a-final-aggregate-v1'
  );
end;
$$;

revoke all on function public._compute_final_aggregate(uuid) from public, anon, authenticated;

-- ============================================================
-- 3. _refresh_final_aggregate — 캐시 upsert (내부 전용)
-- ============================================================

create or replace function public._refresh_final_aggregate(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_agg jsonb;
  v_missing text[];
begin
  v_agg := public._compute_final_aggregate(p_applicant_id);

  if not (v_agg ->> 'applicable')::boolean then
    delete from public.deep_final_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select array(select jsonb_array_elements_text(v_agg -> 'missingAreas')) into v_missing;

  insert into public.deep_final_aggregates (
    applicant_id, year, round, config_revision_id, document_decision_run_id,
    document_score, document_carry,
    group_score, group_complete,
    interview_student_score, interview_student_complete,
    interview_parent_score, interview_parent_complete,
    writing_score, writing_complete,
    missing_areas, complete, final_total,
    function_version, computed_at
  )
  select
    p_applicant_id, a.year, a.round,
    (v_agg #>> '{sourceRevisionSummary,configRevisionId}')::uuid,
    (v_agg #>> '{sourceRevisionSummary,documentDecisionRunId}')::uuid,
    (v_agg ->> 'documentScore')::numeric,
    (v_agg ->> 'documentCarry')::numeric,
    (v_agg ->> 'groupScore')::numeric,
    (v_agg ->> 'groupComplete')::boolean,
    (v_agg ->> 'interviewStudentScore')::numeric,
    (v_agg ->> 'interviewStudentComplete')::boolean,
    (v_agg ->> 'interviewParentScore')::numeric,
    (v_agg ->> 'interviewParentComplete')::boolean,
    (v_agg ->> 'writingScore')::numeric,
    (v_agg ->> 'writingComplete')::boolean,
    v_missing,
    (v_agg ->> 'complete')::boolean,
    (v_agg ->> 'finalTotal')::numeric,
    v_agg ->> 'functionVersion', now()
  from public.applicants a
  where a.id = p_applicant_id
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    document_decision_run_id = excluded.document_decision_run_id,
    document_score = excluded.document_score,
    document_carry = excluded.document_carry,
    group_score = excluded.group_score,
    group_complete = excluded.group_complete,
    interview_student_score = excluded.interview_student_score,
    interview_student_complete = excluded.interview_student_complete,
    interview_parent_score = excluded.interview_parent_score,
    interview_parent_complete = excluded.interview_parent_complete,
    writing_score = excluded.writing_score,
    writing_complete = excluded.writing_complete,
    missing_areas = excluded.missing_areas,
    complete = excluded.complete,
    final_total = excluded.final_total,
    function_version = excluded.function_version,
    computed_at = now();
end;
$$;

revoke all on function public._refresh_final_aggregate(uuid) from public, anon, authenticated;

-- ============================================================
-- 4. 트리거 — group/interview/writing aggregate 변경 시 자동 갱신
--    세 테이블 모두 applicant_id 컬럼을 가지므로 트리거 함수 1개를 공유한다.
-- ============================================================

create or replace function public._trg_refresh_final_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_final_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_final_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._trg_refresh_final_aggregate() from public, anon, authenticated;

drop trigger if exists trg_final_aggregate_from_group on public.deep_group_aggregates;
create trigger trg_final_aggregate_from_group
  after insert or update or delete on public.deep_group_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

drop trigger if exists trg_final_aggregate_from_interview on public.deep_interview_aggregates;
create trigger trg_final_aggregate_from_interview
  after insert or update or delete on public.deep_interview_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

drop trigger if exists trg_final_aggregate_from_writing on public.deep_writing_aggregates;
create trigger trg_final_aggregate_from_writing
  after insert or update or delete on public.deep_writing_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

-- 주의: document_decision_run_id 자체가 (재사정 등으로) 바뀌는 경우는 이 트리거의
-- 대상이 아니다 — 그 경로는 STALE_AFTER_FINALIZATION 상당 처리가 시스템 전체에
-- 아직 없다는 기존 gap과 동일 선상에 있으며, M6b에서 별도로 다룬다.

-- ============================================================
-- 5. recompute_final_aggregates — 관리자 수동 재계산 (config 최초 반영 후 1회 실행 등)
-- ============================================================

create or replace function public.recompute_final_aggregates(
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
  v_round record;
  v_processed int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null then
    raise exception '해당 연도/차수의 admission_round가 없습니다.' using errcode = '55000';
  end if;
  if v_round.document_decision_run_id is null then
    return jsonb_build_object('processed', 0, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  for r in
    select dr.applicant_id
    from public.decision_results dr
    where dr.run_id = v_round.document_decision_run_id
      and dr.outcome = 'passed'
  loop
    perform public._refresh_final_aggregate(r.applicant_id);
    v_processed := v_processed + 1;
  end loop;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type)
  values (p_year, p_round, 'user', caller::text, 'deep_final_aggregates.recomputed', 'deep_final_aggregates');

  return jsonb_build_object('processed', v_processed);
end;
$$;

revoke all on function public.recompute_final_aggregates(int, admission_round) from public, anon;
grant execute on function public.recompute_final_aggregates(int, admission_round) to authenticated;

-- ============================================================
-- 6. get_m6_final_progress — 관리자 진행률 조회. 개별 위원 점수는 노출하지 않는다.
-- ============================================================

create or replace function public.get_m6_final_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;

  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object(
      'year', p_year, 'round', p_round,
      'documentDecisionRunId', null,
      'items', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'year', p_year, 'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'tracks', a.tracks,
        'documentScore', dr.total_score,
        'documentCarry', fa.document_carry,
        'groupComplete', coalesce(fa.group_complete, false),
        'groupScore', fa.group_score,
        'interviewStudentComplete', coalesce(fa.interview_student_complete, false),
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentComplete', coalesce(fa.interview_parent_complete, false),
        'interviewParentScore', fa.interview_parent_score,
        'writingComplete', coalesce(fa.writing_complete, false),
        'writingScore', fa.writing_score,
        'missingAreas', case
          when fa.applicant_id is null
            then to_jsonb(array['group','interviewStudent','interviewParent','writing']::text[])
          else to_jsonb(fa.missing_areas)
        end,
        'complete', coalesce(fa.complete, false),
        'finalTotal', fa.final_total,
        'computedAt', fa.computed_at
      ) order by er.exam_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      join public.applicants a on a.id = dr.applicant_id
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m6_final_progress(int, admission_round) from public, anon;
grant execute on function public.get_m6_final_progress(int, admission_round) to authenticated;

-- ======================================================================
-- 00016_m6b_final_decision.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M6b 최종 사정 simulation/final (Sprint 6 계속)
-- 마스터 스펙 v1.2 섹션 5.5(최종 사정 로직), 5.6(decisionRuns 실행 원칙) 대응.
-- M4 run_document_decision(00008)과 동일한 엔진 철학을 그대로 확장한다:
-- decision_runs/decision_results 테이블 재사용, simulation은 몇 번이든 실행 가능,
-- final은 검증 통과 시에만 확정, 기존 확정 run은 절대 UPDATE하지 않는다(불변).
--
-- 요강 승인본(공고 제2026-42호, 2026.7.6) "(3) 최종 합격자 사정" 근거:
--   1. 인천학생추천전형 상위 3명 우선 사정
--   2. 사회통합전형 상위 1명 우선 사정
--   3. 두 특별전형 미선발자 + 일반전형만 지원한 자를 일반전형 풀에서 합산 경쟁,
--      상위 16명 사정
--   4. 최종 동점: 모둠+면접(deepGroupInterview) → 글쓰기 → 자기소개서 → 출결 → 학업성실도
--
-- 담당 교사 정책 결정(2026-07-08):
--   - unfilledTrackPolicy = carryToGeneral (특별전형 미충원 인원은 일반전형으로 이월)
--   - evaluationStage 상태 전이는 이번 단계에서 건드리지 않는다 (M5 시리즈와 동일하게
--     decision_results 스냅샷 멤버십을 후보 판정의 단일 기준으로 사용)
--
-- M6a와의 관계: documentCarry/finalTotal/4영역 완료여부는 전부 deep_final_aggregates
-- 캐시를 그대로 읽는다. 이 마이그레이션은 새 점수 계산 로직을 추가하지 않는다.

-- ============================================================
-- 1. run_final_decision — 최종 사정 실행 (simulation | final)
-- ============================================================

create or replace function public.run_final_decision(
  p_year int,
  p_round admission_round,
  p_mode decision_mode
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  quota jsonb;
  q_general int;
  q_incheon int;
  q_social int;
  unfilled_policy text;
  policy_recognized boolean;
  v_run_id uuid;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  incheon_passed int := 0;
  social_passed int := 0;
  general_quota_effective int;
  applicant_row record;
  boundary_rank int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    raise exception '이 라운드에는 확정된 M4 1차 서류사정(document final run)이 없습니다.'
      using errcode = '55000';
  end if;
  if v_round.config_revision_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.' using errcode = '55000';
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다.' using errcode = '55000';
  end if;

  q_general := (quota ->> 'general')::int;
  q_incheon := (quota ->> 'incheon')::int;
  q_social := (quota ->> 'social')::int;
  unfilled_policy := quota ->> 'unfilledTrackPolicy';
  policy_recognized := unfilled_policy in ('carryToGeneral', 'remainVacant');

  if q_general is null or q_incheon is null or q_social is null then
    raise exception 'config quota.general/incheon/social 값이 올바르지 않습니다: %', quota
      using errcode = '55000';
  end if;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  -- ── 후보 분류: 1차 서류 합격자 전원을 제외/보류/미완료/유효후보로 분류 ──────
  select count(*) into excluded_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  select count(*) into review_pending_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'reviewPending';

  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  -- ── 유효 후보 pool (제외/보류/미완료 아닌 전원, 4영역 complete 확정) ────────
  drop table if exists tmp_candidates;
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    tracks text[],
    final_total numeric,
    deep_group_interview numeric,
    writing numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  insert into tmp_candidates
  select
    dr.applicant_id, a.tracks, fa.final_total,
    (fa.group_score + fa.interview_student_score + fa.interview_parent_score),
    fa.writing_score,
    (dr.tiebreak_values ->> 'essay')::numeric,
    (dr.tiebreak_values ->> 'attendance')::numeric,
    (dr.tiebreak_values ->> 'academic')::numeric
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  select count(*) into v_candidate_count from tmp_candidates;

  -- ── 인천학생추천전형 사정 ────────────────────────────────────
  drop table if exists tmp_incheon_result;
  create temp table tmp_incheon_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_incheon_ranked;
  create temp table tmp_incheon_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'incheon' = any(tracks);

  select rnk into boundary_rank from tmp_incheon_ranked where rn = q_incheon;

  insert into tmp_incheon_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_incheon_ranked where rnk = boundary_rank and rn > q_incheon)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_incheon) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_incheon_ranked;

  select count(*) into incheon_passed from tmp_incheon_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_incheon_result where outcome = 'manualDecisionRequired');

  -- ── 사회통합전형 사정 (동일 패턴, incheon과 tracks가 겹치지 않으므로 독립) ──
  drop table if exists tmp_social_result;
  create temp table tmp_social_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_social_ranked;
  create temp table tmp_social_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'social' = any(tracks);

  boundary_rank := null;
  select rnk into boundary_rank from tmp_social_ranked where rn = q_social;

  insert into tmp_social_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_social_ranked where rnk = boundary_rank and rn > q_social)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_social) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_social_ranked;

  select count(*) into social_passed from tmp_social_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_social_result where outcome = 'manualDecisionRequired');

  -- ── 일반전형 유효 정원 (unfilledTrackPolicy) ────────────────────
  if unfilled_policy = 'carryToGeneral' then
    general_quota_effective := q_general + (q_incheon - incheon_passed) + (q_social - social_passed);
  else
    -- 'remainVacant' 또는 미확정('pending'/기타) — simulation 미리보기는 보수적으로
    -- 이월 없이 기본 정원만 사용한다. final 확정은 policy_recognized=false면 아래에서 차단.
    general_quota_effective := q_general;
  end if;

  -- ── 일반전형 pool: 특별전형에서 이미 passed/manualDecisionRequired인 사람 제외 ──
  drop table if exists tmp_general_result;
  create temp table tmp_general_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_general_ranked;
  create temp table tmp_general_ranked on commit drop as
  select c.applicant_id,
    rank() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                  c.essay desc, c.attendance desc, c.academic desc) as rnk,
    row_number() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                        c.essay desc, c.attendance desc, c.academic desc) as rn
  from tmp_candidates c
  where c.applicant_id not in (
    select applicant_id from tmp_incheon_result where outcome in ('passed', 'manualDecisionRequired')
  )
  and c.applicant_id not in (
    select applicant_id from tmp_social_result where outcome in ('passed', 'manualDecisionRequired')
  );

  boundary_rank := null;
  select rnk into boundary_rank from tmp_general_ranked where rn = general_quota_effective;

  insert into tmp_general_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_general_ranked where rnk = boundary_rank and rn > general_quota_effective)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, general_quota_effective) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_general_ranked;

  unresolved_count := unresolved_count
    + (select count(*) from tmp_general_result where outcome = 'manualDecisionRequired');

  -- ── decision_runs 생성 (M4와 동일하게 먼저 running으로 생성) ─────────
  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'final', p_mode, 'running', v_round.config_revision_id, caller::text)
  returning id into v_run_id;

  -- ── decision_results 기록: 제외자(위원회 exclusion 결정) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, outcome,
     committee_decision_applied, track_result)
  select
    v_run_id, dr.applicant_id, p_year, p_round, 'final', fa.final_total, 'excluded'::decision_outcome, true,
    jsonb_build_object('incheon', 'notApplicable', 'social', 'notApplicable', 'general', 'notApplicable')
  from public.decision_results dr
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  -- ── decision_results 기록: 유효 후보 전원(전형 결합 결과) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values,
     track_result, outcome)
  select
    v_run_id, c.applicant_id, p_year, p_round, 'final', c.final_total,
    coalesce(gr.rnk, ir.rnk, sr.rnk),
    jsonb_build_object(
      'deepGroupInterview', c.deep_group_interview, 'writing', c.writing,
      'essay', c.essay, 'attendance', c.attendance, 'academic', c.academic
    ),
    jsonb_build_object(
      'incheon', case when 'incheon' = any(c.tracks) then ir.outcome else 'notApplicable' end,
      'social', case when 'social' = any(c.tracks) then sr.outcome else 'notApplicable' end,
      'general', coalesce(gr.outcome, 'notApplicable')
    ),
    (case
      when ir.outcome = 'manualDecisionRequired' or sr.outcome = 'manualDecisionRequired'
           or gr.outcome = 'manualDecisionRequired' then 'manualDecisionRequired'
      when ir.outcome = 'passed' or sr.outcome = 'passed' or gr.outcome = 'passed' then 'passed'
      else 'failed'
    end)::decision_outcome
  from tmp_candidates c
  left join tmp_incheon_result ir on ir.applicant_id = c.applicant_id
  left join tmp_social_result sr on sr.applicant_id = c.applicant_id
  left join tmp_general_result gr on gr.applicant_id = c.applicant_id;

  select count(*) into v_result_count from public.decision_results where run_id = v_run_id;

  update public.decision_runs
  set candidate_count = v_candidate_count,
      result_count = v_result_count,
      unresolved_tie_count = unresolved_count,
      blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 확정 ─────────────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if incomplete_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '심층역량평가 4영역이 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', incomplete_count;
    end if;
    if review_pending_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '학폭 등 소명 절차가 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', review_pending_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;
    if not policy_recognized then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'config quota.unfilledTrackPolicy가 확정되지 않았습니다(현재: %). 입학전형위원회 결정 후 final 확정이 가능합니다.', unfilled_policy;
    end if;

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.final.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.final.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;

revoke all on function public.run_final_decision(int, admission_round, decision_mode) from public, anon;
grant execute on function public.run_final_decision(int, admission_round, decision_mode) to authenticated;

-- ============================================================
-- 2. get_final_decision_blockers — final 확정 전 관리자 확인용 사전 점검
--    (React 확인 dialog에서 blocking 0건 여부를 실행 전에 미리 보여주기 위함)
-- ============================================================

create or replace function public.get_final_decision_blockers(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  quota jsonb;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
  candidate_count int;
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object(
      'ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN'
    );
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  select count(*) into excluded_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  select count(*) into review_pending_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'reviewPending';

  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  select count(*) into candidate_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  return jsonb_build_object(
    'ready', blocking_count = 0 and incomplete_count = 0 and review_pending_count = 0
      and (quota ->> 'unfilledTrackPolicy') in ('carryToGeneral', 'remainVacant'),
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', candidate_count,
    'blockingAlertCount', blocking_count,
    'incompleteDeepCount', incomplete_count,
    'reviewPendingCount', review_pending_count,
    'excludedCount', excluded_count,
    'unfilledTrackPolicy', quota ->> 'unfilledTrackPolicy',
    'quota', quota
  );
end;
$$;

revoke all on function public.get_final_decision_blockers(int, admission_round) from public, anon;
grant execute on function public.get_final_decision_blockers(int, admission_round) to authenticated;

-- ======================================================================
-- 00017_m6c_pass_list.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M6c 최종 발표 산출물 (Sprint 6 계속)
-- 요강 승인본(공고 제2026-42호) "5. 전형 일정 — 최종 합격자 발표: 개별 통보(SMS)
-- 및 홈페이지" 근거.
--
-- 용도(purpose)별 필드를 서버에서 강제로 최소화한다 — 클라이언트가 실수로
-- 과다노출하는 것을 원천 차단(스펙 6.1 "클라이언트 어떤 분기도 보안장치가
-- 아니다" 원칙과 동일선상).
--
-- 담당 교사 확인 필요 사항(가정으로 진행, 확인 후 조정):
--   1. SMS 대상: 지원자 본인 연락처 + 보호자 연락처 둘 다 내려준다(실제 발송 시
--      어느 쪽으로 보낼지는 학교 문자발송 도구에서 선택). 합격/불합격 전원 포함.
--   2. 홈페이지 게시: 접수번호 + 판정만 내려준다(성명·연락처·전형 전부 제외).
--      또한 불합격자는 아예 포함하지 않는다(합격자 명단만 게시하는 일반적 관행).
--   3. 반드시 finalized 상태인 최종(decision_type='final') run만 사용한다.
--      simulation 결과로는 절대 발표 자료를 만들 수 없다.

create or replace function public.get_final_pass_list(
  p_year int,
  p_round admission_round,
  p_purpose text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_purpose not in ('sms', 'website') then
    raise exception '지원하지 않는 purpose입니다: % (sms | website 중 하나)', p_purpose
      using errcode = '55000';
  end if;

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다. simulation 결과로는 발표 자료를 만들 수 없습니다.'
      using errcode = '55000';
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (p_year, p_round, 'user', caller::text, 'decision.final.pass_list_exported.' || p_purpose, 'decision_runs', v_run_id::text);

  if p_purpose = 'sms' then
    return jsonb_build_object(
      'purpose', 'sms',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'name', a.name,
          'applicantPhone', ap.applicant_phone,
          'guardianName', ap.guardian_name,
          'guardianPhone', ap.guardian_phone,
          'outcome', dr.outcome,
          'outcomeLabel', case dr.outcome
            when 'passed' then '합격' when 'failed' then '불합격'
            when 'excluded' then '제외' else '판정보류' end,
          'trackLabel', case
            when dr.track_result ->> 'incheon' = 'passed' then '인천학생추천'
            when dr.track_result ->> 'social' = 'passed' then '사회통합'
            when dr.track_result ->> 'general' = 'passed' then '일반'
            else null
          end
        ) order by a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        left join public.applicants_private ap on ap.applicant_id = a.id
        where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed')
      ), '[]'::jsonb)
    );
  else
    return jsonb_build_object(
      'purpose', 'website',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'outcomeLabel', '합격'
        ) order by a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        where dr.run_id = v_run_id and dr.outcome = 'passed'
      ), '[]'::jsonb)
    );
  end if;
end;
$$;

revoke all on function public.get_final_pass_list(int, admission_round, text) from public, anon;
grant execute on function public.get_final_pass_list(int, admission_round, text) to authenticated;

-- ======================================================================
-- 00018_m6d_committee_packet.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M6d 전형평가회의 자료 (Sprint 6 계속)
-- 마스터 스펙 v1.2 M6 모듈, 검토메모 "M6 회의자료 PDF와 종합 채점표 XLSX는
-- M5e 종이 백업과 역할이 다름" 근거.
--
-- M6b(get_final_decision_blockers)/M6c(get_final_pass_list)와 달리 이 RPC는
-- "확정된 final" 하나로 제한하지 않는다 — 입학전형위원회는 보통 simulation
-- 결과를 미리 보고 동점·제외 여부를 논의한 뒤에 최종 확정하므로, 가장 최근
-- (year,round,decision_type='final') run을 상태(completed 또는 finalized)
-- 관계없이 사용한다. 개별 위원 채점은 노출하지 않고 확정된 집계 점수만 보여준다.
--
-- 익명화는 서버가 아니라 화면(인쇄 미리보기)에서 토글한다 — 이 RPC를 호출할
-- 수 있는 사람은 이미 superadmin/admin이라 성명을 볼 권한이 있고, 익명화는
-- 위원회 회의 중 편향을 줄이기 위한 표시 옵션일 뿐 접근통제가 아니다.

create or replace function public.get_m6_committee_packet(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_run record;
  quota jsonb;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  select * into v_run
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final'
    and status in ('completed', 'finalized')
  order by created_at desc
  limit 1;

  if v_run is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_FINAL_RUN_YET');
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';
  select count(*) into excluded_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'excluded';
  select count(*) into review_pending_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'reviewPending';
  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  return jsonb_build_object(
    'ready', true,
    'runId', v_run.id,
    'runMode', v_run.mode,
    'runStatus', v_run.status,
    'generatedAt', v_run.aggregate_snapshot_at,
    'finalizedAt', v_run.finalized_at,
    'quota', quota,
    'blockers', jsonb_build_object(
      'blockingAlertCount', blocking_count,
      'incompleteDeepCount', incomplete_count,
      'reviewPendingCount', review_pending_count,
      'excludedCount', excluded_count,
      'unresolvedTieCount', v_run.unresolved_tie_count
    ),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'tracks', a.tracks,
        'primaryTrack', case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 'incheon'
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 'social'
          else 'general'
        end,
        'documentScore', fa.document_score,
        'documentCarry', fa.document_carry,
        'groupScore', fa.group_score,
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentScore', fa.interview_parent_score,
        'writingScore', fa.writing_score,
        'finalTotal', dr.total_score,
        'rank', dr.rank,
        'trackResult', dr.track_result,
        'outcome', dr.outcome,
        'tiebreakValues', dr.tiebreak_values
      ) order by
        (case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 0
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 1
          else 2
        end),
        dr.rank nulls last
      )
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome <> 'excluded'
    ), '[]'::jsonb),
    'excludedCandidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'adminNote', aa.admin_note
      ) order by a.receipt_no)
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome = 'excluded'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m6_committee_packet(int, admission_round) from public, anon;
grant execute on function public.get_m6_committee_packet(int, admission_round) to authenticated;

-- ======================================================================
-- 00019_m6e_scoresheet_data.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M6e 종합 채점표 XLSX 원자료 (Sprint 6 계속)
-- 2026학년도 실물 "채점표" 워크북(16시트) 구조를 확인하고 반영한다.
--
-- 확인된 사실(2026 실물 대조):
--   - 서류평가 4영역(공동체/자소서/학부모소견서)+출결·학업은 2026과 2027 config의
--     위원 수가 정확히 일치한다 (공동체 2인, 자소서 5인, 학부모소견서 4인,
--     출결·학업 각 1인). 위원별 개별 시트를 그대로 재현할 수 있다.
--   - 심층평가(모둠/면접/글쓰기)는 다르다. 2026은 모둠활동을 위원 10인 전원이
--     15점씩 채점해 합산(150점)했지만, 2027은 승인 요강 문구("2인의 관찰교사")
--     그대로 관찰교사 2인 체제로 이미 구현되어 있다(M5a/b). 면접도 2026의
--     4인조×2팀 로테이션과 달리 2027은 학생/학부모 각 2인이다. 이 RPC는 2027
--     실제 위원 수(모둠 2, 학생면접 2, 학부모면접 2, 글쓰기 2)를 기준으로 한다.
--   - 서류평가 개별위원 점수의 server_computed 키는 영역별로 다르다
--     (attendance/academic/community는 'score', essay/opinion은 'total').
--
-- 이 RPC는 원자료를 최대한 평탄하게(flat) 반환하고, 시트별 컬럼 구성은
-- 클라이언트(exportFinalScoresheetXlsx.js)에서 담당한다 — SQL 쪽 복잡도를
-- 낮추고 시트 레이아웃 변경 시 SQL을 다시 배포할 필요가 없게 하기 위함.

create or replace function public.get_m6e_scoresheet_data(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_final_run record;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  select * into v_final_run
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final'
    and status in ('completed', 'finalized')
  order by created_at desc
  limit 1;

  return jsonb_build_object(
    'ready', true,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'finalRunId', v_final_run.id,
    'finalRunMode', v_final_run.mode,

    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id, 'receiptNo', a.receipt_no, 'name', a.name,
        'examNo', er.exam_no, 'tracks', a.tracks,
        'bonusEligible', a.bonus_eligible, 'bonusReason', a.bonus_reason
      ) order by coalesce(er.exam_no, a.receipt_no))
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.evaluation_roster er on er.applicant_id = a.id
      where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    ), '[]'::jsonb),

    -- 서류평가 개별위원 원점수 (area별 evaluator_uid 단위 1행)
    'documentIndividualScores', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'attendance',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        ) as x
        from public.scores_attendance s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'academic',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        )
        from public.scores_academic s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'community',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        )
        from public.scores_community s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'essay',
          'evaluatorName', u.display_name, 'inputs', s.items,
          'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_essay s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'opinion',
          'evaluatorName', u.display_name, 'inputs', s.items,
          'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_opinion s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
      ) t
    ),

    -- 서류평가 종합(영역별 breakdown은 _compute_document_aggregate 재계산 — 확정 스냅샷
    -- total_score/rank/outcome은 decision_results 그대로, opinion을 포함한 영역별
    -- 분해값은 decision_results.tiebreak_values에 없어 부득이 현재 값을 다시 계산한다.
    -- 확정 후 재제출이 없었다면 스냅샷과 동일하다.)
    'documentAggregate', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'totalScore', dr.total_score,
        'rank', dr.rank,
        'outcome', dr.outcome,
        'breakdown', public._compute_document_aggregate(dr.applicant_id)
      ) order by dr.rank nulls last)
      from public.decision_results dr
      where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    ), '[]'::jsonb),

    -- 심층평가 개별위원 원점수
    'deepIndividualScores', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'group', 'evaluatorName', u.display_name,
          'observerRole', s.observer_role, 'score', (s.server_computed ->> 'total')::numeric
        ) as x
        from public.scores_group s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'interviewStudent', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.student_server_computed ->> 'total')::numeric
        )
        from public.scores_interview s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.student_submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'interviewParent', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.parent_server_computed ->> 'total')::numeric
        )
        from public.scores_interview s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.parent_submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'writing', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_writing s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
      ) t
    ),

    -- 최종 종합 (M6b final run 기준, 없으면 빈 배열 — simulation만 있어도 표시)
    'finalAggregate', case when v_final_run.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'documentScore', fa.document_score,
        'documentCarry', fa.document_carry,
        'groupScore', fa.group_score,
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentScore', fa.interview_parent_score,
        'writingScore', fa.writing_score,
        'finalTotal', dr.total_score,
        'rank', dr.rank,
        'outcome', dr.outcome,
        'trackResult', dr.track_result
      ) order by dr.rank nulls last)
      from public.decision_results dr
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_final_run.id and dr.outcome <> 'excluded'
    ), '[]'::jsonb) end
  );
end;
$$;

revoke all on function public.get_m6e_scoresheet_data(int, admission_round) from public, anon;
grant execute on function public.get_m6e_scoresheet_data(int, admission_round) to authenticated;

-- ======================================================================
-- 00020_m7a_audit_log_viewer.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M7a 감사 로그 조회 (Sprint 7 시작)
-- 마스터 스펙 v1.2 M7 "감사 로그 조회... 평가 잠금 해제·재제출·위원 대체배정 이력"
-- 대응.
--
-- audit_logs 테이블과 그 기록 자체는 이미 존재한다(00001에서 테이블 생성,
-- M4~M6 전체 RPC가 이미 40여 종의 action으로 기록 중). 이 마이그레이션은
-- 신규 로깅을 추가하지 않는다 — 이미 쌓인 데이터를 관리자가 필터링해서
-- 조회할 수 있는 RPC 하나만 추가한다.

create or replace function public.get_audit_logs(
  p_year int default null,
  p_round admission_round default null,
  p_action_like text default null,
  p_actor_uid uuid default null,
  p_resource_type text default null,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select count(*) into v_total
  from public.audit_logs al
  where (p_year is null or al.year = p_year)
    and (p_round is null or al.round = p_round)
    and (p_action_like is null or al.action like p_action_like)
    and (p_actor_uid is null or al.actor_uid = p_actor_uid::text)
    and (p_resource_type is null or al.resource_type = p_resource_type)
    and (p_date_from is null or al.created_at >= p_date_from)
    and (p_date_to is null or al.created_at <= p_date_to);

  return jsonb_build_object(
    'totalCount', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', al.id,
        'createdAt', al.created_at,
        'year', al.year,
        'round', al.round,
        'actorType', al.actor_type,
        'actorUid', al.actor_uid,
        'actorName', u.display_name,
        'action', al.action,
        'resourceType', al.resource_type,
        'resourceId', al.resource_id,
        'applicantId', al.applicant_id,
        'area', al.area,
        'reasonCode', al.reason_code,
        'metadata', al.metadata
      ) order by al.created_at desc)
      from (
        select *
        from public.audit_logs al
        where (p_year is null or al.year = p_year)
          and (p_round is null or al.round = p_round)
          and (p_action_like is null or al.action like p_action_like)
          and (p_actor_uid is null or al.actor_uid = p_actor_uid::text)
          and (p_resource_type is null or al.resource_type = p_resource_type)
          and (p_date_from is null or al.created_at >= p_date_from)
          and (p_date_to is null or al.created_at <= p_date_to)
        order by al.created_at desc
        limit v_limit offset v_offset
      ) al
      left join public.users u on u.id::text = al.actor_uid
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_audit_logs(int, admission_round, text, uuid, text, timestamptz, timestamptz, int, int) from public, anon;
grant execute on function public.get_audit_logs(int, admission_round, text, uuid, text, timestamptz, timestamptz, int, int) to authenticated;

-- ============================================================
-- 조회 성능을 위한 인덱스 (audit_logs는 00001부터 계속 쌓여왔고 인덱스가 없었다)
-- ============================================================

create index if not exists idx_audit_logs_year_round_created
  on public.audit_logs (year, round, created_at desc);

create index if not exists idx_audit_logs_action
  on public.audit_logs (action);

create index if not exists idx_audit_logs_actor_uid
  on public.audit_logs (actor_uid);

-- ======================================================================
-- 00021_m7b_export_history.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M7b 내보내기 이력·체크섬 (Sprint 7 계속)
-- 마스터 스펙 v1.2 섹션 3.23 "내보내기 이력"(exports/{exportId}) 대응.
--
-- 스펙 원안은 Firestore + Storage 기준으로 generatedFilePath(서버 저장 경로)를
-- 포함하지만, 이 프로젝트는 서버 함수 없이 클라이언트가 직접 XLSX/CSV를
-- 생성해 즉시 다운로드하는 구조다(검토메모에서 이미 확정된 제약). 그래서
-- 파일을 서버에 남기지 않고, "무엇을 언제 누가 어떤 소스 데이터 기준으로
-- 내보냈는지 + 체크섬"만 기록한다 — 나중에 "그때 그 파일이 이 데이터와
-- 일치하는가"를 사후 검증할 수 있는 최소한의 증거로 충분하다.
--
-- checksum은 클라이언트에서 생성된 파일 바이트를 SHA-256으로 해시해 전달한다
-- (브라우저 Web Crypto API, 서버 재계산 없음 — 파일 자체가 서버에 없으므로
-- 서버가 재계산할 방법이 없다. 클라이언트 신뢰가 전제이며, 이는 감사로그
-- 전반의 "actor가 주장하는 사실을 기록"이라는 기존 원칙과 동일하다).

create type export_type as enum
  ('receiptLedger', 'documentResult', 'finalResultSms', 'finalResultWebsite',
   'committeePacket', 'scoreWorkbook', 'educationOffice');

create table public.exports (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  export_type export_type not null,
  file_format text not null,
  checksum_sha256 text not null,
  decision_run_id uuid references public.decision_runs (id),
  config_revision_id uuid references public.config_revisions (id),
  row_count int,
  metadata jsonb not null default '{}'::jsonb,
  generated_by text not null,
  generated_at timestamptz not null default now()
);

comment on table public.exports is
  '내보내기(다운로드) 이력. 파일 자체는 서버에 저장하지 않는다(클라이언트 직접
   생성·다운로드 구조) — 무엇을 언제 누가 어떤 decisionRun/configRevision
   기준으로 내보냈는지와 체크섬만 남겨 사후 검증 근거로 삼는다.';

alter table public.exports enable row level security;

create policy exports_select_admins
  on public.exports for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write 정책 없음: RPC 전용.

-- ============================================================
-- log_export — 클라이언트가 파일 생성·다운로드 직후 호출
-- ============================================================

create or replace function public.log_export(
  p_year int,
  p_round admission_round,
  p_export_type export_type,
  p_file_format text,
  p_checksum_sha256 text,
  p_decision_run_id uuid default null,
  p_config_revision_id uuid default null,
  p_row_count int default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_checksum_sha256 is null or length(trim(p_checksum_sha256)) <> 64 then
    raise exception 'checksum_sha256은 64자 hex 문자열이어야 합니다.' using errcode = '55000';
  end if;

  insert into public.exports
    (year, round, export_type, file_format, checksum_sha256, decision_run_id,
     config_revision_id, row_count, metadata, generated_by)
  values
    (p_year, p_round, p_export_type, p_file_format, lower(trim(p_checksum_sha256)),
     p_decision_run_id, p_config_revision_id, p_row_count, p_metadata, caller::text)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.log_export(int, admission_round, export_type, text, text, uuid, uuid, int, jsonb) from public, anon;
grant execute on function public.log_export(int, admission_round, export_type, text, text, uuid, uuid, int, jsonb) to authenticated;

-- ============================================================
-- get_export_history — 조회
-- ============================================================

create or replace function public.get_export_history(
  p_year int default null,
  p_round admission_round default null,
  p_export_type export_type default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select count(*) into v_total
  from public.exports e
  where (p_year is null or e.year = p_year)
    and (p_round is null or e.round = p_round)
    and (p_export_type is null or e.export_type = p_export_type);

  return jsonb_build_object(
    'totalCount', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'year', e.year,
        'round', e.round,
        'exportType', e.export_type,
        'fileFormat', e.file_format,
        'checksumSha256', e.checksum_sha256,
        'decisionRunId', e.decision_run_id,
        'decisionRunStatus', dr.status,
        'decisionRunMode', dr.mode,
        'configRevisionId', e.config_revision_id,
        'rowCount', e.row_count,
        'metadata', e.metadata,
        'generatedByName', u.display_name,
        'generatedAt', e.generated_at
      ) order by e.generated_at desc)
      from (
        select * from public.exports e
        where (p_year is null or e.year = p_year)
          and (p_round is null or e.round = p_round)
          and (p_export_type is null or e.export_type = p_export_type)
        order by e.generated_at desc
        limit v_limit offset v_offset
      ) e
      left join public.users u on u.id::text = e.generated_by
      left join public.decision_runs dr on dr.id = e.decision_run_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_export_history(int, admission_round, export_type, int, int) from public, anon;
grant execute on function public.get_export_history(int, admission_round, export_type, int, int) to authenticated;

-- ======================================================================
-- 00022_delete_applicant.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 지원자 삭제 (접수 실수·테스트 데이터 정리용)
-- 담당 교사 리허설 중 요청: "접수 대장에서 이미 접수된 지원자의 정보를 모두
-- 지울 수 있는 기능이 있어야 함".
--
-- applicants를 참조하는 모든 테이블(applicants_private/applicants_admin/
-- admission_documents/scores_*/evaluation_roster/deep_*_aggregates/
-- decision_results)이 이미 on delete cascade로 걸려있어 applicants 행 하나만
-- 지우면 관련 데이터가 전부 정리된다 — 새 cascade 설정 불필요.
--
-- audit_logs.applicant_id는 uuid FK가 아니라 text 컬럼이라(00001) cascade
-- 대상이 아니다 — 삭제 기록 자체는 지원자가 사라진 뒤에도 안전하게 남는다.
--
-- 최종 사정이 끝난(finalPassed/finalFailed) 지원자는 삭제를 막는다 — 이미
-- 공식 결과가 나온 사람은 삭제가 아니라 입학전형위원회 결정을 거친 정정
-- 절차로 처리해야 한다.

create or replace function public.delete_applicant(
  p_applicant_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  select id, year, round, receipt_no, name, application_status, evaluation_stage
  into app
  from public.applicants where id = p_applicant_id;

  if app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = '55000';
  end if;

  if app.evaluation_stage in ('finalPassed', 'finalFailed') then
    raise exception '최종 사정이 끝난 지원자는 삭제할 수 없습니다. 정정이 필요하면 입학전형위원회 결정을 거쳐 처리하세요.'
      using errcode = '55000';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code, metadata)
  values
    (app.year, app.round, 'user', caller::text, 'applicant.deleted', 'applicants', app.id::text, app.id::text,
     p_reason,
     jsonb_build_object('receiptNo', app.receipt_no, 'name', app.name,
       'applicationStatus', app.application_status, 'evaluationStage', app.evaluation_stage));

  delete from public.applicants where id = p_applicant_id;

  return jsonb_build_object('deleted', true, 'receiptNo', app.receipt_no, 'name', app.name);
end;
$$;

revoke all on function public.delete_applicant(uuid, text) from public, anon;
grant execute on function public.delete_applicant(uuid, text) to authenticated;

-- ======================================================================
-- 00023_pre_applications_m8.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 사전작성·접수조회 포털 데이터 모델 (Sprint 1B #1)
-- 마스터 스펙 v1.2 섹션 3.4(484행 데이터모델), 1330행 M8a~d 대응.
-- `M8_아키텍처_결정_2026-07-10.md` 결정에 따라 Firebase(Firestore) 원안 대신
-- Supabase(Postgres)로 통합한다 — 4개 컬렉션을 4개 테이블로 1:1 이전.
--
-- 이번 마이그레이션 범위(7절 스프린트 분해 1번): 테이블 + RLS 전면 차단만.
-- 조회코드 verifier(pgcrypto/hmac), Edge Function, RPC 5종은 다음 단계(2~3번).
--
-- 불변조건(결정 문서 9절 재확인):
--   2. 4테이블은 anon/authenticated RLS 전면 차단. 모든 접근은 Edge Function
--      (service_role) 또는 SECURITY DEFINER RPC(관리자)만.
--   5. 상태조회 응답은 최소 상태만 — 이 스키마 자체에 주소·연락처·보호자 정보를
--      pre_applications_private로 분리해 격리한다 (M0~M7과 동일한 "접근권한이
--      다른 정보는 다른 테이블에" 원칙, 00003 applicants_private과 동일 패턴).
--   6. convertPreApplicationToApplicant는 단일 트랜잭션 — 이를 위해
--      applicants.source_pre_application_id에 FK를 지금 건다(2.1 핵심 이득).

-- ============================================================
-- 1. 테이블
-- ============================================================

create table public.pre_applications (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  pre_application_no text not null unique,   -- 'PYYMMDDNNN' (채번 로직은 2~3번 단계 RPC)
  tracks text[] not null
    check (tracks in (array['general'], array['general','incheon'], array['general','social'])),
  academic_status text not null
    check (academic_status in ('졸업예정', '졸업', '검정고시', '기타')),
  school text,
  grade_class_no text,
  semester_choice text,
  receipt_method text not null check (receipt_method in ('M', 'V')),
  status text not null default 'completed'
    check (status in ('completed', 'bundleGenerated', 'arrived', 'reviewing',
                       'supplementRequired', 'converted', 'expired')),
  checklist_ack jsonb not null default '{}'::jsonb,
  -- { version, acknowledgedAt }
  print_bundle jsonb not null default '{}'::jsonb,
  -- { version, firstGeneratedAt, lastGeneratedAt, generationCount }
  shipping jsonb not null default '{}'::jsonb,
  -- { trackingNumber, registeredAt } — 등기 선택자만 사용
  arrival jsonb not null default '{}'::jsonb,
  -- { method, confirmedAt, confirmedBy }
  document_review jsonb not null default '{}'::jsonb,
  -- { checklistVersion, items, publicStatus, adminMemo, reviewedAt, reviewedBy }
  conversion jsonb not null default '{}'::jsonb,
  -- { applicantId, receiptNo, convertedAt, convertedBy }
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

comment on table public.pre_applications is
  'M8 사전작성 본체(공개 비민감 정보). 원문 개인정보는 pre_applications_private,
   인증 비밀은 pre_application_secrets로 분리. 온라인 원서접수가 아니다 —
   등기우편/방문 제출 필수(마스터스펙 1332행).';

create table public.pre_applications_private (
  pre_application_id uuid primary key
    references public.pre_applications (id) on delete cascade,
  name text not null,
  gender text check (gender in ('남', '여')),
  birth_date date,
  applicant_phone text,
  email text,
  address text,
  guardian_name text,
  guardian_relation text,
  guardian_phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pre_applications_private is
  '사전작성자 원문 개인정보. 상태조회(getPreApplicationStatus) 응답에 이 테이블의
   어떤 컬럼도 절대 포함하지 않는다(결정 문서 9절 5번).';

create table public.pre_application_secrets (
  pre_application_id uuid primary key
    references public.pre_applications (id) on delete cascade,
  access_code_verifier text not null,
  -- 6자리 조회코드 원문 비저장 — pepper 기반 HMAC/KDF verifier만 (2~3번 단계에서 구현)
  verifier_version int not null default 1,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  last_failed_at timestamptz
);

comment on table public.pre_application_secrets is
  '조회코드 verifier + 잠금 상태. 5회 연속 인증 실패 시 10분 잠금(결정 문서 9절 4번).
   존재여부/이름불일치/코드불일치 실패 사유는 공개 응답에서 구분하지 않는다 — 이
   테이블 자체는 그 구분을 강제하지 않으므로 Edge Function 구현 시 반드시 지킬 것.';

create table public.pre_application_events (
  id uuid primary key default gen_random_uuid(),
  pre_application_id uuid
    references public.pre_applications (id) on delete set null,
  -- 30일 자동파기 후에도 감사 이력은 남겨야 하므로 cascade 대신 set null.
  -- pre_application_no를 별도 컬럼으로 복제해 파기 후에도 이벤트를 추적 가능하게 함.
  pre_application_no text not null,
  event_type text not null,
  actor_type text not null check (actor_type in ('applicant', 'admin', 'system')),
  actor_uid uuid,
  metadata jsonb not null default '{}'::jsonb,
  function_version text,
  created_at timestamptz not null default now()
);

comment on table public.pre_application_events is
  'M8 감사 이벤트. metadata에 성명·주소·전화번호·조회코드·등기번호 원문을 복제하지
   않는다(마스터스펙 3.4 문구 그대로).';

-- ============================================================
-- 2. 인덱스
-- ============================================================

create index idx_pre_applications_status on public.pre_applications (status);
create index idx_pre_applications_expires_at on public.pre_applications (expires_at);
create index idx_pre_applications_year_round on public.pre_applications (year, round);
create index idx_pre_application_events_pre_application_id
  on public.pre_application_events (pre_application_id);
create index idx_pre_application_events_pre_application_no
  on public.pre_application_events (pre_application_no);

-- ============================================================
-- 3. RLS — anon/authenticated 전면 차단 (정책 없음 = 전면 거부)
--    service_role(Edge Function)과 SECURITY DEFINER RPC(테이블 소유자 postgres)는
--    RLS를 우회하므로 정상 동작한다 — M0~M7과 동일한 원칙(결정 문서 2.2).
-- ============================================================

alter table public.pre_applications enable row level security;
alter table public.pre_applications_private enable row level security;
alter table public.pre_application_secrets enable row level security;
alter table public.pre_application_events enable row level security;

-- 정책을 의도적으로 하나도 만들지 않는다. select/insert/update/delete 전부 거부.

-- ============================================================
-- 4. applicants.source_pre_application_id FK 연결
--    (00003에서 컬럼만 미리 만들어둔 것 — 결정 문서 2.1/4절 핵심 이득 실현 지점)
-- ============================================================

alter table public.applicants
  add constraint fk_applicants_source_pre_application
  foreign key (source_pre_application_id) references public.pre_applications (id);

comment on column public.applicants.source_pre_application_id is
  'M8 pre_applications.id 참조. convertPreApplicationToApplicant가 단일 트랜잭션
   안에서 이 FK와 pre_applications.status=''converted''를 함께 확정한다.';

-- ======================================================================
-- 00024_pre_application_verifier.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 조회코드 verifier·잠금 로직 (Sprint 1B #2)
-- 마스터 스펙 v1.2 섹션 3.4(preApplicationSecrets), 1330행 M8 보안 불변 원칙 대응.
-- `M8_아키텍처_결정_2026-07-10.md` 3.4 대응.
--
-- 이번 마이그레이션 범위(7절 스프린트 분해 2번): "Edge Function 없이도 RPC
-- 레벨에서 먼저 단위 검증 가능"한 조회코드 verifier + 잠금 로직만. 실제
-- 익명(anon) 호출 경로(Edge Function + Turnstile)는 3번 단계에서 붙인다.
-- 그때까지 이 함수들은 anon/authenticated에서 호출 불가 — postgres/service_role
-- 에서만 (SQL Editor로 직접 단위 테스트 가능, Edge Function은 service_role로
-- 동일하게 호출할 예정).
--
-- 불변조건(결정 문서 9절 재확인):
--   3. 6자리 조회코드는 원문 미저장, pepper 기반 HMAC verifier만 저장.
--   4. 5회 연속 인증실패 → 10분 잠금. 실패 사유(존재안함/이름불일치/코드불일치)는
--      공개 응답에서 구분하지 않는다 — 이 함수들도 결과를 boolean 하나로만
--      돌려주고, 실패 종류에 따라 다른 값/에러를 던지지 않는다.
--
-- 액션 아이템(담당 교사이 직접 해야 함 — Claude가 대신 못 함, 결정 문서 8절과 동일 성격):
--   (최초 시도했던 "alter database ... set app.settings.xxx"는 Supabase 호스팅
--   프로젝트에서 권한 오류로 막힌다 — DB 전역 GUC는 클라이언트가 못 바꾼다.
--   대신 Supabase 공식 비밀값 저장소인 Vault 확장을 쓴다.)
--
--   SQL Editor에서 딱 1회만 실행(pepper 값 자체는 git에 올리지 말 것):
--
--     select vault.create_secret(
--       '<32바이트 이상의 무작위 문자열>',
--       'pre_application_pepper',
--       'M8 조회코드 HMAC pepper'
--     );
--
--   무작위 값은 이 마이그레이션 실행 후 SQL Editor에서
--     select encode(gen_random_bytes(32), 'base64');
--   로 만들어서 그대로 위 문장에 붙여넣으면 된다.
--
--   미설정 시 verify/set 함수가 조용히 넘어가지 않고 바로 예외를 던지도록
--   만들어뒀다(약한 기본값으로 동작하는 것보다 안전).

-- ============================================================
-- 1. pgcrypto 확장 (hmac 함수용)
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 2. pepper 조회 helper — Supabase Vault에서 읽는다.
--    (미설정 시 조용히 넘어가지 않고 예외 — 위 액션 아이템 참고)
-- ============================================================

create or replace function public._pre_application_pepper()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pepper text;
begin
  select decrypted_secret into pepper
  from vault.decrypted_secrets
  where name = 'pre_application_pepper'
  limit 1;

  if pepper is null or length(pepper) < 16 then
    raise exception 'Vault에 pre_application_pepper 비밀값이 없거나 너무 짧습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;
  return pepper;
end;
$$;

revoke execute on function public._pre_application_pepper() from public, anon, authenticated;

-- ============================================================
-- 3. 조회코드 해시 helper (HMAC-SHA256 + pepper, hex 인코딩)
-- ============================================================

create or replace function public._hash_pre_application_code(raw_code text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select encode(hmac(raw_code, public._pre_application_pepper(), 'sha256'), 'hex');
$$;

revoke execute on function public._hash_pre_application_code(text) from public, anon, authenticated;

-- ============================================================
-- 4. 이벤트 기록 helper (내부 전용 — 원문 개인정보 복제 금지)
-- ============================================================

create or replace function public._record_pre_application_event(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_event_type text,
  p_actor_type text,
  p_actor_uid uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.pre_application_events
    (pre_application_id, pre_application_no, event_type, actor_type, actor_uid, metadata, function_version)
  values
    (p_pre_application_id, p_pre_application_no, p_event_type, p_actor_type, p_actor_uid, p_metadata, 'v1');
end;
$$;

revoke execute on function public._record_pre_application_event(uuid, text, text, text, uuid, jsonb) from public, anon, authenticated;

-- ============================================================
-- 5. 조회코드 설정 (createPreApplication에서 사용 — 3번 단계에서 호출)
--    호출자가 6자리 원문을 만들어 넘기면, 여기서 해시만 저장하고 원문은
--    반환하지 않는다(원문은 완료 화면에 1회만 보여주고 저장하지 않음).
-- ============================================================

create or replace function public.set_pre_application_access_code(
  p_pre_application_id uuid,
  p_raw_code text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_raw_code is null or p_raw_code !~ '^[0-9]{6}$' then
    raise exception '조회코드는 6자리 숫자여야 합니다.';
  end if;

  insert into public.pre_application_secrets
    (pre_application_id, access_code_verifier, verifier_version, failed_attempts, locked_until, last_failed_at)
  values
    (p_pre_application_id, public._hash_pre_application_code(p_raw_code), 1, 0, null, null)
  on conflict (pre_application_id) do update set
    access_code_verifier = excluded.access_code_verifier,
    verifier_version = public.pre_application_secrets.verifier_version + 1,
    failed_attempts = 0,
    locked_until = null,
    last_failed_at = null;
end;
$$;

revoke execute on function public.set_pre_application_access_code(uuid, text) from public, anon, authenticated;

-- ============================================================
-- 6. 조회 인증 — 임시접수번호 + 성명 + 6자리 조회코드
--    성공/실패 boolean만 반환. 실패 사유(미존재/이름불일치/코드불일치/잠금)는
--    호출자에게 절대 구분해서 알려주지 않는다(결정 문서 9절 4번).
--    내부 이벤트 로그에는 감사 목적으로 사유를 남기되, 원문 개인정보는 넣지 않는다.
-- ============================================================

create or replace function public.verify_pre_application_access(
  p_pre_application_no text,
  p_name text,
  p_raw_code text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  sec_row record;
  name_ok boolean;
  code_ok boolean;
begin
  -- 대상 pre_application + private + secrets를 한 번에 잠금 조회
  -- (FOR UPDATE로 동시 요청 간 failed_attempts 경합을 막는다)
  select pa.id, pa.pre_application_no, pp.name
  into app_row
  from public.pre_applications pa
  join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    -- 존재하지 않음 — 잠글 secrets 행 자체가 없으므로 실패만 기록하고 반환.
    perform public._record_pre_application_event(
      null, p_pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'not_found'));
    return false;
  end if;

  select * into sec_row
  from public.pre_application_secrets
  where pre_application_id = app_row.id
  for update;

  if sec_row is null then
    -- 데이터 정합성 이상(사전작성은 있는데 secrets가 없음) — 역시 일반 실패로 처리
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'no_secret_row'));
    return false;
  end if;

  -- 잠금 상태면 코드 검증 자체를 하지 않고 즉시 실패(추가 시도로 잠금이
  -- 갱신되지 않도록 failed_attempts도 건드리지 않는다)
  if sec_row.locked_until is not null and sec_row.locked_until > now() then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.locked_attempt', 'applicant',
      null, jsonb_build_object('lockedUntil', sec_row.locked_until));
    return false;
  end if;

  name_ok := trim(app_row.name) = trim(p_name);
  code_ok := sec_row.access_code_verifier = public._hash_pre_application_code(p_raw_code);

  if name_ok and code_ok then
    update public.pre_application_secrets
    set failed_attempts = 0, locked_until = null, last_failed_at = null
    where pre_application_id = app_row.id;

    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.succeeded', 'applicant');
    return true;
  end if;

  -- 실패: 시도 횟수 증가. 5회 도달 시 10분 잠금(결정 문서 9절 4번).
  update public.pre_application_secrets
  set failed_attempts = sec_row.failed_attempts + 1,
      last_failed_at = now(),
      locked_until = case
        when sec_row.failed_attempts + 1 >= 5 then now() + interval '10 minutes'
        else locked_until
      end
  where pre_application_id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
    null,
    jsonb_build_object(
      'reason', case when not name_ok and not code_ok then 'name_and_code_mismatch'
                     when not name_ok then 'name_mismatch'
                     else 'code_mismatch' end,
      'failedAttempts', sec_row.failed_attempts + 1
    ));

  return false;
end;
$$;

revoke execute on function public.verify_pre_application_access(text, text, text) from public, anon, authenticated;

comment on function public.verify_pre_application_access(text, text, text) is
  '반환값은 boolean 하나뿐이며 실패 사유를 절대 노출하지 않는다. 이 함수를 감싸는 Edge Function(3번 단계)도 이 원칙을 그대로 지켜야 한다 — 사유별로 다른 HTTP 상태코드/메시지를 만들지 말 것.';

-- ======================================================================
-- 00025_create_pre_application.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8a createPreApplication RPC (Sprint 1B #3 일부)
-- 마스터 스펙 v1.2 섹션 1330행 M8a, `M8_아키텍처_결정_2026-07-10.md` 3.1/5절 대응.
--
-- 이 함수는 Edge Function(createPreApplication, 이 마이그레이션과 별도로
-- supabase/functions/create-pre-application/index.ts에서 작성)이 Turnstile
-- 검증을 통과한 뒤 service_role로 호출한다. public/anon/authenticated에서는
-- 직접 호출 불가 — 00024에서 확인한 대로 revoke는 반드시 public까지 포함한다.
--
-- 임시번호 형식: 'P' + YYMMDD + 3자리 일련번호(연/차수/일자별) — 00003의
-- _allocate_receipt_no와 동일한 FOR UPDATE 카운터 패턴(방법 구분만 없음).

-- ============================================================
-- 1. 임시번호 카운터 테이블
-- ============================================================

create table public.pre_application_counters (
  year int not null,
  round admission_round not null,
  date_key text not null,   -- 'YYMMDD'
  last_seq int not null default 0,
  primary key (year, round, date_key)
);

alter table public.pre_application_counters enable row level security;
-- 정책 없음 = 클라이언트 전면 차단(00023과 동일 원칙). RPC 내부에서만 접근.

-- ============================================================
-- 2. 임시번호 채번 (내부 함수 — RPC에서만 호출)
-- ============================================================

create or replace function public._allocate_pre_application_no(
  target_year int,
  target_round admission_round,
  at_time timestamptz default now()
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dk text := to_char(at_time at time zone 'Asia/Seoul', 'YYMMDD');
  seq int;
begin
  insert into public.pre_application_counters (year, round, date_key, last_seq)
  values (target_year, target_round, dk, 0)
  on conflict (year, round, date_key) do nothing;

  update public.pre_application_counters
  set last_seq = last_seq + 1
  where year = target_year and round = target_round and date_key = dk
  returning last_seq into seq;

  if seq > 999 then
    raise exception '일일 사전작성 임시번호 한도(999)를 초과했습니다.';
  end if;

  return 'P' || dk || lpad(seq::text, 3, '0');
end;
$$;

revoke execute on function public._allocate_pre_application_no(int, admission_round, timestamptz)
  from public, anon, authenticated;

-- ============================================================
-- 3. 6자리 조회코드 무작위 생성 (암호학적 난수 — pgcrypto gen_random_bytes)
-- ============================================================

create or replace function public._generate_pre_application_access_code()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  buf bytea := gen_random_bytes(4);
  n bigint;
begin
  -- 4바이트 하나를 뽑아 정수로 합치고 6자리로 축소 — 매 바이트마다 새
  -- gen_random_bytes를 부르지 않는다(불필요한 낭비이자 원래 의도와도 다름).
  n := get_byte(buf, 0)::bigint * 16777216
     + get_byte(buf, 1)::bigint * 65536
     + get_byte(buf, 2)::bigint * 256
     + get_byte(buf, 3)::bigint;
  return lpad((n % 1000000)::text, 6, '0');
end;
$$;

revoke execute on function public._generate_pre_application_access_code() from public, anon, authenticated;

comment on function public._generate_pre_application_access_code() is
  'gen_random_bytes(pgcrypto)로 암호학적 난수를 뽑아 6자리 숫자로 변환. random()은
   보안 목적 난수로 부적합해 사용하지 않는다.';

-- ============================================================
-- 4. createPreApplication 본체
--    Turnstile 검증은 Edge Function에서 이미 통과한 뒤 호출된다고 가정 —
--    이 함수 자체는 봇 방지 로직을 모른다(단일 책임 분리).
-- ============================================================

create or replace function public.create_pre_application(
  p_year int,
  p_round admission_round,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_name text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  schedule_json jsonb;
  receipt_end date;
  new_expires_at timestamptz;
  new_pre_application_no text;
  new_access_code text;
  new_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_tracks is null or array_length(p_tracks, 1) is null then
    raise exception '전형(tracks)은 필수입니다.';
  end if;
  if p_receipt_method not in ('M', 'V') then
    raise exception '접수방법은 M(우편) 또는 V(방문)이어야 합니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  -- expires_at = 접수마감(receiptEnd) + 30일 (결정 문서 9절 7번).
  -- schedule에 receiptEnd가 없으면 조용히 넘어가지 않고 예외 — 약한
  -- 기본값(예: "일단 60일 뒤")보다 안전.
  select cr.schedule into schedule_json
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = p_year and ar.round = p_round;

  receipt_end := (schedule_json->>'receiptEnd')::date;
  if receipt_end is null then
    raise exception '차수(%, %) config에 receiptEnd가 설정되어 있지 않습니다.', p_year, p_round;
  end if;
  new_expires_at := (receipt_end + interval '30 days') at time zone 'Asia/Seoul';

  new_pre_application_no := public._allocate_pre_application_no(p_year, p_round);
  new_access_code := public._generate_pre_application_access_code();

  insert into public.pre_applications
    (year, round, pre_application_no, tracks, academic_status, school,
     grade_class_no, semester_choice, receipt_method, expires_at)
  values
    (p_year, p_round, new_pre_application_no, p_tracks, p_academic_status, p_school,
     p_grade_class_no, p_semester_choice, p_receipt_method, new_expires_at)
  returning id into new_id;

  insert into public.pre_applications_private
    (pre_application_id, name, gender, birth_date, applicant_phone, email,
     address, guardian_name, guardian_relation, guardian_phone)
  values
    (new_id, trim(p_name), p_gender, p_birth_date, p_applicant_phone, p_email,
     p_address, p_guardian_name, p_guardian_relation, p_guardian_phone);

  perform public.set_pre_application_access_code(new_id, new_access_code);

  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.created', 'system');

  -- accessCode는 이 응답에서만 1회 반환한다 — 이후 어디에도 원문으로 남지 않는다
  -- (pre_application_secrets에는 해시만 저장됨, 00024 참고).
  return json_build_object(
    'preApplicationId', new_id,
    'preApplicationNo', new_pre_application_no,
    'accessCode', new_access_code,
    'expiresAt', new_expires_at
  );
end;
$$;

revoke execute on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text
) from public, anon, authenticated;

comment on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text
) is
  'Edge Function(createPreApplication)이 Turnstile 검증 통과 후 service_role로만
   호출한다. public/anon/authenticated 직접 호출 전면 차단.';

-- ======================================================================
-- 00026_pre_application_rate_limit.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 Edge Function IP 레이트리밋 (Sprint 1B #3 일부)
-- `M8_아키텍처_결정_2026-07-10.md` 3.3 대응: "Edge Function 자체의 IP/
-- preApplicationId 기준 레이트리밋은 별도 pre_application_rate_limits
-- 테이블(윈도우 카운트 방식)로 구현".
--
-- Redis 없이 고정 윈도우 카운터로 구현 (기존 receipt_counters/
-- pre_application_counters와 동일한 단순 카운터 패턴). 완벽한 슬라이딩
--윈도우는 아니지만 봇 방지 목적엔 충분하고, 별도 인프라가 필요 없다.

create table public.pre_application_rate_limits (
  bucket_key text primary key,   -- 예: 'create:203.0.113.1' (동작종류:IP)
  window_start timestamptz not null,
  request_count int not null default 0
);

alter table public.pre_application_rate_limits enable row level security;
-- 정책 없음 = 클라이언트 전면 차단. RPC 내부에서만 접근.

create or replace function public._check_pre_application_rate_limit(
  p_bucket_key text,
  p_max_requests int,
  p_window_seconds int
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  row_rec record;
begin
  select * into row_rec
  from public.pre_application_rate_limits
  where bucket_key = p_bucket_key
  for update;

  if row_rec is null then
    insert into public.pre_application_rate_limits (bucket_key, window_start, request_count)
    values (p_bucket_key, now(), 1);
    return true;
  end if;

  if row_rec.window_start + make_interval(secs => p_window_seconds) <= now() then
    -- 윈도우 만료 → 새 윈도우로 리셋
    update public.pre_application_rate_limits
    set window_start = now(), request_count = 1
    where bucket_key = p_bucket_key;
    return true;
  end if;

  if row_rec.request_count >= p_max_requests then
    return false;
  end if;

  update public.pre_application_rate_limits
  set request_count = request_count + 1
  where bucket_key = p_bucket_key;
  return true;
end;
$$;

revoke execute on function public._check_pre_application_rate_limit(text, int, int)
  from public, anon, authenticated;

comment on function public._check_pre_application_rate_limit(text, int, int) is
  '고정 윈도우 카운터. true면 허용(카운트 증가됨), false면 이번 요청은 거부(카운트
   증가 없음). Edge Function이 IP별로 호출 — 예: 5분당 5회.';

-- ======================================================================
-- 00027_pre_application_bundle_support.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8b 제출서류 병합 PDF 지원 (Sprint 1B #5 전반부)
-- 마스터 스펙 1368행 M8b, `M8_아키텍처_결정_2026-07-10.md` 3.5/3.6/3.24/3.25 대응.
--
-- 이번 마이그레이션 범위:
--   1. Storage 버킷(pre-application-bundles) — 정책 없음(전면 차단), 접근은
--      전부 generate-application-bundle Edge Function(service_role)이 발급하는
--      15분 signed URL을 통해서만(3.6).
--   2. record_pre_application_bundle_generated RPC — 병합 PDF 생성 완료 후
--      pre_applications.print_bundle/checklist_ack/status를 원자적으로 갱신하고
--      감사 이벤트를 남긴다. Edge Function이 PDF를 만들고 Storage에 올린 *다음*
--      이 RPC를 호출하는 순서로 쓴다(PDF 생성 자체는 RPC 밖, Deno 쪽 책임).
--
-- 불변조건 재확인:
--   2. 이 RPC는 public/anon/authenticated에서 실행 금지 — service_role
--      (Edge Function)만 호출한다.
--   5. print_bundle에는 파일 원문이나 개인정보를 담지 않는다 — 경로·시각·횟수만.

-- ============================================================
-- 1. Storage 버킷
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pre-application-bundles', 'pre-application-bundles', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

-- 의도적으로 storage.objects 정책을 하나도 만들지 않는다 — RLS enabled +
-- 정책 없음 = anon/authenticated 전면 차단. 모든 읽기는 service_role이
-- Edge Function 안에서 만드는 15분 signed URL로만 이뤄진다(3.6 원칙,
-- 00023의 pre_applications 4테이블과 동일한 패턴).

-- ============================================================
-- 2. record_pre_application_bundle_generated
-- ============================================================

create or replace function public.record_pre_application_bundle_generated(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_storage_path text,
  p_checklist_version text,
  p_acknowledged_at timestamptz
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  is_first boolean;
  new_status text;
  prev_count int;
  new_bundle jsonb;
begin
  select * into app_row
  from public.pre_applications
  where id = p_pre_application_id
  for update;

  if not found then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  is_first := (app_row.print_bundle ->> 'firstGeneratedAt') is null;
  prev_count := coalesce((app_row.print_bundle ->> 'generationCount')::int, 0);

  -- 접수마감 이후(만료) 상태는 재생성 자체를 허용하지 않는다.
  if app_row.status = 'expired' then
    raise exception '이미 만료된 사전작성입니다.';
  end if;

  -- completed 상태에서 최초 생성 시에만 상태를 bundleGenerated로 올린다.
  -- 도착확인/검수/전환 이후 단계에서 재출력해도 상태는 그대로 유지한다
  -- (마스터스펙 1410행 — 재출력은 상태 전이가 아니다).
  new_status := case
    when app_row.status = 'completed' then 'bundleGenerated'
    else app_row.status
  end;

  new_bundle := jsonb_build_object(
    'version', p_checklist_version,
    'firstGeneratedAt', coalesce(app_row.print_bundle ->> 'firstGeneratedAt', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
    'lastGeneratedAt', now(),
    'generationCount', prev_count + 1,
    'storagePath', p_storage_path
  );

  update public.pre_applications
  set status = new_status,
      print_bundle = new_bundle,
      checklist_ack = jsonb_build_object('version', p_checklist_version, 'acknowledgedAt', p_acknowledged_at)
  where id = p_pre_application_id;

  perform public._record_pre_application_event(
    p_pre_application_id,
    p_pre_application_no,
    case when is_first then 'preApplication.bundle.generated' else 'preApplication.bundle.reprinted' end,
    'applicant',
    null,
    jsonb_build_object('checklistVersion', p_checklist_version, 'generationCount', prev_count + 1)
  );

  return json_build_object(
    'status', new_status,
    'firstGenerated', is_first,
    'generationCount', prev_count + 1
  );
end;
$$;

revoke execute on function public.record_pre_application_bundle_generated(
  uuid, text, text, text, timestamptz
) from public, anon, authenticated;

comment on function public.record_pre_application_bundle_generated(uuid, text, text, text, timestamptz) is
  'generate-application-bundle Edge Function이 PDF를 Storage에 올린 *다음* 호출한다.
   PDF 생성 자체(pdf-lib)는 이 함수 밖 Deno 코드 책임 — 이 함수는 메타데이터
   갱신·상태 전이·감사로그만 담당한다.';

-- ======================================================================
-- 00028_pre_application_tracking_and_cron.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8b/c 마무리: 등기 발송정보 등록 + 자동 파기/정리 (Sprint 1B #5 후반부)
-- 마스터 스펙 1389행 M8c(등기 발송정보 등록), `M8_아키텍처_결정_2026-07-10.md` 3.6/3.7 대응.
--
-- 이번 마이그레이션 범위:
--   1. register_pre_application_tracking_number RPC — 등기우편(receipt_method='M')
--      선택자만 등기번호를 등록할 수 있다. registerTrackingNumber Edge Function이
--      호출한다.
--   2. pg_cron 자동 정리 2건:
--      a) 임시 PDF 24시간 삭제(3.6) — pre-application-bundles 버킷 오브젝트
--      b) 미전환 사전작성 30일 후 자동 파기(3.7, Sprint 1B DoD) — 이미
--         expires_at 자체가 "접수마감+30일" 시점으로 계산되어 있으므로
--         (00025 create_pre_application), expires_at이 지난 미전환 건의
--         개인정보(pre_applications_private/secrets)를 삭제하고 상태만
--         'expired'로 남긴다 — 통계·감사 목적의 비민감 정보는 유지.
--
-- ⚠️ 이 마이그레이션은 pg_cron 확장이 프로젝트에 이미 활성화돼 있어야
-- 한다. Supabase 대시보드 → Database → Extensions에서 "pg_cron"을 먼저
-- 켜야 할 수 있다(Vault 때와 마찬가지로, 없으면 CREATE EXTENSION 구문이
-- 권한 오류를 낼 수 있음 — 그때는 대시보드에서 켠 다음 이 파일만 다시
-- 실행하면 된다).

create extension if not exists pg_cron;

-- ============================================================
-- 1. 등기 발송정보 등록
-- ============================================================

create or replace function public.register_pre_application_tracking_number(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_tracking_number text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  cleaned text;
begin
  select * into app_row
  from public.pre_applications
  where id = p_pre_application_id
  for update;

  if not found then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  if app_row.status = 'expired' then
    raise exception '이미 만료된 사전작성입니다.';
  end if;

  if app_row.receipt_method <> 'M' then
    -- 마스터스펙 1408행: 등기우편 선택자만 이 기능을 쓸 수 있다.
    raise exception '등기우편으로 접수하는 경우에만 등기 발송정보를 등록할 수 있습니다.';
  end if;

  cleaned := regexp_replace(coalesce(p_tracking_number, ''), '\s', '', 'g');
  if length(cleaned) < 8 or length(cleaned) > 20 or cleaned !~ '^[0-9A-Za-z-]+$' then
    raise exception '등기번호 형식이 올바르지 않습니다.';
  end if;

  update public.pre_applications
  set shipping = jsonb_build_object('trackingNumber', cleaned, 'registeredAt', now())
  where id = p_pre_application_id;

  perform public._record_pre_application_event(
    p_pre_application_id, p_pre_application_no,
    'preApplication.shipping.trackingRegistered', 'applicant',
    null, jsonb_build_object('hasTrackingNumber', true)
  );

  return json_build_object('registeredAt', now());
end;
$$;

revoke execute on function public.register_pre_application_tracking_number(uuid, text, text)
  from public, anon, authenticated;

comment on function public.register_pre_application_tracking_number(uuid, text, text) is
  '등기번호 원문은 shipping jsonb에만 저장한다(마스터스펙 1408행 — 1차년도에는
   배송조회 API 연동 없음, 등록 자체가 원서접수 완료를 의미하지 않음).';

-- ============================================================
-- 2a. 임시 PDF 24시간 삭제
-- ============================================================

create or replace function public._cleanup_expired_pre_application_bundles()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from storage.objects
  where bucket_id = 'pre-application-bundles'
    and created_at < now() - interval '24 hours';
end;
$$;

comment on function public._cleanup_expired_pre_application_bundles() is
  'pg_cron 전용. Storage 오브젝트만 지운다 — pre_applications.print_bundle
   메타데이터(경로·시각·횟수)는 감사 목적으로 그대로 남긴다.';

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-expired-pre-application-bundles') then
    perform cron.unschedule('cleanup-expired-pre-application-bundles');
  end if;
end;
$$;

select cron.schedule(
  'cleanup-expired-pre-application-bundles',
  '0 * * * *', -- 매시 정각
  $$select public._cleanup_expired_pre_application_bundles();$$
);

-- ============================================================
-- 2b. 미전환 사전작성 30일 후 자동 파기
-- ============================================================

create or replace function public._purge_expired_pre_applications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
begin
  for rec in
    select id, pre_application_no
    from public.pre_applications
    where status not in ('converted', 'expired')
      and expires_at < now()
    for update skip locked
  loop
    delete from public.pre_applications_private where pre_application_id = rec.id;
    delete from public.pre_application_secrets where pre_application_id = rec.id;

    update public.pre_applications
    set status = 'expired'
    where id = rec.id;

    perform public._record_pre_application_event(
      rec.id, rec.pre_application_no, 'preApplication.purged', 'system'
    );
  end loop;
end;
$$;

comment on function public._purge_expired_pre_applications() is
  'pg_cron 전용. expires_at은 create_pre_application 시점에 이미
   "접수마감+30일"로 계산돼 있다(00025) — 이 함수는 그 시점이 지난
   미전환 건의 개인정보만 삭제하고 pre_applications 행 자체와 이벤트
   로그는 통계·감사 목적으로 남긴다.';

do $$
begin
  if exists (select 1 from cron.job where jobname = 'purge-expired-pre-applications') then
    perform cron.unschedule('purge-expired-pre-applications');
  end if;
end;
$$;

select cron.schedule(
  'purge-expired-pre-applications',
  '0 3 * * *', -- 매일 새벽 3시
  $$select public._purge_expired_pre_applications();$$
);

-- ======================================================================
-- 00029_get_pre_application_status.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8c 원서 준비·접수 조회 (Sprint 1B #6)
-- 마스터 스펙 1389행 M8c, `M8_아키텍처_결정_2026-07-10.md` 3.1/9절 불변조건 5 대응.
--
-- get_pre_application_status: 회원가입 없이 임시접수번호+성명+6자리 조회코드로
-- 인증한 뒤, 마스터스펙 1393~1404행이 정한 "표시 가능 정보"만 반환한다.
-- 주소·전화번호·보호자 정보·등기번호 원문·관리자 메모·평가정보는 절대
-- 반환하지 않는다 — 이 함수 자체가 그 경계를 강제한다(pre_applications_private/
-- pre_application_secrets 컬럼은 여기서 단 하나도 select하지 않는다).

create or replace function public.get_pre_application_status(
  p_pre_application_no text,
  p_name text,
  p_raw_code text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  auth_ok boolean;
  app_row record;
  priv_name text;
  masked_name text;
  current_step text;
begin
  auth_ok := public.verify_pre_application_access(p_pre_application_no, p_name, p_raw_code);
  if not auth_ok then
    return null;
  end if;

  select *
  into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if not found then
    return null;
  end if;

  -- 파기(30일 경과)로 private 행이 이미 삭제됐을 수 있다 — 그 경우 인증 시
  -- 입력한 성명으로 마스킹한다(어차피 verify가 이름 일치를 확인했으므로 안전).
  select name into priv_name
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  masked_name := left(coalesce(priv_name, p_name), 1)
    || repeat('*', greatest(char_length(coalesce(priv_name, p_name)) - 1, 0));

  current_step := case app_row.status
    when 'completed' then '출력서류 생성 대기'
    when 'bundleGenerated' then '제출 준비/발송'
    when 'arrived' then '제출서류 검수 대기'
    when 'reviewing' then '제출서류 검수 중'
    when 'supplementRequired' then '보완 필요'
    when 'converted' then '원서접수 완료'
    when 'expired' then '접수기간 만료'
    else '확인 필요'
  end;

  return json_build_object(
    'maskedName', masked_name,
    'preApplicationNo', app_row.pre_application_no,
    'completedAt', app_row.created_at,
    'status', app_row.status,
    'receiptMethod', app_row.receipt_method,
    'bundleGeneratedAt', app_row.print_bundle ->> 'lastGeneratedAt',
    'bundleGenerationCount', coalesce((app_row.print_bundle ->> 'generationCount')::int, 0),
    'shippingRegistered', (app_row.shipping ? 'trackingNumber'),
    'arrivalConfirmed', (app_row.arrival ? 'confirmedAt'),
    'documentReviewStatus', app_row.document_review ->> 'publicStatus',
    'converted', (app_row.status = 'converted'),
    'finalApplicationNo', app_row.conversion ->> 'receiptNo',
    'currentStep', current_step
  );
end;
$$;

revoke execute on function public.get_pre_application_status(text, text, text)
  from public, anon, authenticated;

comment on function public.get_pre_application_status(text, text, text) is
  '반환 필드는 마스터스펙 1393~1404행 "표시 가능 정보" 목록을 그대로 따른다.
   주소·전화번호·보호자 정보·등기번호 원문·관리자 메모·평가정보는 절대 포함
   하지 않는다 — 이 함수를 감싸는 Edge Function도 이 목록을 넘어서는 필드를
   추가로 조회·반환하면 안 된다.';

-- ======================================================================
-- 00030_pre_application_assets_bucket.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8b 정적 자산(한글 폰트·원본 양식 PDF) Storage 버킷
-- `generate-application-bundle` Edge Function이 폰트 2종·원본 양식 PDF 3종을
-- 함수 코드에 직접 묻지 않고(배포 페이로드 제한으로 두 번 실패했음 — 자세한
-- 내용은 supabase/functions/_shared/pdfKoreanFont.ts 상단 주석 참고)
-- 이 버킷에서 매 호출마다 service_role로 다운로드해서 쓴다.
--
-- 이 마이그레이션은 버킷만 만든다. 실제 파일 5개(fonts/Pretendard-Regular.ttf,
-- fonts/Pretendard-Bold.ttf, formTemplates/2026-draft-v1/general.pdf,
-- formTemplates/2026-draft-v1/incheonRecommend.pdf,
-- formTemplates/2026-draft-v1/socialIntegration.pdf)는 Supabase 대시보드
-- Storage 화면에서 관리자가 직접 업로드한다 — CLI/코드가 아니라 사람이
-- 올려두는 정적 자산이라는 점이 다른 버킷과 다르다.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pre-application-assets',
  'pre-application-assets',
  false,
  10485760,
  array['font/ttf', 'application/font-sfnt', 'application/octet-stream', 'application/pdf']
)
on conflict (id) do nothing;

-- 의도적으로 storage.objects 정책을 하나도 만들지 않는다 — RLS enabled +
-- 정책 없음 = anon/authenticated 전면 차단. Edge Function의 service_role만
-- 다운로드 가능(00027/00028과 동일한 원칙).

-- ======================================================================
-- 00031_pre_application_purge_status_fix.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8c 파기 후 상태조회 가능하도록 수정 (회귀 테스트 작성 중 발견된 버그)
--
-- 문제: 00029 get_pre_application_status는 "private 행이 파기된 뒤에도 입력한
-- 성명으로 마스킹해 응답한다"는 fallback을 갖고 있었지만, 인증을 담당하는
-- 00024 verify_pre_application_access가 pre_applications_private를 INNER JOIN
-- 하기 때문에 private 행이 삭제되면(=30일 자동 파기 이후) 인증 자체가 무조건
-- 실패해서 그 fallback에 절대 도달하지 못했다 — 즉 파기 후에는 지원자가 정확한
-- 이름/조회코드를 입력해도 상태조회가 완전히 막히는 버그였다.
--
-- 결정: 파기 후에도 "접수기간 만료"라는 최소 상태는 조회 가능해야 한다(제품
-- 결정, 2026-07-10). 다만 파기의 목적(주소·연락처·보호자 등 민감정보 삭제)은
-- 그대로 지킨다 — 이름은 원문이 아니라 해시로만 남겨서 이름 검증을 계속
-- 가능하게 하고, 조회코드 검증에 필요한 pre_application_secrets는 이제 파기
-- 시점에 삭제하지 않는다(주소/연락처/보호자 등 민감정보가 아니므로).
--
-- 변경 사항:
--   1. pre_applications.purged_name_hash 컬럼 추가(파기 시점에만 채워짐).
--   2. _hash_pre_application_name(name) — 조회코드 해시와 동일한 pepper/HMAC
--      방식으로 성명을 해시. 원문 복원 불가.
--   3. verify_pre_application_access를 LEFT JOIN으로 바꿔 private이 없어도
--      진행하고, private.name이 없으면 purged_name_hash와 비교한다.
--   4. _purge_expired_pre_applications: private 삭제 *직전*에 이름을 해시로
--      저장. pre_application_secrets는 더 이상 삭제하지 않는다(조회코드 검증을
--      계속 쓸 수 있어야 하므로 — 5회 실패시 10분 잠금 로직도 계속 유효).

-- ============================================================
-- 1. 컬럼 추가
-- ============================================================

alter table public.pre_applications
  add column if not exists purged_name_hash text;

comment on column public.pre_applications.purged_name_hash is
  '30일 자동 파기로 pre_applications_private.name이 삭제된 뒤에도 상태조회
   인증(verify_pre_application_access)이 이름을 확인할 수 있도록 남겨두는
   해시. 원문 성명은 복원 불가(HMAC + pepper, 00024와 동일 방식).';

-- ============================================================
-- 2. 성명 해시 helper
-- ============================================================

create or replace function public._hash_pre_application_name(p_name text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select encode(hmac(trim(coalesce(p_name, '')), public._pre_application_pepper(), 'sha256'), 'hex');
$$;

revoke execute on function public._hash_pre_application_name(text) from public, anon, authenticated;

-- ============================================================
-- 3. verify_pre_application_access 재정의 (LEFT JOIN + 해시 fallback)
-- ============================================================

create or replace function public.verify_pre_application_access(
  p_pre_application_no text,
  p_name text,
  p_raw_code text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  sec_row record;
  name_ok boolean;
  code_ok boolean;
begin
  -- private이 파기돼 없어도(=purged_name_hash로 대체 검증) 진행할 수 있도록
  -- INNER JOIN 대신 LEFT JOIN으로 바꾼다.
  select pa.id, pa.pre_application_no, pp.name, pa.purged_name_hash
  into app_row
  from public.pre_applications pa
  left join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    perform public._record_pre_application_event(
      null, p_pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'not_found'));
    return false;
  end if;

  select * into sec_row
  from public.pre_application_secrets
  where pre_application_id = app_row.id
  for update;

  if sec_row is null then
    -- private/secrets 둘 다 없는 데이터 정합성 이상 — 일반 실패로 처리
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'no_secret_row'));
    return false;
  end if;

  if sec_row.locked_until is not null and sec_row.locked_until > now() then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.locked_attempt', 'applicant',
      null, jsonb_build_object('lockedUntil', sec_row.locked_until));
    return false;
  end if;

  if app_row.name is not null then
    name_ok := trim(app_row.name) = trim(p_name);
  elsif app_row.purged_name_hash is not null then
    -- 파기 후: 원문 이름 대신 해시로 비교.
    name_ok := app_row.purged_name_hash = public._hash_pre_application_name(p_name);
  else
    name_ok := false;
  end if;

  code_ok := sec_row.access_code_verifier = public._hash_pre_application_code(p_raw_code);

  if name_ok and code_ok then
    update public.pre_application_secrets
    set failed_attempts = 0, locked_until = null, last_failed_at = null
    where pre_application_id = app_row.id;

    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.succeeded', 'applicant');
    return true;
  end if;

  update public.pre_application_secrets
  set failed_attempts = sec_row.failed_attempts + 1,
      last_failed_at = now(),
      locked_until = case
        when sec_row.failed_attempts + 1 >= 5 then now() + interval '10 minutes'
        else locked_until
      end
  where pre_application_id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
    null,
    jsonb_build_object(
      'reason', case when not name_ok and not code_ok then 'name_and_code_mismatch'
                     when not name_ok then 'name_mismatch'
                     else 'code_mismatch' end,
      'failedAttempts', sec_row.failed_attempts + 1
    ));

  return false;
end;
$$;

revoke execute on function public.verify_pre_application_access(text, text, text) from public, anon, authenticated;

comment on function public.verify_pre_application_access(text, text, text) is
  '반환값은 boolean 하나뿐이며 실패 사유를 절대 노출하지 않는다. 파기(30일 경과)
   이후에는 pre_applications_private.name 대신 pre_applications.purged_name_hash로
   이름을 검증한다(00031) — 조회코드 검증은 pre_application_secrets를 그대로 쓴다
   (파기 시점에 더 이상 삭제하지 않음).';

-- ============================================================
-- 4. _purge_expired_pre_applications 재정의 (이름 해시 저장 + secrets 보존)
-- ============================================================

create or replace function public._purge_expired_pre_applications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  v_name text;
begin
  for rec in
    select id, pre_application_no
    from public.pre_applications
    where status not in ('converted', 'expired')
      and expires_at < now()
    for update skip locked
  loop
    select name into v_name
    from public.pre_applications_private
    where pre_application_id = rec.id;

    update public.pre_applications
    set status = 'expired',
        purged_name_hash = case
          when v_name is not null then public._hash_pre_application_name(v_name)
          else purged_name_hash
        end
    where id = rec.id;

    delete from public.pre_applications_private where pre_application_id = rec.id;
    -- pre_application_secrets는 의도적으로 유지한다(00031) — 조회코드
    -- 검증(access_code_verifier)과 5회 실패 잠금 로직이 파기 후에도 계속
    -- 동작해야 상태조회(get_pre_application_status)가 가능하다. 주소·연락처·
    -- 보호자 등 실제 민감정보는 pre_applications_private 삭제만으로 충분히
    -- 제거된다 — 조회코드 해시는 원문 복원이 불가능하므로 민감정보로 보지
    -- 않는다(00024와 동일한 판단).

    perform public._record_pre_application_event(
      rec.id, rec.pre_application_no, 'preApplication.purged', 'system'
    );
  end loop;
end;
$$;

comment on function public._purge_expired_pre_applications() is
  'pg_cron 전용. expires_at은 create_pre_application 시점에 이미
   "접수마감+30일"로 계산돼 있다(00025). private(주소·연락처·보호자 등)은
   삭제하되 이름은 해시로만 남기고(purged_name_hash), 조회코드 secrets는
   삭제하지 않는다(00031) — 파기 후에도 최소 상태("접수기간 만료")는
   지원자 본인이 조회할 수 있어야 하기 때문.';

-- ======================================================================
-- 00032_pre_application_bundle_cleanup_via_edge_function.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8b 24시간 PDF 정리 방식 수정 (회귀 테스트 실행 중 발견된 버그)
--
-- 문제: 00028의 _cleanup_expired_pre_application_bundles()는
-- "delete from storage.objects where ..."로 24시간 지난 병합 PDF를 직접
-- 지우도록 만들어져 있었다. 그런데 Supabase가 storage.objects에
-- protect_delete() 트리거를 걸어놔서 SQL로 직접 DELETE하는 것 자체를
-- 전면 차단한다:
--   ERROR: 42501: Direct deletion from storage tables is not allowed.
--   Use the Storage API instead.
-- 즉 00028 이후 매시 정각 실행된 pg_cron 잡이 실제로는 매번 이 오류로
-- 조용히(사람이 안 보고 있으면 못 알아챌 정도로) 실패해왔다 — 병합 PDF가
-- 24시간 뒤에도 전혀 지워지지 않고 있었다는 뜻이다.
--
-- 원인: storage.objects 메타데이터 행만 지우면 실제 파일(S3 백엔드)이
-- 고아 상태로 남기 때문에, Supabase는 메타데이터+실제 파일을 함께 지우는
-- Storage API(스토리지 REST 엔드포인트, supabase-js의 storage.remove())를
-- 통해서만 삭제를 허용한다.
--
-- 수정 방향: SQL에서는 "무엇을 지울지 목록만 고르고", 실제 삭제는
-- cleanup-expired-bundles Edge Function이 Storage API로 수행하게 한다.
--   1. list_expired_pre_application_bundle_paths() — SELECT만, DELETE 없음.
--   2. _cleanup_expired_pre_application_bundles() — pg_net으로 Edge Function을
--      비동기 호출하도록 재정의(같은 이름 유지 — pg_cron 잡 재등록 불필요).
--
-- ⚠️ 실행 전/후 액션 아이템(담당 교사이 직접 해야 함 — 8/9절과 동일 성격):
--   1) pg_net 확장이 꺼져 있으면 Supabase 대시보드 → Database → Extensions에서
--      "pg_net"을 먼저 켜야 할 수 있다(pg_cron 때와 동일한 이유).
--   2) 이 마이그레이션 실행 후, SQL Editor에서 아래 두 값을 Vault에 등록한다
--      (원문은 git에 올리지 않는다):
--
--        select vault.create_secret(
--          'https://<프로젝트-ref>.supabase.co/functions/v1',
--          'pre_application_edge_functions_base_url',
--          'M8b cleanup-expired-bundles Edge Function base URL'
--        );
--
--        select vault.create_secret(
--          '<32바이트 이상의 무작위 문자열>',
--          'pre_application_cron_secret',
--          'M8b cleanup-expired-bundles 호출 인증용 공유 비밀'
--        );
--
--      무작위 값은 select encode(gen_random_bytes(32), 'base64'); 로 만든다.
--   3) 같은 pre_application_cron_secret 값을 Edge Function 환경변수로도 설정
--      한다(터미널에서):
--        supabase secrets set PRE_APPLICATION_CRON_SECRET=<위와 동일한 값>
--   4) cleanup-expired-bundles Edge Function을 배포한다(아래 8절 참고).

-- ============================================================
-- 1. pg_net 확장
-- ============================================================

create extension if not exists pg_net;

-- ============================================================
-- 2. 정리 대상 경로만 골라주는 RPC (DELETE 없음)
-- ============================================================

create or replace function public.list_expired_pre_application_bundle_paths()
returns text[]
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(array_agg(name), array[]::text[])
  from storage.objects
  where bucket_id = 'pre-application-bundles'
    and created_at < now() - interval '24 hours';
$$;

revoke execute on function public.list_expired_pre_application_bundle_paths()
  from public, anon, authenticated;

comment on function public.list_expired_pre_application_bundle_paths() is
  '실제 삭제는 하지 않는다 — storage.objects 직접 DELETE는 Supabase가 차단한다
   ("Direct deletion from storage tables is not allowed. Use the Storage API
   instead."). cleanup-expired-bundles Edge Function이 이 목록을 받아
   storage.remove()(Storage API)로 실제 삭제한다(00032).';

-- ============================================================
-- 3. _cleanup_expired_pre_application_bundles 재정의
--    (더 이상 DELETE하지 않는다 — pg_net으로 Edge Function을 비동기 호출)
-- ============================================================

create or replace function public._cleanup_expired_pre_application_bundles()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  base_url text;
  cron_secret text;
begin
  select decrypted_secret into base_url
  from vault.decrypted_secrets
  where name = 'pre_application_edge_functions_base_url';

  select decrypted_secret into cron_secret
  from vault.decrypted_secrets
  where name = 'pre_application_cron_secret';

  if base_url is null or cron_secret is null then
    raise exception 'Vault에 pre_application_edge_functions_base_url/pre_application_cron_secret이 없습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;

  -- 비동기(fire-and-forget) 호출 — 응답을 기다리지 않는다. 실행 결과는
  -- Edge Function 로그(cleanup-expired-bundles) 또는 net._http_response
  -- 테이블에서 확인할 수 있다.
  perform net.http_post(
    url => base_url || '/cleanup-expired-bundles',
    body => '{}'::jsonb,
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cron_secret
    ),
    timeout_milliseconds => 10000
  );
end;
$$;

comment on function public._cleanup_expired_pre_application_bundles() is
  'pg_cron 전용(매시 정각). 더 이상 storage.objects를 직접 DELETE하지 않는다
   (Supabase가 차단 — 00032 상단 주석 참고). 대신 pg_net으로
   cleanup-expired-bundles Edge Function을 비동기 호출하고, 그 함수가
   list_expired_pre_application_bundle_paths()로 목록을 받아 storage.remove()
   (Storage API)로 실제 삭제한다. 기존 cron.job(00028에서 등록, 매시 정각)은
   함수 이름이 그대로라 재등록할 필요 없다.';

-- ======================================================================
-- 00033_pre_application_access_code_reissue.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8d(일부) 관리자 조회코드 재발급 + SMS 재발송
-- 담당 교사 요청: "6자리 조회코드를 관리자 화면에서 조회할 수 있으면 좋겠다.
-- 학부모 전화 문의가 많을 것 같다" — 조회코드는 원문 미저장(해시만 저장,
-- 00024)이라 "조회"는 불가능하다. 대신 관리자가 새 코드를 발급하고(기존
-- 코드는 즉시 무효화) 바로 문자로 재발송하는 기능으로 대체한다. 관리자도
-- 새 코드를 화면으로 보지 않는다 — 시스템이 만들어서 바로 발송만 한다.
--
-- 접수 완료 시점 자동발송(같은 요청의 다른 절반)은 Edge Function 쪽
-- (create-pre-application/index.ts + _shared/smsProvider.ts)에서 처리한다 —
-- 그쪽은 이미 원문 코드를 들고 있는 시점이라 별도 RPC가 필요 없다.
--
-- ⚠️ 실행 전/후 액션 아이템:
--   1) 00032에서 이미 등록했다면 pre_application_edge_functions_base_url은
--      재등록할 필요 없다(그대로 재사용).
--   2) 이 마이그레이션 실행 후, SQL Editor에서 새 비밀 1개를 Vault에 등록:
--
--        select vault.create_secret(
--          '<32바이트 이상의 무작위 문자열>',
--          'pre_application_sms_secret',
--          'M8 send-pre-application-sms Edge Function 호출 인증용 공유 비밀'
--        );
--
--      무작위 값은 select encode(gen_random_bytes(32), 'base64'); 로 만든다.
--      (00032의 pre_application_cron_secret과 다른 값을 쓴다 — 기능별로
--      비밀을 분리해서, 하나가 새어도 다른 하나까지 뚫리지 않게 한다.)
--   3) 같은 값을 Edge Function 환경변수로도 설정:
--        supabase secrets set PRE_APPLICATION_SMS_SECRET=<위와 동일한 값>
--   4) send-pre-application-sms Edge Function을 배포한다.
--   5) 실제 문자 발송 자체는 SMS_PROVIDER_ENDPOINT/SMS_PROVIDER_API_KEY/
--      SMS_SENDER_NUMBER가 설정되기 전까지는 "발송 스킵"으로 조용히
--      끝난다(_shared/smsProvider.ts 참고) — 문자 API 계정이 준비되면
--      그 3개 시크릿만 추가로 설정하면 된다.

create or replace function public.reissue_pre_application_access_code(
  p_pre_application_no text,
  p_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  new_code text;
  base_url text;
  sms_secret text;
  masked_phone text;
  phone_len int;
begin
  -- 접수(reception)·관리자(admin)·최고관리자(superadmin)만 — 평가위원 등은 불가.
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);

  select pa.id, pa.pre_application_no, pa.status, pp.name,
         coalesce(pp.applicant_phone, pp.guardian_phone) as phone
  into app_row
  from public.pre_applications pa
  left join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  if app_row.status in ('converted', 'expired') then
    raise exception '이미 전환되었거나 만료된 사전작성은 조회코드를 재발급할 수 없습니다.';
  end if;

  if app_row.phone is null or length(trim(app_row.phone)) = 0 then
    raise exception '등록된 연락처(본인 또는 보호자)가 없어 문자로 재발송할 수 없습니다.';
  end if;

  -- 새 코드 발급 — set_pre_application_access_code가 기존 코드를 즉시
  -- 무효화하고(verifier_version 증가) 실패횟수/잠금도 초기화한다(00024).
  new_code := public._generate_pre_application_access_code();
  perform public.set_pre_application_access_code(app_row.id, new_code);

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.accessCode.reissued', 'admin',
    caller, jsonb_build_object('reason', p_reason)
  );
  -- 원문 코드/전화번호는 이벤트 metadata에도 절대 남기지 않는다.

  select decrypted_secret into base_url
  from vault.decrypted_secrets where name = 'pre_application_edge_functions_base_url';
  select decrypted_secret into sms_secret
  from vault.decrypted_secrets where name = 'pre_application_sms_secret';

  if base_url is null or sms_secret is null then
    raise exception 'Vault에 pre_application_edge_functions_base_url/pre_application_sms_secret이 없습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;

  -- 비동기(fire-and-forget) 호출 — 새 코드는 이 요청 본문에만 실려서
  -- send-pre-application-sms Edge Function으로 전달되고, 이 함수는 이후
  -- 어디에도 원문을 남기지 않는다.
  perform net.http_post(
    url => base_url || '/send-pre-application-sms',
    body => jsonb_build_object(
      'phone', app_row.phone,
      'name', app_row.name,
      'preApplicationNo', app_row.pre_application_no,
      'code', new_code
    ),
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', sms_secret
    ),
    timeout_milliseconds => 10000
  );

  -- 관리자 화면에는 마스킹된 연락처만 돌려준다(원문 코드/전체 전화번호 노출 금지).
  phone_len := char_length(app_row.phone);
  masked_phone := left(app_row.phone, 3)
    || repeat('*', greatest(phone_len - 7, 0))
    || right(app_row.phone, least(4, greatest(phone_len - 3, 0)));

  return json_build_object(
    'reissuedAt', now(),
    'maskedPhone', masked_phone
  );
end;
$$;

revoke all on function public.reissue_pre_application_access_code(text, text) from public, anon;
grant execute on function public.reissue_pre_application_access_code(text, text) to authenticated;

comment on function public.reissue_pre_application_access_code(text, text) is
  '관리자가 6자리 조회코드를 "조회"할 수는 없다(원문 미저장, 00024) — 대신 이
   함수가 새 코드를 발급하고 즉시 SMS로 재발송한다. 반환값에는 마스킹된
   전화번호만 담기고, 원문 코드/전체 전화번호는 호출자(관리자)에게도 절대
   노출하지 않는다. 실제 발송은 send-pre-application-sms Edge Function이
   담당(pg_net으로 비동기 호출).';

-- ======================================================================
-- 00034_pre_application_assets_allow_png.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — pre-application-assets 버킷에 로고(PNG) 업로드 허용
--
-- 00030에서 이 버킷을 만들 때는 폰트(font/ttf 등)와 원본 양식 PDF만 염두에
-- 두고 allowed_mime_types를 좁게 잡았다. 이후 우편라벨에 학교 로고를 넣기로
-- 하면서(logo/school-logo.png) 관리자가 Supabase 대시보드에서 업로드를
-- 시도했으나 "Mime type image/png is not supported" 오류가 발생 — 버킷
-- 생성 시점엔 image/png가 허용 목록에 없었기 때문이다.
--
-- 00030은 `on conflict do nothing`이라 재실행해도 기존 버킷 설정을 덮어쓰지
-- 않으므로, 여기서는 별도로 update만 수행한다.

update storage.buckets
set allowed_mime_types = array[
  'font/ttf',
  'application/font-sfnt',
  'application/octet-stream',
  'application/pdf',
  'image/png'
]
where id = 'pre-application-assets';

-- ======================================================================
-- 00035_pre_application_postal_code.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 사전작성 우편번호(postal_code) 추가
--
-- 배경: 사전작성 5단계의 주소 입력이 자유 텍스트 1칸이라 오타·형식 편차가
-- 컸다. 프론트엔드에 Daum(카카오) 우편번호 검색 위젯을 붙이면서(키 불필요
-- 공개 embed) 5자리 우편번호를 주소 문자열에 섞지 않고 별도 컬럼으로
-- 저장한다 — generate-application-bundle의 우편라벨 "보내는 사람" 칸이
-- 우편번호를 독립적으로 읽어 찍어야 하기 때문.
--
-- 변경 내용:
--   1. pre_applications_private에 postal_code text 컬럼 추가
--   2. create_pre_application RPC에 p_postal_code(선택) 파라미터 추가
--      — 마이그레이션은 append-only이므로 00025를 고치지 않고 여기서
--      전체 본문을 다시 정의한다. 파라미터가 늘면 create or replace가
--      기존 17-인자 버전을 대체하지 못하고 오버로드로 남아 PostgREST
--      rpc() 호출이 모호해지므로, 옛 시그니처를 명시적으로 drop한다.

-- ============================================================
-- 1. 컬럼 추가
-- ============================================================

alter table public.pre_applications_private
  add column if not exists postal_code text;

comment on column public.pre_applications_private.postal_code is
  'Daum 우편번호 검색(zonecode)으로 채워지는 5자리 우편번호. 주소 문자열과
   분리 저장 — 우편라벨(보내는 사람) 프리필에서 독립적으로 사용. 위젯을
   건너뛴 지원자는 null(선택 입력).';

-- ============================================================
-- 2. create_pre_application 재정의 (p_postal_code 추가)
--    본문은 00025 원본 그대로 + pre_applications_private insert에
--    postal_code 한 줄 추가. 옛 시그니처는 오버로드 방지를 위해 drop.
-- ============================================================

drop function if exists public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text);

create or replace function public.create_pre_application(
  p_year int,
  p_round admission_round,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_name text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_postal_code text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  schedule_json jsonb;
  receipt_end date;
  new_expires_at timestamptz;
  new_pre_application_no text;
  new_access_code text;
  new_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_tracks is null or array_length(p_tracks, 1) is null then
    raise exception '전형(tracks)은 필수입니다.';
  end if;
  if p_receipt_method not in ('M', 'V') then
    raise exception '접수방법은 M(우편) 또는 V(방문)이어야 합니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  -- expires_at = 접수마감(receiptEnd) + 30일 (결정 문서 9절 7번).
  -- schedule에 receiptEnd가 없으면 조용히 넘어가지 않고 예외 — 약한
  -- 기본값(예: "일단 60일 뒤")보다 안전.
  select cr.schedule into schedule_json
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = p_year and ar.round = p_round;

  receipt_end := (schedule_json->>'receiptEnd')::date;
  if receipt_end is null then
    raise exception '차수(%, %) config에 receiptEnd가 설정되어 있지 않습니다.', p_year, p_round;
  end if;
  new_expires_at := (receipt_end + interval '30 days') at time zone 'Asia/Seoul';

  new_pre_application_no := public._allocate_pre_application_no(p_year, p_round);
  new_access_code := public._generate_pre_application_access_code();

  insert into public.pre_applications
    (year, round, pre_application_no, tracks, academic_status, school,
     grade_class_no, semester_choice, receipt_method, expires_at)
  values
    (p_year, p_round, new_pre_application_no, p_tracks, p_academic_status, p_school,
     p_grade_class_no, p_semester_choice, p_receipt_method, new_expires_at)
  returning id into new_id;

  insert into public.pre_applications_private
    (pre_application_id, name, gender, birth_date, applicant_phone, email,
     address, postal_code, guardian_name, guardian_relation, guardian_phone)
  values
    (new_id, trim(p_name), p_gender, p_birth_date, p_applicant_phone, p_email,
     p_address, p_postal_code, p_guardian_name, p_guardian_relation, p_guardian_phone);

  perform public.set_pre_application_access_code(new_id, new_access_code);

  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.created', 'system');

  -- accessCode는 이 응답에서만 1회 반환한다 — 이후 어디에도 원문으로 남지 않는다
  -- (pre_application_secrets에는 해시만 저장됨, 00024 참고).
  return json_build_object(
    'preApplicationId', new_id,
    'preApplicationNo', new_pre_application_no,
    'accessCode', new_access_code,
    'expiresAt', new_expires_at
  );
end;
$$;

revoke execute on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text
) from public, anon, authenticated;

comment on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text
) is
  'Edge Function(createPreApplication)이 Turnstile 검증 통과 후 service_role로만
   호출한다. public/anon/authenticated 직접 호출 전면 차단.
   00035: p_postal_code(선택) 추가 — Daum 우편번호 검색 연동.';

-- ======================================================================
-- 00036_transfer_admission_intake.sql
-- ======================================================================

-- 새봄고 전·편입생 선발 전형(공고 제2026-40호, 2026학년도 7월) — 접수대장
--
-- 배경: 신입생 M1~M8 파이프라인과는 지원자격·전형서류·채점기준이 완전히
-- 다른 별개 전형이다(요강 참고: 지원자격은 "고1 재학중"/"자퇴 후 학점 합산
-- 가능"/"대안학교 등에서 전편입", 서류전형은 출결·학업성실도·자기소개서·
-- 보호자소견서 4항목 1000점, 2차는 면접). 접수기간도 2026-07-13(월)~16(목)
-- 이며 우편(등기) 접수만 허용(방문 접수 없음).
--
-- 사용자 요청(2026-07-11)에 따라 신입생 데이터와 물리적으로 완전히
-- 분리한다: admission_round enum('main'/'extra1'/'extra2')을 재사용하지
-- 않고, applicants/applicants_private 등 신입생 테이블도 건드리지 않는다.
-- 대신 M1 register_applicant 패턴(수기접수 RPC + 카운터 기반 접수번호)을
-- 그대로 본떠 완전히 독립된 테이블·RPC 세트를 새로 만든다.
--
-- 접수 방법: 원서 접수 자체가 우편(등기)만 허용되므로(방문 접수 없음),
-- "지원자는 전화/이메일로 문의만 하고 실제 서류는 우편으로 도착 → 직원이
-- 도착한 서류를 보고 시스템에 수기 입력"하는 흐름을 그대로 반영한다
-- (공개 자기작성 위자드는 만들지 않는다 — 애초에 요강에 그런 접수 경로가
-- 없음).

-- ============================================================
-- 1. 접수번호 카운터 + 지원자 테이블
-- ============================================================

create table public.transfer_receipt_counters (
  round_label text not null,        -- 예: '2026-07' (요강 공고 기준 회차 라벨)
  date_key text not null,           -- 'YYMMDD'
  last_seq int not null default 0,
  primary key (round_label, date_key)
);

alter table public.transfer_receipt_counters enable row level security;
-- 정책 없음 = 클라이언트 전면 차단(신입생 receipt_counters와 동일 원칙). RPC 내부에서만 접근.

create table public.transfer_applicants (
  id uuid primary key default gen_random_uuid(),
  round_label text not null default '2026-07',
  receipt_no text not null,          -- 'T' + YYMMDD + 3자리 일련번호 (신입생 접수번호와 시각적으로 구분)
  exam_no text,
  name text not null,
  -- 요강 3번 지원자격: 가(고1 재학중) / 나-1(고1 재학중 자퇴, 잔여 수업일수
  -- 합산으로 진급 기준 충족 가능) / 나-2(대안학교 등에서 학점 인정 전편입)
  eligibility_category text not null
    check (eligibility_category in ('enrolled', 'withdrawn', 'altSchool')),
  current_school text,               -- 전적교(현재 재학 또는 최종 재학) 학교명
  current_grade text,                -- 전적교 학년(대부분 '고1'이지만 자유 기재)
  receipt_method text not null default 'M' check (receipt_method = 'M'), -- 요강: 우편(등기) 접수만, 방문 없음
  receipt_date date not null,        -- 등기 도착일(직원이 봉투 확인 후 입력)
  tracking_no text,                  -- 등기 송장번호(선택, 조회용)
  -- 요강 6번 제출서류 체크리스트를 그대로 키로 사용. 값은 boolean.
  -- {applicationForm, photos, selfIntroduction, guardianOpinion, consentForms,
  --  schoolRecordOrGed, enrollmentOrWithdrawalCert, other}
  document_checklist jsonb not null default '{}'::jsonb,
  application_status text not null default 'received'
    check (application_status in ('received', 'incomplete', 'complete', 'withdrawn', 'excluded')),
  evaluation_stage text not null default 'none'
    check (evaluation_stage in ('none', 'document', 'documentPassed', 'documentFailed',
                                'interview', 'finalPassed', 'finalFailed')),
  staff_memo text,                   -- 전화/이메일 문의 등 접수 전 메모(선택)
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  unique (round_label, receipt_no)
);

comment on table public.transfer_applicants is
  '전·편입생 선발 전형(공고 2026-40호) 지원자. 신입생 applicants 테이블과 완전히 분리된 별도 테이블 — admission_round enum을 공유하지 않는다.';

create table public.transfer_applicants_private (
  applicant_id uuid primary key references public.transfer_applicants (id) on delete cascade,
  gender text check (gender in ('남', '여')),
  birth_date date,
  applicant_phone text,
  email text,
  address text,
  guardian_name text,
  guardian_relation text,
  guardian_phone text,
  withdrawal_date date,              -- 자퇴일자(나-1 해당자)
  alt_school_name text,              -- 전적 대안학교명(나-2 해당자, current_school과 다를 수 있음)
  staff_note text,                   -- 직원 전용 비고(민감할 수 있어 private에 배치)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.transfer_applicants_private is
  '전편입학 지원자 개인정보. M1 applicants_private와 동일한 접근권한 분리 원칙 — superadmin/admin/reception만 조회.';

-- ============================================================
-- 2. RLS — select만 정책, write는 전부 RPC 전용(정책 없음)
-- ============================================================

alter table public.transfer_applicants enable row level security;
alter table public.transfer_applicants_private enable row level security;

create policy transfer_applicants_select_staff
  on public.transfer_applicants for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

create policy transfer_applicants_private_select_staff
  on public.transfer_applicants_private for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

-- ============================================================
-- 3. 접수번호 채번 (내부 함수 — RPC에서만 호출)
-- ============================================================

create or replace function public._allocate_transfer_receipt_no(
  p_round_label text,
  at_time timestamptz default now()
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dk text := to_char(at_time at time zone 'Asia/Seoul', 'YYMMDD');
  seq int;
begin
  insert into public.transfer_receipt_counters (round_label, date_key, last_seq)
  values (p_round_label, dk, 0)
  on conflict (round_label, date_key) do nothing;

  update public.transfer_receipt_counters
  set last_seq = last_seq + 1
  where round_label = p_round_label and date_key = dk
  returning last_seq into seq;

  if seq > 999 then
    raise exception '일일 전편입학 접수번호 한도(999)를 초과했습니다.';
  end if;

  return 'T' || dk || lpad(seq::text, 3, '0');
end;
$$;

revoke execute on function public._allocate_transfer_receipt_no(text, timestamptz) from anon, authenticated;

-- ============================================================
-- 4. register_transfer_applicant RPC — 수기접수(우편 도착분 등록)
-- ============================================================

create or replace function public.register_transfer_applicant(
  p_name text,
  p_eligibility_category text,
  p_receipt_date date,
  p_round_label text default '2026-07',
  p_current_school text default null,
  p_current_grade text default null,
  p_tracking_no text default null,
  p_document_checklist jsonb default '{}'::jsonb,
  p_staff_memo text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_withdrawal_date date default null,
  p_alt_school_name text default null,
  p_staff_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_eligibility_category not in ('enrolled', 'withdrawn', 'altSchool') then
    raise exception '지원자격 구분이 올바르지 않습니다: %', p_eligibility_category;
  end if;
  if p_receipt_date is null then
    raise exception '접수일(등기 도착일)은 필수입니다.';
  end if;

  new_receipt_no := public._allocate_transfer_receipt_no(p_round_label);

  insert into public.transfer_applicants
    (round_label, receipt_no, name, eligibility_category, current_school, current_grade,
     receipt_date, tracking_no, document_checklist, staff_memo, created_by, updated_by)
  values
    (p_round_label, new_receipt_no, trim(p_name), p_eligibility_category, p_current_school,
     p_current_grade, p_receipt_date, p_tracking_no, coalesce(p_document_checklist, '{}'::jsonb),
     p_staff_memo, caller::text, caller::text)
  returning id into new_id;

  insert into public.transfer_applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone, withdrawal_date, alt_school_name, staff_note)
  values
    (new_id, p_gender, p_birth_date, p_applicant_phone, p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_withdrawal_date,
     p_alt_school_name, p_staff_note);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.registered', 'transfer_applicants',
     new_id::text, new_id::text);

  return json_build_object(
    'applicantId', new_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_transfer_applicant(
  text, text, date, text, text, text, text, jsonb, text, text, date, text, text, text,
  text, text, text, date, text, text
) from anon;

-- ============================================================
-- 5. update_transfer_application_status RPC
-- ============================================================

create or replace function public.update_transfer_application_status(
  p_applicant_id uuid,
  p_new_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_new_status not in ('received', 'incomplete', 'complete', 'withdrawn', 'excluded') then
    raise exception '알 수 없는 접수 상태입니다: %', p_new_status;
  end if;

  update public.transfer_applicants
  set application_status = p_new_status,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code)
  values
    ('user', caller::text, 'transferApplicant.status_changed:' || p_new_status, 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text, p_reason);
end;
$$;

revoke execute on function public.update_transfer_application_status(uuid, text, text) from anon;

-- ============================================================
-- 6. update_transfer_document_checklist RPC — 제출서류 체크리스트 갱신
-- ============================================================

create or replace function public.update_transfer_document_checklist(
  p_applicant_id uuid,
  p_checklist jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_checklist is null or jsonb_typeof(p_checklist) <> 'object' then
    raise exception '체크리스트는 JSON 객체여야 합니다.';
  end if;

  update public.transfer_applicants
  -- 부분 갱신: 기존 체크리스트에 새 값만 덮어쓴다(다른 항목은 유지).
  set document_checklist = document_checklist || p_checklist,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.checklist_updated', 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_transfer_document_checklist(uuid, jsonb) from anon;

-- ======================================================================
-- 00037_transfer_document_scores.sql
-- ======================================================================

-- 새봄고 전·편입생 선발 전형(공고 2026-40호) — 1차 서류전형 채점(1000점)
--
-- 요강 4번 전형방법 그대로:
--   ① 학교생활기록부(300점) = 출결(200) + 학업성실도(100)
--   ② 자기소개서(자필, 500) + 보호자소견서(200) = 700점
-- 총 1000점. 2차 면접(별도 전형)은 이번 마이그레이션 범위 밖 — 원서 접수
-- (7/13~16) 이후 서류전형(7/20~22)에 맞춰 나중에 추가한다.
--
-- 신입생 M3a/b(scores_attendance/scores_academic)와 달리 이 전형은
-- 평가위원별 제출·평균 집계 구조가 아니라 학교(전편입학위원회)가 서류를
-- 검토해 확정 점수 하나를 입력하는 방식이라 지원자 1인당 1행이면 충분하다
-- (unique(applicant_id), evaluator_uid 없음). 출결·학업성실도는 요강의
-- 점수표를 그대로 서버에서 계산하고(클라이언트가 계산한 값은 신뢰하지
-- 않음 — 마스터스펙 5.1 원칙과 동일), 자기소개서·보호자소견서는 서면
-- 평가라 점수를 직접 입력받되 배점 상한만 서버가 검증한다.
--
-- config_revisions.scoring_params 체계는 신입생 다회차·연도별 재사용을
-- 위한 것이라 이번 단발성 전편입 전형에는 과한 설계라 판단해 채택하지
-- 않았다 — 요강 점수표를 RPC에 직접 반영한다(향후 매년 반복되는 정례
-- 전형이 되면 그때 config화 검토).

create table public.transfer_document_scores (
  applicant_id uuid primary key references public.transfer_applicants (id) on delete cascade,

  -- 출결(200점). record_type: schoolRecord(일반 계산) | ged(검정고시 출신, 180점 고정)
  -- | noRecord(중학교 학생부 미제출, 0점).
  attendance_record_type text check (attendance_record_type in ('schoolRecord', 'ged', 'noRecord')),
  attendance_inputs jsonb,
  attendance_score numeric check (attendance_score is null or (attendance_score >= 0 and attendance_score <= 200)),

  -- 학업성실도(100점). record_type: schoolRecord(성취도 A~E) | ged(원점수 구간환산)
  -- | equivalentNoRecord(동등학력 인정자 중 학생부 미제출, 70점 고정).
  academic_record_type text check (academic_record_type in ('schoolRecord', 'ged', 'equivalentNoRecord')),
  academic_inputs jsonb,
  academic_score numeric check (academic_score is null or (academic_score >= 0 and academic_score <= 100)),

  -- 자기소개서(자필)·보호자소견서 — 서면 평가, 직접 입력(상한만 서버 검증)
  self_intro_score numeric check (self_intro_score is null or (self_intro_score >= 0 and self_intro_score <= 500)),
  guardian_opinion_score numeric check (guardian_opinion_score is null or (guardian_opinion_score >= 0 and guardian_opinion_score <= 200)),

  updated_at timestamptz not null default now(),
  updated_by text
);

comment on table public.transfer_document_scores is
  '전편입학 1차 서류전형(1000점 만점) 채점 결과. 총점 = attendance_score + academic_score + self_intro_score + guardian_opinion_score(널 항목은 미채점으로 취급, 화면에서 0으로 합산하지 않는다).';

alter table public.transfer_document_scores enable row level security;

create policy transfer_document_scores_select_staff
  on public.transfer_document_scores for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

-- write는 전부 아래 RPC 전용(정책 없음)

-- ============================================================
-- 1. submit_transfer_attendance_score — 출결 200점
-- ============================================================

create or replace function public.submit_transfer_attendance_score(
  p_applicant_id uuid,
  p_record_type text,
  p_unexcused_absences int default null,
  p_other_event_count int default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  effective_days int;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'noRecord') then
    raise exception '알 수 없는 출결 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'ged' then
    computed_score := 180; -- 요강: 중학교 졸업학력 검정고시 출신자는 180점
    effective_days := null;
  elsif p_record_type = 'noRecord' then
    computed_score := 0;   -- 요강: 중학교 학교생활기록부 미제출자는 0점
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_other_event_count is null or p_other_event_count < 0 then
      raise exception '미인정 결석 일수·조퇴/지각/결과 횟수는 0 이상의 정수여야 합니다.';
    end if;
    -- 요강: 미인정 조퇴·지각·결과 3회 = 미인정 결석 1일로 환산
    effective_days := p_unexcused_absences + floor(p_other_event_count::numeric / 3);
    -- 요강 점수표: 결석 0일=200점, 1일당 -10점, 20일 이상=0점
    -- (200 - 10*일수를 0 이상으로 clamp하면 표의 모든 행과 정확히 일치함)
    computed_score := greatest(0, 200 - 10 * effective_days);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, attendance_record_type, attendance_inputs, attendance_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'otherEventCount', p_other_event_count,
       'effectiveAbsenceDays', effective_days
     ),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    attendance_record_type = excluded.attendance_record_type,
    attendance_inputs = excluded.attendance_inputs,
    attendance_score = excluded.attendance_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.attendance.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days);
end;
$$;

revoke execute on function public.submit_transfer_attendance_score(uuid, text, int, int) from anon;

-- ============================================================
-- 2. submit_transfer_academic_score — 학업성실도 100점
--    p_subjects: [{"subject":"국어","achievement":"A"}] (schoolRecord) 또는
--                [{"subject":"국어","rawScore":85}] (ged) — 서버가 상위 5개 선정·합산
-- ============================================================

create or replace function public.submit_transfer_academic_score(
  p_applicant_id uuid,
  p_record_type text,
  p_subjects jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'equivalentNoRecord') then
    raise exception '알 수 없는 학업성실도 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'equivalentNoRecord' then
    -- 요강: 고1 중 중학교 졸업자와 동등 학력 인정자 중 학교생활기록부 미제출자 = 70점
    computed_score := 70;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_record_type = 'schoolRecord' then
        -- 요강 표: A=20, B=16, C=8, D=4, E=2
        points := case subj ->> 'achievement'
          when 'A' then 20 when 'B' then 16 when 'C' then 8
          when 'D' then 4 when 'E' then 2
          else null
        end;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception '검정고시 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          -- 요강 표: ~60=2, 61~70=4, 71~80=8, 81~90=16, 91~100=20
          points := case
            when raw <= 60 then 2
            when raw <= 70 then 4
            when raw <= 80 then 8
            when raw <= 90 then 16
            else 20
          end;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    -- 상위 5과목 선정·합산은 서버만 수행(클라이언트가 미리 고르지 않음 — M3b와 동일 원칙)
    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, 100);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, academic_record_type, academic_inputs, academic_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object('subjects', p_subjects),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    academic_record_type = excluded.academic_record_type,
    academic_inputs = excluded.academic_inputs,
    academic_score = excluded.academic_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.academic.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score);
end;
$$;

revoke execute on function public.submit_transfer_academic_score(uuid, text, jsonb) from anon;

-- ============================================================
-- 3. submit_transfer_essay_scores — 자기소개서(500)·보호자소견서(200)
--    서면 평가 결과를 직접 입력(전편입학위원회가 합의한 점수). 서버는
--    배점 상한만 검증한다.
-- ============================================================

create or replace function public.submit_transfer_essay_scores(
  p_applicant_id uuid,
  p_self_intro_score numeric default null,
  p_guardian_opinion_score numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_self_intro_score is not null and (p_self_intro_score < 0 or p_self_intro_score > 500) then
    raise exception '자기소개서 점수는 0~500 사이여야 합니다.';
  end if;
  if p_guardian_opinion_score is not null and (p_guardian_opinion_score < 0 or p_guardian_opinion_score > 200) then
    raise exception '보호자소견서 점수는 0~200 사이여야 합니다.';
  end if;

  insert into public.transfer_document_scores
    (applicant_id, self_intro_score, guardian_opinion_score, updated_at, updated_by)
  values
    (p_applicant_id, p_self_intro_score, p_guardian_opinion_score, now(), caller::text)
  on conflict (applicant_id) do update set
    self_intro_score = coalesce(excluded.self_intro_score, public.transfer_document_scores.self_intro_score),
    guardian_opinion_score = coalesce(excluded.guardian_opinion_score, public.transfer_document_scores.guardian_opinion_score),
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.essays.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object(
    'selfIntroScore', p_self_intro_score,
    'guardianOpinionScore', p_guardian_opinion_score
  );
end;
$$;

revoke execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) from anon;

-- ======================================================================
-- 00038_transfer_admission_privilege_fix.sql
-- ======================================================================

-- 전·편입생 선발 전형(00036/00037) 권한 하드닝 핫픽스
--
-- 회귀 테스트([0])에서 register_transfer_applicant에 anon execute가 여전히
-- 열려 있는 것이 실제로 확인됐다. 원인: 00036/00037이 `revoke ... from anon`
-- 만 실행했는데, 이 프로젝트의 public 스키마 기본 권한 하에서는 PUBLIC
-- 자체에 대한 EXECUTE 권한(또는 이번 배포 과정에서 반복된 db push/migration
-- repair 과정에서 남았을 수 있는 동일 이름의 과거 오버로드)이 별도로 남아
-- anon 롤에도 그대로 승계되고 있었다. `revoke ... from anon`만으로는 PUBLIC
-- 부여분 자체를 제거하지 못한다(Postgres GRANT 의미상 PUBLIC 부여는 개별
-- 롤에 대한 REVOKE로 지워지지 않음).
--
-- 조치:
--   1) 혹시 남아있을 수 있는 동일 함수명의 다른 시그니처(과거 배포 잔재)를
--      전부 동적으로 찾아 삭제한다 — 어떤 오버로드가 원인이든 깨끗하게 정리.
--   2) 7개 함수를 동일한 본문으로 재생성하면서 `revoke ... from public, anon`
--      을 명시하고, 실제 호출 주체(직원, authenticated)에게는
--      `grant ... to authenticated`를 명시적으로 다시 부여해 애매함을 없앤다.
--   3) _allocate_transfer_receipt_no(내부 전용)는 public/anon/authenticated
--      모두에서 회수한다(원래 의도와 동일, 명시적으로 재확인).

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'register_transfer_applicant',
        'update_transfer_application_status',
        'update_transfer_document_checklist',
        '_allocate_transfer_receipt_no',
        'submit_transfer_attendance_score',
        'submit_transfer_academic_score',
        'submit_transfer_essay_scores'
      )
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end;
$$;

-- ============================================================
-- 1. _allocate_transfer_receipt_no (내부 전용 — public/anon/authenticated 전면 차단)
-- ============================================================

create function public._allocate_transfer_receipt_no(
  p_round_label text,
  at_time timestamptz default now()
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dk text := to_char(at_time at time zone 'Asia/Seoul', 'YYMMDD');
  seq int;
begin
  insert into public.transfer_receipt_counters (round_label, date_key, last_seq)
  values (p_round_label, dk, 0)
  on conflict (round_label, date_key) do nothing;

  update public.transfer_receipt_counters
  set last_seq = last_seq + 1
  where round_label = p_round_label and date_key = dk
  returning last_seq into seq;

  if seq > 999 then
    raise exception '일일 전편입학 접수번호 한도(999)를 초과했습니다.';
  end if;

  return 'T' || dk || lpad(seq::text, 3, '0');
end;
$$;

revoke execute on function public._allocate_transfer_receipt_no(text, timestamptz) from public, anon, authenticated;

-- ============================================================
-- 2. register_transfer_applicant
-- ============================================================

create function public.register_transfer_applicant(
  p_name text,
  p_eligibility_category text,
  p_receipt_date date,
  p_round_label text default '2026-07',
  p_current_school text default null,
  p_current_grade text default null,
  p_tracking_no text default null,
  p_document_checklist jsonb default '{}'::jsonb,
  p_staff_memo text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_withdrawal_date date default null,
  p_alt_school_name text default null,
  p_staff_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_eligibility_category not in ('enrolled', 'withdrawn', 'altSchool') then
    raise exception '지원자격 구분이 올바르지 않습니다: %', p_eligibility_category;
  end if;
  if p_receipt_date is null then
    raise exception '접수일(등기 도착일)은 필수입니다.';
  end if;

  new_receipt_no := public._allocate_transfer_receipt_no(p_round_label);

  insert into public.transfer_applicants
    (round_label, receipt_no, name, eligibility_category, current_school, current_grade,
     receipt_date, tracking_no, document_checklist, staff_memo, created_by, updated_by)
  values
    (p_round_label, new_receipt_no, trim(p_name), p_eligibility_category, p_current_school,
     p_current_grade, p_receipt_date, p_tracking_no, coalesce(p_document_checklist, '{}'::jsonb),
     p_staff_memo, caller::text, caller::text)
  returning id into new_id;

  insert into public.transfer_applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone, withdrawal_date, alt_school_name, staff_note)
  values
    (new_id, p_gender, p_birth_date, p_applicant_phone, p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_withdrawal_date,
     p_alt_school_name, p_staff_note);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.registered', 'transfer_applicants',
     new_id::text, new_id::text);

  return json_build_object(
    'applicantId', new_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_transfer_applicant(
  text, text, date, text, text, text, text, jsonb, text, text, date, text, text, text,
  text, text, text, date, text, text
) from public, anon;
grant execute on function public.register_transfer_applicant(
  text, text, date, text, text, text, text, jsonb, text, text, date, text, text, text,
  text, text, text, date, text, text
) to authenticated;

-- ============================================================
-- 3. update_transfer_application_status
-- ============================================================

create function public.update_transfer_application_status(
  p_applicant_id uuid,
  p_new_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_new_status not in ('received', 'incomplete', 'complete', 'withdrawn', 'excluded') then
    raise exception '알 수 없는 접수 상태입니다: %', p_new_status;
  end if;

  update public.transfer_applicants
  set application_status = p_new_status,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code)
  values
    ('user', caller::text, 'transferApplicant.status_changed:' || p_new_status, 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text, p_reason);
end;
$$;

revoke execute on function public.update_transfer_application_status(uuid, text, text) from public, anon;
grant execute on function public.update_transfer_application_status(uuid, text, text) to authenticated;

-- ============================================================
-- 4. update_transfer_document_checklist
-- ============================================================

create function public.update_transfer_document_checklist(
  p_applicant_id uuid,
  p_checklist jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_checklist is null or jsonb_typeof(p_checklist) <> 'object' then
    raise exception '체크리스트는 JSON 객체여야 합니다.';
  end if;

  update public.transfer_applicants
  set document_checklist = document_checklist || p_checklist,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.checklist_updated', 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_transfer_document_checklist(uuid, jsonb) from public, anon;
grant execute on function public.update_transfer_document_checklist(uuid, jsonb) to authenticated;

-- ============================================================
-- 5. submit_transfer_attendance_score
-- ============================================================

create function public.submit_transfer_attendance_score(
  p_applicant_id uuid,
  p_record_type text,
  p_unexcused_absences int default null,
  p_other_event_count int default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  effective_days int;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'noRecord') then
    raise exception '알 수 없는 출결 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'ged' then
    computed_score := 180;
    effective_days := null;
  elsif p_record_type = 'noRecord' then
    computed_score := 0;
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_other_event_count is null or p_other_event_count < 0 then
      raise exception '미인정 결석 일수·조퇴/지각/결과 횟수는 0 이상의 정수여야 합니다.';
    end if;
    effective_days := p_unexcused_absences + floor(p_other_event_count::numeric / 3);
    computed_score := greatest(0, 200 - 10 * effective_days);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, attendance_record_type, attendance_inputs, attendance_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'otherEventCount', p_other_event_count,
       'effectiveAbsenceDays', effective_days
     ),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    attendance_record_type = excluded.attendance_record_type,
    attendance_inputs = excluded.attendance_inputs,
    attendance_score = excluded.attendance_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.attendance.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days);
end;
$$;

revoke execute on function public.submit_transfer_attendance_score(uuid, text, int, int) from public, anon;
grant execute on function public.submit_transfer_attendance_score(uuid, text, int, int) to authenticated;

-- ============================================================
-- 6. submit_transfer_academic_score
-- ============================================================

create function public.submit_transfer_academic_score(
  p_applicant_id uuid,
  p_record_type text,
  p_subjects jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'equivalentNoRecord') then
    raise exception '알 수 없는 학업성실도 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'equivalentNoRecord' then
    computed_score := 70;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_record_type = 'schoolRecord' then
        points := case subj ->> 'achievement'
          when 'A' then 20 when 'B' then 16 when 'C' then 8
          when 'D' then 4 when 'E' then 2
          else null
        end;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception '검정고시 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          points := case
            when raw <= 60 then 2
            when raw <= 70 then 4
            when raw <= 80 then 8
            when raw <= 90 then 16
            else 20
          end;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, 100);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, academic_record_type, academic_inputs, academic_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object('subjects', p_subjects),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    academic_record_type = excluded.academic_record_type,
    academic_inputs = excluded.academic_inputs,
    academic_score = excluded.academic_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.academic.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score);
end;
$$;

revoke execute on function public.submit_transfer_academic_score(uuid, text, jsonb) from public, anon;
grant execute on function public.submit_transfer_academic_score(uuid, text, jsonb) to authenticated;

-- ============================================================
-- 7. submit_transfer_essay_scores
-- ============================================================

create function public.submit_transfer_essay_scores(
  p_applicant_id uuid,
  p_self_intro_score numeric default null,
  p_guardian_opinion_score numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_self_intro_score is not null and (p_self_intro_score < 0 or p_self_intro_score > 500) then
    raise exception '자기소개서 점수는 0~500 사이여야 합니다.';
  end if;
  if p_guardian_opinion_score is not null and (p_guardian_opinion_score < 0 or p_guardian_opinion_score > 200) then
    raise exception '보호자소견서 점수는 0~200 사이여야 합니다.';
  end if;

  insert into public.transfer_document_scores
    (applicant_id, self_intro_score, guardian_opinion_score, updated_at, updated_by)
  values
    (p_applicant_id, p_self_intro_score, p_guardian_opinion_score, now(), caller::text)
  on conflict (applicant_id) do update set
    self_intro_score = coalesce(excluded.self_intro_score, public.transfer_document_scores.self_intro_score),
    guardian_opinion_score = coalesce(excluded.guardian_opinion_score, public.transfer_document_scores.guardian_opinion_score),
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.essays.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object(
    'selfIntroScore', p_self_intro_score,
    'guardianOpinionScore', p_guardian_opinion_score
  );
end;
$$;

revoke execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) from public, anon;
grant execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) to authenticated;

-- ======================================================================
-- 00039_list_pending_signins.sql
-- ======================================================================

-- 사용자(선생님) 권한 관리 화면 지원 — 로그인은 했지만 아직 public.users에
-- 없는(= 승인 대기) 계정 목록 조회 RPC.
--
-- 배경: 00001에서 upsert_user_access/set_user_active_status RPC는 이미
-- 만들어뒀지만 이걸 쓰는 화면이 없었다(2026-07-11 사용자 지적). public.users는
-- users_select_superadmin 정책으로 superadmin이 이미 전체 조회 가능하지만,
-- "구글 로그인은 했는데 아직 승인 안 된" 계정은 auth.users에만 있고
-- public.users에는 행이 없어 PostgREST로 직접 조회가 안 된다(auth 스키마는
-- 노출되지 않음). 이 RPC가 그 간극을 메운다 — auth.users를 SECURITY DEFINER로
-- 조회하되 이메일/가입시각 등 최소 정보만 반환한다(비밀번호 해시 등 민감
-- 컬럼은 절대 select하지 않음).

create or replace function public.list_pending_signins()
returns table (id uuid, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_superadmin();

  return query
    select au.id, au.email::text, au.created_at
    from auth.users au
    left join public.users u on u.id = au.id
    where u.id is null
    order by au.created_at desc;
end;
$$;

revoke execute on function public.list_pending_signins() from anon, authenticated;
comment on function public.list_pending_signins() is
  '구글 로그인은 완료했으나 아직 upsert_user_access로 승인되지 않은 계정 목록(superadmin 전용). auth.users에서 id/email/created_at만 최소 반환.';

-- ======================================================================
-- 00040_list_pending_signins_privilege_fix.sql
-- ======================================================================

-- list_pending_signins(00039) 권한 하드닝 핫픽스
--
-- 회귀 테스트([0])에서 anon execute가 여전히 열려 있는 것이 확인됐다 —
-- 00036/00037에서 이미 한 번 겪은 것과 동일한 원인이다(00038 참고):
-- `revoke ... from anon, authenticated`만으로는 이 프로젝트의 PUBLIC 기본
-- 부여분(또는 반복된 배포 과정에서 남았을 수 있는 동일 이름의 과거
-- 오버로드)이 제거되지 않는다. 이번엔 authenticated 쪽도 완전히 막아야
-- 하는 함수라 `from public, anon, authenticated`로 명시한다 — 이 RPC는
-- superadmin만 호출해야 하고 내부에서 _require_superadmin()으로도
-- 재검증하지만, PostgREST 레벨에서도 완전히 막아 이중 방어한다.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'list_pending_signins'
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end;
$$;

create function public.list_pending_signins()
returns table (id uuid, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_superadmin();

  return query
    select au.id, au.email::text, au.created_at
    from auth.users au
    left join public.users u on u.id = au.id
    where u.id is null
    order by au.created_at desc;
end;
$$;

revoke execute on function public.list_pending_signins() from public, anon, authenticated;
-- 주의: authenticated에게도 execute를 주지 않는다 — PostgREST RPC 호출
-- 자체는 "로그인된 계정이면 누구나 함수 존재는 호출 시도 가능"하지만,
-- 실제 데이터 접근은 함수 내부 _require_superadmin()이 막는다(기존
-- upsert_user_access/set_user_active_status와 동일한 이중 방어 패턴).
-- 다만 이 프로젝트의 다른 superadmin 전용 RPC(upsert_user_access 등)는
-- "revoke ... from anon"만 하고 authenticated에는 execute를 남겨
-- _require_superadmin() 내부 검증에만 의존한다 — list_pending_signins도
-- 그 패턴을 따르려면 authenticated는 남겨야 정상 동작한다(관리 화면이
-- superadmin 계정으로 이 RPC를 호출하는 것 자체가 authenticated 롤로
-- 이루어지기 때문). 따라서 아래에서 authenticated에게는 다시 execute를
-- 부여한다 — 최종 방어선은 함수 내부 _require_superadmin()이다.
grant execute on function public.list_pending_signins() to authenticated;

comment on function public.list_pending_signins() is
  '구글 로그인은 완료했으나 아직 upsert_user_access로 승인되지 않은 계정 목록(superadmin 전용, 내부 _require_superadmin()으로 검증). auth.users에서 id/email/created_at만 최소 반환. anon은 완전 차단.';

-- ======================================================================
-- 00041_pre_application_instant_bundle_token.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 사전작성 "즉시출력" 1회용 토큰 (Task #35)
--
-- 배경: 사전작성 완료 화면에서 임시접수번호/조회코드를 받은 직후, 지원자가
-- /portal/status로 다시 가서 성명+조회코드를 재입력하고 Turnstile을 한 번
-- 더 통과해야만 서류(PDF 합본)를 내려받을 수 있었다 — 방금 제출을 마친
-- 사람에게는 불필요한 마찰이라는 사용자 피드백(전화 문의 폭주 우려) 반영.
--
-- 접근: create_pre_application 성공 시(=Turnstile을 이미 한 번 통과한 직후)
-- 서버가 별도의 1회용 불투명 토큰(instantBundleToken)을 만들어 응답에
-- 딱 1회만 실어 보낸다. 완료 화면은 이 토큰을 메모리에 들고 있다가 "지금
-- 바로 서류 출력" 버튼 클릭 시 generate-application-bundle에 그대로
-- 넘기고, 그 함수는 이 토�1큰이 있으면 성명/조회코드 재입력·Turnstile을
-- 요구하지 않고 즉시 서류를 만든다(그 대신 토큰은 1회용 + 30분 TTL).
--
-- 조회코드(6자리, ~20비트 엔트로피)와 달리 이 토큰은 gen_random_bytes(24)
-- (192비트)라 무차별 대입 잠금 로직이 불필요하다 — 대신 1회용(used_at)과
-- 만료(expires_at)로 노출 범위를 최소화한다. 해시 저장·pepper 재사용 등
-- 나머지 패턴은 00024의 조회코드 verifier와 동일하게 따른다.

-- ============================================================
-- 1. pre_application_secrets에 즉시출력 토큰 컬럼 추가
-- ============================================================

alter table public.pre_application_secrets
  add column if not exists instant_bundle_token_verifier text,
  add column if not exists instant_bundle_token_expires_at timestamptz,
  add column if not exists instant_bundle_token_used_at timestamptz;

-- ============================================================
-- 2. 토큰 생성 (암호학적 난수, hex 인코딩 — URL/JSON에 안전)
-- ============================================================

create or replace function public._generate_instant_bundle_token()
returns text
language sql
security definer
set search_path = public, extensions
as $$
  select encode(gen_random_bytes(24), 'hex');
$$;

revoke execute on function public._generate_instant_bundle_token() from public, anon, authenticated;

-- ============================================================
-- 3. 토큰 해시 (HMAC-SHA256 + 기존 pre_application_pepper 재사용)
-- ============================================================

create or replace function public._hash_instant_bundle_token(raw_token text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select encode(hmac(raw_token, public._pre_application_pepper(), 'sha256'), 'hex');
$$;

revoke execute on function public._hash_instant_bundle_token(text) from public, anon, authenticated;

-- ============================================================
-- 4. 토큰 발급 — create_pre_application 내부에서만 호출.
--    set_pre_application_access_code가 이미 secrets 행을 만든 뒤 호출된다고
--    가정하고 update만 한다(같은 트랜잭션 안이므로 존재가 보장됨).
-- ============================================================

create or replace function public._set_pre_application_instant_bundle_token(
  p_pre_application_id uuid,
  p_raw_token text,
  p_ttl interval default interval '30 minutes'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.pre_application_secrets
  set instant_bundle_token_verifier = public._hash_instant_bundle_token(p_raw_token),
      instant_bundle_token_expires_at = now() + p_ttl,
      instant_bundle_token_used_at = null
  where pre_application_id = p_pre_application_id;

  if not found then
    raise exception '즉시출력 토큰을 저장할 secrets 행이 없습니다(pre_application_id=%).', p_pre_application_id;
  end if;
end;
$$;

revoke execute on function public._set_pre_application_instant_bundle_token(uuid, text, interval)
  from public, anon, authenticated;

-- ============================================================
-- 5. create_pre_application 재정의 — 토큰 발급 + 응답에 1회 포함
--    (파라미터 목록은 00035와 동일 — 시그니처 변경 없으므로 drop 불필요)
-- ============================================================

create or replace function public.create_pre_application(
  p_year int,
  p_round admission_round,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_name text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_postal_code text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  schedule_json jsonb;
  receipt_end date;
  new_expires_at timestamptz;
  new_pre_application_no text;
  new_access_code text;
  new_instant_token text;
  new_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_tracks is null or array_length(p_tracks, 1) is null then
    raise exception '전형(tracks)은 필수입니다.';
  end if;
  if p_receipt_method not in ('M', 'V') then
    raise exception '접수방법은 M(우편) 또는 V(방문)이어야 합니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select cr.schedule into schedule_json
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = p_year and ar.round = p_round;

  receipt_end := (schedule_json->>'receiptEnd')::date;
  if receipt_end is null then
    raise exception '차수(%, %) config에 receiptEnd가 설정되어 있지 않습니다.', p_year, p_round;
  end if;
  new_expires_at := (receipt_end + interval '30 days') at time zone 'Asia/Seoul';

  new_pre_application_no := public._allocate_pre_application_no(p_year, p_round);
  new_access_code := public._generate_pre_application_access_code();
  new_instant_token := public._generate_instant_bundle_token();

  insert into public.pre_applications
    (year, round, pre_application_no, tracks, academic_status, school,
     grade_class_no, semester_choice, receipt_method, expires_at)
  values
    (p_year, p_round, new_pre_application_no, p_tracks, p_academic_status, p_school,
     p_grade_class_no, p_semester_choice, p_receipt_method, new_expires_at)
  returning id into new_id;

  insert into public.pre_applications_private
    (pre_application_id, name, gender, birth_date, applicant_phone, email,
     address, postal_code, guardian_name, guardian_relation, guardian_phone)
  values
    (new_id, trim(p_name), p_gender, p_birth_date, p_applicant_phone, p_email,
     p_address, p_postal_code, p_guardian_name, p_guardian_relation, p_guardian_phone);

  perform public.set_pre_application_access_code(new_id, new_access_code);
  perform public._set_pre_application_instant_bundle_token(new_id, new_instant_token);

  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.created', 'system');
  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.instantBundle.issued', 'system');

  -- accessCode/instantBundleToken 둘 다 이 응답에서만 1회 반환한다 — 이후
  -- 어디에도 원문으로 남지 않는다(pre_application_secrets에는 해시만 저장).
  return json_build_object(
    'preApplicationId', new_id,
    'preApplicationNo', new_pre_application_no,
    'accessCode', new_access_code,
    'instantBundleToken', new_instant_token,
    'expiresAt', new_expires_at
  );
end;
$$;

revoke execute on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text
) from public, anon, authenticated;

comment on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text
) is
  'Edge Function(createPreApplication)이 Turnstile 검증 통과 후 service_role로만
   호출한다. public/anon/authenticated 직접 호출 전면 차단. 응답의 accessCode와
   instantBundleToken은 이 1회 응답에만 실리고 저장되지 않는다(해시만 보관).';

-- ============================================================
-- 6. 즉시출력 토큰 사용(redeem) — generate-application-bundle이 instantToken
--    경로에서 호출. 1회용 + 30분 TTL이라 조회코드와 달리 실패 잠금은 두지
--    않는다(192비트 토큰 무차별 대입은 비현실적 — 위 파일 상단 설명 참고).
--    성공/실패 boolean만 반환하고 사유는 절대 구분해 노출하지 않는다(기존
--    verify_pre_application_access와 동일 원칙).
-- ============================================================

create or replace function public.redeem_instant_bundle_token(
  p_pre_application_no text,
  p_raw_token text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  sec_row record;
  token_ok boolean;
begin
  select pa.id, pa.pre_application_no
  into app_row
  from public.pre_applications pa
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    perform public._record_pre_application_event(
      null, p_pre_application_no, 'preApplication.instantBundle.redeemFailed', 'applicant',
      null, jsonb_build_object('reason', 'not_found'));
    return false;
  end if;

  select * into sec_row
  from public.pre_application_secrets
  where pre_application_id = app_row.id
  for update;

  if sec_row is null or sec_row.instant_bundle_token_verifier is null then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.instantBundle.redeemFailed', 'applicant',
      null, jsonb_build_object('reason', 'no_token_issued'));
    return false;
  end if;

  if sec_row.instant_bundle_token_used_at is not null then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.instantBundle.redeemFailed', 'applicant',
      null, jsonb_build_object('reason', 'already_used'));
    return false;
  end if;

  if sec_row.instant_bundle_token_expires_at is null or sec_row.instant_bundle_token_expires_at < now() then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.instantBundle.redeemFailed', 'applicant',
      null, jsonb_build_object('reason', 'expired'));
    return false;
  end if;

  token_ok := sec_row.instant_bundle_token_verifier = public._hash_instant_bundle_token(p_raw_token);

  if not token_ok then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.instantBundle.redeemFailed', 'applicant',
      null, jsonb_build_object('reason', 'token_mismatch'));
    return false;
  end if;

  update public.pre_application_secrets
  set instant_bundle_token_used_at = now()
  where pre_application_id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.instantBundle.redeemed', 'applicant');

  return true;
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'redeem_instant_bundle_token'
  loop
    execute format('alter function %s owner to current_user', r.sig);
  end loop;
end;
$$;

revoke execute on function public.redeem_instant_bundle_token(text, text) from public, anon, authenticated;
grant execute on function public.redeem_instant_bundle_token(text, text) to service_role;

comment on function public.redeem_instant_bundle_token(text, text) is
  '사전작성 완료 직후 발급된 1회용 즉시출력 토큰을 소비한다. 성공 시 그 즉시
   instant_bundle_token_used_at을 찍어 재사용을 막는다. anon/authenticated는
   직접 호출 불가 — generate-application-bundle Edge Function이 service_role로만
   호출한다.';

-- ======================================================================
-- 00042_pre_application_admin_dashboard.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8 사전작성 관리자 대시보드 + 접수대장 전환 (Task #36)
--
-- 배경: 00023 설계 당시부터 예정돼 있던 기능(00023 헤더 주석 6번:
-- "convertPreApplicationToApplicant는 단일 트랜잭션")인데 지금까지 이걸 호출할
-- 어떤 RPC도, 관리자가 사전작성 현황을 볼 화면도 없었다 — 실사용 피드백
-- ("사전작성 현황을 관리자 화면에서 전혀 볼 수가 없네 ㅠㅠ") 반영.
--
-- pre_applications 4테이블은 RLS 정책이 하나도 없다(00023) — 즉 클라이언트가
-- .from(...).select()로 직접 못 읽는다. 이 마이그레이션의 모든 RPC는
-- SECURITY DEFINER + _require_any_role(['superadmin','admin','reception'])로만
-- 접근을 허용한다(00003 register_applicant와 동일한 역할 조합 — 우편/방문
-- 서류를 실제로 받는 쪽이 reception이므로).
--
-- status 상태기계(00023에 이미 정의돼 있었지만 지금까지 'completed'→
-- 'bundleGenerated' 외에는 아무것도 전이시키지 않았음):
--   completed/bundleGenerated → (도착 확인) → arrived
--   arrived → (검수 시작) → reviewing
--   reviewing ⇄ supplementRequired (체크리스트 검수 중 보완 필요 시)
--   (converted·expired 전이는 이번 마이그레이션의 convert 함수/기존 만료
--    cron이 각각 담당 — 그 외 상태에서는 언제든 관리자가 직접 전환 가능:
--    실무상 절차를 엄격히 강제하면 오히려 방문접수 등 예외 케이스에서
--    직원을 막는 부작용이 크다고 판단해 "이미 전환됨/만료됨"만 막는다.)

-- ============================================================
-- 1. 감사 이벤트 기록 helper 재사용 헬퍼(파라미터 기본값만 다르게) —
--    이미 00025의 _record_pre_application_event를 그대로 쓴다. 새로 만들지 않음.
-- ============================================================

-- ============================================================
-- 2. admin_list_pre_applications — 사전작성 현황 목록
-- ============================================================

create or replace function public.admin_list_pre_applications(
  p_status_filter text[] default null
)
returns table (
  id uuid,
  pre_application_no text,
  year int,
  round admission_round,
  name text,
  applicant_phone text,
  guardian_phone text,
  status text,
  tracks text[],
  academic_status text,
  receipt_method text,
  school text,
  created_at timestamptz,
  expires_at timestamptz,
  shipping jsonb,
  arrival jsonb,
  document_review jsonb,
  conversion jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  return query
    select
      pa.id, pa.pre_application_no, pa.year, pa.round,
      pp.name, pp.applicant_phone, pp.guardian_phone,
      pa.status, pa.tracks, pa.academic_status, pa.receipt_method, pa.school,
      pa.created_at, pa.expires_at,
      pa.shipping, pa.arrival, pa.document_review, pa.conversion
    from public.pre_applications pa
    join public.pre_applications_private pp on pp.pre_application_id = pa.id
    where p_status_filter is null or pa.status = any(p_status_filter)
    order by pa.created_at desc;
end;
$$;

-- ============================================================
-- 3. admin_get_pre_application_detail — 관리자용 상세(개인정보 포함) + 최근 이벤트
-- ============================================================

create or replace function public.admin_get_pre_application_detail(
  p_pre_application_no text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  priv_row record;
  events_json json;
begin
  perform public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  select coalesce(json_agg(e order by e.created_at desc), '[]'::json) into events_json
  from (
    select event_type, actor_type, created_at, metadata
    from public.pre_application_events
    where pre_application_id = app_row.id
    order by created_at desc
    limit 20
  ) e;

  return json_build_object(
    'preApplicationNo', app_row.pre_application_no,
    'year', app_row.year,
    'round', app_row.round,
    'status', app_row.status,
    'tracks', app_row.tracks,
    'academicStatus', app_row.academic_status,
    'school', app_row.school,
    'gradeClassNo', app_row.grade_class_no,
    'semesterChoice', app_row.semester_choice,
    'receiptMethod', app_row.receipt_method,
    'name', priv_row.name,
    'gender', priv_row.gender,
    'birthDate', priv_row.birth_date,
    'applicantPhone', priv_row.applicant_phone,
    'email', priv_row.email,
    'address', priv_row.address,
    'postalCode', priv_row.postal_code,
    'guardianName', priv_row.guardian_name,
    'guardianRelation', priv_row.guardian_relation,
    'guardianPhone', priv_row.guardian_phone,
    'shipping', app_row.shipping,
    'arrival', app_row.arrival,
    'documentReview', app_row.document_review,
    'conversion', app_row.conversion,
    'createdAt', app_row.created_at,
    'expiresAt', app_row.expires_at,
    'events', events_json
  );
end;
$$;

-- ============================================================
-- 4. mark_pre_application_arrived — 서류 도착 확인
-- ============================================================

create or replace function public.mark_pre_application_arrived(
  p_pre_application_no text,
  p_method text default 'M'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('completed', 'bundleGenerated') then
    raise exception '이미 도착 확인되었거나(또는 전환/만료되어) 이 상태에서는 도착 확인을 할 수 없습니다(현재 상태: %).', app_row.status;
  end if;

  update public.pre_applications
  set status = 'arrived',
      arrival = jsonb_build_object('method', p_method, 'confirmedAt', now(), 'confirmedBy', caller::text)
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.arrived', 'admin', caller,
    jsonb_build_object('method', p_method));
end;
$$;

-- ============================================================
-- 5. mark_pre_application_reviewing — 서류 검수 시작
-- ============================================================

create or replace function public.mark_pre_application_reviewing(
  p_pre_application_no text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('arrived', 'supplementRequired') then
    raise exception '도착 확인 후에만 검수를 시작할 수 있습니다(현재 상태: %).', app_row.status;
  end if;

  update public.pre_applications
  set status = 'reviewing'
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.reviewing', 'admin', caller);
end;
$$;

-- ============================================================
-- 6. update_pre_application_document_review — 체크리스트/메모 갱신
--    (+ 보완 필요 여부에 따라 상태를 reviewing ⇄ supplementRequired로)
-- ============================================================

create or replace function public.update_pre_application_document_review(
  p_pre_application_no text,
  p_items jsonb default '[]'::jsonb,
  p_admin_memo text default null,
  p_supplement_required boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  new_status text;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('reviewing', 'supplementRequired') then
    raise exception '검수 중 상태에서만 체크리스트를 갱신할 수 있습니다(현재 상태: %).', app_row.status;
  end if;

  new_status := case when p_supplement_required then 'supplementRequired' else 'reviewing' end;

  update public.pre_applications
  set status = new_status,
      document_review = jsonb_build_object(
        'items', p_items,
        'adminMemo', p_admin_memo,
        'reviewedAt', now(),
        'reviewedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.documentReviewUpdated', 'admin', caller,
    jsonb_build_object('supplementRequired', p_supplement_required));
end;
$$;

-- ============================================================
-- 7. convert_pre_application_to_applicant — 접수대장(applicants) 전환
--    00003 register_applicant와 동일한 4테이블 insert 패턴 + receipt_no 채번
--    재사용. source_pre_application_id로 FK 연결(00023에서 미리 걸어둔 목적).
-- ============================================================

create or replace function public.convert_pre_application_to_applicant(
  p_pre_application_no text,
  p_year int,
  p_round admission_round,
  p_receipt_method text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  priv_row record;
  effective_method text;
  new_receipt_no text;
  new_applicant_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환된 건입니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'expired' then
    raise exception '접수기간이 만료되어 전환할 수 없습니다(%).', p_pre_application_no;
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  if priv_row is null then
    raise exception '사전작성 개인정보 행을 찾을 수 없습니다(데이터 정합성 이상, %).', p_pre_application_no;
  end if;

  effective_method := coalesce(p_receipt_method, app_row.receipt_method);
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, effective_method);

  insert into public.applicants
    (year, round, receipt_no, name, tracks, academic_status, school, grade_class_no,
     semester_choice, receipt_method, source_pre_application_id, created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, priv_row.name, app_row.tracks, app_row.academic_status,
     app_row.school, app_row.grade_class_no, app_row.semester_choice, effective_method,
     app_row.id, caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone)
  values
    (new_applicant_id, priv_row.gender, priv_row.birth_date, priv_row.applicant_phone,
     priv_row.email, priv_row.address, priv_row.guardian_name, priv_row.guardian_relation,
     priv_row.guardian_phone);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, priv_row.name);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered.fromPreApplication', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  update public.pre_applications
  set status = 'converted',
      conversion = jsonb_build_object(
        'applicantId', new_applicant_id,
        'receiptNo', new_receipt_no,
        'convertedAt', now(),
        'convertedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.converted', 'admin', caller,
    jsonb_build_object('applicantId', new_applicant_id, 'receiptNo', new_receipt_no));

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

-- ============================================================
-- 8. 권한 하드닝 — 이번 세션에서 두 번 겪은 "revoke만으로는 anon execute가
--    안 막히는" 문제(00038/00040 참고) 재발을 막기 위해, 처음부터 기존
--    오버로드를 전부 drop한 뒤 명시적으로 public/anon/authenticated를 revoke하고
--    authenticated에만 다시 grant한다(내부 _require_any_role이 최종 게이트).
-- ============================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'admin_list_pre_applications',
      'admin_get_pre_application_detail',
      'mark_pre_application_arrived',
      'mark_pre_application_reviewing',
      'update_pre_application_document_review',
      'convert_pre_application_to_applicant'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_list_pre_applications(text[]) is
  '사전작성 현황 목록(관리자 대시보드). superadmin/admin/reception만 — 내부 _require_any_role로 검증. anon 완전 차단.';
comment on function public.admin_get_pre_application_detail(text) is
  '사전작성 건 상세(개인정보 포함) + 최근 이벤트 20건. superadmin/admin/reception만.';
comment on function public.convert_pre_application_to_applicant(text, int, admission_round, text) is
  '사전작성 건을 접수대장(applicants)으로 전환하는 단일 트랜잭션(00023 설계 의도).
   receipt_no는 00003의 _allocate_receipt_no를 그대로 재사용해 M1 수기접수와
   동일한 채번 규칙을 따른다. 전환 후 pre_applications.status=converted, 원본
   건과 신규 applicants 행이 source_pre_application_id로 연결된다.';

-- ======================================================================
-- 00043_pre_application_wizard_expansion.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — M8a 사전작성 위저드 확장 (사용자 피드백 일괄, 2026-07-12)
--
-- 이번 세션 사용자 피드백 7가지 중 데이터모델이 필요한 항목을 반영한다:
--   1. 관리자 사전작성 현황에서 삭제(소프트 삭제/취소 상태로 — 사용자 확인)
--   2. 학적상태 '졸업' 선택 시 졸업일자 입력(입력일 이후 날짜 금지)
--   3. '기타' 학적은 자유 서술 텍스트(school 컬럼 그대로 재사용) + 관리자가
--      나중에 고쳐줄 수 있는 전용 RPC
--   5. 지원자 영문 성명 + 국적(대한민국/외국, 외국이면 국가명도 — 사용자 확인)
--   7. 보호자 주소 "지원자와 동일" 체크박스 — 다르면 보호자 주소를 별도로
--      저장(같으면 저장하지 않고 플래그만 true로 둔다 — generate-application-
--      bundle이 이 플래그를 보고 지원자 주소를 재사용할지 결정)
--   8. (추가 요청, 같은 날) 인천 소재 학교는 전형 옵션(일반+인천학생추천)을
--      강제하고, 그중 강화군 소재 중학교 졸업(예정)자는 가산점 자진신고
--      체크박스를 보여준다(마스터스펙 5.2.7 — 서류평가 20% 가산, 인천학생
--      추천 지원자 한정). applicants.bonus_reason/bonus_eligible과 동일한
--      이름·의미로 pre_applications에도 둔다 — bonus_eligible은 두지 않는다
--      (마스터스펙 "null≠0" 원칙: 자진신고는 어디까지나 미확인 claim이고,
--      실제 서류(주민등록초본 등) 대조로 관리자가 검증해야 확정되는 값이라
--      applicants 전환 이후 M4 서류사정 단계에서 admin이 확인한다 — 지금
--      단계에서 true/false를 함부로 단정하지 않는다).
--
-- (4번 라벨 문구, 6번 위저드 단계 순서는 프론트엔드 전용 변경이라 이 마이그
-- 레이션 범위 밖.)

-- ============================================================
-- 1. pre_applications — 상태값에 'cancelled' 추가 + 졸업일자 컬럼
-- ============================================================

alter table public.pre_applications drop constraint if exists pre_applications_status_check;
alter table public.pre_applications
  add constraint pre_applications_status_check
  check (status in ('completed', 'bundleGenerated', 'arrived', 'reviewing',
                     'supplementRequired', 'converted', 'expired', 'cancelled'));

alter table public.pre_applications
  add column if not exists graduation_date date,
  add column if not exists bonus_reason text;

comment on column public.pre_applications.graduation_date is
  '학적상태가 "졸업"일 때만 의미 있는 졸업일자. 입력 시점보다 미래일 수 없음
   (create_pre_application에서 검증). "졸업예정"/"검정고시"/"기타"는 null.';
comment on column public.pre_applications.bonus_reason is
  '가산점 자진신고 사유(현재는 강화군소재중학교졸업만 위저드에서 수집 —
   마스터스펙 5.2.7). applicants.bonus_reason과 같은 이름·의미. 실제 적용
   여부(bonus_eligible)는 여기 두지 않는다 — M1 applicants와 마찬가지로
   전환 후 관리자가 서류로 검증해야 확정되는 값("null≠0" 원칙, 00003 참고).';

-- ============================================================
-- 2. pre_applications_private — 영문성명/국적/보호자 주소 컬럼 추가
-- ============================================================

alter table public.pre_applications_private
  add column if not exists english_name text,
  add column if not exists nationality text,
  add column if not exists nationality_country text,
  add column if not exists guardian_address_same_as_applicant boolean not null default true,
  add column if not exists guardian_address text,
  add column if not exists guardian_postal_code text;

alter table public.pre_applications_private drop constraint if exists pre_applications_private_nationality_check;
alter table public.pre_applications_private
  add constraint pre_applications_private_nationality_check
  check (nationality is null or nationality in ('대한민국', '외국'));

comment on column public.pre_applications_private.english_name is
  '입학원서 영문성명 칸(여권상 이름, 성/이름) 프리필용.';
comment on column public.pre_applications_private.nationality is
  '입학원서 국적 체크박스(대한민국/외국 국적자) 프리필용.';
comment on column public.pre_applications_private.nationality_country is
  'nationality=''외국''일 때만 사용하는 국가명 자유입력. 대한민국이면 null.';
comment on column public.pre_applications_private.guardian_address_same_as_applicant is
  '사전작성 위저드 "지원자와 주민등록상 주소 같음" 체크박스 값. true(기본값)면
   guardian_address/guardian_postal_code는 비워두고 generate-application-bundle이
   지원자 본인 주소(address/postal_code)를 보호자란에도 그대로 채운다. false면
   guardian_address/guardian_postal_code를 따로 채워서 써야 한다.';
comment on column public.pre_applications_private.guardian_address is
  'guardian_address_same_as_applicant=false일 때만 값이 있는 보호자 본인 주소.';

-- ============================================================
-- 3. create_pre_application 재정의 — 위 신규 컬럼 파라미터 추가.
--    00035 시그니처(18-인자)를 명시적으로 drop하고 새 파라미터를 끝에
--    덧붙인 새 시그니처로 다시 만든다(오버로드 방지 — 00035 주석과 동일 이유).
-- ============================================================

drop function if exists public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text);

create or replace function public.create_pre_application(
  p_year int,
  p_round admission_round,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_name text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_postal_code text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_english_name text default null,
  p_nationality text default null,
  p_nationality_country text default null,
  p_graduation_date date default null,
  p_guardian_address_same_as_applicant boolean default true,
  p_guardian_address text default null,
  p_guardian_postal_code text default null,
  p_bonus_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  schedule_json jsonb;
  receipt_end date;
  new_expires_at timestamptz;
  new_pre_application_no text;
  new_access_code text;
  new_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_tracks is null or array_length(p_tracks, 1) is null then
    raise exception '전형(tracks)은 필수입니다.';
  end if;
  if p_receipt_method not in ('M', 'V') then
    raise exception '접수방법은 M(우편) 또는 V(방문)이어야 합니다.';
  end if;
  if p_nationality is not null and p_nationality not in ('대한민국', '외국') then
    raise exception '국적은 대한민국 또는 외국이어야 합니다.';
  end if;
  if p_graduation_date is not null and p_graduation_date > current_date then
    raise exception '졸업일자는 오늘보다 미래일 수 없습니다.';
  end if;
  if p_bonus_reason is not null and not ('incheon' = any(p_tracks)) then
    raise exception '가산점(강화군 소재 중학교 등)은 인천학생추천전형(incheon) 지원자만 신청할 수 있습니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select cr.schedule into schedule_json
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = p_year and ar.round = p_round;

  receipt_end := (schedule_json->>'receiptEnd')::date;
  if receipt_end is null then
    raise exception '차수(%, %) config에 receiptEnd가 설정되어 있지 않습니다.', p_year, p_round;
  end if;
  new_expires_at := (receipt_end + interval '30 days') at time zone 'Asia/Seoul';

  new_pre_application_no := public._allocate_pre_application_no(p_year, p_round);
  new_access_code := public._generate_pre_application_access_code();

  insert into public.pre_applications
    (year, round, pre_application_no, tracks, academic_status, school,
     grade_class_no, semester_choice, receipt_method, expires_at, graduation_date,
     bonus_reason)
  values
    (p_year, p_round, new_pre_application_no, p_tracks, p_academic_status, p_school,
     p_grade_class_no, p_semester_choice, p_receipt_method, new_expires_at, p_graduation_date,
     p_bonus_reason)
  returning id into new_id;

  insert into public.pre_applications_private
    (pre_application_id, name, gender, birth_date, applicant_phone, email,
     address, postal_code, guardian_name, guardian_relation, guardian_phone,
     english_name, nationality, nationality_country,
     guardian_address_same_as_applicant, guardian_address, guardian_postal_code)
  values
    (new_id, trim(p_name), p_gender, p_birth_date, p_applicant_phone, p_email,
     p_address, p_postal_code, p_guardian_name, p_guardian_relation, p_guardian_phone,
     p_english_name, p_nationality, p_nationality_country,
     coalesce(p_guardian_address_same_as_applicant, true), p_guardian_address, p_guardian_postal_code);

  perform public.set_pre_application_access_code(new_id, new_access_code);

  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.created', 'system');

  return json_build_object(
    'preApplicationId', new_id,
    'preApplicationNo', new_pre_application_no,
    'accessCode', new_access_code,
    'expiresAt', new_expires_at
  );
end;
$$;

revoke execute on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text,
  text, text, text, date, boolean, text, text, text
) from public, anon, authenticated;

comment on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text,
  text, text, text, date, boolean, text, text, text
) is
  'Edge Function(createPreApplication)이 Turnstile 검증 통과 후 service_role로만
   호출한다. public/anon/authenticated 직접 호출 전면 차단.
   00043: 영문성명/국적/졸업일자/보호자 주소(동일여부 포함)/가산점 사유 파라미터 추가.';

-- ============================================================
-- 4. admin_cancel_pre_application — 소프트 삭제(사용자 확인: 완전삭제 아님)
-- ============================================================

create or replace function public.admin_cancel_pre_application(
  p_pre_application_no text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환된 건은 취소할 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'cancelled' then
    raise exception '이미 취소된 건입니다(%).', p_pre_application_no;
  end if;

  update public.pre_applications
  set status = 'cancelled'
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.cancelled', 'admin', caller,
    jsonb_build_object('reason', p_reason));
end;
$$;

comment on function public.admin_cancel_pre_application(text, text) is
  '사전작성 건 소프트 삭제(취소) — 데이터는 남기고 status만 cancelled로 전환한다
   (2026-07-12 사용자 확인: 완전 삭제 대신 취소 상태 유지). 이미 접수대장으로
   전환된 건은 취소 불가.';

-- ============================================================
-- 5. admin_update_pre_application_school — '기타' 학적 등 학교/학적 설명 수정
-- ============================================================

create or replace function public.admin_update_pre_application_school(
  p_pre_application_no text,
  p_school text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;

  update public.pre_applications
  set school = nullif(trim(p_school), '')
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.schoolUpdated', 'admin', caller);
end;
$$;

comment on function public.admin_update_pre_application_school(text, text) is
  '관리자가 출신학교/학적 설명(주로 "기타" 학적의 자유서술) 텍스트를 고칠 수 있게
   하는 RPC(2026-07-12 사용자 요청 — 미인가 대안학교 등 학부모가 잘못 입력했을 때
   관리자가 정정).';

-- ============================================================
-- 6. admin_list_pre_applications / admin_get_pre_application_detail 재정의
--    — 신규 컬럼 노출 + cancelled 상태 포함(목록에서 별도 필터링은 프론트 몫)
-- ============================================================

create or replace function public.admin_list_pre_applications(
  p_status_filter text[] default null
)
returns table (
  id uuid,
  pre_application_no text,
  year int,
  round admission_round,
  name text,
  applicant_phone text,
  guardian_phone text,
  status text,
  tracks text[],
  academic_status text,
  receipt_method text,
  school text,
  created_at timestamptz,
  expires_at timestamptz,
  shipping jsonb,
  arrival jsonb,
  document_review jsonb,
  conversion jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  return query
    select
      pa.id, pa.pre_application_no, pa.year, pa.round,
      pp.name, pp.applicant_phone, pp.guardian_phone,
      pa.status, pa.tracks, pa.academic_status, pa.receipt_method, pa.school,
      pa.created_at, pa.expires_at,
      pa.shipping, pa.arrival, pa.document_review, pa.conversion
    from public.pre_applications pa
    join public.pre_applications_private pp on pp.pre_application_id = pa.id
    where p_status_filter is null or pa.status = any(p_status_filter)
    order by pa.created_at desc;
end;
$$;

-- (admin_get_pre_application_detail 재정의는 원본 파일이 잘려 있어 뺐다 — 00042 판을 쓰고, 00049에서 사전 원서 기능 전체를 지운다)

-- ======================================================================
-- 00044_restore_instant_bundle_token.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — create_pre_application 즉시출력 토큰 발급 복구
--
-- 버그: 00043에서 create_pre_application을 drop+재정의하면서(신규 파라미터
-- 추가 목적) 00041에서 추가됐던 즉시출력 토큰(instantBundleToken) 발급 로직을
-- 실수로 빠뜨렸다 — new_instant_token 변수 선언, _generate_instant_bundle_token()
-- 호출, _set_pre_application_instant_bundle_token() perform, 응답 json의
-- 'instantBundleToken' 필드, 'preApplication.instantBundle.issued' 이벤트가
-- 모두 누락됨. 그 결과 00043 배포(db push) 이후 새로 접수된 사전작성 건은
-- 완료 화면에 "지금 바로 서류 출력" 버튼이 뜨지 않았다(2026-07-12 실사용
-- 확인 — 사용자 피드백: "사전 작성 완료 화면에서 바로 서류 인쇄하는 버튼이
-- 사라졌네???").
--
-- 조치: create_pre_application을 00043과 완전히 동일한 26개 파라미터
-- 시그니처로 다시 재정의하되(시그니처가 같으므로 drop 불필요 — create or
-- replace로 충분), 00041의 즉시출력 토큰 발급 로직을 그대로 복원해 넣는다.
-- 그 외 검증/insert 로직은 00043과 동일하게 유지한다.

create or replace function public.create_pre_application(
  p_year int,
  p_round admission_round,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_name text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_postal_code text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_english_name text default null,
  p_nationality text default null,
  p_nationality_country text default null,
  p_graduation_date date default null,
  p_guardian_address_same_as_applicant boolean default true,
  p_guardian_address text default null,
  p_guardian_postal_code text default null,
  p_bonus_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  schedule_json jsonb;
  receipt_end date;
  new_expires_at timestamptz;
  new_pre_application_no text;
  new_access_code text;
  new_instant_token text;
  new_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_tracks is null or array_length(p_tracks, 1) is null then
    raise exception '전형(tracks)은 필수입니다.';
  end if;
  if p_receipt_method not in ('M', 'V') then
    raise exception '접수방법은 M(우편) 또는 V(방문)이어야 합니다.';
  end if;
  if p_nationality is not null and p_nationality not in ('대한민국', '외국') then
    raise exception '국적은 대한민국 또는 외국이어야 합니다.';
  end if;
  if p_graduation_date is not null and p_graduation_date > current_date then
    raise exception '졸업일자는 오늘보다 미래일 수 없습니다.';
  end if;
  if p_bonus_reason is not null and not ('incheon' = any(p_tracks)) then
    raise exception '가산점(강화군 소재 중학교 등)은 인천학생추천전형(incheon) 지원자만 신청할 수 있습니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select cr.schedule into schedule_json
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = p_year and ar.round = p_round;

  receipt_end := (schedule_json->>'receiptEnd')::date;
  if receipt_end is null then
    raise exception '차수(%, %) config에 receiptEnd가 설정되어 있지 않습니다.', p_year, p_round;
  end if;
  new_expires_at := (receipt_end + interval '30 days') at time zone 'Asia/Seoul';

  new_pre_application_no := public._allocate_pre_application_no(p_year, p_round);
  new_access_code := public._generate_pre_application_access_code();
  new_instant_token := public._generate_instant_bundle_token();

  insert into public.pre_applications
    (year, round, pre_application_no, tracks, academic_status, school,
     grade_class_no, semester_choice, receipt_method, expires_at, graduation_date,
     bonus_reason)
  values
    (p_year, p_round, new_pre_application_no, p_tracks, p_academic_status, p_school,
     p_grade_class_no, p_semester_choice, p_receipt_method, new_expires_at, p_graduation_date,
     p_bonus_reason)
  returning id into new_id;

  insert into public.pre_applications_private
    (pre_application_id, name, gender, birth_date, applicant_phone, email,
     address, postal_code, guardian_name, guardian_relation, guardian_phone,
     english_name, nationality, nationality_country,
     guardian_address_same_as_applicant, guardian_address, guardian_postal_code)
  values
    (new_id, trim(p_name), p_gender, p_birth_date, p_applicant_phone, p_email,
     p_address, p_postal_code, p_guardian_name, p_guardian_relation, p_guardian_phone,
     p_english_name, p_nationality, p_nationality_country,
     coalesce(p_guardian_address_same_as_applicant, true), p_guardian_address, p_guardian_postal_code);

  perform public.set_pre_application_access_code(new_id, new_access_code);
  perform public._set_pre_application_instant_bundle_token(new_id, new_instant_token);

  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.created', 'system');
  perform public._record_pre_application_event(
    new_id, new_pre_application_no, 'preApplication.instantBundle.issued', 'system');

  -- accessCode/instantBundleToken 둘 다 이 응답에서만 1회 반환한다 — 이후
  -- 어디에도 원문으로 남지 않는다(pre_application_secrets에는 해시만 저장).
  return json_build_object(
    'preApplicationId', new_id,
    'preApplicationNo', new_pre_application_no,
    'accessCode', new_access_code,
    'instantBundleToken', new_instant_token,
    'expiresAt', new_expires_at
  );
end;
$$;

revoke execute on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text,
  text, text, text, date, boolean, text, text, text
) from public, anon, authenticated;

comment on function public.create_pre_application(
  int, admission_round, text[], text, text, text, text, text, text,
  text, date, text, text, text, text, text, text, text,
  text, text, text, date, boolean, text, text, text
) is
  'Edge Function(createPreApplication)이 Turnstile 검증 통과 후 service_role로만
   호출한다. public/anon/authenticated 직접 호출 전면 차단.
   00043: 영문성명/국적/졸업일자/보호자 주소(동일여부 포함)/가산점 사유 파라미터 추가.
   00044: 00043 재정의 시 실수로 빠졌던 즉시출력 토큰(instantBundleToken) 발급을 복구.';

-- ======================================================================
-- 00045_pre_application_permanent_delete.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 사전작성 건 완전삭제(하드 delete) (Task #53)
--
-- 배경: 00043의 admin_cancel_pre_application은 의도적으로 소프트 삭제만
-- 지원했다("완전삭제 대신 취소 상태 유지" — 당시 사용자 확인). 이번에는
-- 사용자가 명시적으로 "개별 지원자 정보도 완전삭제하는 기능"을 요청함
-- (2026-07-12). 소프트 삭제(취소) 기능은 그대로 두고, 진짜 하드 delete를
-- 별도 함수로 추가한다 — 기존 취소 기능을 대체하지 않는다.
--
-- 권한: mark_*/admin_cancel_pre_application 등은 reception까지 허용하지만,
-- 이 함수는 PII를 영구히 파기하는 작업이라 superadmin/admin만 허용한다
-- (delete_applicant(00022)와 동일한 권한 수준 — reception 제외).
--
-- 접수대장 전환(converted) 건은 이 함수로 지울 수 없다(2026-07-12 사용자 확인:
-- "전환된 건은 삭제 금지하되, 정식 접수대장에서 지울 수 있으면 됨") — 이미
-- applicants 테이블에 실제 지원자 기록이 생성돼 있으므로, 그 기록을 지우고
-- 싶으면 00022의 delete_applicant를 정식 접수대장 화면에서 사용해야 한다
-- (delete_applicant는 pre_applications를 건드리지 않으므로 두 함수가 서로
-- 안전하게 독립적으로 동작한다).
--
-- 삭제 순서: pre_applications_private/pre_application_secrets는 00023에서
-- on delete cascade로 걸려있어 자동 삭제된다. pre_application_events는
-- on delete set null이라 삭제 후에도 pre_application_no 텍스트로 감사 이력이
-- 남는다 — 그래서 실제 delete 직전에 이벤트를 1건 기록해둔다(삭제 자체를
-- 추적할 마지막 흔적).

create or replace function public.admin_permanently_delete_pre_application(
  p_pre_application_no text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  priv_row record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;

  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환된 건은 완전삭제할 수 없습니다. 실제 지원자 기록을 지우려면 정식 접수대장(지원자 삭제) 기능을 사용하세요(%).', p_pre_application_no
      using errcode = '55000';
  end if;

  select name into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  -- delete 직전에 이벤트를 남긴다 — pre_application_events.pre_application_id는
  -- on delete set null이라 삭제 후에도 pre_application_no 텍스트로 이력이 남는다.
  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.permanentlyDeleted', 'admin', caller,
    jsonb_build_object('reason', p_reason));

  delete from public.pre_applications where id = app_row.id;
  -- pre_applications_private / pre_application_secrets는 on delete cascade로 함께 삭제.

  return jsonb_build_object(
    'deleted', true,
    'preApplicationNo', p_pre_application_no,
    'name', priv_row.name
  );
end;
$$;

revoke all on function public.admin_permanently_delete_pre_application(text, text) from public, anon, authenticated;
grant execute on function public.admin_permanently_delete_pre_application(text, text) to authenticated;

comment on function public.admin_permanently_delete_pre_application(text, text) is
  '사전작성 건 완전삭제(하드 delete) — 이름/연락처/주소 등 원문 개인정보까지
   pre_applications_private/pre_application_secrets가 cascade로 함께 삭제된다.
   superadmin/admin만(reception 제외 — PII 영구삭제이므로 소프트
   삭제(admin_cancel_pre_application, reception 포함 허용)보다 권한을 좁힌다).
   이미 접수대장으로 전환된 건은 삭제 금지 — 정식 접수대장에서는 기존
   delete_applicant로 처리한다(2026-07-12 사용자 확인).';

-- ======================================================================
-- 00046_upsert_user_access_provider_neutral_message.sql
-- ======================================================================

-- 2026-07-13: 로그인 방식을 Google OAuth에서 자체 이메일/비밀번호로 전환하면서
-- (feature/local-server-migration, Login.jsx 개편) upsert_user_access의 에러
-- 메시지에 남아있던 "Google로 로그인" 문구를 provider-중립 표현으로 교체한다.
-- 로직(auth.users 존재 여부 확인) 자체는 그대로 — 애초에 이 함수는 provider를
-- 구분하지 않았고, 문구만 구글 전용으로 돼 있었다.

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
    raise exception '% 계정이 아직 로그인(가입)한 적이 없습니다. 대상자가 먼저 앱에서 계정을 만들고 1회 로그인한 뒤 다시 시도하세요.', target_email;
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

-- ======================================================================
-- 00047_pre_application_bridge_export.sql
-- ======================================================================

-- 2026-07-13: 로컬 서버 전환 이원화(A안) — 사전작성(M8)은 클라우드에 남기고,
-- 정식 접수 이후 데이터만 로컬로 이전한다(docs/로컬서버_전환_검토_2026-07.md 9절).
--
-- 지금까지의 convert_pre_application_to_applicant(00042)는 같은 DB 안에서
-- pre_applications -> applicants로 "한 트랜잭션"에 옮겼다. 이원화 이후에는
-- 두 DB가 물리적으로 분리되므로(클라우드=사전작성, 로컬=접수대장) 한
-- 트랜잭션으로 묶을 수 없다 — 대신 2단계로 나눈다:
--   1) (이 마이그레이션, 클라우드 DB에 적용) admin_export_pre_application_for_bridge
--      로 개인정보 포함 전체 데이터를 jsonb로 꺼낸다. 아직 상태를 바꾸지 않는다
--      — 로컬 쪽 insert가 실패할 수도 있으므로, 실제로 로컬에 저장된 뒤에만
--      완료 처리해야 한다(2번 함수).
--   2) 로컬 시스템에서 00048의 admin_import_applicant_from_pre_application_bridge로
--      실제 applicants 행을 만든 뒤, 성공하면 다시 이 클라우드 DB로 돌아와
--      admin_mark_pre_application_bridged를 호출해 완료 처리한다.
--
-- 인증/전송 방식: 관리자가 클라우드 대시보드 계정으로 이 함수를 호출한다
-- (기존 사전작성 대시보드와 동일한 로그인). 별도 공유 비밀키·Edge Function
-- 없이, 관리자가 로컬 시스템의 "사전작성 이관" 화면에서 클라우드 계정으로
-- 한 번 더 로그인해 이 RPC를 직접 호출하는 방식을 전제로 설계했다 — 새
-- Edge Function을 로컬에 추가하지 않아도 되고(설치절차서의 "Edge Function
-- 이전 불필요" 결론을 그대로 유지), 이 RPC를 호출한 실제 사람이 caller로
-- 남아 감사 추적이 더 명확하다.
--
-- 이 함수가 반환하는 jsonb는 00048의 admin_import_applicant_from_pre_application_bridge
-- 파라미터 p_payload와 1:1로 맞춰서 설계했다 — 필드명을 바꾸면 양쪽을 같이
-- 고쳐야 한다.

create or replace function public.admin_export_pre_application_for_bridge(
  p_pre_application_no text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  priv_row record;
  payload jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환/이관된 건입니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'expired' then
    raise exception '접수기간이 만료되어 이관할 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'cancelled' then
    raise exception '취소된 건입니다(%).', p_pre_application_no;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  if priv_row is null then
    raise exception '사전작성 개인정보 행을 찾을 수 없습니다(데이터 정합성 이상, %).', p_pre_application_no;
  end if;

  payload := jsonb_build_object(
    'preApplicationNo', app_row.pre_application_no,
    'tracks', to_jsonb(app_row.tracks),
    'academicStatus', app_row.academic_status,
    'school', app_row.school,
    'gradeClassNo', app_row.grade_class_no,
    'semesterChoice', app_row.semester_choice,
    'receiptMethod', app_row.receipt_method,
    'name', priv_row.name,
    'gender', priv_row.gender,
    'birthDate', priv_row.birth_date,
    'applicantPhone', priv_row.applicant_phone,
    'email', priv_row.email,
    'address', priv_row.address,
    'guardianName', priv_row.guardian_name,
    'guardianRelation', priv_row.guardian_relation,
    'guardianPhone', priv_row.guardian_phone,
    'exportedAt', now(),
    'exportedBy', caller::text
  );

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.exportedForBridge', 'admin', caller,
    jsonb_build_object('exportedAt', now()));

  return payload;
end;
$$;

-- 로컬 쪽 insert가 성공적으로 끝난 뒤에만 호출한다. 실패했는데도 이 함수를
-- 호출하면 로컬에는 데이터가 없는데 클라우드만 "전환됨"으로 표시되는
-- 불일치가 생긴다 — 반드시 로컬 insert 성공을 확인한 뒤 호출할 것.
create or replace function public.admin_mark_pre_application_bridged(
  p_pre_application_no text,
  p_local_receipt_no text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 완료 처리된 건입니다(%).', p_pre_application_no;
  end if;

  update public.pre_applications
  set status = 'converted',
      conversion = jsonb_build_object(
        'bridgedToLocal', true,
        'localReceiptNo', p_local_receipt_no,
        'bridgedAt', now(),
        'bridgedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.bridgedToLocal', 'admin', caller,
    jsonb_build_object('localReceiptNo', p_local_receipt_no));

  return json_build_object('preApplicationNo', p_pre_application_no, 'localReceiptNo', p_local_receipt_no);
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'admin_export_pre_application_for_bridge',
      'admin_mark_pre_application_bridged'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_export_pre_application_for_bridge(text) is
  '이원화(A안) 브릿지 1단계 — 사전작성 데이터를 jsonb로 내보낸다(클라우드 DB용).
   상태는 아직 바꾸지 않는다. 로컬 시스템(00048)에서 실제 접수대장 insert가
   성공한 뒤 admin_mark_pre_application_bridged를 호출해 완료 처리한다.';
comment on function public.admin_mark_pre_application_bridged(text, text) is
  '이원화(A안) 브릿지 2단계 — 로컬 접수대장 insert 성공 확인 후 호출. status를
   converted로 바꾸고 conversion에 로컬 접수번호를 기록한다(applicantId는 다른
   DB에 있어 여기 저장하지 않는다).';

-- ======================================================================
-- 00048_pre_application_bridge_import.sql
-- ======================================================================

-- 2026-07-13: 이원화(A안) 브릿지 2단계 — 로컬(교내) 서버 DB에 적용할 마이그레이션.
-- 00047(클라우드)의 admin_export_pre_application_for_bridge가 반환한 jsonb를
-- 그대로 받아 접수대장(applicants) 4테이블에 insert한다. 00042의
-- convert_pre_application_to_applicant와 같은 패턴이지만, 원본
-- pre_applications 행이 이 DB에는 없으므로(다른 DB에 있음) FK로 연결할 수
-- 없다 — source_pre_application_id(uuid FK) 대신 source_pre_application_no
-- (text, FK 없음)를 새로 둔다.
--
-- 이 마이그레이션은 클라우드 DB에도 똑같이 적용될 수 있다(같은 migrations
-- 폴더를 두 프로젝트에 그대로 적용하는 현재 운영 방식과 일치) — 클라우드
-- 쪽에서는 이 컬럼/함수가 그냥 쓰이지 않을 뿐, 문제는 없다.

alter table public.applicants
  add column if not exists source_pre_application_no text;

comment on column public.applicants.source_pre_application_no is
  '이원화(A안) 브릿지로 가져온 경우의 원본 사전작성 번호(다른 DB에 있어 FK
   불가 — 자연키만 보관). 같은 DB 안에서 전환된 경우(00042 경로)는 대신
   source_pre_application_id(uuid FK)를 쓴다. 두 값이 동시에 채워지는 경우는
   없다.';

-- 아래 함수 안의 exists 체크만으로는 동시 요청(관리자 두 명이 동시에 같은
-- 건을 이관 시도하는 등) 경쟁 조건을 완전히 막지 못한다 — DB 유니크
-- 인덱스로 최종 방어선을 둔다.
create unique index if not exists applicants_source_pre_application_no_uidx
  on public.applicants (source_pre_application_no)
  where source_pre_application_no is not null;

create or replace function public.admin_import_applicant_from_pre_application_bridge(
  p_payload jsonb,
  p_year int,
  p_round admission_round,
  p_receipt_method text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  effective_method text;
  new_receipt_no text;
  new_applicant_id uuid;
  v_pre_application_no text;
  v_tracks text[];
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  v_pre_application_no := p_payload->>'preApplicationNo';
  if v_pre_application_no is null or length(trim(v_pre_application_no)) = 0 then
    raise exception 'payload에 preApplicationNo가 없습니다.';
  end if;

  if exists (
    select 1 from public.applicants where source_pre_application_no = v_pre_application_no
  ) then
    raise exception '이미 이 사전작성 번호(%)로 가져온 접수 건이 있습니다. 중복 이관을 막기 위해 중단합니다.', v_pre_application_no;
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select array(select jsonb_array_elements_text(p_payload->'tracks')) into v_tracks;

  effective_method := coalesce(p_receipt_method, p_payload->>'receiptMethod');
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, effective_method);

  insert into public.applicants
    (year, round, receipt_no, name, tracks, academic_status, school, grade_class_no,
     semester_choice, receipt_method, source_pre_application_no, created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, p_payload->>'name', v_tracks, p_payload->>'academicStatus',
     p_payload->>'school', p_payload->>'gradeClassNo', p_payload->>'semesterChoice', effective_method,
     v_pre_application_no, caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone)
  values
    (new_applicant_id, p_payload->>'gender',
     nullif(p_payload->>'birthDate', '')::date,
     p_payload->>'applicantPhone', p_payload->>'email', p_payload->>'address',
     p_payload->>'guardianName', p_payload->>'guardianRelation', p_payload->>'guardianPhone');

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, p_payload->>'name');

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered.fromPreApplicationBridge', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no,
    'preApplicationNo', v_pre_application_no
  );
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'admin_import_applicant_from_pre_application_bridge'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_import_applicant_from_pre_application_bridge(jsonb, int, admission_round, text) is
  '이원화(A안) 브릿지 2단계(로컬 DB) — 00047 admin_export_pre_application_for_bridge가
   반환한 jsonb를 받아 접수대장에 insert한다. 호출 성공 후 반드시 클라우드
   DB의 admin_mark_pre_application_bridged를 호출해 원본을 완료 처리할 것
   (안 하면 클라우드 목록에 "미이관"으로 계속 남아 있을 뿐 — 중복 이관은
   source_pre_application_no unique 체크로 이미 막혀 있어 데이터 오류는
   발생하지 않는다).';

-- ======================================================================
-- 00049_remove_pre_application_m8.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 사전작성(M8) 온라인 포털 완전 제거
--
-- 2026-07-13 결정(docs/로컬서버_설치절차_2026-07.md): 이원화(클라우드+로컬 동시
-- 운영)로 인한 학교 측 운영 부담이 너무 크다고 판단, 온라인 사전작성 포털을
-- 포기하고 등기우편·방문 접수(M1 수기접수)만 운영하기로 확정. 이 마이그레이션은
-- 00023~00048에서 만든 pre_applications 관련 테이블·함수·스토리지 버킷·cron
-- 작업을 전부 제거한다.
--
-- 기존 migrations(00023~00048) 파일 자체는 수정하지 않는다(이 프로젝트의
-- "이미 적용된 마이그레이션은 손대지 않는다" 원칙 — 검토메모_2026-07-06 참고).
-- 대신 이 신규 migration으로 되돌린다.

-- ============================================================
-- 1. cron 작업 해제
-- ============================================================

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-expired-pre-application-bundles') then
    perform cron.unschedule('cleanup-expired-pre-application-bundles');
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-expired-pre-applications') then
    perform cron.unschedule('purge-expired-pre-applications');
  end if;
end $$;

-- ============================================================
-- 2. applicants 테이블에 붙어있던 M8 연결 컬럼 제거
-- ============================================================

alter table public.applicants
  drop constraint if exists fk_applicants_source_pre_application;

alter table public.applicants
  drop column if exists source_pre_application_id;

alter table public.applicants
  drop column if exists source_pre_application_no;

-- ============================================================
-- 3. pre_application 관련 함수 전부 제거 (시그니처를 pg_catalog에서
--    동적으로 찾아서 삭제 — 오버로드/인자 목록을 일일이 안 적어도 됨)
-- ============================================================

do $$
declare
  fn_names text[] := array[
    '_allocate_pre_application_no',
    '_check_pre_application_rate_limit',
    '_cleanup_expired_pre_application_bundles',
    '_generate_instant_bundle_token',
    '_generate_pre_application_access_code',
    '_hash_instant_bundle_token',
    '_hash_pre_application_code',
    '_hash_pre_application_name',
    '_pre_application_pepper',
    '_purge_expired_pre_applications',
    '_record_pre_application_event',
    '_set_pre_application_instant_bundle_token',
    'admin_cancel_pre_application',
    'admin_export_pre_application_for_bridge',
    'admin_get_pre_application_detail',
    'admin_import_applicant_from_pre_application_bridge',
    'admin_list_pre_applications',
    'admin_mark_pre_application_bridged',
    'admin_permanently_delete_pre_application',
    'admin_update_pre_application_school',
    'convert_pre_application_to_applicant',
    'create_pre_application',
    'get_pre_application_status',
    'list_expired_pre_application_bundle_paths',
    'mark_pre_application_arrived',
    'mark_pre_application_reviewing',
    'record_pre_application_bundle_generated',
    'redeem_instant_bundle_token',
    'register_pre_application_tracking_number',
    'reissue_pre_application_access_code',
    'set_pre_application_access_code',
    'update_pre_application_document_review',
    'verify_pre_application_access'
  ];
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any(fn_names)
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- ============================================================
-- 4. pre_application 테이블 전부 제거
-- ============================================================

drop table if exists public.pre_application_events cascade;
drop table if exists public.pre_application_secrets cascade;
drop table if exists public.pre_application_rate_limits cascade;
drop table if exists public.pre_application_counters cascade;
drop table if exists public.pre_applications_private cascade;
drop table if exists public.pre_applications cascade;

-- ============================================================
-- 5. Storage 버킷 제거 (오브젝트 먼저, 버킷은 나중에)
-- ============================================================

delete from storage.objects
where bucket_id in ('pre-application-assets', 'pre-application-bundles');

delete from storage.buckets
where id in ('pre-application-assets', 'pre-application-bundles');

comment on table public.applicants is
  '지원자 기본정보(M1). 2026-07-13: 온라인 사전작성(M8) 포기 결정으로 source_pre_application_id/no 컬럼 제거 — 등기우편·방문 접수(수기등록)만 운영.';

-- ======================================================================
-- 00050_update_applicant.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 지원자 정보 수정 RPC (00003 register_applicant 보완)
--
-- 2026-07-14 요청: 접수 담당자가 수기접수 중 오타/입력 실수를 했을 경우
-- 지원자 목록에서 정보를 고칠 수단이 전혀 없었음(상태 변경/삭제만 가능).
-- register_applicant와 동일한 편집 가능 필드 집합을 그대로 받아 applicants +
-- applicants_private를 함께 갱신한다.
--
-- 편집 불가(이 RPC로는 못 바꿈) — 다른 전용 RPC/흐름으로만 변경:
--   receipt_no, year, round, receipt_date : 접수번호 채번과 얽혀있어 불변
--   application_status                    : update_application_status RPC
--   evaluation_stage 이후 필드들           : M4~M6 사정 RPC들
--
-- register_applicant처럼 "전체 스냅샷을 받아서 그대로 덮어쓰는" 방식이다
-- (coalesce로 부분 수정하지 않음) — 편집 폼이 현재 값을 미리 채워서 보여주고
-- 담당자가 고친 뒤 전체를 다시 제출하는 흐름과 맞다. 즉 필드를 비우면
-- 실제로 null/빈 값으로 저장된다(의도적인 삭제도 가능해야 하므로).

create or replace function public.update_applicant(
  p_applicant_id uuid,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  update public.applicants
  set name = trim(p_name),
      tracks = p_tracks,
      academic_status = p_academic_status,
      school = p_school,
      grade_class_no = p_grade_class_no,
      semester_choice = p_semester_choice,
      receipt_method = p_receipt_method,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  update public.applicants_private
  set gender = p_gender,
      birth_date = p_birth_date,
      applicant_phone = p_applicant_phone,
      email = p_email,
      address = p_address,
      guardian_name = p_guardian_name,
      guardian_relation = p_guardian_relation,
      guardian_phone = p_guardian_phone,
      guardian_address = p_guardian_address,
      updated_at = now()
  where applicant_id = p_applicant_id;

  -- evaluation_roster.display_name도 같이 맞춰준다(평가위원 화면 표시용).
  update public.evaluation_roster
  set display_name = trim(p_name),
      updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'applicant.updated', 'applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_applicant(
  uuid, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text
) from anon;

-- ======================================================================
-- 00051_delete_deactivated_user.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 비활성화된 선생님(사용자) 계정 삭제
-- 2026-07-14 요청: "선생님들 중 비활성화된 계정에 대해 삭제하는 기능도 만들어달라"
--
-- 지금까지는 set_user_active_status(00001/00046)로 활성/비활성 전환만
-- 가능했고, 계정 자체를 지우는 수단이 없었다. 이 RPC는 "이미 비활성화된"
-- 계정만 완전히 삭제한다(활성 계정은 먼저 비활성화부터 해야 함 — 실수로
-- 로그인 중인 계정을 바로 지우는 사고 방지).
--
-- 삭제 범위: auth.users 행까지 지운다(로그인 자체를 막기 위함). public.users는
-- auth.users(id) on delete cascade라 자동으로 같이 삭제된다(00001).
--
-- 평가 기록 보호: scores_*/interview_team_members/writing_plan_members/
-- deep_group_primary_observers/deep_group_rotation_assignments의
-- evaluator_uid는 public.users(id)를 참조하되 on delete cascade가 아니다
-- (RESTRICT가 기본값, 00005/00006/00009/00010/00012/00013 참고) — 즉 평가
-- 기록이 남아있는 계정을 지우려 하면 FK 위반으로 막힌다. DB 에러 메시지 대신
-- 이 RPC가 먼저 확인해서 친절한 한국어 메시지로 안내한다.

create or replace function public.delete_deactivated_user(
  p_target_uid uuid,
  p_reason text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  target record;
  ref_count int;
begin
  caller := public._require_superadmin();

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  if p_target_uid = caller then
    raise exception '자기 자신의 계정은 이 기능으로 삭제할 수 없습니다.' using errcode = '55000';
  end if;

  select id, email, display_name, active into target
  from public.users where id = p_target_uid;

  if target is null then
    raise exception '사용자를 찾을 수 없습니다.' using errcode = '55000';
  end if;

  if target.active then
    raise exception '활성 상태인 계정입니다. 먼저 비활성화한 뒤 삭제할 수 있습니다.' using errcode = '55000';
  end if;

  select
    (select count(*) from public.scores_attendance where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_academic where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_essay where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_opinion where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_group where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_interview where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_writing where evaluator_uid = p_target_uid) +
    (select count(*) from public.deep_group_primary_observers where evaluator_uid = p_target_uid) +
    (select count(*) from public.deep_group_rotation_assignments where evaluator_uid = p_target_uid) +
    (select count(*) from public.interview_team_members where evaluator_uid = p_target_uid) +
    (select count(*) from public.writing_plan_members where evaluator_uid = p_target_uid)
  into ref_count;

  if ref_count > 0 then
    raise exception '이 계정은 평가 기록(%건)이 남아있어 삭제할 수 없습니다. 기록 보존이 필요하면 비활성화 상태로 유지하세요.', ref_count
      using errcode = '55000';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, reason_code, metadata)
  values
    ('user', caller::text, 'user.access.deleted', 'users', p_target_uid::text, p_reason,
     jsonb_build_object('email', target.email, 'displayName', target.display_name));

  delete from auth.users where id = p_target_uid; -- public.users는 cascade로 함께 삭제됨

  return json_build_object('deleted', true, 'email', target.email, 'displayName', target.display_name);
end;
$$;

revoke all on function public.delete_deactivated_user(uuid, text) from public, anon;
grant execute on function public.delete_deactivated_user(uuid, text) to authenticated;

-- ======================================================================
-- 00052_admin_score_entry_on_behalf.sql
-- ======================================================================

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

-- ======================================================================
-- 00053_admin_score_entry_read_context.sql
-- ======================================================================

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

-- ======================================================================
-- 00054_final_result_sms.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 최종 합격자 개별 통보 SMS 발송 (2026-07-14)
--
-- 배경: 최종 사정 확정(run_final_decision, mode='final') 이후, 지금까지는
-- FinalAnnouncePage에서 CSV만 뽑아 "학교 문자발송 도구에서 수동 진행"하는
-- 방식이었다(00017_m6c_pass_list.sql). 접수증 안내 문자에 이미 문자나라
-- 연동(_shared/smsProvider.ts)이 있으므로, 같은 연동을 재사용해 합격자에게
-- 시스템에서 바로 SMS를 보낼 수 있게 확장한다. 대상은 "합격자"로 한정한다
-- (get_final_pass_list의 purpose='sms'는 합격/불합격 전원을 내려주지만, 이
-- 기능은 불합격 통보까지 시스템이 대신하는 것은 범위 밖 — 요청대로 합격자만).
--
-- 안전장치:
--   * 반드시 finalized 상태인 최종(decision_type='final') run만 사용 —
--     시뮬레이션 결과로는 절대 발송 대상을 만들 수 없다(get_final_pass_list와
--     동일 원칙).
--   * 중복발송 방지: (run_id, applicant_id, target)별 발송 이력을 로그
--     테이블에 남기고, 이미 성공 발송된 대상은 화면에서 "발송완료"로 표시해
--     실수로 여러 번 누르다 중복 발송하는 걸 막는다(그래도 재발송 자체는
--     막지 않는다 — 학교 쪽에서 필요하면 다시 보낼 수 있어야 하므로).
--   * audit_logs.metadata에는 연락처 원문을 절대 넣지 않는다(00001 코멘트
--     원칙 그대로) — 로그 테이블에도 전화번호를 저장하지 않고 target/발송
--     결과만 남긴다(전화번호 자체는 이미 applicants_private에 있다).

-- ============================================================
-- 1. 발송 이력 테이블
-- ============================================================

create table public.final_result_sms_log (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.decision_runs(id),
  applicant_id uuid not null references public.applicants(id),
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid not null references public.users(id),
  created_at timestamptz not null default now()
);

create index final_result_sms_log_run_applicant_idx
  on public.final_result_sms_log (run_id, applicant_id);

comment on table public.final_result_sms_log is
  '최종 합격자 개별 통보 SMS 발송 이력. 전화번호 원문은 저장하지 않는다(applicants_private 참조). 직접 SELECT는 막고 get_final_result_sms_recipients RPC로만 조회.';

alter table public.final_result_sms_log enable row level security;
revoke all on public.final_result_sms_log from public, anon, authenticated;
-- RLS 정책을 만들지 않는다 = 클라이언트 직접 접근 전면 거부, SECURITY DEFINER
-- RPC를 통해서만 읽고 쓴다(scores_* 테이블과 동일한 원칙).

-- ============================================================
-- 2. 발송 대상 조회 — 합격자만, 발송 이력 포함
-- ============================================================

create or replace function public.get_final_result_sms_recipients(
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
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome = 'passed';

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$$;

revoke all on function public.get_final_result_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_final_result_sms_recipients(int, admission_round) to authenticated;

-- ============================================================
-- 3. 발송 결과 기록 — Edge Function(send-final-result-sms)이 문자나라
--    호출 후 이 RPC로 결과를 남긴다(전화번호 자체는 남기지 않음)
-- ============================================================

create or replace function public.record_final_result_sms_sent(
  p_run_id uuid,
  p_applicant_id uuid,
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
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_target not in ('applicant', 'guardian') then
    raise exception 'target은 applicant 또는 guardian이어야 합니다.' using errcode = '22023';
  end if;

  if not exists (select 1 from public.decision_runs where id = p_run_id and decision_type = 'final' and status = 'finalized') then
    raise exception '확정된 최종 사정(run)만 기록할 수 있습니다.' using errcode = '55000';
  end if;

  insert into public.final_result_sms_log
    (run_id, applicant_id, target, sent, provider_code, provider_message, sent_by)
  values
    (p_run_id, p_applicant_id, p_target, p_sent, p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    ('user', caller::text, 'decision.final.result_sms_sent', 'final_result_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('runId', p_run_id, 'target', p_target, 'sent', p_sent, 'providerCode', p_provider_code));
end;
$$;

revoke all on function public.record_final_result_sms_sent(uuid, uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_final_result_sms_sent(uuid, uuid, text, boolean, text, text) to authenticated;

-- ======================================================================
-- 00055_current_admission_cycle.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 관리자 화면에서 현재 년도/전형(회차) 전환
--
-- 배경: 지금까지 YEAR=2027 / ROUND='main'이 20개 가까운 화면 파일에 각각
-- 하드코딩되어 있었다. admission_round enum이 애초에 'main','extra1',
-- 'extra2' 세 값을 갖도록 설계돼 있었던 것도(00001) 추가모집 등 회차 전환을
-- 염두에 둔 것이었는데, 실제로 전환할 수 있는 화면이 없었다. 이 마이그레이션은
-- admission_rounds에 "현재 활성 회차" 플래그를 추가하고, superadmin/admin이
-- 관리자 화면에서 이를 전환할 수 있는 RPC를 제공한다.
--
-- 설계: 여러 (year, round) 조합이 admission_rounds에 미리 init_admission_round로
-- 만들어져 있을 수 있으나, 그중 정확히 하나만 "현재"로 표시되어 전체
-- 화면(접수/평가/사정/발표 등)이 기본으로 바라보는 대상이 된다. 새 (year, round)
-- 자체를 만드는 것은 기존과 동일하게 init_admission_round + config revision
-- 절차를 그대로 쓰고, 이 마이그레이션은 "이미 있는 것 중 어느 걸 지금 볼지"만
-- 다룬다.

alter table public.admission_rounds
  add column is_current boolean not null default false;

-- 한 번에 하나의 (year, round)만 현재로 표시되도록 부분 유니크 인덱스로 강제.
create unique index admission_rounds_one_current_idx
  on public.admission_rounds (is_current)
  where is_current;

-- ============================================================
-- 1. 목록 조회 — 설정 화면에서 고를 수 있는 후보 목록
-- ============================================================

create or replace function public.list_admission_rounds()
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
    'year', year, 'round', round, 'stage', stage, 'stageStatus', stage_status,
    'isCurrent', is_current, 'updatedAt', updated_at
  ) order by year desc, round), '[]'::jsonb)
  into v_result
  from public.admission_rounds;

  return v_result;
end;
$$;

revoke all on function public.list_admission_rounds() from public, anon;
grant execute on function public.list_admission_rounds() to authenticated;

-- ============================================================
-- 2. 현재 활성 회차 조회 — 로그인한 모든 사용자가 앱 로드시 호출
--    (특정 데이터 노출 없이 year/round만 반환하므로 role 제한 불필요,
--    단 활성 계정만 — is_active_user()로 최소한의 게이트만 건다)
-- ============================================================

create or replace function public.get_current_admission_cycle()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
begin
  if not public.is_active_user() then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select year, round into v_row
  from public.admission_rounds
  where is_current = true
  limit 1;

  if v_row is null then
    -- 아직 아무도 현재 회차를 지정하지 않았다면, 가장 최근에 만들어진
    -- admission_round를 잠정 기본값으로 돌려준다(관리자가 곧 지정하도록 유도).
    select year, round into v_row
    from public.admission_rounds
    order by created_at desc
    limit 1;
  end if;

  if v_row is null then
    return jsonb_build_object('year', null, 'round', null);
  end if;

  return jsonb_build_object('year', v_row.year, 'round', v_row.round);
end;
$$;

revoke all on function public.get_current_admission_cycle() from public, anon;
grant execute on function public.get_current_admission_cycle() to authenticated;

-- ============================================================
-- 3. 현재 활성 회차 전환 — superadmin/admin
-- ============================================================

create or replace function public.set_current_admission_cycle(
  p_year int,
  p_round admission_round
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not exists (select 1 from public.admission_rounds where year = p_year and round = p_round) then
    raise exception 'admission_round(%, %)가 초기화되어 있지 않습니다. 먼저 해당 회차 설정을 만들어주세요.', p_year, p_round
      using errcode = 'P0002';
  end if;

  update public.admission_rounds set is_current = false where is_current = true;
  update public.admission_rounds set is_current = true where year = p_year and round = p_round;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (p_year, p_round, 'user', caller::text, 'admission_round.set_current', 'admission_rounds',
          p_year::text || '_' || p_round::text);
end;
$$;

revoke all on function public.set_current_admission_cycle(int, admission_round) from public, anon;
grant execute on function public.set_current_admission_cycle(int, admission_round) to authenticated;

-- ============================================================
-- 4. 기존 2027/main을 현재로 지정(마이그레이션 적용 직후 화면이 비지 않도록)
-- ============================================================

update public.admission_rounds
set is_current = true
where year = 2027 and round = 'main'
  and exists (select 1 from public.admission_rounds where year = 2027 and round = 'main');

-- ======================================================================
-- 00056_interview_call_queue.sql
-- ======================================================================

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

-- ======================================================================
-- 00057_interview_call_by_section.sql
-- ======================================================================

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

-- ======================================================================
-- 00058_interview_call_sms_exam_no.sql
-- ======================================================================

-- 면접 호출 문자에 수험번호(exam_no)를 쓰도록 수정 (2026-07-31)
--
-- 00056의 get_interview_call_sms_recipient는 applicants.receipt_no(접수번호,
-- 예: 260731V001)를 내려주고 Edge Function이 이를 "수험번호"라고 안내했다.
-- 그런데 대기실 프로젝터 화면은 evaluation_roster.exam_no(예: 2027-001)를
-- 띄운다. 지원자 입장에서 문자와 화면의 번호가 서로 달라 혼란스럽다.
--
-- 1차 서류사정 확정 시점에 exam_no가 부여되고 면접은 그 이후이므로, 면접
-- 호출에서는 항상 exam_no를 기준으로 통일한다. exam_no가 아직 없으면
-- 접수번호로 대체한다(방어적 처리).

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

  select a.name,
         a.receipt_no,
         r.exam_no,
         p.applicant_phone,
         p.guardian_name,
         p.guardian_phone
  into v_row
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.evaluation_roster r on r.applicant_id = a.id
  where a.id = p_applicant_id;

  if v_row is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'name', v_row.name,
    'receiptNo', v_row.receipt_no,
    -- 면접 단계에서는 수험번호가 기준이다(프로젝터 화면과 동일).
    'examNo', coalesce(v_row.exam_no, v_row.receipt_no),
    'applicantPhone', v_row.applicant_phone,
    'guardianName', v_row.guardian_name,
    'guardianPhone', v_row.guardian_phone
  );
end;
$$;

revoke all on function public.get_interview_call_sms_recipient(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_sms_recipient(int, admission_round, uuid) to authenticated;

-- ======================================================================
-- 00059_applicant_nationality_and_bonus.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 2027 확정 양식(서식 1 입학원서) 반영 (2026-09-04)
--
-- 배경: 2027학년도 전형 양식 최종본이 확정되어, 입학원서(서식 1)에 있는 항목
-- 중 시스템이 받지 못하던 것들을 채운다.
--
-- 1) 국적 / 영문 성명
--    양식에 "국적(ISO Alpha-3)"과 "성명(영문 · 여권상 표기)" 칸이 신설됐다.
--    외국 국적 지원자를 받을 수 있어야 하므로 컬럼을 추가한다.
--    ※ 주민등록번호는 의도적으로 저장하지 않는다(마스터스펙: 주민번호 원본
--      비저장 원칙, 성별·생년월일만 파생 저장). 양식에는 있으나 종이 원본으로만
--      보관하고 시스템에는 넣지 않는다.
--
-- 2) 가산점 입력 경로 — 실질적 버그 수정
--    applicants.bonus_eligible / bonus_reason 컬럼과, 이를 읽어 20% 가산을
--    적용하는 사정 엔진(00008)은 처음부터 있었는데, 정작 이 값을 입력할 RPC나
--    화면이 없었다. 그래서 모든 지원자가 영구히 '미확인'(null) 상태였고,
--    00008의 `app.bonus_eligible = true` 조건에 걸려 가산점이 실제로는
--    누구에게도 적용되지 않았다. 접수 RPC에서 입력받도록 뚫는다.
--
--    가산점은 인천학생추천전형 지원자에게만 적용된다(00008에서 'incheon'
--    tracks 조건으로 강제). 양식의 가산점 체크란도 인천학생추천전형 칸
--    아래에 배치되어 있어 서로 일치한다.
--
-- 3) 전형기간 중 유선 연락처
--    applicants_private.applicant_landline 컬럼은 있었으나 접수 RPC가 받지
--    않아 항상 비어 있었다. 양식에 칸이 있으므로 함께 뚫는다.

-- ============================================================
-- 1. 컬럼 추가
-- ============================================================

alter table public.applicants
  add column if not exists nationality text not null default 'KOR',
  add column if not exists name_english text;

comment on column public.applicants.nationality is
  'ISO 3166-1 Alpha-3 국가코드. 대한민국은 KOR(기본값).';
comment on column public.applicants.name_english is
  '여권상 영문 성명(성/이름 순). 외국 국적자 및 필요 시 기재.';

-- ============================================================
-- 2. register_applicant — 새 파라미터를 뒤에 덧붙인다
--    (기존 위치인자 호출을 깨지 않기 위해 반드시 맨 뒤에 추가)
--    인자 개수가 달라져 create or replace로는 교체되지 않고 중복 정의가
--    생기므로(호출 시 모호성 오류), 기존 시그니처를 명시적으로 제거한다.
-- ============================================================

drop function if exists public.register_applicant(
  int, admission_round, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text
);

create or replace function public.register_applicant(
  p_year int,
  p_round admission_round,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null,
  -- 2026-09-04 추가분
  p_nationality text default 'KOR',
  p_name_english text default null,
  p_applicant_landline text default null,
  p_bonus_eligible boolean default null,   -- null = 미확인 (null ≠ false)
  p_bonus_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_applicant_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds
    where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다. init_admission_round를 먼저 실행하세요.', p_year, p_round;
  end if;

  new_receipt_no := public._allocate_receipt_no(p_year, p_round, p_receipt_method);

  insert into public.applicants
    (year, round, receipt_no, name, name_english, nationality, tracks, academic_status,
     school, grade_class_no, semester_choice, receipt_method,
     bonus_eligible, bonus_reason, bonus_verified_at, bonus_verified_by,
     created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, trim(p_name), nullif(trim(coalesce(p_name_english,'')), ''),
     coalesce(nullif(trim(coalesce(p_nationality,'')), ''), 'KOR'),
     p_tracks, p_academic_status,
     p_school, p_grade_class_no, p_semester_choice, p_receipt_method,
     p_bonus_eligible, p_bonus_reason,
     case when p_bonus_eligible is not null then now() end,
     case when p_bonus_eligible is not null then caller::text end,
     caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, applicant_landline, email, address,
     guardian_name, guardian_relation, guardian_phone, guardian_address)
  values
    (new_applicant_id, p_gender, p_birth_date, p_applicant_phone, p_applicant_landline,
     p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_guardian_address);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, trim(p_name));

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_applicant(
  int, admission_round, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text, text, text, text, boolean, text
) from anon;

-- ============================================================
-- 3. update_applicant — 동일하게 확장
-- ============================================================

drop function if exists public.update_applicant(
  uuid, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text
);

create or replace function public.update_applicant(
  p_applicant_id uuid,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null,
  -- 2026-09-04 추가분
  p_nationality text default 'KOR',
  p_name_english text default null,
  p_applicant_landline text default null,
  p_bonus_eligible boolean default null,
  p_bonus_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  prev_bonus boolean;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  select bonus_eligible into prev_bonus from public.applicants where id = p_applicant_id;

  update public.applicants
  set name = trim(p_name),
      name_english = nullif(trim(coalesce(p_name_english,'')), ''),
      nationality = coalesce(nullif(trim(coalesce(p_nationality,'')), ''), 'KOR'),
      tracks = p_tracks,
      academic_status = p_academic_status,
      school = p_school,
      grade_class_no = p_grade_class_no,
      semester_choice = p_semester_choice,
      receipt_method = p_receipt_method,
      bonus_eligible = p_bonus_eligible,
      bonus_reason = p_bonus_reason,
      -- 확인 기록은 값이 실제로 바뀐 경우에만 새로 남긴다.
      bonus_verified_at = case
        when p_bonus_eligible is null then null
        when p_bonus_eligible is distinct from prev_bonus then now()
        else bonus_verified_at end,
      bonus_verified_by = case
        when p_bonus_eligible is null then null
        when p_bonus_eligible is distinct from prev_bonus then caller::text
        else bonus_verified_by end,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  update public.applicants_private
  set gender = p_gender,
      birth_date = p_birth_date,
      applicant_phone = p_applicant_phone,
      applicant_landline = p_applicant_landline,
      email = p_email,
      address = p_address,
      guardian_name = p_guardian_name,
      guardian_relation = p_guardian_relation,
      guardian_phone = p_guardian_phone,
      guardian_address = p_guardian_address,
      updated_at = now()
  where applicant_id = p_applicant_id;

  update public.evaluation_roster
  set display_name = trim(p_name),
      updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'applicant.updated', 'applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_applicant(
  uuid, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text, text, text, text, boolean, text
) from anon;

-- ======================================================================
-- 00060_applicant_photo_document.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 지원자 사진(증명사진) 문서 유형 추가 (2026-09-04)
--
-- 배경: 2027 전형 양식(서식 1 입학원서) 우측 상단에 여권용 3.5×4.5cm 사진을
-- 부착하게 되어 있다. 사진은 원서와 별도로 동봉해 받고, 접수 담당자가 스캔해
-- 시스템에 넣는다. 나중에 수험표 발급에 쓴다.
--
-- 공개 범위: 평가위원도 볼 수 있게 한다(2026-09-04 확인). 따라서 classification은
-- 'evaluation'으로 두고 access_areas에 전 영역을 넣어, 어느 영역을 배정받은
-- 평가위원이든 열람할 수 있게 한다. (업로드 화면의 기본값으로 처리하며,
-- 필요하면 담당자가 업로드 시 좁힐 수 있다)
--
-- ※ ALTER TYPE ... ADD VALUE는 트랜잭션 블록 안에서 쓸 수 없으므로 이 문장은
--   파일 맨 앞에 단독으로 둔다(psql이 문장 단위로 자동 커밋한다).

alter type document_type add value if not exists 'photo';

-- ======================================================================
-- 00061_storage_allow_photo_images.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 증명사진 업로드를 위한 스토리지 MIME 허용 (2026-09-16)
--
-- 00004에서 admission-documents 버킷을 만들 때 allowed_mime_types를
-- {application/pdf}로 못박았다. 당시에는 모든 제출서류가 PDF였기 때문이다.
--
-- 2026-09-04에 지원자 증명사진(서식 1 부착 사진의 스캔본)을 받게 되면서
-- JPG·PNG가 필요해졌는데, 버킷 제한이 그대로라 업로드가 스토리지 단계에서
-- 거부된다(메타데이터 등록 RPC까지 가지도 못한다). 허용 목록을 넓힌다.
--
-- 이미지만 추가하고 그 외 형식은 계속 막는다 — 실행 파일이나 임의 첨부가
-- 올라가는 경로가 되지 않도록 최소한으로만 연다.

update storage.buckets
set allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
where id = 'admission-documents';

-- 확인용 — 적용 후 이 결과가 3개 형식을 보여야 한다.
select id, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'admission-documents';

-- ======================================================================
-- 00062_student_record_single_upload.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 학생부를 영역별 발췌 대신 전체 1건으로 (2026-09-16)
--
-- 기존 설계(마스터스펙 735행): 학생부 전체 원본(studentRecordSource)은 항상
-- adminOnly로 두고, 평가위원에게는 출결·학업·공동체 영역별로 발췌한 파생자료
-- (studentRecordAttendanceView / AcademicView / CommunityView)만 제공한다.
-- 평가위원이 자기 영역과 무관한 정보까지 보지 않게 하려는 최소노출 원칙이었다.
--
-- 바꾸는 이유(2026-09-16 운영 판단): 지원자 1명마다 발췌본 3종을 사람이 만들어야
-- 해서, 지원자 수가 늘면 접수 담당자 혼자 감당할 수 없는 분량이 된다. 발췌본
-- 제작이 밀리면 오히려 채점 자체가 지연되어 전형 일정이 위태로워진다.
-- 그래서 학생부를 전체 1건으로 올리고, 출결·학업·공동체 채점자가 그 한 건을
-- 함께 열람하도록 바꾼다.
--
-- 이 변경으로 평가위원의 열람 범위가 넓어진다는 점은 분명히 인지하고 내린 결정이다.
-- 보완책:
--   · 열람은 여전히 log_document_view로 전건 기록된다(누가 언제 무엇을 열었는지).
--   · 자기소개서·학부모소견서 담당 위원에게는 학생부를 주지 않는다
--     (업로드 시 access_areas를 attendance/academic/community로 한정).
--   · 평가위원 보안서약·사전교육에서 학생부 열람 범위를 안내한다.
--
-- ※ 마스터스펙 735행("평가위원에게는 영역별 파생 평가자료만 제공한다")은 이
--   결정에 맞춰 갱신이 필요하다. 개인정보처리방침·내부결재 문서에는 발췌본
--   관련 문구가 없어 그대로 두어도 상충하지 않는다.
--
-- 기술적으로는 register_admission_document의 "studentRecordSource는 반드시
-- adminOnly" 강제 검사만 걷어낸다. 발췌 문서 유형은 enum에 그대로 남겨둔다
-- (이미 올라간 데이터가 있을 수 있고, 필요하면 언제든 다시 쓸 수 있다).

create or replace function public.register_admission_document(
  p_applicant_id uuid,
  p_document_type document_type,
  p_storage_path text,
  p_classification document_classification,
  p_access_areas evaluation_area[] default '{}',
  p_mime_type text default 'application/pdf',
  p_file_size int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
  new_id uuid;
begin
  -- 문서 등록은 접수 담당 이상 (섹션 6.6 reception 이상이 업로드 주체)
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  -- 2026-09-16: studentRecordSource의 adminOnly 강제 검사를 제거했다.
  -- (위 주석의 운영 판단 참고 — 학생부를 전체 1건으로 올려 정량평가 담당자가
  --  함께 열람한다. 대신 evaluation으로 올릴 때는 배정영역을 반드시 지정해야
  --  한다 — 영역 없이 올리면 아무도 못 보는 문서가 되어 사고로 이어진다.)
  if p_classification = 'evaluation'
     and coalesce(array_length(p_access_areas, 1), 0) = 0 then
    raise exception '평가용 문서는 배정영역을 1개 이상 지정해야 합니다.';
  end if;

  insert into public.admission_documents
    (applicant_id, year, round, document_type, storage_path, mime_type, file_size,
     classification, access_areas, uploaded_by)
  values
    (p_applicant_id, app.year, app.round, p_document_type, p_storage_path, p_mime_type,
     p_file_size, p_classification, p_access_areas, caller::text)
  returning id into new_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (app.year, app.round, 'user', caller::text, 'document.registered', 'admission_documents',
     new_id::text, p_applicant_id::text);

  return new_id;
end;
$$;

revoke all on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) from public, anon;
grant execute on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) to authenticated;

-- ======================================================================
-- 00063_deactivate_admission_document.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 잘못 올린 서류 내리기 (2026-09-16)
--
-- 배경: 접수 중 실수로 엉뚱한 파일을 올리거나 같은 서류를 중복으로 올리는 일이
-- 생기는데, 지금까지는 한 번 올린 서류를 내릴 방법이 없었다.
--
-- "삭제"가 아니라 "비활성화(active=false)"로 구현하는 이유:
--   admission_documents는 append-only 설계다(00004 — UPDATE/DELETE 정책 자체가
--   없어 클라이언트는 손댈 수 없다). 입시 서류는 "언제 무엇이 올라왔고 언제
--   내려갔는가"가 나중에 이의제기·감사에서 근거가 되므로, 행을 지워 흔적을
--   없애는 것보다 남겨두고 감춘 뒤 사유를 기록하는 편이 안전하다.
--
--   비활성화된 문서는 active=true 조건으로 걸러지는 모든 화면(평가위원 열람,
--   서류 목록, 수험표 사진 조회)에서 즉시 사라진다. 실제 파일도 storage RLS가
--   admission_documents의 active=true 행을 참조하므로 서명 URL이 더는 발급되지
--   않는다 — 링크를 알고 있어도 열 수 없다.
--
-- 스토리지의 파일 바이트 자체는 남는다(스토리지 DELETE 정책이 없다). 운영 종료
-- 후 일괄 정리는 담당자가 별도로 수행한다.

create or replace function public.deactivate_admission_document(
  p_document_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  doc record;
begin
  -- 올리는 주체와 같은 권한 범위(접수 담당 이상)
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 2 then
    raise exception '내리는 사유를 입력해야 합니다.';
  end if;

  select * into doc from public.admission_documents where id = p_document_id;
  if doc is null then
    raise exception '문서를 찾을 수 없습니다.';
  end if;
  if not doc.active then
    raise exception '이미 내려간 문서입니다.';
  end if;

  update public.admission_documents
  set active = false
  where id = p_document_id;

  -- audit_logs에는 reason_text 컬럼이 없다(reason_code + metadata 구조).
  -- 자유서술 사유는 metadata에 담는다.
  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id,
     applicant_id, reason_code, metadata)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.deactivated',
     'admission_documents', p_document_id::text, doc.applicant_id::text, '서류 내림',
     jsonb_build_object(
       'documentType', doc.document_type,
       'storagePath', doc.storage_path,
       'reason', trim(p_reason)));
end;
$$;

revoke all on function public.deactivate_admission_document(uuid, text) from public, anon;
grant execute on function public.deactivate_admission_document(uuid, text) to authenticated;

-- ======================================================================
-- 00064_admin_document_score_entry.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 서류평가 관리자 대리 채점 입력 (2026-09-28)
--
-- 배경: 심층역량평가(모둠·면접·글쓰기)에는 이미 관리자 대리 입력이 있다(00052/00053).
-- 서류평가 5개 영역(출결·학업성실도·공동체·자기소개서·학부모소견서)에는 없어서,
-- 평가위원이 로그인이 안 되거나 시스템 문제로 입력하지 못하면 대안이 없었다.
-- 첫 운영이라 그런 상황이 생길 수 있어 같은 안전장치를 만든다.
--
-- ┌─ 설계상 가장 중요한 결정 ────────────────────────────────────────┐
-- │ 00052(심층역량평가)는 채점 계산 로직을 admin_* 함수에 복사해 넣었다. │
-- │ 서류평가에서 같은 방식을 쓰면 계산 로직이 두 벌(총 490여 줄)이 되고,│
-- │ 나중에 배점을 고칠 때 한쪽만 고치면 "누가 입력했느냐에 따라 점수가  │
-- │ 달라지는" 버그가 생긴다. 채점에서 이건 치명적이다.                  │
-- │                                                                  │
-- │ 그래서 여기서는 복사하지 않는다. 관리자 함수는 권한·사유를 검증한 뒤 │
-- │ request.jwt.claims를 대상 평가위원으로 잠시(트랜잭션 한정) 바꾸고    │
-- │ 기존 submit_*_score를 그대로 호출한다. 계산·검증·설정 조회가 전부   │
-- │ 원래 경로 한 곳에서만 일어나므로 점수가 갈라질 수 없다.             │
-- │ (테스트 시드 스크립트가 쓰는 것과 같은 방식이다)                    │
-- └──────────────────────────────────────────────────────────────────┘
--
-- 감사 기록: 안쪽 submit_*는 평가위원 명의로 기록을 남기고(원래 동작 그대로),
-- 바깥 관리자 함수가 "관리자가 누구를 대신해 왜 입력했는지"를 따로 한 줄 더 남긴다.
-- 두 줄이 같이 남아야 나중에 "이 점수를 실제로 누가 넣었나"를 설명할 수 있다.

-- ============================================================
-- 0. 영역별로 필요한 역할이 다르다
--    출결·학업은 quant, 나머지는 evaluator.
-- ============================================================

create or replace function public._score_area_required_role(p_area evaluation_area)
returns app_role
language sql
immutable
as $$
  select case
    when p_area in ('attendance', 'academic') then 'quant'::app_role
    else 'evaluator'::app_role
  end;
$$;

-- 기존 목록 함수는 'evaluator'만 보고 있어 출결·학업 담당(quant)이 하나도
-- 나오지 않았다. 영역에 맞는 역할을 보도록 고친다.
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
  v_role app_role;
  v_result jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  v_role := public._score_area_required_role(p_area);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email
  ) order by display_name), '[]'::jsonb)
  into v_result
  from public.users
  where active = true
    and v_role = any(roles)
    and p_area = any(assigned_areas);

  return v_result;
end;
$$;

revoke all on function public.admin_list_score_entry_evaluators(evaluation_area) from public, anon;
grant execute on function public.admin_list_score_entry_evaluators(evaluation_area) to authenticated;

-- ============================================================
-- 1. 대리 입력 공통 검증 — 관리자 권한·사유·대상 평가위원 자격
-- ============================================================

create or replace function public._admin_score_proxy_check(
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_role app_role;
  valid_reasons text[] := array['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code using errcode = '22023';
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 사유 내용을 반드시 입력해야 합니다.' using errcode = '23514';
  end if;

  v_role := public._score_area_required_role(p_area);

  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid
      and u.active = true
      and v_role = any(u.roles)
      and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역(%) 담당으로 등록되어 있지 않습니다.', p_area
      using errcode = '42501';
  end if;

  return caller;
end;
$$;

revoke execute on function public._admin_score_proxy_check(evaluation_area, uuid, text, text) from anon, authenticated;

-- ============================================================
-- 2. 대리 입력 사실 기록 (관리자 명의)
-- ============================================================

create or replace function public._admin_score_proxy_log(
  p_admin_uid uuid,
  p_applicant_id uuid,
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app record;
begin
  select year, round into v_app from public.applicants where id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id,
     applicant_id, area, reason_code, metadata)
  values
    (v_app.year, v_app.round, 'user', p_admin_uid::text,
     'score.' || p_area::text || '.submitted_on_behalf',
     'scores_' || p_area::text, p_applicant_id::text, p_applicant_id::text, p_area,
     p_reason_code,
     jsonb_build_object(
       'targetEvaluatorUid', p_target_evaluator_uid,
       'reasonText', p_reason_text));
end;
$$;

revoke execute on function public._admin_score_proxy_log(uuid, uuid, evaluation_area, uuid, text, text) from anon, authenticated;

-- ============================================================
-- 3. 영역별 대리 제출 — 전부 원래 submit_*_score를 그대로 호출한다
--    (계산 로직 복사 없음. 상단 주석 참고)
-- ============================================================

create or replace function public.admin_submit_attendance_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_unexcused_absences int,
  p_tardy_early_result_count int,
  p_no_record boolean,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('attendance', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_attendance_score(
    p_applicant_id, p_unexcused_absences, p_tardy_early_result_count, coalesce(p_no_record, false));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'attendance', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_attendance_score(uuid, uuid, int, int, boolean, text, text) from public, anon;
grant execute on function public.admin_submit_attendance_score(uuid, uuid, int, int, boolean, text, text) to authenticated;

create or replace function public.admin_submit_academic_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_input_type text,
  p_subjects jsonb,
  p_no_document boolean,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('academic', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_academic_score(
    p_applicant_id, p_input_type, coalesce(p_subjects, '[]'::jsonb), coalesce(p_no_document, false));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'academic', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_academic_score(uuid, uuid, text, jsonb, boolean, text, text) from public, anon;
grant execute on function public.admin_submit_academic_score(uuid, uuid, text, jsonb, boolean, text, text) to authenticated;

create or replace function public.admin_submit_community_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_grade int,
  p_evidence_memo text,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('community', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_community_score(p_applicant_id, p_grade, p_evidence_memo);

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'community', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_community_score(uuid, uuid, int, text, text, text) from public, anon;
grant execute on function public.admin_submit_community_score(uuid, uuid, int, text, text, text) to authenticated;

create or replace function public.admin_submit_essay_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_items jsonb,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('essay', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_essay_score(p_applicant_id, p_items);

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'essay', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_essay_score(uuid, uuid, jsonb, text, text) from public, anon;
grant execute on function public.admin_submit_essay_score(uuid, uuid, jsonb, text, text) to authenticated;

create or replace function public.admin_submit_opinion_score(
  p_applicant_id uuid,
  p_target_evaluator_uid uuid,
  p_items jsonb,
  p_deduction_flags jsonb,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_saved text;
  v_result json;
begin
  v_admin := public._admin_score_proxy_check('opinion', p_target_evaluator_uid, p_reason_code, p_reason_text);

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_target_evaluator_uid::text, 'role', 'authenticated')::text, true);

  v_result := public.submit_opinion_score(
    p_applicant_id, p_items, coalesce(p_deduction_flags, '{}'::jsonb));

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  perform public._admin_score_proxy_log(
    v_admin, p_applicant_id, 'opinion', p_target_evaluator_uid, p_reason_code, p_reason_text);

  return v_result;
end;
$$;

revoke all on function public.admin_submit_opinion_score(uuid, uuid, jsonb, jsonb, text, text) from public, anon;
grant execute on function public.admin_submit_opinion_score(uuid, uuid, jsonb, jsonb, text, text) to authenticated;

-- ============================================================
-- 4. 대리 입력 화면용 조회 — 대상 평가위원이 이 영역에서 어디까지 했는지
-- ============================================================

create or replace function public.admin_get_document_score_entry_context(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_target_evaluator_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_role app_role;
  v_table text;
  v_items jsonb;
  v_area_open boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '이 화면은 서류평가 5개 영역만 지원합니다 (입력값: %).', p_area
      using errcode = '22023';
  end if;

  v_role := public._score_area_required_role(p_area);
  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and v_role = any(u.roles) and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역 담당으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  select (stage_status = 'open' and p_area = any(open_evaluation_areas))
  into v_area_open
  from public.admission_rounds
  where year = p_year and round = p_round;

  -- 영역마다 점수 테이블이 다르다. 위에서 영역을 5개로 좁혀 검증했으므로
  -- 테이블명 조립은 안전하다(사용자 입력이 그대로 들어가지 않는다).
  v_table := 'scores_' || p_area::text;

  -- 값은 문자열로 끼워 넣지 않고 USING으로 넘긴다(따옴표·형변환 사고 방지).
  -- 테이블명만 %I로 조립하며, 위에서 영역을 5개로 좁혀 검증했으므로 안전하다.
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', r.applicant_id,
      'examNo', r.exam_no,
      'displayName', r.display_name,
      'receiptNo', r.receipt_no,
      'submissionState', s.submission_state,
      'serverComputed', s.server_computed,
      'submittedAt', s.submitted_at
    ) order by r.receipt_no), '[]'::jsonb)
    from public.evaluation_roster r
    left join public.%I s
      on s.applicant_id = r.applicant_id and s.evaluator_uid = $1
    where r.year = $2 and r.round = $3 and r.evaluation_active = true
  $q$, v_table)
  into v_items
  using p_target_evaluator_uid, p_year, p_round;

  return jsonb_build_object(
    'area', p_area,
    'areaOpen', coalesce(v_area_open, false),
    'targetEvaluatorUid', p_target_evaluator_uid,
    'items', v_items
  );
end;
$$;

revoke all on function public.admin_get_document_score_entry_context(int, admission_round, evaluation_area, uuid) from public, anon;
grant execute on function public.admin_get_document_score_entry_context(int, admission_round, evaluation_area, uuid) to authenticated;

-- ======================================================================
-- 00065_evaluation_staffing.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 평가 준비(전형위원 배정 현황) (2026-09-28)
--
-- 배경: 담당 영역 배정은 예전부터 "사용자(선생님) 권한 관리"에서 할 수 있었다.
-- 다만 그 화면은 사람 단위라 "자기소개서 평가위원이 지금 몇 명인가"를 볼 수 없다.
--
-- 이게 실제 사고로 이어진다. 서류평가는 영역마다 제출해야 할 평가위원 수가
-- 설정(scoring_params.<area>.requiredSubmissions)으로 정해져 있고,
-- _compute_document_aggregate가 그 인원수를 정확히 채운 지원자만 "완료"로 본다.
-- 인원이 모자라면 1차 사정 확정이 아예 되지 않는데, 지금 구조로는 그 사실을
-- 사정 단계에 가서야 알게 된다. 준비 단계에서 미리 보이게 하는 것이 목적이다.
--
-- 데이터는 새로 만들지 않는다. users.assigned_areas 하나를 사람 중심(권한 관리)과
-- 영역 중심(이 화면)으로 다르게 보여줄 뿐이라, 두 화면이 서로 어긋날 수 없다.
--
-- 심층역량평가(모둠·면접·글쓰기)는 성격이 다르다. 여기서는 "이 영역에 참여할
-- 위원"만 정하고, 실제 몇 명이 필요한지는 조 편성(전형 준비)에서 결정된다.
-- 그래서 필요 인원을 숫자로 못 박지 않고 배정된 인원만 보여준다.

-- ============================================================
-- 1. 영역별 배정 현황 조회
-- ============================================================

create or replace function public.get_evaluation_staffing(
  p_year int,
  p_round admission_round,
  p_stage text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_areas evaluation_area[];
  v_rev_id uuid;
  v_params jsonb;
  v_result jsonb;
  v_available jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_stage = 'document' then
    v_areas := array['attendance','academic','community','essay','opinion']::evaluation_area[];
  elsif p_stage = 'deep' then
    v_areas := array['group','interview','writing']::evaluation_area[];
  else
    raise exception '알 수 없는 평가 단계입니다: % (document 또는 deep)', p_stage
      using errcode = '22023';
  end if;

  select config_revision_id into v_rev_id
  from public.admission_rounds where year = p_year and round = p_round;
  if v_rev_id is not null then
    select scoring_params into v_params from public.config_revisions where id = v_rev_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'area', a.area,
    -- 필요 인원은 서류평가에만 의미가 있다(위 주석 참고). 심층역량평가는 null.
    'requiredCount', case
      when p_stage = 'document'
        then (v_params -> a.area::text ->> 'requiredSubmissions')::int
      else null
    end,
    'requiredRole', public._score_area_required_role(a.area)::text,
    'assigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id, 'displayName', u.display_name, 'email', u.email,
        'roles', u.roles
      ) order by u.display_name)
      from public.users u
      where u.active = true and a.area = any(u.assigned_areas)
    ), '[]'::jsonb)
  ) order by ord), '[]'::jsonb)
  into v_result
  from unnest(v_areas) with ordinality as a(area, ord);

  -- 배정 후보: 활성 계정 중 평가 역할을 가진 사람 전원.
  -- (영역마다 필요한 역할이 달라 화면에서 다시 거른다)
  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email,
    'roles', roles, 'assignedAreas', assigned_areas
  ) order by display_name), '[]'::jsonb)
  into v_available
  from public.users
  where active = true
    and roles && array['evaluator','quant']::app_role[];

  return jsonb_build_object(
    'stage', p_stage,
    'year', p_year,
    'round', p_round,
    'areas', v_result,
    'availableUsers', v_available
  );
end;
$$;

revoke all on function public.get_evaluation_staffing(int, admission_round, text) from public, anon;
grant execute on function public.get_evaluation_staffing(int, admission_round, text) to authenticated;

-- ============================================================
-- 2. 영역 배정 / 해제
--    권한은 기존 담당영역 변경 경로(upsert_user_access)와 동일하게
--    superadmin으로 맞춘다 — 누가 어떤 지원자를 채점하는지가 바뀌는 일이라
--    admin까지 열지 않는다. 화면에서는 admin에게 조회만 허용한다.
-- ============================================================

create or replace function public.set_user_area_assignment(
  p_target_uid uuid,
  p_area evaluation_area,
  p_assigned boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_user record;
  v_required app_role;
  v_next evaluation_area[];
begin
  caller := public._require_superadmin();

  select * into v_user from public.users where id = p_target_uid;
  if v_user is null then
    raise exception '대상 사용자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not v_user.active then
    raise exception '비활성 계정에는 영역을 배정할 수 없습니다.' using errcode = '55000';
  end if;

  v_required := public._score_area_required_role(p_area);

  if p_assigned then
    -- 역할이 없으면 배정해도 실제 채점을 할 수 없다. 조용히 넘어가면
    -- "배정은 했는데 화면이 안 보인다"는 문제가 되므로 여기서 막는다.
    if not (v_required = any(v_user.roles)) then
      raise exception '% 영역은 % 역할이 필요합니다. 사용자 권한 관리에서 역할을 먼저 부여하세요.',
        p_area, v_required using errcode = '42501';
    end if;
    if p_area = any(v_user.assigned_areas) then
      return jsonb_build_object('changed', false, 'assignedAreas', v_user.assigned_areas);
    end if;
    v_next := array_append(v_user.assigned_areas, p_area);
  else
    if not (p_area = any(v_user.assigned_areas)) then
      return jsonb_build_object('changed', false, 'assignedAreas', v_user.assigned_areas);
    end if;
    v_next := array_remove(v_user.assigned_areas, p_area);
  end if;

  update public.users
  set assigned_areas = v_next,
      updated_at = now(),
      updated_by = caller::text
  where id = p_target_uid;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    ('user', caller::text,
     case when p_assigned then 'user.area.assigned' else 'user.area.unassigned' end,
     'users', p_target_uid::text, p_area,
     jsonb_build_object('assignedAreas', v_next));

  return jsonb_build_object('changed', true, 'assignedAreas', v_next);
end;
$$;

revoke all on function public.set_user_area_assignment(uuid, evaluation_area, boolean) from public, anon;
grant execute on function public.set_user_area_assignment(uuid, evaluation_area, boolean) to authenticated;

-- ======================================================================
-- 00066_evaluation_area_staffing.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 영역별 "배정 인원"을 "제출 필요 건수"와 분리 (2026-09-28)
--
-- 배경: 평가 준비 화면(00065)은 필요 인원을 scoring_params.<area>.requiredSubmissions
-- 에서 읽었다. 그런데 그 값은 이미 다른 뜻으로 쓰이고 있다.
--
--   · 평가 진행 현황(00007): 이 값만큼 "제출"돼야 완료로 본다.
--   · 1차 사정 완료 판정(00008): 설정을 읽지 않고 SQL에 박혀 있다
--     (공동체 2건·자기소개서 5건·학부모소견서 4건, 출결·학업은 1건이면 통과).
--
-- 그래서 출결·학업의 requiredSubmissions를 2로 올리면, 실제로는 한 사람이
-- 입력하므로 진행 현황이 영원히 미완료로 남고 대시보드의 "미완료 평가"가
-- 0이 되지 않는다. 반면 사정은 그대로 통과해 화면과 사정이 엇갈린다.
--
-- 실제로 필요한 것은 두 가지가 다르다는 사실을 인정하는 것이다.
--   · 배정 인원: 내부 규정상 몇 명이 그 영역을 맡아야 하는가 (출결·학업도 2명)
--   · 제출 필요 건수: 채점이 완료되려면 몇 건이 들어와야 하는가 (출결·학업은 1건)
--
-- 이 마이그레이션은 "배정 인원"만 담는 표를 따로 만든다. requiredSubmissions는
-- 손대지 않으므로 진행 현황·사정 동작은 그대로다.
--
-- config_revisions에 넣지 않은 이유: config revision은 잠기면 수정 불가라
-- 값 하나 바꾸려고 새 revision을 만들어 회차에 다시 연결해야 하는데, 그러면
-- 심층역량평가 계획이 CONFIG_SOURCE_STALE로 무효화된다. 배정 인원은 배점이
-- 아니라 운영 규정에 가까워 별도 표가 더 알맞다.

create table if not exists public.evaluation_area_staffing (
  year int not null,
  round admission_round not null,
  area evaluation_area not null,
  required_evaluators int not null check (required_evaluators >= 0),
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (year, round, area)
);

comment on table public.evaluation_area_staffing is
  '영역별로 배정해야 할 전형위원 수(내부 규정). 채점 완료 판정에 쓰이는 scoring_params.requiredSubmissions와는 다른 값이다.';

alter table public.evaluation_area_staffing enable row level security;
revoke all on public.evaluation_area_staffing from anon, authenticated;

-- 이미 만들어진 모든 회차에 기본값을 넣는다.
-- 출결·학업은 실제 입력은 1명이 하더라도 규정상 2명을 배정한다(2026-09-28 확인).
insert into public.evaluation_area_staffing (year, round, area, required_evaluators, updated_by)
select r.year, r.round, d.area, d.cnt, 'migration-00066'
from public.admission_rounds r
cross join (values
  ('attendance'::evaluation_area, 2),
  ('academic'::evaluation_area, 2),
  ('community'::evaluation_area, 2),
  ('essay'::evaluation_area, 5),
  ('opinion'::evaluation_area, 4)
) as d(area, cnt)
on conflict (year, round, area) do nothing;

-- ============================================================
-- 배정 인원 변경 (superadmin)
-- ============================================================

create or replace function public.set_evaluation_area_staffing(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_required_evaluators int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_superadmin();

  if p_required_evaluators is null or p_required_evaluators < 0 or p_required_evaluators > 50 then
    raise exception '배정 인원은 0~50 사이여야 합니다.' using errcode = '23514';
  end if;

  insert into public.evaluation_area_staffing
    (year, round, area, required_evaluators, updated_by)
  values
    (p_year, p_round, p_area, p_required_evaluators, caller::text)
  on conflict (year, round, area) do update set
    required_evaluators = excluded.required_evaluators,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'staffing.required_evaluators_changed',
     'evaluation_area_staffing', p_area::text, p_area,
     jsonb_build_object('requiredEvaluators', p_required_evaluators));
end;
$$;

revoke all on function public.set_evaluation_area_staffing(int, admission_round, evaluation_area, int) from public, anon;
grant execute on function public.set_evaluation_area_staffing(int, admission_round, evaluation_area, int) to authenticated;

-- ============================================================
-- 조회 함수 갱신 — 배정 인원은 새 표에서, 없으면 기존 동작(설정값)으로 대체
-- ============================================================

create or replace function public.get_evaluation_staffing(
  p_year int,
  p_round admission_round,
  p_stage text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_areas evaluation_area[];
  v_rev_id uuid;
  v_params jsonb;
  v_result jsonb;
  v_available jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_stage = 'document' then
    v_areas := array['attendance','academic','community','essay','opinion']::evaluation_area[];
  elsif p_stage = 'deep' then
    v_areas := array['group','interview','writing']::evaluation_area[];
  else
    raise exception '알 수 없는 평가 단계입니다: % (document 또는 deep)', p_stage
      using errcode = '22023';
  end if;

  select config_revision_id into v_rev_id
  from public.admission_rounds where year = p_year and round = p_round;
  if v_rev_id is not null then
    select scoring_params into v_params from public.config_revisions where id = v_rev_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'area', a.area,
    -- 배정해야 할 인원(운영 규정). 표에 값이 없으면 예전처럼 설정값을 쓴다.
    'requiredCount', coalesce(
      (select s.required_evaluators from public.evaluation_area_staffing s
        where s.year = p_year and s.round = p_round and s.area = a.area),
      (v_params -> a.area::text ->> 'requiredSubmissions')::int
    ),
    -- 채점 완료로 보기 위해 실제로 들어와야 하는 제출 건수(참고 표시용).
    -- 배정 인원과 다를 수 있다(예: 출결은 2명 배정, 1건 제출이면 완료).
    'requiredSubmissions', (v_params -> a.area::text ->> 'requiredSubmissions')::int,
    'requiredRole', public._score_area_required_role(a.area)::text,
    'assigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id, 'displayName', u.display_name, 'email', u.email,
        'roles', u.roles
      ) order by u.display_name)
      from public.users u
      where u.active = true and a.area = any(u.assigned_areas)
    ), '[]'::jsonb)
  ) order by ord), '[]'::jsonb)
  into v_result
  from unnest(v_areas) with ordinality as a(area, ord);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email,
    'roles', roles, 'assignedAreas', assigned_areas
  ) order by display_name), '[]'::jsonb)
  into v_available
  from public.users
  where active = true
    and roles && array['evaluator','quant']::app_role[];

  return jsonb_build_object(
    'stage', p_stage,
    'year', p_year,
    'round', p_round,
    'areas', v_result,
    'availableUsers', v_available
  );
end;
$$;

revoke all on function public.get_evaluation_staffing(int, admission_round, text) from public, anon;
grant execute on function public.get_evaluation_staffing(int, admission_round, text) to authenticated;

-- ======================================================================
-- 00067_receipt_and_exam_numbers_per_guideline.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 접수번호·수험번호를 원서 접수 지침에 맞춤 (2026-09-28)
--
-- 근거: 「2026학년도 신입생 입학전형 원서 접수 업무 진행 지침(수정 2025.10.21.)」
--   3. 기본 방침
--     · (접수번호 부여) 전형별로 접수일자 및 일자별 접수 순서순으로 부여
--     · (수험번호 부여) 접수 마감 후 지원 전형에 상관없이 지원자 성명 가나다 순으로 부여
--   4-(2) 번호 형식
--     · 접수번호: YYMMDD + 전형코드(G 일반 / I 일반+인천학생추천 / U 일반+사회통합) + XXX
--                 (접수일마다 전형별로 001부터 다시 셈)
--     · 수험번호: A + 회차(1 신입생 입학전형 / 2 1차 추가모집 / 3 2차 추가모집) + XXX
--                 (수험번호로 지원 전형·성별 등을 특정할 수 없어야 함)
--     · 원서 접수 마감 이후 3일 이내 개인별 연락처로 수험번호 안내
--
-- 지금까지의 구현이 지침과 달랐던 점:
--   · 접수번호: 초기 개발 때 G·U를 "접수방법(등기·방문)"으로 잘못 읽었고, 핫픽스
--     002에서 아예 M(우편)·V(방문)로 바꿨다. 지침의 G/I/U는 "전형" 코드다.
--   · 수험번호: 00008은 1차 합격자에게 "2027-001" 형식으로 부여했다. 지침은
--     접수 마감 후 전원에게, 가나다순으로, A+회차+순번 형식으로 부여한다.
--
-- 바뀌는 것:
--   1. register_applicant — 접수번호 가운데 글자를 전형코드(G/I/U)로
--   2. assign_exam_numbers — 접수 마감 후 관리자가 한 번 실행하는 수험번호 일괄 부여
--   3. run_document_decision — 1차 사정에서 수험번호를 더 이상 매기지 않음
--
-- 이미 만들어진 지원자의 접수번호는 바꾸지 않는다(접수증이 이미 나갔을 수 있다).
-- 현재 저장소에는 테스트 데이터뿐이므로, 새 형식은 이후 접수분부터 적용된다.

-- ============================================================
-- 0. 이전 시도 정리 (접수 즉시 수험번호를 주던 초안이 적용된 경우 대비)
-- ============================================================

drop function if exists public._allocate_exam_no(int, admission_round);
drop table if exists public.exam_no_counters;

-- 지침 형식(A+회차+3자리)이 아닌 수험번호는 비운다. 단, 1차 사정이 이미 확정된
-- 회차는 건드리지 않는다(그 번호로 이미 안내·평가가 진행됐을 수 있다).
update public.evaluation_roster er
set exam_no = null, updated_at = now()
where er.exam_no is not null
  and er.exam_no !~ '^A[123][0-9]{3}$'
  and not exists (
    select 1 from public.admission_rounds r
    where r.year = er.year and r.round = er.round and r.document_decision_run_id is not null
  );

update public.applicants a
set exam_no = null, updated_at = now()
where a.exam_no is not null
  and a.exam_no !~ '^A[123][0-9]{3}$'
  and not exists (
    select 1 from public.admission_rounds r
    where r.year = a.year and r.round = a.round and r.document_decision_run_id is not null
  );

-- ============================================================
-- 1. 접수번호 카운터가 전형코드(G/I/U)를 받을 수 있게
--    (기존 M/V 행이 남아 있을 수 있어 함께 허용한다)
-- ============================================================

do $$
declare
  cname text;
begin
  select conname into cname
  from pg_constraint
  where conrelid = 'public.receipt_counters'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%method%';
  if cname is not null then
    execute format('alter table public.receipt_counters drop constraint %I', cname);
  end if;
  alter table public.receipt_counters
    add constraint receipt_counters_method_check check (method in ('G', 'I', 'U', 'M', 'V'));
end $$;

-- ============================================================
-- 2. register_applicant — 접수번호 전형코드 반영
--    (00059 버전에서 접수번호 채번 부분만 바꿨다. 수험번호는 여기서 주지 않는다)
-- ============================================================

create or replace function public.register_applicant(
  p_year int,
  p_round admission_round,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
  p_school text default null,
  p_grade_class_no text default null,
  p_semester_choice text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_guardian_address text default null,
  -- 2026-09-04 추가분
  p_nationality text default 'KOR',
  p_name_english text default null,
  p_applicant_landline text default null,
  p_bonus_eligible boolean default null,   -- null = 미확인 (null ≠ false)
  p_bonus_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_applicant_id uuid;
  v_track_code text;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  if not exists (
    select 1 from public.admission_rounds
    where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다. init_admission_round를 먼저 실행하세요.', p_year, p_round;
  end if;

  -- 접수번호 = YYMMDD + 전형코드 + 순번 (원서 접수 지침 4-(2)).
  --   G: 일반 / I: 일반+인천학생추천 / U: 일반+사회통합
  -- 순번은 접수일자별·전형별로 001부터 다시 센다. 접수방법(우편/방문)은
  -- 번호에 넣지 않고 receipt_method 컬럼에만 기록한다.
  v_track_code := case
    when 'incheon' = any(p_tracks) then 'I'
    when 'social'  = any(p_tracks) then 'U'
    else 'G'
  end;
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, v_track_code);

  insert into public.applicants
    (year, round, receipt_no, name, name_english, nationality, tracks, academic_status,
     school, grade_class_no, semester_choice, receipt_method,
     bonus_eligible, bonus_reason, bonus_verified_at, bonus_verified_by,
     created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, trim(p_name), nullif(trim(coalesce(p_name_english,'')), ''),
     coalesce(nullif(trim(coalesce(p_nationality,'')), ''), 'KOR'),
     p_tracks, p_academic_status,
     p_school, p_grade_class_no, p_semester_choice, p_receipt_method,
     p_bonus_eligible, p_bonus_reason,
     case when p_bonus_eligible is not null then now() end,
     case when p_bonus_eligible is not null then caller::text end,
     caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, applicant_landline, email, address,
     guardian_name, guardian_relation, guardian_phone, guardian_address)
  values
    (new_applicant_id, p_gender, p_birth_date, p_applicant_phone, p_applicant_landline,
     p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_guardian_address);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, trim(p_name));

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_applicant(
  int, admission_round, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text, text, text, text, boolean, text
) from anon;


-- ============================================================
-- 3. 수험번호 일괄 부여 (접수 마감 후 1회)
-- ============================================================

create or replace function public.assign_exam_numbers(
  p_year int,
  p_round admission_round,
  p_reassign boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round_digit text;
  v_decision uuid;
  v_already int;
  v_seq int := 0;
  v_first text;
  v_last text;
  v_no text;
  app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  -- 회차 코드: 신입생 입학전형(1) / 1차 추가모집(2) / 2차 추가모집(3)
  v_round_digit := case p_round
    when 'main' then '1'
    when 'extra1' then '2'
    when 'extra2' then '3'
  end;

  select document_decision_run_id into v_decision
  from public.admission_rounds where year = p_year and round = p_round;
  if not found then
    raise exception '전형 회차(%, %)가 없습니다.', p_year, p_round using errcode = 'P0002';
  end if;

  select count(*) into v_already
  from public.applicants
  where year = p_year and round = p_round and exam_no is not null;

  if v_already > 0 and not p_reassign then
    raise exception '이미 수험번호가 부여된 지원자가 %명 있습니다. 다시 매기려면 재부여를 선택하세요.', v_already
      using errcode = '55000';
  end if;

  -- 1차 사정이 확정된 뒤에는 번호를 바꾸지 못하게 막는다
  -- (평가·안내가 이미 그 번호로 진행됐다).
  if p_reassign and v_decision is not null then
    raise exception '1차 사정이 확정된 회차는 수험번호를 다시 매길 수 없습니다.' using errcode = '55000';
  end if;

  -- 재부여: 먼저 전부 비운다(철회·제외된 지원자의 옛 번호도 함께 정리).
  update public.applicants set exam_no = null, updated_at = now()
    where year = p_year and round = p_round;
  update public.evaluation_roster set exam_no = null, updated_at = now()
    where year = p_year and round = p_round;

  -- 지원 전형에 상관없이 성명 가나다순. 한글 완성형 음절은 유니코드 순서가
  -- 가나다순과 같으므로 collate "C"로 서버 로캘과 무관하게 정렬한다.
  -- 동명이인은 접수번호 순으로 정한다. 철회·제외된 지원자는 번호를 받지 않는다.
  for app in
    select a.id
    from public.applicants a
    where a.year = p_year and a.round = p_round
      and a.application_status not in ('withdrawn', 'excluded')
    order by a.name collate "C", a.receipt_no collate "C"
  loop
    v_seq := v_seq + 1;
    if v_seq > 999 then
      raise exception '수험번호는 회차당 999명까지 부여할 수 있습니다.' using errcode = '22003';
    end if;
    v_no := 'A' || v_round_digit || lpad(v_seq::text, 3, '0');
    if v_first is null then v_first := v_no; end if;
    v_last := v_no;

    update public.applicants set exam_no = v_no, updated_at = now(), updated_by = caller::text
      where id = app.id;
    update public.evaluation_roster set exam_no = v_no, updated_at = now()
      where applicant_id = app.id;
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when p_reassign then 'exam_no.reassigned' else 'exam_no.assigned' end,
     'admission_rounds', p_year::text || '_' || p_round::text,
     jsonb_build_object('count', v_seq, 'first', v_first, 'last', v_last));

  return jsonb_build_object('assigned', v_seq, 'first', v_first, 'last', v_last);
end;
$$;

revoke all on function public.assign_exam_numbers(int, admission_round, boolean) from public, anon;
grant execute on function public.assign_exam_numbers(int, admission_round, boolean) to authenticated;

-- ============================================================
-- 4. run_document_decision — 수험번호 채번 제거
--    (00008 원문에서 채번 블록만 기계적으로 교체. 나머지는 그대로다)
-- ============================================================

create or replace function public.run_document_decision(
  p_year int,
  p_round admission_round,
  p_mode decision_mode
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  quota jsonb;
  pass_limit int;
  v_run_id uuid;
  blocking_count int;
  applicant_row record;
  agg jsonb;
  boundary_rank int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  next_exam_seq int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(p_year, p_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'quota' into quota from public.config_revisions where id = rev_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다. setup 스크립트를 먼저 실행하세요.';
  end if;
  pass_limit := floor((quota ->> 'total')::numeric * (quota ->> 'screeningMultiple')::numeric);

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'document', p_mode, 'running', rev_id, caller::text)
  returning id into v_run_id;

  -- 후보군: 접수완료 + 사정제외 아님 (섹션 5.3.1 — evaluationStage 게이트는
  -- 아직 별도 전환 단계를 만들지 않아 이번 구현에서는 생략, 검토메모 기록)
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    document_final numeric,
    community numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  for applicant_row in
    select a.id from public.applicants a
    left join public.applicants_admin aa on aa.applicant_id = a.id
    where a.year = p_year and a.round = p_round and a.application_status = 'complete'
      and coalesce(aa.exclusion_status, 'none') <> 'excluded'
  loop
    agg := public._compute_document_aggregate(applicant_row.id);
    if (agg ->> 'complete')::boolean then
      insert into tmp_candidates values (
        applicant_row.id,
        (agg ->> 'finalTotal')::numeric,
        (agg ->> 'community')::numeric,
        (agg ->> 'essay')::numeric,
        (agg ->> 'attendance')::numeric,
        (agg ->> 'academic')::numeric
      );
      v_candidate_count := v_candidate_count + 1;
    end if;
  end loop;

  -- 순위 산정 (섹션 5.3.3 정렬 기준 그대로) + 동점 경계 판정
  create temp table tmp_ranked on commit drop as
  select *,
    rank() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rn
  from tmp_candidates;

  select rnk into boundary_rank from tmp_ranked where rn = pass_limit;

  -- decision_results 기록
  for applicant_row in select * from tmp_ranked loop
    declare
      this_outcome decision_outcome;
    begin
      if boundary_rank is not null and applicant_row.rnk = boundary_rank
         and (select count(*) from tmp_ranked where rnk = boundary_rank and rn > pass_limit) > 0 then
        this_outcome := 'manualDecisionRequired';
        unresolved_count := unresolved_count + 1;
      elsif applicant_row.rnk <= coalesce(boundary_rank, pass_limit) then
        this_outcome := 'passed';
      else
        this_outcome := 'failed';
      end if;

      insert into public.decision_results
        (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values, outcome)
      values
        (v_run_id, applicant_row.applicant_id, p_year, p_round, 'document', applicant_row.document_final,
         applicant_row.rnk,
         jsonb_build_object(
           'community', applicant_row.community, 'essay', applicant_row.essay,
           'attendance', applicant_row.attendance, 'academic', applicant_row.academic
         ),
         this_outcome);
      v_result_count := v_result_count + 1;
    end;
  end loop;

  update public.decision_runs
  set candidate_count = v_candidate_count, result_count = v_result_count,
      unresolved_tie_count = unresolved_count, blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 실제 반영 ──────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;

    -- 2026-09-28: 수험번호는 원서 접수 지침에 따라 접수 마감 후 일괄 부여한다
    -- (assign_exam_numbers, 00067). 1차 사정에서는 더 이상 수험번호를 매기지 않고
    -- 합격 단계만 표시한다. 여기서 다시 매기면 이미 안내한 번호와 어긋난다.
    for applicant_row in
      select dr.applicant_id from public.decision_results dr
      where dr.run_id = v_run_id and dr.outcome = 'passed'
      order by dr.rank
    loop
      update public.applicants set evaluation_stage = 'documentPassed', updated_at = now(), updated_by = caller::text
        where id = applicant_row.applicant_id;
      update public.evaluation_roster
        set evaluation_stage = 'documentPassed', updated_at = now()
        where applicant_id = applicant_row.applicant_id;
    end loop;

    update public.applicants set evaluation_stage = 'documentFailed', updated_at = now(), updated_by = caller::text
      where id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');
    update public.evaluation_roster set evaluation_stage = 'documentFailed', updated_at = now()
      where applicant_id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;

-- ======================================================================
-- 00068_exam_no_sms.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 수험번호 안내 문자 (2026-09-28)
--
-- 근거: 원서 접수 업무 진행 지침(2025.10.21.) 4-(2)
--   "원서 접수 마감 이후 3일 이내 개인별 연락처로 부여된 수험번호 안내(SMS 등)"
--   문구는 붙임 3(수험번호 부여 SMS 예제)을 따른다(Edge Function send-exam-no-sms).
--
-- 구조는 합격자 통보 문자(00054)와 같다.
--   · 발송 대상 조회 RPC → 화면에서 대상 확인
--   · Edge Function이 실제 발송 → 결과를 이 로그에 기록
--   · 로그에는 연락처를 저장하지 않는다(누구에게·언제·성공 여부만).
--   · 재발송은 막지 않는다(수신 실패·번호 변경 대응). 화면에서 "발송완료"로만 표시.

create table if not exists public.exam_no_sms_log (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  exam_no text not null,
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid references public.users (id),
  created_at timestamptz not null default now()
);

create index if not exists exam_no_sms_log_applicant_idx
  on public.exam_no_sms_log (year, round, applicant_id);

alter table public.exam_no_sms_log enable row level security;
revoke all on public.exam_no_sms_log from anon, authenticated;

-- ============================================================
-- 1. 발송 대상 — 수험번호가 부여된 지원자(철회·제외 제외)
-- ============================================================

create or replace function public.get_exam_no_sms_recipients(
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
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'examNo', a.exam_no,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'applicantPhone', p.applicant_phone,
    'guardianPhone', p.guardian_phone,
    'applicantSent', exists (
      select 1 from public.exam_no_sms_log l
      where l.applicant_id = a.id and l.target = 'applicant' and l.sent
        and l.exam_no = a.exam_no),
    'guardianSent', exists (
      select 1 from public.exam_no_sms_log l
      where l.applicant_id = a.id and l.target = 'guardian' and l.sent
        and l.exam_no = a.exam_no)
  ) order by a.exam_no), '[]'::jsonb)
  into v_items
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  where a.year = p_year and a.round = p_round
    and a.exam_no is not null
    and a.application_status not in ('withdrawn', 'excluded');

  -- "발송완료"는 지금 번호 기준으로만 본다(exam_no 일치 조건). 재부여로 번호가
  -- 바뀌면 옛 번호로 보낸 문자는 완료로 치지 않아 다시 보내도록 유도한다.
  return jsonb_build_object('items', v_items);
end;
$$;

revoke all on function public.get_exam_no_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_exam_no_sms_recipients(int, admission_round) to authenticated;

-- ============================================================
-- 2. 발송 결과 기록 (Edge Function이 사용자 JWT로 호출)
-- ============================================================

create or replace function public.record_exam_no_sms_sent(
  p_applicant_id uuid,
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
  v_app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_target not in ('applicant', 'guardian') then
    raise exception '대상은 applicant 또는 guardian이어야 합니다.' using errcode = '22023';
  end if;

  select id, year, round, exam_no into v_app from public.applicants where id = p_applicant_id;
  if v_app is null or v_app.exam_no is null then
    raise exception '수험번호가 부여된 지원자가 아닙니다.' using errcode = 'P0002';
  end if;

  insert into public.exam_no_sms_log
    (year, round, applicant_id, exam_no, target, sent, provider_code, provider_message, sent_by)
  values
    (v_app.year, v_app.round, p_applicant_id, v_app.exam_no, p_target, p_sent,
     p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'exam_no.sms_sent', 'exam_no_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('target', p_target, 'sent', p_sent, 'examNo', v_app.exam_no));
end;
$$;

revoke all on function public.record_exam_no_sms_sent(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_exam_no_sms_sent(uuid, text, boolean, text, text) to authenticated;

-- ======================================================================
-- 00069_quant_areas_single_superadmin.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 출결·학업성실도·공동체를 최고관리자 1인 채점으로 (2026-09-28)
--
-- 결정(2026-09-28, 담당 교사): 출결·학업성실도·공동체생활적합성은 최고관리자 혼자 채점한다.
-- 00066에서 내부 규정상 2명으로 늘렸던 배정 인원을 1명으로 되돌리고, 공동체의
-- "2인 제출·평균" 규칙도 1건 제출이면 확정되도록 바꾼다.
--
-- 제출 건수 기준은 config_revisions.scoring_params.requiredSubmissions에 있었지만,
-- 확정(lock)된 설정은 고칠 수 없고 고치면 기존 계획이 무효화된다(CONFIG_SOURCE_STALE).
-- 그래서 운영 설정 표 evaluation_area_staffing에 required_submissions(제출 건수
-- 재정의) 칸을 두고, 아래 한 함수가 모든 곳의 기준이 되게 한다.
--   _document_required_submissions(연도, 차수, 영역)
--     = 운영 설정 재정의 → 설정(config) 값 → 기본값(출결1·학업1·공동체2·자소서5·소견서4)
--
-- 이 함수를 쓰도록 바꾸는 곳:
--   · _compute_document_aggregate (00008) — 1차 사정 점수 계산. 공동체/자소서/소견서 건수 비교
--   · get_evaluation_progress / recompute_evaluation_alerts (00007) — 진행 현황·미제출 경고
--   · get_evaluation_staffing (00066) — 평가 준비 화면의 "필요 제출" 표시
-- 자소서 5건·소견서 4건은 그대로다(값이 같으므로 동작 변화 없음).

alter table public.evaluation_area_staffing
  add column if not exists required_submissions int check (required_submissions is null or required_submissions >= 1);

comment on column public.evaluation_area_staffing.required_submissions is
  '채점 완료로 보는 제출 건수 재정의(null이면 config의 requiredSubmissions 사용). 2026-09-28 공동체 1건.';

-- 배정 인원 1명, 공동체 제출 1건 — 모든 차수
update public.evaluation_area_staffing
   set required_evaluators = 1, updated_at = now(), updated_by = 'migration-00069'
 where area in ('attendance','academic','community');

update public.evaluation_area_staffing
   set required_submissions = 1, updated_at = now(), updated_by = 'migration-00069'
 where area = 'community';

-- 앞으로 새 차수를 만들 때도 같은 기본값이 들어가게 한다.
create or replace function public._trg_seed_evaluation_area_staffing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.evaluation_area_staffing (year, round, area, required_evaluators, required_submissions, updated_by)
  select new.year, new.round, d.area, d.cnt, d.sub, 'default'
  from (values
    ('attendance'::evaluation_area, 1, null::int),
    ('academic'::evaluation_area, 1, null::int),
    ('community'::evaluation_area, 1, 1),
    ('essay'::evaluation_area, 5, null::int),
    ('opinion'::evaluation_area, 4, null::int)
  ) as d(area, cnt, sub)
  on conflict (year, round, area) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_seed_evaluation_area_staffing on public.admission_rounds;
create trigger trg_seed_evaluation_area_staffing
  after insert on public.admission_rounds
  for each row execute function public._trg_seed_evaluation_area_staffing();

-- ============================================================
-- 제출 건수 기준 함수
-- ============================================================

create or replace function public._document_required_submissions(
  p_year int,
  p_round admission_round,
  p_area text
)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_override int;
  v_config int;
begin
  select s.required_submissions into v_override
  from public.evaluation_area_staffing s
  where s.year = p_year and s.round = p_round and s.area::text = p_area;
  if v_override is not null then
    return v_override;
  end if;

  select (c.scoring_params -> p_area ->> 'requiredSubmissions')::int into v_config
  from public.admission_rounds r
  join public.config_revisions c on c.id = r.config_revision_id
  where r.year = p_year and r.round = p_round;
  if v_config is not null then
    return v_config;
  end if;

  return case p_area
    when 'attendance' then 1
    when 'academic' then 1
    when 'community' then 2
    when 'essay' then 5
    when 'opinion' then 4
    else null
  end;
end;
$$;

revoke all on function public._document_required_submissions(int, admission_round, text) from public, anon, authenticated;

-- ============================================================
-- 1차 사정 점수 계산 (00008 원문에서 건수 비교만 바꿈)
-- ============================================================

create or replace function public._compute_document_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  app record;
  rev_id uuid;
  params jsonb;
  attendance_score numeric;
  academic_score numeric;
  community_score numeric;
  community_count int;
  essay_score numeric;
  essay_count int;
  opinion_score numeric;
  opinion_count int;
  raw_total numeric;
  final_total numeric;
  is_complete boolean;
  bonus_applied boolean := false;
  bonus_amount numeric := 0;
begin
  select id, year, round, tracks, bonus_eligible, bonus_reason
    into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- 출결 (5.2.1): 필수 1건, 없으면 null/미확정
  select (server_computed ->> 'score')::numeric into attendance_score
    from public.scores_attendance
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 학업성실도 (5.2.2)
  select (server_computed ->> 'score')::numeric into academic_score
    from public.scores_academic
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 공동체 (5.2.3): 필요 제출 건수(기본 2, 2026-09-28부터 1)를 정확히 채워야 확정. 여러 명이면 평균.
  select count(*), avg((server_computed ->> 'score')::numeric)
    into community_count, community_score
    from public.scores_community
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if community_count <> public._document_required_submissions(app.year, app.round, 'community') then
    community_score := null;
  end if;

  -- 자소서 (5.2.4): 필요 제출 건수(기본 5)를 정확히 채워야 확정
  select count(*), sum((server_computed ->> 'total')::numeric)
    into essay_count, essay_score
    from public.scores_essay
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if essay_count <> public._document_required_submissions(app.year, app.round, 'essay') then
    essay_score := null;
  end if;

  -- 소견서 (5.2.5): 필요 제출 건수(기본 4)를 정확히 채워야 확정
  select count(*), sum((server_computed ->> 'total')::numeric)
    into opinion_count, opinion_score
    from public.scores_opinion
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if opinion_count <> public._document_required_submissions(app.year, app.round, 'opinion') then
    opinion_score := null;
  end if;

  -- 서류평가 원점수 (5.2.6): 5개 영역 전부 확정일 때만
  is_complete := attendance_score is not null and academic_score is not null
    and community_score is not null and essay_score is not null and opinion_score is not null;

  if is_complete then
    raw_total := attendance_score + academic_score + community_score + essay_score + opinion_score;

    -- 가산점 (5.2.7, applyLevel='total' 기본값 — 섹션 5.8 D 확인 전까지 이 값 사용)
    -- config에 bonus 파라미터가 아직 없으면(설정 전 단계) 안전하게 가산점 미적용으로 처리.
    if params -> 'bonus' is not null
       and 'incheon' = any(app.tracks)
       and app.bonus_eligible = true
       and app.bonus_reason = any(
         array(select jsonb_array_elements_text(coalesce(params -> 'bonus' -> 'eligibleReasons', '[]'::jsonb)))
       )
    then
      bonus_applied := true;
      final_total := least(
        coalesce((params -> 'bonus' ->> 'cap')::numeric, raw_total),
        raw_total * (1 + coalesce((params -> 'bonus' ->> 'rate')::numeric, 0))
      );
      bonus_amount := final_total - raw_total;
    else
      final_total := raw_total;
    end if;
  end if;

  return jsonb_build_object(
    'attendance', attendance_score,
    'academic', academic_score,
    'community', community_score,
    'essay', essay_score,
    'opinion', opinion_score,
    'complete', is_complete,
    'rawTotal', raw_total,
    'bonusApplied', bonus_applied,
    'bonusAmount', bonus_amount,
    'finalTotal', final_total
  );
end;
$$;

revoke execute on function public._compute_document_aggregate(uuid) from anon, authenticated;

-- ============================================================
-- 진행 현황·미제출 경고 (00007 원문에서 필요 건수만 바꿈)
-- ============================================================

create or replace function public.recompute_evaluation_alerts(
  target_year int,
  target_round admission_round
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
  created_count int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- ── scoreGap: essay ──────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_essay
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'essay' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'essay', 'scoreGap', 'warning',
         format('자소서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'essay' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'essay' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── scoreGap: opinion ────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_opinion
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'opinion' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'opinion', 'scoreGap', 'warning',
         format('소견서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'opinion' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'opinion' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── missingSubmission: 5개 영역 전부, 평가활성 지원자 기준 ──
  for r in
    select er.applicant_id, area_key.area,
           public._document_required_submissions(target_year, target_round, area_key.area) as required,
           coalesce(cnt.submitted, 0) as submitted
    from public.evaluation_roster er
    cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
    left join lateral (
      select count(*) as submitted from (
        select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
        union all
        select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
        union all
        select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
        union all
        select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
        union all
        select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
      ) x
    ) cnt on true
    where er.year = target_year and er.round = target_round and er.evaluation_active = true
  loop
    if r.required is not null and r.submitted < r.required then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary)
      values
        (target_year, target_round, r.applicant_id, r.area::evaluation_area, 'missingSubmission', 'warning',
         format('%s 영역 제출 %s/%s건', r.area, r.submitted, r.required))
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = r.area::evaluation_area and alert_type = 'missingSubmission' and status != 'resolved';
    end if;
  end loop;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type)
  values (target_year, target_round, 'user', caller::text, 'evaluation_alerts.recomputed', 'evaluation_alerts');

  return jsonb_build_object('processed', created_count)::json;
end;
$$;

revoke execute on function public.recompute_evaluation_alerts(int, admission_round) from anon;

create or replace function public.get_evaluation_progress(
  target_year int,
  target_round admission_round
)
returns table (
  applicant_id uuid,
  receipt_no text,
  display_name text,
  area text,
  required int,
  submitted int,
  complete boolean,
  open_alerts int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  return query
  select
    er.applicant_id,
    er.receipt_no,
    er.display_name,
    area_key.area,
    public._document_required_submissions(target_year, target_round, area_key.area) as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= public._document_required_submissions(target_year, target_round, area_key.area) as complete,
    (select count(*)::int from public.evaluation_alerts ea
      where ea.applicant_id = er.applicant_id and ea.area::text = area_key.area and ea.status = 'open') as open_alerts
  from public.evaluation_roster er
  cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
  left join lateral (
    select count(*) as submitted from (
      select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
      union all
      select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
      union all
      select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
      union all
      select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
      union all
      select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
    ) x
  ) cnt on true
  where er.year = target_year and er.round = target_round and er.evaluation_active = true
  order by er.receipt_no, area_key.area;
end;
$$;

revoke execute on function public.get_evaluation_progress(int, admission_round) from anon;

-- ============================================================
-- 평가 준비 화면 (00066 원문에서 필요 제출 표시만 바꿈)
-- ============================================================

create or replace function public.get_evaluation_staffing(
  p_year int,
  p_round admission_round,
  p_stage text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_areas evaluation_area[];
  v_rev_id uuid;
  v_params jsonb;
  v_result jsonb;
  v_available jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_stage = 'document' then
    v_areas := array['attendance','academic','community','essay','opinion']::evaluation_area[];
  elsif p_stage = 'deep' then
    v_areas := array['group','interview','writing']::evaluation_area[];
  else
    raise exception '알 수 없는 평가 단계입니다: % (document 또는 deep)', p_stage
      using errcode = '22023';
  end if;

  select config_revision_id into v_rev_id
  from public.admission_rounds where year = p_year and round = p_round;
  if v_rev_id is not null then
    select scoring_params into v_params from public.config_revisions where id = v_rev_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'area', a.area,
    -- 배정해야 할 인원(운영 규정). 표에 값이 없으면 예전처럼 설정값을 쓴다.
    'requiredCount', coalesce(
      (select s.required_evaluators from public.evaluation_area_staffing s
        where s.year = p_year and s.round = p_round and s.area = a.area),
      (v_params -> a.area::text ->> 'requiredSubmissions')::int
    ),
    -- 채점 완료로 보기 위해 실제로 들어와야 하는 제출 건수(참고 표시용).
    -- 배정 인원과 다를 수 있다(예: 출결은 2명 배정, 1건 제출이면 완료).
    'requiredSubmissions', case when a.area in ('attendance','academic','community','essay','opinion')
      then public._document_required_submissions(p_year, p_round, a.area::text)
      else (v_params -> a.area::text ->> 'requiredSubmissions')::int end,
    'requiredRole', public._score_area_required_role(a.area)::text,
    'assigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id, 'displayName', u.display_name, 'email', u.email,
        'roles', u.roles
      ) order by u.display_name)
      from public.users u
      where u.active = true and a.area = any(u.assigned_areas)
    ), '[]'::jsonb)
  ) order by ord), '[]'::jsonb)
  into v_result
  from unnest(v_areas) with ordinality as a(area, ord);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email,
    'roles', roles, 'assignedAreas', assigned_areas
  ) order by display_name), '[]'::jsonb)
  into v_available
  from public.users
  where active = true
    and roles && array['evaluator','quant']::app_role[];

  return jsonb_build_object(
    'stage', p_stage,
    'year', p_year,
    'round', p_round,
    'areas', v_result,
    'availableUsers', v_available
  );
end;
$$;

revoke all on function public.get_evaluation_staffing(int, admission_round, text) from public, anon;
grant execute on function public.get_evaluation_staffing(int, admission_round, text) to authenticated;

-- ======================================================================
-- 00070_document_scoresheet_print.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 서류평가 채점표 출력(결재용) (2026-09-28)
--
-- 목적: 서류평가 영역별 채점표를 인쇄해 서명을 받고, 스캔해서 K-에듀파인으로
-- 결재받는다. 출결·학업성실도·공동체는 최고관리자 1명이 시스템에서 채점하지만
-- (00069), 내부 규정상 채점위원은 2명이어야 하므로 채점표 서명란에 이름을 한 명
-- 더 올릴 수 있게 한다(2026-09-28 결정).
--
-- · scoresheet_cosigners: 영역별로 서명란에 추가할 이름(시스템 계정이 아니어도 됨).
--   시스템 채점 기록에는 영향이 없고, 인쇄물 서명란에만 쓰인다.
-- · get_document_scoresheet: 영역별 채점표 데이터(평가 대상 명단 + 제출된 채점 + 추가 서명자).
--   1차 사정 확정 전에도 볼 수 있다(결재는 확정 전후 모두 필요할 수 있음).

create table if not exists public.scoresheet_cosigners (
  year int not null,
  round admission_round not null,
  area evaluation_area not null,
  names text[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (year, round, area)
);

comment on table public.scoresheet_cosigners is
  '채점표 인쇄 시 서명란에 추가로 올릴 이름(내부 규정상 채점위원 수 충족용). 채점 기록과 무관.';

alter table public.scoresheet_cosigners enable row level security;
revoke all on public.scoresheet_cosigners from anon, authenticated;

-- ============================================================
-- 1. 추가 서명자 저장
-- ============================================================

create or replace function public.set_scoresheet_cosigners(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_names text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_names text[];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(array_agg(n order by ord), '{}')
    into v_names
  from (
    select btrim(x) as n, ord
    from unnest(coalesce(p_names, '{}'::text[])) with ordinality as t(x, ord)
    where btrim(coalesce(x, '')) <> ''
  ) s;

  if array_length(v_names, 1) > 5 then
    raise exception '추가 서명자는 최대 5명까지입니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_names) n where length(n) > 30) then
    raise exception '이름은 30자 이내로 입력하세요.' using errcode = '23514';
  end if;

  insert into public.scoresheet_cosigners (year, round, area, names, updated_by)
  values (p_year, p_round, p_area, v_names, caller::text)
  on conflict (year, round, area) do update set
    names = excluded.names, updated_at = now(), updated_by = caller::text;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'scoresheet.cosigners_changed',
     'scoresheet_cosigners', p_area::text, p_area, jsonb_build_object('names', to_jsonb(v_names)));

  return jsonb_build_object('names', to_jsonb(v_names));
end;
$$;

revoke all on function public.set_scoresheet_cosigners(int, admission_round, evaluation_area, text[]) from public, anon;
grant execute on function public.set_scoresheet_cosigners(int, admission_round, evaluation_area, text[]) to authenticated;

-- ============================================================
-- 2. 채점표 데이터
-- ============================================================

create or replace function public.get_document_scoresheet(
  p_year int,
  p_round admission_round,
  p_area evaluation_area
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_scores jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '서류평가 영역이 아닙니다: %', p_area using errcode = '22023';
  end if;

  if p_area = 'attendance' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_attendance s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'academic' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_academic s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'community' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_community s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'essay' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.items, 'score', (s.server_computed ->> 'total')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_essay s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.items, 'score', (s.server_computed ->> 'total')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_opinion s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  end if;

  -- 개별 점수가 이름과 함께 나가는 조회이므로 열람 기록을 남긴다.
  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, area)
  values (p_year, p_round, 'user', caller::text, 'scoresheet.viewed', 'scores', p_area::text, p_area);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', coalesce(er.exam_no, a.exam_no),
        'receiptNo', a.receipt_no,
        'name', a.name
      ) order by coalesce(er.exam_no, a.exam_no, a.receipt_no))
      from public.evaluation_roster er
      join public.applicants a on a.id = er.applicant_id
      where er.year = p_year and er.round = p_round and er.evaluation_active = true
    ), '[]'::jsonb),
    'scores', v_scores,
    'cosigners', coalesce((
      select to_jsonb(c.names) from public.scoresheet_cosigners c
      where c.year = p_year and c.round = p_round and c.area = p_area
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_document_scoresheet(int, admission_round, evaluation_area) from public, anon;
grant execute on function public.get_document_scoresheet(int, admission_round, evaluation_area) to authenticated;

-- ======================================================================
-- 00071_live_scoring_monitor.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 실시간 채점 현황(최고관리자) (2026-09-28)
--
-- 결정(2026-09-28, 담당 교사): 최고관리자가 채점 도중에도 위원별 채점 여부와 점수를
-- 이름까지 그대로 보고, 위원 간 편차를 확인할 수 있게 한다.
--
-- 원래 설계(00007)는 "관리자 화면은 진행률·경보만, 개별 점수는 사유를 남기고 열람"
-- 이었다. 이 결정으로 그 원칙을 최고관리자에 한해 완화한다. 대신
--   · 최고관리자(superadmin)만 볼 수 있다(일반 관리자 admin은 기존대로).
--   · 조회 기록을 audit_logs에 'scores.live_monitor_viewed'로 남긴다(같은 영역은 10분에 1번).
--   · 읽기 전용이다. 점수 수정은 기존 절차(재개방·대리 입력)로만 한다.
--
-- 영역: 서류평가 5개 + 모둠활동·학생면접·학부모면접·글쓰기.
-- 임시 저장(draft) 중인 채점은 "작성 중"으로만 보이고 점수는 보여주지 않는다.

create or replace function public.get_live_scoring_monitor(
  p_year int,
  p_round admission_round,
  p_area text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_rev uuid;
  v_params jsonb;
  v_scores jsonb;
  v_required int;
  v_gap numeric;
  v_is_document boolean;
  v_expected jsonb := '[]'::jsonb;
begin
  caller := public._require_superadmin();

  if p_area not in ('attendance','academic','community','essay','opinion',
                    'group','interview_student','interview_parent','writing') then
    raise exception '알 수 없는 영역입니다: %', p_area using errcode = '22023';
  end if;
  v_is_document := p_area in ('attendance','academic','community','essay','opinion');

  select config_revision_id into v_rev
  from public.admission_rounds where year = p_year and round = p_round;

  -- 필요 제출 건수·편차 경보 기준(설정에 있으면)
  begin
    if v_is_document then
      v_required := public._document_required_submissions(p_year, p_round, p_area);
      select (scoring_params -> p_area ->> 'alertGap')::numeric into v_gap
      from public.config_revisions where id = v_rev;
    elsif p_area = 'group' then
      v_params := public._m5b_group_params(v_rev);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    elsif p_area = 'writing' then
      v_params := public._m5d_writing_params(v_rev);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    else
      v_params := public._m5c_interview_params(v_rev, case when p_area = 'interview_student' then 'student' else 'parent' end);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    end if;
  exception when others then
    -- 설정이 아직 없으면 기준 없이 보여준다.
    v_required := null;
    v_gap := null;
  end;

  -- 채점(제출·임시·재개방). 임시·재개방은 점수를 숨긴다.
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_scores from (
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs) as x
    from public.scores_attendance s
    where p_area = 'attendance' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs)
    from public.scores_academic s
    where p_area = 'academic' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs)
    from public.scores_community s
    where p_area = 'community' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'total')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.items)
    from public.scores_essay s
    where p_area = 'essay' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'total')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.items)
    from public.scores_opinion s
    where p_area = 'opinion' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state,
      'score', case when s.submission_state = 'submitted' then (s.server_computed ->> 'total')::numeric end,
      'submittedAt', s.submitted_at,
      'inputs', case when s.submission_state = 'submitted' then s.items end)
    from public.scores_group s
    where p_area = 'group' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.student_submission_state,
      'score', case when s.student_submission_state = 'submitted' then (s.student_server_computed ->> 'total')::numeric end,
      'submittedAt', s.student_submitted_at,
      'inputs', case when s.student_submission_state = 'submitted' then s.student_items end)
    from public.scores_interview s
    where p_area = 'interview_student' and s.year = p_year and s.round = p_round
      and (s.student_revision > 0 or s.student_submission_state <> 'draft')
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.parent_submission_state,
      'score', case when s.parent_submission_state = 'submitted' then (s.parent_server_computed ->> 'total')::numeric end,
      'submittedAt', s.parent_submitted_at,
      'inputs', case when s.parent_submission_state = 'submitted' then s.parent_items end)
    from public.scores_interview s
    where p_area = 'interview_parent' and s.year = p_year and s.round = p_round
      and (s.parent_revision > 0 or s.parent_submission_state <> 'draft')
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state,
      'score', case when s.submission_state = 'submitted' then (s.server_computed ->> 'total')::numeric end,
      'submittedAt', s.submitted_at,
      'inputs', case when s.submission_state = 'submitted' then s.responses end)
    from public.scores_writing s
    where p_area = 'writing' and s.year = p_year and s.round = p_round
  ) t;

  -- 서류평가는 영역을 배정받은 사람이 "채점해야 할 위원"이다(평가 준비 화면과 같은 기준).
  if v_is_document then
    select coalesce(jsonb_agg(u.id order by u.display_name), '[]'::jsonb) into v_expected
    from public.users u
    where u.active = true and p_area::evaluation_area = any(u.assigned_areas);
  end if;

  -- 자동 새로고침(30초)마다 기록이 쌓이지 않게, 같은 사람·같은 영역은 10분에 한 번만 남긴다.
  if not exists (
    select 1 from public.audit_logs l
    where l.action = 'scores.live_monitor_viewed' and l.actor_uid = caller::text
      and l.year = p_year and l.round = p_round and l.resource_id = p_area
      and l.created_at > now() - interval '10 minutes'
  ) then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'scores.live_monitor_viewed', 'scores', p_area,
            jsonb_build_object('area', p_area));
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'requiredSubmissions', v_required,
    'alertGap', v_gap,
    'expectedEvaluatorUids', v_expected,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object('uid', u.id, 'name', u.display_name) order by u.display_name)
      from public.users u
      where u.id in (
        select (e ->> 'evaluatorUid')::uuid from jsonb_array_elements(v_scores) e
        union
        select (e #>> '{}')::uuid from jsonb_array_elements(v_expected) e
      )
    ), '[]'::jsonb),
    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id,
        'examNo', coalesce(er.exam_no, a.exam_no),
        'receiptNo', a.receipt_no,
        'name', a.name
      ) order by coalesce(er.exam_no, a.exam_no, a.receipt_no))
      from public.applicants a
      left join public.evaluation_roster er on er.applicant_id = a.id
      where a.year = p_year and a.round = p_round
        and (
          (v_is_document and er.evaluation_active = true)
          or (not v_is_document and er.evaluation_stage = 'documentPassed')
          or a.id in (select (e ->> 'applicantId')::uuid from jsonb_array_elements(v_scores) e)
        )
    ), '[]'::jsonb),
    'scores', v_scores,
    'fetchedAt', now()
  );
end;
$$;

revoke all on function public.get_live_scoring_monitor(int, admission_round, text) from public, anon;
grant execute on function public.get_live_scoring_monitor(int, admission_round, text) to authenticated;

-- ======================================================================
-- 00072_deep_checkin.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 2차 심층역량평가 입실 확인(바코드) (2026-09-28)
--
-- 현장 PC에 연결한 USB 바코드 리더로 수험표(수험번호) 또는 접수증(접수번호)을
-- 찍으면 사진·수험번호·성명·접수번호·생년월일·성별·출신중학교를 띄워 본인 확인을
-- 하고, 입실 시각을 기록한다. 장소는 본관(노트북 Tailscale 접속, 2026-09-28 결정).
--
-- · 대상: 1차 합격(evaluation_stage = documentPassed/deep), 철회·제외 아님.
--   대상이 아니면 정보는 보여주되 입실 기록은 하지 않는다(현장에서 바로 알아보도록).
--   단, 1차 사정 전 리허설을 위해 p_allow_ineligible = true면 대상이 아니어도 기록한다.
-- · 생년월일·성별이 나가므로 최고관리자·관리자만 쓸 수 있고, 찍을 때마다 감사 기록을 남긴다.
-- · 잘못 찍었을 때를 위해 입실 취소가 있다.

create table if not exists public.deep_checkins (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  checked_in_at timestamptz not null default now(),
  checked_in_by uuid references public.users (id),
  scanned_code text,
  method text not null check (method in ('exam_no', 'receipt_no'))
);

create index if not exists deep_checkins_round_idx on public.deep_checkins (year, round);

alter table public.deep_checkins enable row level security;
revoke all on public.deep_checkins from anon, authenticated;

-- ============================================================
-- 1. 바코드 스캔 → 조회 + 입실 기록
-- ============================================================

create or replace function public.checkin_scan(
  p_year int,
  p_round admission_round,
  p_code text,
  p_allow_ineligible boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_app record;
  v_priv record;
  v_method text;
  v_eligible boolean;
  v_existing record;
  v_recorded boolean := false;
  v_checked_at timestamptz;
  v_photo_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if v_code = '' then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select a.* into v_app from public.applicants a
  where a.year = p_year and a.round = p_round and upper(a.exam_no) = v_code
  limit 1;
  if found then
    v_method := 'exam_no';
  else
    select a.* into v_app from public.applicants a
    where a.year = p_year and a.round = p_round and upper(a.receipt_no) = v_code
    limit 1;
    if found then
      v_method := 'receipt_no';
    end if;
  end if;

  if v_method is null then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, metadata)
    values (p_year, p_round, 'user', caller::text, 'checkin.not_found', 'deep_checkins',
            jsonb_build_object('code', v_code));
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select gender, birth_date into v_priv from public.applicants_private where applicant_id = v_app.id;

  select id into v_photo_id from public.admission_documents
  where applicant_id = v_app.id and document_type = 'photo' and active = true
  order by uploaded_at desc limit 1;

  v_eligible := v_app.evaluation_stage in ('documentPassed', 'deep')
    and v_app.application_status not in ('withdrawn', 'excluded');

  select * into v_existing from public.deep_checkins where applicant_id = v_app.id;

  if v_existing.applicant_id is null and (v_eligible or p_allow_ineligible) then
    insert into public.deep_checkins (applicant_id, year, round, checked_in_by, scanned_code, method)
    values (v_app.id, v_app.year, v_app.round, caller, v_code, v_method)
    returning checked_in_at into v_checked_at;
    v_recorded := true;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when v_recorded then 'checkin.recorded' else 'checkin.scanned' end,
     'deep_checkins', v_app.id::text, v_app.id::text,
     jsonb_build_object('method', v_method, 'eligible', v_eligible,
                        'alreadyCheckedIn', v_existing.applicant_id is not null));

  return jsonb_build_object(
    'found', true,
    'code', v_code,
    'method', v_method,
    'applicant', jsonb_build_object(
      'applicantId', v_app.id,
      'examNo', v_app.exam_no,
      'receiptNo', v_app.receipt_no,
      'name', v_app.name,
      'birthDate', v_priv.birth_date,
      'gender', v_priv.gender,
      'school', v_app.school,
      'academicStatus', v_app.academic_status,
      'tracks', to_jsonb(v_app.tracks),
      'applicationStatus', v_app.application_status,
      'evaluationStage', v_app.evaluation_stage,
      'hasPhoto', v_photo_id is not null
    ),
    'eligible', v_eligible,
    'recorded', v_recorded,
    'checkedInAt', coalesce(v_checked_at, v_existing.checked_in_at),
    'alreadyCheckedIn', v_existing.applicant_id is not null
  );
end;
$$;

revoke all on function public.checkin_scan(int, admission_round, text, boolean) from public, anon;
grant execute on function public.checkin_scan(int, admission_round, text, boolean) to authenticated;

-- ============================================================
-- 2. 입실 현황(대상자 전원 + 입실 시각)
-- ============================================================

create or replace function public.get_checkin_status(
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
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id,
        'examNo', a.exam_no,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'eligible', a.evaluation_stage in ('documentPassed', 'deep')
          and a.application_status not in ('withdrawn', 'excluded'),
        'checkedInAt', c.checked_in_at
      ) order by coalesce(a.exam_no, a.receipt_no))
      from public.applicants a
      left join public.deep_checkins c on c.applicant_id = a.id
      where a.year = p_year and a.round = p_round
        and (
          (a.evaluation_stage in ('documentPassed', 'deep') and a.application_status not in ('withdrawn', 'excluded'))
          or c.applicant_id is not null
        )
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_checkin_status(int, admission_round) from public, anon;
grant execute on function public.get_checkin_status(int, admission_round) to authenticated;

-- ============================================================
-- 3. 입실 취소(잘못 찍었을 때)
-- ============================================================

create or replace function public.cancel_checkin(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  delete from public.deep_checkins where applicant_id = p_applicant_id returning * into v_row;
  if v_row.applicant_id is null then
    raise exception '입실 기록이 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_row.year, v_row.round, 'user', caller::text, 'checkin.cancelled', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('checkedInAt', v_row.checked_in_at));
end;
$$;

revoke all on function public.cancel_checkin(uuid) from public, anon;
grant execute on function public.cancel_checkin(uuid) to authenticated;

-- ======================================================================
-- 00073_reopen_score_entry.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 채점 재개방 한 곳으로 (2026-09-28)
--
-- 문제: 재개방 RPC는 영역별로 흩어져 있고(reopen_score / reopen_interview_score /
-- reopen_writing_score), 채점 문서 id를 알아야 해서 화면에서 부를 곳이 없었다
-- ("재개방 메뉴가 숨겨져 있다"). 화면에서는 "지원자 + 위원 + 영역"만 알면
-- 재개방할 수 있도록 하나로 묶는다.
--
-- · 서류평가 5개 영역·모둠활동: 기존 reopen_score 호출 + 사유를 감사 기록에 남김
--   (reopen_score는 사유 인자가 없고 연도·지원자도 기록하지 않아 여기서 보완한다).
-- · 학생/학부모 면접·글쓰기: 기존 reopen_interview_score / reopen_writing_score 호출
--   (원래대로 최고관리자만 가능, 사유 5자 이상).
-- · 제출확정 상태가 아니면 재개방하지 않는다.

create or replace function public.reopen_score_entry(
  p_area text,
  p_applicant_id uuid,
  p_evaluator_uid uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_id uuid;
  v_state text;
  v_year int;
  v_round admission_round;
  v_table text;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception '재개방 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  if p_area in ('interview_student', 'interview_parent') then
    select id, year, round,
           case when p_area = 'interview_student' then student_submission_state else parent_submission_state end
      into v_id, v_year, v_round, v_state
    from public.scores_interview
    where applicant_id = p_applicant_id and evaluator_uid = p_evaluator_uid;
    if v_id is null then
      raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
    end if;
    if v_state <> 'submitted' then
      raise exception '제출확정된 채점만 재개방할 수 있습니다(현재: %).', v_state using errcode = '55000';
    end if;
    perform public.reopen_interview_score(
      v_id, case when p_area = 'interview_student' then 'student' else 'parent' end, btrim(p_reason));
    return jsonb_build_object('reopened', true, 'scoreId', v_id);
  end if;

  if p_area = 'writing' then
    select id, submission_state into v_id, v_state
    from public.scores_writing
    where applicant_id = p_applicant_id and evaluator_uid = p_evaluator_uid;
    if v_id is null then
      raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
    end if;
    perform public.reopen_writing_score(v_id, btrim(p_reason));
    return jsonb_build_object('reopened', true, 'scoreId', v_id);
  end if;

  v_table := case p_area
    when 'attendance' then 'scores_attendance'
    when 'academic' then 'scores_academic'
    when 'community' then 'scores_community'
    when 'essay' then 'scores_essay'
    when 'opinion' then 'scores_opinion'
    when 'group' then 'scores_group'
    else null end;
  if v_table is null then
    raise exception '알 수 없는 영역입니다: %', p_area using errcode = '22023';
  end if;

  execute format(
    'select id, submission_state, year, round from public.%I where applicant_id = $1 and evaluator_uid = $2',
    v_table)
  into v_id, v_state, v_year, v_round
  using p_applicant_id, p_evaluator_uid;

  if v_id is null then
    raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_state <> 'submitted' then
    raise exception '제출확정된 채점만 재개방할 수 있습니다(현재: %).', v_state using errcode = '55000';
  end if;

  perform public.reopen_score(v_table, v_id);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.reopened_with_reason', v_table, v_id::text,
     p_applicant_id::text, p_area::evaluation_area, '재개방',
     jsonb_build_object('reason', btrim(p_reason), 'evaluatorUid', p_evaluator_uid));

  return jsonb_build_object('reopened', true, 'scoreId', v_id);
end;
$$;

revoke all on function public.reopen_score_entry(text, uuid, uuid, text) from public, anon;
grant execute on function public.reopen_score_entry(text, uuid, uuid, text) to authenticated;

-- ======================================================================
-- 00074_academic_semester_from_application.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 학업성실도: 원서의 반영 학기 자동 표시·기록 (2026-09-28)
--
-- 요강: 학업성실도는 "지원자가 입학원서에 학업성실도 반영을 선택하여 기재한 학기"의
-- 상위 5개 과목 성취도로 산정한다. 반영 학기는 접수 때 applicants.semester_choice에
-- 이미 들어가 있으므로, 채점 화면에서 따로 입력받지 않고 원서 값을 보여주고(get_academic_context),
-- 제출할 때 서버가 그 값을 inputs.semesterChoice에 함께 저장한다(채점표·XLSX에 표시).
-- 채점 담당(quant)은 applicants 표를 직접 읽을 수 없어서 전용 조회 함수를 둔다.
--
-- 입력 유형(학생부 성취도 / 검정고시 원점수)도 채점자가 고르지 않고 원서의 학적을 따른다
-- (2026-09-28 — 선생님들이 잘못 고르는 실수 방지). 졸업예정·졸업 → 학생부(regular),
-- 검정고시 → 원점수(ged). '기타'(동등학력 인정 등)만 화면에서 고른다. 서버도 같은 규칙으로
-- 원서 학적과 맞지 않는 유형의 제출을 거부한다.

create or replace function public.get_academic_context(p_applicant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_app record;
begin
  if not (public.has_role('superadmin') or public.has_role('admin')
          or (public.has_role('quant') and public.has_area('academic'))) then
    raise exception '학업성실도 평가 권한이 없습니다.' using errcode = '42501';
  end if;

  select semester_choice, academic_status into v_app
  from public.applicants where id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'semesterChoice', v_app.semester_choice,
    'academicStatus', v_app.academic_status
  );
end;
$$;

revoke all on function public.get_academic_context(uuid) from public, anon;
grant execute on function public.get_academic_context(uuid) to authenticated;

-- submit_academic_score: 00005 원문에서 반영 학기 저장만 추가
create or replace function public.submit_academic_score(
  p_applicant_id uuid,
  p_input_type text,
  p_subjects jsonb default '[]'::jsonb,
  p_no_document boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  params jsonb;
  grade_map jsonb;
  ged_bands jsonb;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('quant') and public.has_area('academic')) then
    raise exception '학업성실도 평가 권한이 없습니다 (quant + academic 배정 필요).';
  end if;
  if p_input_type not in ('regular', 'ged') then
    raise exception 'p_input_type은 regular 또는 ged여야 합니다.';
  end if;

  select * into existing from public.scores_academic
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  select id, year, round, semester_choice, academic_status into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  -- 원서 학적과 입력 유형이 맞아야 한다(무증빙 점수 적용은 예외).
  if not p_no_document then
    if app.academic_status = '검정고시' and p_input_type <> 'ged' then
      raise exception '원서 학적이 검정고시인 지원자입니다. 검정고시 원점수로 입력하세요.' using errcode = '23514';
    end if;
    if app.academic_status in ('졸업예정', '졸업') and p_input_type <> 'regular' then
      raise exception '원서 학적이 %인 지원자입니다. 학교생활기록부 성취도(A~E)로 입력하세요.', app.academic_status using errcode = '23514';
    end if;
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'academic') then
    raise exception '학업성실도 평가가 현재 열려있지 않습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'academic' into params from public.config_revisions where id = rev_id;
  if params is null then
    raise exception 'config에 academic 배점 파라미터가 없습니다.';
  end if;

  if p_no_document then
    computed_score := (params ->> 'noDocumentScore')::numeric;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    grade_map := params -> 'gradeMap';
    ged_bands := params -> 'gedBands';

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_input_type = 'regular' then
        points := (grade_map ->> (subj ->> 'achievement'))::numeric;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
          band jsonb;
          matched boolean := false;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception 'GED 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          for band in select * from jsonb_array_elements(ged_bands)
          loop
            if raw >= (band ->> 0)::numeric and raw <= (band ->> 1)::numeric then
              points := (band ->> 2)::numeric;
              matched := true;
              exit;
            end if;
          end loop;
          if not matched then
            raise exception 'GED 원점수 %에 해당하는 구간을 찾지 못했습니다.', raw;
          end if;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    -- 상위 5과목 선정·합산 (서버만 수행 — 클라이언트가 고르지 않음)
    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, (params ->> 'max')::numeric);
  end if;

  insert into public.scores_academic
    (applicant_id, evaluator_uid, year, round, config_revision_id, inputs, server_computed)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id,
     jsonb_build_object('inputType', p_input_type, 'subjects', p_subjects, 'noDocument', p_no_document,
                        'semesterChoice', case when p_input_type = 'regular' then app.semester_choice end),
     jsonb_build_object('score', computed_score, 'usedNoDocumentScore', p_no_document, 'configRevisionId', rev_id))
  on conflict (applicant_id, evaluator_uid) do update set
    inputs = excluded.inputs,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.academic.submitted', 'scores_academic',
     p_applicant_id::text, p_applicant_id::text, 'academic');

  return jsonb_build_object('score', computed_score)::json;
end;
$$;

revoke execute on function public.submit_academic_score(uuid, text, jsonb, boolean) from anon;

-- ======================================================================
-- 00075_bulk_user_scopes.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 사용자 권한 적용 연도·차수 일괄 지정 (2026-09-29)
--
-- 사용자 권한 관리에서 여러 선생님을 골라 "몇 학년도 · 어느 차수(본전형/추가모집)"에
-- 권한이 적용되는지를 한 번에 바꾼다. 역할·영역별 세부 배정은 기존 화면
-- (역할 수정, 평가 준비)에서 따로 한다.
--
-- mode: 'replace' = 지정한 값으로 교체, 'add' = 기존 값에 추가(중복 제거)
-- 연도·차수를 비워 두면(빈 배열) 그 항목은 건드리지 않는다.

create or replace function public.set_user_scopes_bulk(
  p_user_ids uuid[],
  p_year_scopes int[],
  p_round_scopes admission_round[],
  p_mode text default 'replace'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_count int;
begin
  caller := public._require_superadmin();

  if p_user_ids is null or array_length(p_user_ids, 1) is null then
    raise exception '대상 사용자를 1명 이상 선택하세요.' using errcode = '22023';
  end if;
  if p_mode not in ('replace', 'add') then
    raise exception 'mode는 replace 또는 add여야 합니다.' using errcode = '22023';
  end if;
  if coalesce(array_length(p_year_scopes, 1), 0) = 0 and coalesce(array_length(p_round_scopes, 1), 0) = 0 then
    raise exception '연도나 차수 중 하나 이상을 지정하세요.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_year_scopes, '{}')) y where y < 2020 or y > 2200) then
    raise exception '연도 값이 올바르지 않습니다.' using errcode = '22023';
  end if;

  update public.users u set
    year_scopes = case
      when coalesce(array_length(p_year_scopes, 1), 0) = 0 then u.year_scopes
      when p_mode = 'replace' then (select array_agg(distinct y order by y) from unnest(p_year_scopes) y)
      else (select array_agg(distinct y order by y) from unnest(coalesce(u.year_scopes, '{}') || p_year_scopes) y)
    end,
    round_scopes = case
      when coalesce(array_length(p_round_scopes, 1), 0) = 0 then u.round_scopes
      when p_mode = 'replace' then (select array_agg(distinct r order by r) from unnest(p_round_scopes) r)
      else (select array_agg(distinct r order by r) from unnest(coalesce(u.round_scopes, '{}') || p_round_scopes) r)
    end,
    updated_at = now()
  where u.id = any(p_user_ids);
  get diagnostics v_count = row_count;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, metadata)
  values ('user', caller::text, 'user.scopes_bulk_updated', 'users',
          jsonb_build_object('userIds', to_jsonb(p_user_ids), 'yearScopes', to_jsonb(p_year_scopes),
                             'roundScopes', to_jsonb(p_round_scopes), 'mode', p_mode, 'updated', v_count));

  return jsonb_build_object('updated', v_count);
end;
$$;

revoke all on function public.set_user_scopes_bulk(uuid[], int[], admission_round[], text) from public, anon;
grant execute on function public.set_user_scopes_bulk(uuid[], int[], admission_round[], text) to authenticated;

-- ======================================================================
-- 00076_document_view_permissions.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 전형위원 서류 열람 권한을 서류 종류별로 수동 설정 (2026-10-01)
--
-- 기존 규칙(00013): 평가위원·정량평가 위원은 "본인 담당영역 ∩ 서류의 access_areas"가
-- 겹칠 때만 열람했다. 입학원서·자격 증빙·동의서(reception 분류)는 아예 못 봤고,
-- 글쓰기 답안은 서류평가 통과자 것을 글쓰기 배정 위원만 볼 수 있었다.
--
-- 바꾸는 이유(2026-10-01 운영 판단): 종이 전형 때처럼 지원자가 제출한 서류 일체를
-- 전형위원 모두가 열람할 수 있어야 한다. 대신 슈퍼관리자가 위원별로 특정 서류
-- 종류를 수동으로 막을 수 있게 한다.
--
-- 새 규칙:
--   · superadmin / admin: 지금처럼 전부.
--   · adminOnly 분류: 관리자만(변경 없음).
--   · reception 역할: reception 분류 서류는 지금처럼 열람.
--   · evaluator / quant: 분류(reception·evaluation)와 담당영역에 관계없이,
--     users.viewable_document_types에 그 서류 종류가 있으면 열람.
--     viewable_document_types가 NULL이면 "전체" — 나중에 서류 종류가 추가돼도 자동 포함.
--
-- 보완책: 모든 열람은 여전히 log_document_view로 전건 감사 기록된다.
-- 업로드 시 정하는 access_areas는 이제 열람 판정에 쓰이지 않는다(데이터는 그대로 둔다).

alter table public.users
  add column if not exists viewable_document_types document_type[];

comment on column public.users.viewable_document_types is
  '평가위원·정량평가 위원이 열람할 수 있는 서류 종류. NULL = 전체.';

create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

-- 슈퍼관리자가 위원별 열람 서류 종류를 지정한다.
-- p_types = NULL → 전체 열람(기본값으로 되돌림), 빈 배열 → 아무 서류도 열람 불가.
create or replace function public.set_user_document_access(
  p_user_ids uuid[],
  p_types document_type[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_count int;
begin
  caller := public._require_superadmin();

  if p_user_ids is null or array_length(p_user_ids, 1) is null then
    raise exception '대상 사용자를 1명 이상 선택하세요.' using errcode = '22023';
  end if;

  update public.users u set
    viewable_document_types = case
      when p_types is null then null
      else (select coalesce(array_agg(distinct t order by t), '{}') from unnest(p_types) t)
    end,
    updated_at = now(),
    updated_by = caller::text
  where u.id = any(p_user_ids);
  get diagnostics v_count = row_count;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, metadata)
  values ('user', caller::text, 'user.document_access_updated', 'users',
          jsonb_build_object('userIds', to_jsonb(p_user_ids), 'types', to_jsonb(p_types),
                             'updated', v_count));

  return jsonb_build_object('updated', v_count);
end;
$$;

revoke all on function public.set_user_document_access(uuid[], document_type[]) from public, anon;
grant execute on function public.set_user_document_access(uuid[], document_type[]) to authenticated;

-- ======================================================================
-- 00077_list_order_by_exam_no.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 목록을 수험번호 순으로 정렬 (2026-10-01)
--
-- 수험번호가 부여된 뒤에도 일부 목록이 접수번호(receipt_no) 순으로 나와,
-- 전형별 접수번호(M·V 계열)가 섞여 수험번호 순서가 뒤죽박죽으로 보였다
-- (예: 관리자 대리 채점 화면 A1003, A1006, A1009, A1001 …).
-- 화면용 목록은 "수험번호 순, 수험번호가 아직 없으면 그 뒤에 접수번호 순"으로 맞춘다.
-- (exam_no 오름차순은 NULL을 마지막에 둔다.)
--
-- 바꾸지 않는 것: assign_exam_numbers — 수험번호를 매기는 순서 자체라 접수 기준 유지.
-- 아래 함수는 서버 DB의 현재 정의(pg_get_functiondef)에서 ORDER BY만 바꿨다.

CREATE OR REPLACE FUNCTION public.admin_get_document_score_entry_context(p_year integer, p_round admission_round, p_area evaluation_area, p_target_evaluator_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_role app_role;
  v_table text;
  v_items jsonb;
  v_area_open boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '이 화면은 서류평가 5개 영역만 지원합니다 (입력값: %).', p_area
      using errcode = '22023';
  end if;

  v_role := public._score_area_required_role(p_area);
  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and v_role = any(u.roles) and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역 담당으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  select (stage_status = 'open' and p_area = any(open_evaluation_areas))
  into v_area_open
  from public.admission_rounds
  where year = p_year and round = p_round;

  -- 영역마다 점수 테이블이 다르다. 위에서 영역을 5개로 좁혀 검증했으므로
  -- 테이블명 조립은 안전하다(사용자 입력이 그대로 들어가지 않는다).
  v_table := 'scores_' || p_area::text;

  -- 값은 문자열로 끼워 넣지 않고 USING으로 넘긴다(따옴표·형변환 사고 방지).
  -- 테이블명만 %I로 조립하며, 위에서 영역을 5개로 좁혀 검증했으므로 안전하다.
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', r.applicant_id,
      'examNo', r.exam_no,
      'displayName', r.display_name,
      'receiptNo', r.receipt_no,
      'submissionState', s.submission_state,
      'serverComputed', s.server_computed,
      'submittedAt', s.submitted_at
    ) order by r.exam_no, r.receipt_no), '[]'::jsonb)
    from public.evaluation_roster r
    left join public.%I s
      on s.applicant_id = r.applicant_id and s.evaluator_uid = $1
    where r.year = $2 and r.round = $3 and r.evaluation_active = true
  $q$, v_table)
  into v_items
  using p_target_evaluator_uid, p_year, p_round;

  return jsonb_build_object(
    'area', p_area,
    'areaOpen', coalesce(v_area_open, false),
    'targetEvaluatorUid', p_target_evaluator_uid,
    'items', v_items
  );
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_evaluation_progress(target_year integer, target_round admission_round)
 RETURNS TABLE(applicant_id uuid, receipt_no text, display_name text, area text, required integer, submitted integer, complete boolean, open_alerts integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  return query
  select
    er.applicant_id,
    er.receipt_no,
    er.display_name,
    area_key.area,
    public._document_required_submissions(target_year, target_round, area_key.area) as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= public._document_required_submissions(target_year, target_round, area_key.area) as complete,
    (select count(*)::int from public.evaluation_alerts ea
      where ea.applicant_id = er.applicant_id and ea.area::text = area_key.area and ea.status = 'open') as open_alerts
  from public.evaluation_roster er
  cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
  left join lateral (
    select count(*) as submitted from (
      select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
      union all
      select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
      union all
      select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
      union all
      select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
      union all
      select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
    ) x
  ) cnt on true
  where er.year = target_year and er.round = target_round and er.evaluation_active = true
  order by er.exam_no, er.receipt_no, area_key.area;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_final_pass_list(p_year integer, p_round admission_round, p_purpose text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_purpose not in ('sms', 'website') then
    raise exception '지원하지 않는 purpose입니다: % (sms | website 중 하나)', p_purpose
      using errcode = '55000';
  end if;

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다. simulation 결과로는 발표 자료를 만들 수 없습니다.'
      using errcode = '55000';
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (p_year, p_round, 'user', caller::text, 'decision.final.pass_list_exported.' || p_purpose, 'decision_runs', v_run_id::text);

  if p_purpose = 'sms' then
    return jsonb_build_object(
      'purpose', 'sms',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'name', a.name,
          'applicantPhone', ap.applicant_phone,
          'guardianName', ap.guardian_name,
          'guardianPhone', ap.guardian_phone,
          'outcome', dr.outcome,
          'outcomeLabel', case dr.outcome
            when 'passed' then '합격' when 'failed' then '불합격'
            when 'excluded' then '제외' else '판정보류' end,
          'trackLabel', case
            when dr.track_result ->> 'incheon' = 'passed' then '인천학생추천'
            when dr.track_result ->> 'social' = 'passed' then '사회통합'
            when dr.track_result ->> 'general' = 'passed' then '일반'
            else null
          end
        ) order by a.exam_no, a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        left join public.applicants_private ap on ap.applicant_id = a.id
        where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed')
      ), '[]'::jsonb)
    );
  else
    return jsonb_build_object(
      'purpose', 'website',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'outcomeLabel', '합격'
        ) order by a.exam_no, a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        where dr.run_id = v_run_id and dr.outcome = 'passed'
      ), '[]'::jsonb)
    );
  end if;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_final_result_sms_recipients(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome = 'passed';

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_m6_committee_packet(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round record;
  v_run record;
  quota jsonb;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  select * into v_run
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final'
    and status in ('completed', 'finalized')
  order by created_at desc
  limit 1;

  if v_run is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_FINAL_RUN_YET');
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';
  select count(*) into excluded_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'excluded';
  select count(*) into review_pending_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'reviewPending';
  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  return jsonb_build_object(
    'ready', true,
    'runId', v_run.id,
    'runMode', v_run.mode,
    'runStatus', v_run.status,
    'generatedAt', v_run.aggregate_snapshot_at,
    'finalizedAt', v_run.finalized_at,
    'quota', quota,
    'blockers', jsonb_build_object(
      'blockingAlertCount', blocking_count,
      'incompleteDeepCount', incomplete_count,
      'reviewPendingCount', review_pending_count,
      'excludedCount', excluded_count,
      'unresolvedTieCount', v_run.unresolved_tie_count
    ),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'tracks', a.tracks,
        'primaryTrack', case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 'incheon'
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 'social'
          else 'general'
        end,
        'documentScore', fa.document_score,
        'documentCarry', fa.document_carry,
        'groupScore', fa.group_score,
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentScore', fa.interview_parent_score,
        'writingScore', fa.writing_score,
        'finalTotal', dr.total_score,
        'rank', dr.rank,
        'trackResult', dr.track_result,
        'outcome', dr.outcome,
        'tiebreakValues', dr.tiebreak_values
      ) order by
        (case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 0
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 1
          else 2
        end),
        dr.rank nulls last
      )
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome <> 'excluded'
    ), '[]'::jsonb),
    'excludedCandidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'adminNote', aa.admin_note
      ) order by a.exam_no, a.receipt_no)
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome = 'excluded'
    ), '[]'::jsonb)
  );
end;
$function$

;

-- ======================================================================
-- 00078_writing_lists_by_exam_no.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 글쓰기 목록을 수험번호 순으로 (2026-10-01)
--
-- 글쓰기 준비(관리자)와 글쓰기 채점(위원) 목록이 1차 서류사정 순위(dr.rank) 순이었다.
--   · 관리자: 시험 당일 스캔한 답안을 수험번호 순으로 올리기 어렵다.
--   · 위원: 목록 순서만으로 지원자의 서류 성적 순위를 짐작할 수 있다.
-- 둘 다 수험번호 순(같으면 접수번호·이름)으로 바꾼다. 서버 DB의 현재 정의에서 ORDER BY만 바꿨다.

CREATE OR REPLACE FUNCTION public.get_m5d_writing_plan_admin(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round record;
  v_plan_config_revision_id uuid;
  v_validation jsonb;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select config_revision_id into v_plan_config_revision_id
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;

  if found then
    v_validation := public._m5d_validate_writing_plan(p_year, p_round);
  else
    v_validation := jsonb_build_object('complete', false, 'blockingIssues', '[]'::jsonb, 'status', null, 'revision', 0);
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'config', case
      when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null
      else public._m5d_writing_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id))
    end,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id,
        'displayName', u.display_name,
        'email', u.email
      ) order by u.display_name, u.email)
      from public.users u
      where u.active = true
        and 'evaluator' = any(u.roles)
        and 'writing' = any(u.assigned_areas)
        and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
        and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    ), '[]'::jsonb),
    'memberUids', coalesce((
      select jsonb_agg(m.evaluator_uid order by m.member_slot)
      from public.writing_plan_members m
      where m.year = p_year and m.round = p_round
    ), '[]'::jsonb),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'documentScore', dr.total_score,
        'answerDocumentId', answer_doc.id,
        'answerVersion', answer_doc.version
      ) order by er.exam_no, er.receipt_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      left join lateral (
        select d.id, d.version
        from public.admission_documents d
        where d.applicant_id = dr.applicant_id
          and d.document_type = 'writingAnswer'
          and d.active = true
          and d.classification = 'evaluation'
          and 'writing'::evaluation_area = any(d.access_areas)
        order by d.version desc, d.uploaded_at desc
        limit 1
      ) answer_doc on true
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb),
    'validation', v_validation
  );
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_m5d_writing_workspace(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_round record;
  v_plan record;
  v_config jsonb;
  v_candidates jsonb;
begin
  caller := public._m5d_require_writing_user(p_year, p_round);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select p.* into v_plan
  from public.writing_evaluation_plans p
  join public.writing_plan_members m
    on m.year = p.year and m.round = p.round
  where p.year = p_year and p.round = p_round
    and p.status = 'finalized'
    and m.evaluator_uid = caller;
  if not found then
    raise exception '현재 평가자에게 최종확정된 글쓰기 평가 배정이 없습니다.' using errcode = '42501';
  end if;

  v_config := public._m5d_writing_params(v_plan.config_revision_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', er.applicant_id,
    'examNo', er.exam_no,
    'displayName', er.display_name,
    'rankOrder', dr.rank,
    'answerDocument', case when answer_doc.id is null then null else jsonb_build_object(
      'documentId', answer_doc.id,
      'version', answer_doc.version,
      'mimeType', answer_doc.mime_type
    ) end,
    'myScore', case when sw.id is null then null else jsonb_build_object(
      'scoreId', sw.id,
      'responses', sw.responses,
      'memo', sw.memo,
      'submissionState', sw.submission_state,
      'revision', sw.revision,
      'serverComputed', sw.server_computed,
      'clientUpdatedAt', sw.client_updated_at,
      'submittedAt', sw.submitted_at
    ) end
  ) order by er.exam_no, er.receipt_no, er.display_name), '[]'::jsonb)
  into v_candidates
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  left join lateral (
    select d.id, d.version, d.mime_type
    from public.admission_documents d
    where d.applicant_id = dr.applicant_id
      and d.document_type = 'writingAnswer'
      and d.active = true
      and d.classification = 'evaluation'
      and 'writing'::evaluation_area = any(d.access_areas)
    order by d.version desc, d.uploaded_at desc
    limit 1
  ) answer_doc on true
  left join public.scores_writing sw
    on sw.applicant_id = dr.applicant_id and sw.evaluator_uid = caller
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'serverNow', now(),
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'configRevisionId', v_plan.config_revision_id,
    'config', v_config,
    'candidates', v_candidates
  );
end;
$function$

;

-- ======================================================================
-- 00079_final_result_sms_include_failed.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 최종 결과 문자: 불합격자도 시스템에서 발송 (2026-10-01)
--
-- 처음(00054)에는 실수로 불합격자에게 합격 문자가 가는 일을 막으려고 합격자만
-- 시스템 발송 대상으로 두고, 불합격 통보는 CSV로 학교 문자 도구에서 따로 보냈다.
-- 불합격자에게도 정중한 안내 문구를 보내기 위해 시스템 발송 대상에 넣는다.
--
-- 안전장치는 유지한다: 어느 문구를 보낼지는 화면이 아니라 Edge Function
-- (send-final-result-sms)이 확정된 최종 사정 결과(outcome)를 직접 다시 읽어 고른다.
-- 화면이 판정을 잘못 넘겨도 합격·불합격 문구가 바뀌어 나갈 수 없다.
--
-- 바뀐 점: outcome in ('passed','failed')로 확대, 'outcome'·'examNo' 필드 추가,
-- 합격자 먼저(수험번호 순). 제외(excluded)·위원회 결정 필요는 대상이 아니다.

CREATE OR REPLACE FUNCTION public.get_final_result_sms_recipients(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'examNo', a.exam_no,
    'outcome', dr.outcome,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by (dr.outcome <> 'passed'), a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed');

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$function$;

-- ======================================================================
-- 00080_final_decision_cutoffs.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 최종 사정 합격선·과락선 (2026-10-01)
--
-- 지금까지 최종 사정은 전형별 모집정원만큼 총점 순으로 합격시켰다. 지원자가 정원보다
-- 적으면 점수와 관계없이 전원 합격이었다. 회차별로 합격선·과락선을 두어, 기준에
-- 못 미친 지원자는 정원 안이어도 불합격시킨다.
--
-- 기준(모두 선택, 비우면 미적용, 전 전형 공통):
--   finalTotal(최종 총점 합격선), document(서류평가 점수), group(모둠활동),
--   interview(학생+학부모 면접 합계), writing(글쓰기) — 각각 "이 점수 미만이면 불합격".
--
-- 사정 방식: 기준에 걸린 지원자는 순위 경쟁 전에 불합격(사유를 track_result.cutoffReason에
-- 남김). 나머지끼리 기존 정원·순위·동점 규칙으로 사정하고, 못 채운 자리는 미충원으로 남는다
-- (특별전형 미충원의 일반전형 이월 정책은 기존 그대로).
-- 사정할 때 쓴 기준값은 decision_runs.cutoffs와 감사 기록에 함께 남긴다.

alter table public.admission_rounds
  add column if not exists final_cutoffs jsonb not null default '{}'::jsonb;
alter table public.decision_runs
  add column if not exists cutoffs jsonb;

comment on column public.admission_rounds.final_cutoffs is
  '최종 사정 합격선·과락선. 키: finalTotal, document, group, interview, writing(값 미만이면 불합격). 빈 객체=미적용.';
comment on column public.decision_runs.cutoffs is '이 사정에 적용된 합격선·과락선(admission_rounds.final_cutoffs 사본).';

-- 슈퍼관리자가 합격선·과락선을 정한다. 최종 사정이 이미 확정된 회차는 바꿀 수 없다.
create or replace function public.set_final_cutoffs(
  p_year int,
  p_round admission_round,
  p_cutoffs jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  k text;
  v jsonb;
  clean jsonb := '{}'::jsonb;
begin
  caller := public._require_superadmin();

  if jsonb_typeof(coalesce(p_cutoffs, '{}'::jsonb)) <> 'object' then
    raise exception '기준값 형식이 올바르지 않습니다.' using errcode = '22023';
  end if;
  for k, v in select key, value from jsonb_each(coalesce(p_cutoffs, '{}'::jsonb))
  loop
    if k not in ('finalTotal', 'document', 'group', 'interview', 'writing') then
      raise exception '알 수 없는 기준입니다: %', k using errcode = '22023';
    end if;
    if v is null or jsonb_typeof(v) = 'null' then
      continue; -- 빈칸 = 미적용
    end if;
    if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 then
      raise exception '% 기준은 0 이상의 숫자여야 합니다.', k using errcode = '22023';
    end if;
    clean := clean || jsonb_build_object(k, v);
  end loop;

  if exists (
    select 1 from public.decision_runs
    where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  ) then
    raise exception '최종 사정이 이미 확정된 회차라 합격선을 바꿀 수 없습니다.' using errcode = '55000';
  end if;

  update public.admission_rounds set final_cutoffs = clean, updated_at = now(), updated_by = caller::text
  where year = p_year and round = p_round;
  if not found then
    raise exception '회차(%, %)를 찾을 수 없습니다.', p_year, p_round using errcode = 'P0002';
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text, 'decision.final.cutoffs_set', 'admission_rounds',
          p_year::text || '_' || p_round::text, jsonb_build_object('cutoffs', clean));

  return clean;
end;
$$;

revoke all on function public.set_final_cutoffs(int, admission_round, jsonb) from public, anon;
grant execute on function public.set_final_cutoffs(int, admission_round, jsonb) to authenticated;

-- 최종 사정: 서버 DB의 현재 정의에 합격선·과락선 적용만 더했다.
CREATE OR REPLACE FUNCTION public.run_final_decision(p_year integer, p_round admission_round, p_mode decision_mode)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_round record;
  quota jsonb;
  q_general int;
  q_incheon int;
  q_social int;
  unfilled_policy text;
  policy_recognized boolean;
  v_run_id uuid;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  incheon_passed int := 0;
  social_passed int := 0;
  general_quota_effective int;
  applicant_row record;
  boundary_rank int;
  v_cut jsonb;
  below_cutoff_count int := 0;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    raise exception '이 라운드에는 확정된 M4 1차 서류사정(document final run)이 없습니다.'
      using errcode = '55000';
  end if;
  if v_round.config_revision_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.' using errcode = '55000';
  end if;
  -- 합격선·과락선(00080). 빈 객체면 지금까지와 똑같이 동작한다.
  v_cut := coalesce(v_round.final_cutoffs, '{}'::jsonb);

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다.' using errcode = '55000';
  end if;

  q_general := (quota ->> 'general')::int;
  q_incheon := (quota ->> 'incheon')::int;
  q_social := (quota ->> 'social')::int;
  unfilled_policy := quota ->> 'unfilledTrackPolicy';
  policy_recognized := unfilled_policy in ('carryToGeneral', 'remainVacant');

  if q_general is null or q_incheon is null or q_social is null then
    raise exception 'config quota.general/incheon/social 값이 올바르지 않습니다: %', quota
      using errcode = '55000';
  end if;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  -- ── 후보 분류: 1차 서류 합격자 전원을 제외/보류/미완료/유효후보로 분류 ──────
  select count(*) into excluded_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  select count(*) into review_pending_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'reviewPending';

  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  -- ── 유효 후보 pool (제외/보류/미완료 아닌 전원, 4영역 complete 확정) ────────
  drop table if exists tmp_candidates;
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    tracks text[],
    final_total numeric,
    deep_group_interview numeric,
    writing numeric,
    essay numeric,
    attendance numeric,
    academic numeric,
    document_score numeric,
    group_score numeric,
    interview_score numeric,
    cutoff_reason text
  ) on commit drop;

  insert into tmp_candidates
  select
    dr.applicant_id, a.tracks, fa.final_total,
    (fa.group_score + fa.interview_student_score + fa.interview_parent_score),
    fa.writing_score,
    (dr.tiebreak_values ->> 'essay')::numeric,
    (dr.tiebreak_values ->> 'attendance')::numeric,
    (dr.tiebreak_values ->> 'academic')::numeric,
    fa.document_score,
    fa.group_score,
    (fa.interview_student_score + fa.interview_parent_score),
    null
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  select count(*) into v_candidate_count from tmp_candidates;

  -- ── 합격선·과락선 적용(00080): 걸린 지원자는 순위 경쟁 전에 불합격 처리 ──────
  -- 기준을 넘은 지원자끼리만 정원을 채우고, 못 채운 자리는 미충원으로 남는다.
  update tmp_candidates c set cutoff_reason = nullif(concat_ws(' · ',
    case when v_cut ? 'finalTotal' and c.final_total < (v_cut ->> 'finalTotal')::numeric
      then format('최종 총점 합격선 미달(%s < %s)', round(c.final_total, 2), v_cut ->> 'finalTotal') end,
    case when v_cut ? 'document' and c.document_score < (v_cut ->> 'document')::numeric
      then format('서류평가 과락(%s < %s)', round(c.document_score, 2), v_cut ->> 'document') end,
    case when v_cut ? 'group' and c.group_score < (v_cut ->> 'group')::numeric
      then format('모둠활동 과락(%s < %s)', round(c.group_score, 2), v_cut ->> 'group') end,
    case when v_cut ? 'interview' and c.interview_score < (v_cut ->> 'interview')::numeric
      then format('면접 과락(%s < %s)', round(c.interview_score, 2), v_cut ->> 'interview') end,
    case when v_cut ? 'writing' and c.writing < (v_cut ->> 'writing')::numeric
      then format('글쓰기 과락(%s < %s)', round(c.writing, 2), v_cut ->> 'writing') end
  ), '')
  -- 모든 후보 행이 대상이지만 WHERE를 명시한다: API 접속(authenticator)에는
  -- pg_safeupdate가 걸려 있어 WHERE 없는 UPDATE를 거부한다.
  where c.applicant_id is not null;
  select count(*) into below_cutoff_count from tmp_candidates where cutoff_reason is not null;

  -- ── 인천학생추천전형 사정 ────────────────────────────────────
  drop table if exists tmp_incheon_result;
  create temp table tmp_incheon_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_incheon_ranked;
  create temp table tmp_incheon_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'incheon' = any(tracks) and cutoff_reason is null;

  select rnk into boundary_rank from tmp_incheon_ranked where rn = q_incheon;

  insert into tmp_incheon_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_incheon_ranked where rnk = boundary_rank and rn > q_incheon)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_incheon) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_incheon_ranked;

  select count(*) into incheon_passed from tmp_incheon_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_incheon_result where outcome = 'manualDecisionRequired');

  -- ── 사회통합전형 사정 (동일 패턴, incheon과 tracks가 겹치지 않으므로 독립) ──
  drop table if exists tmp_social_result;
  create temp table tmp_social_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_social_ranked;
  create temp table tmp_social_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'social' = any(tracks) and cutoff_reason is null;

  boundary_rank := null;
  select rnk into boundary_rank from tmp_social_ranked where rn = q_social;

  insert into tmp_social_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_social_ranked where rnk = boundary_rank and rn > q_social)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_social) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_social_ranked;

  select count(*) into social_passed from tmp_social_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_social_result where outcome = 'manualDecisionRequired');

  -- ── 일반전형 유효 정원 (unfilledTrackPolicy) ────────────────────
  if unfilled_policy = 'carryToGeneral' then
    general_quota_effective := q_general + (q_incheon - incheon_passed) + (q_social - social_passed);
  else
    -- 'remainVacant' 또는 미확정('pending'/기타) — simulation 미리보기는 보수적으로
    -- 이월 없이 기본 정원만 사용한다. final 확정은 policy_recognized=false면 아래에서 차단.
    general_quota_effective := q_general;
  end if;

  -- ── 일반전형 pool: 특별전형에서 이미 passed/manualDecisionRequired인 사람 제외 ──
  drop table if exists tmp_general_result;
  create temp table tmp_general_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_general_ranked;
  create temp table tmp_general_ranked on commit drop as
  select c.applicant_id,
    rank() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                  c.essay desc, c.attendance desc, c.academic desc) as rnk,
    row_number() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                        c.essay desc, c.attendance desc, c.academic desc) as rn
  from tmp_candidates c
  where c.cutoff_reason is null
  and c.applicant_id not in (
    select applicant_id from tmp_incheon_result where outcome in ('passed', 'manualDecisionRequired')
  )
  and c.applicant_id not in (
    select applicant_id from tmp_social_result where outcome in ('passed', 'manualDecisionRequired')
  );

  boundary_rank := null;
  select rnk into boundary_rank from tmp_general_ranked where rn = general_quota_effective;

  insert into tmp_general_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_general_ranked where rnk = boundary_rank and rn > general_quota_effective)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, general_quota_effective) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_general_ranked;

  unresolved_count := unresolved_count
    + (select count(*) from tmp_general_result where outcome = 'manualDecisionRequired');

  -- ── decision_runs 생성 (M4와 동일하게 먼저 running으로 생성) ─────────
  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by, cutoffs)
  values
    (p_year, p_round, 'final', p_mode, 'running', v_round.config_revision_id, caller::text, v_cut)
  returning id into v_run_id;

  -- ── decision_results 기록: 제외자(위원회 exclusion 결정) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, outcome,
     committee_decision_applied, track_result)
  select
    v_run_id, dr.applicant_id, p_year, p_round, 'final', fa.final_total, 'excluded'::decision_outcome, true,
    jsonb_build_object('incheon', 'notApplicable', 'social', 'notApplicable', 'general', 'notApplicable')
  from public.decision_results dr
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  -- ── decision_results 기록: 유효 후보 전원(전형 결합 결과) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values,
     track_result, outcome)
  select
    v_run_id, c.applicant_id, p_year, p_round, 'final', c.final_total,
    coalesce(gr.rnk, ir.rnk, sr.rnk),
    jsonb_build_object(
      'deepGroupInterview', c.deep_group_interview, 'writing', c.writing,
      'essay', c.essay, 'attendance', c.attendance, 'academic', c.academic
    ),
    jsonb_build_object(
      'incheon', case when 'incheon' = any(c.tracks) then ir.outcome else 'notApplicable' end,
      'social', case when 'social' = any(c.tracks) then sr.outcome else 'notApplicable' end,
      'general', coalesce(gr.outcome, 'notApplicable'),
      'cutoffReason', c.cutoff_reason
    ),
    (case
      when c.cutoff_reason is not null then 'failed'
      when ir.outcome = 'manualDecisionRequired' or sr.outcome = 'manualDecisionRequired'
           or gr.outcome = 'manualDecisionRequired' then 'manualDecisionRequired'
      when ir.outcome = 'passed' or sr.outcome = 'passed' or gr.outcome = 'passed' then 'passed'
      else 'failed'
    end)::decision_outcome
  from tmp_candidates c
  left join tmp_incheon_result ir on ir.applicant_id = c.applicant_id
  left join tmp_social_result sr on sr.applicant_id = c.applicant_id
  left join tmp_general_result gr on gr.applicant_id = c.applicant_id;

  select count(*) into v_result_count from public.decision_results where run_id = v_run_id;

  update public.decision_runs
  set candidate_count = v_candidate_count,
      result_count = v_result_count,
      unresolved_tie_count = unresolved_count,
      blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 확정 ─────────────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if incomplete_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '심층역량평가 4영역이 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', incomplete_count;
    end if;
    if review_pending_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '학폭 등 소명 절차가 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', review_pending_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;
    if not policy_recognized then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'config quota.unfilledTrackPolicy가 확정되지 않았습니다(현재: %). 입학전형위원회 결정 후 final 확정이 가능합니다.', unfilled_policy;
    end if;

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'decision.final.finalized', 'decision_runs', v_run_id::text,
            jsonb_build_object('cutoffs', v_cut, 'belowCutoffCount', below_cutoff_count));
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'decision.final.simulated', 'decision_runs', v_run_id::text,
            jsonb_build_object('cutoffs', v_cut, 'belowCutoffCount', below_cutoff_count));
  end if;

  return v_run_id;
end;
$function$;

-- ======================================================================
-- 00081_applicant_registered_mail_and_note.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 우편 접수 등기번호·접수 비고 (2026-10-12)
--
-- 예전 엑셀 접수대장에서는 우편 접수 건의 등기번호를 비고 칸에 적어 두었다.
-- 분실·도착 시점 문의에 대비해 시스템에도 남긴다.
--   registered_mail_no : 우편(등기) 접수 시 등기번호
--   reception_note     : 접수대장 비고(자유 기재)
--
-- register_applicant / update_applicant는 인자가 22개라 손대지 않고, 두 값만
-- 고치는 RPC를 따로 둔다(접수·수정 양식이 저장 직후 이어서 호출).

alter table public.applicants
  add column if not exists registered_mail_no text,
  add column if not exists reception_note text;

create or replace function public.set_applicant_reception_extra(
  p_applicant_id uuid,
  p_registered_mail_no text default null,
  p_reception_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  update public.applicants
  set registered_mail_no = nullif(trim(coalesce(p_registered_mail_no, '')), ''),
      reception_note = nullif(trim(coalesce(p_reception_note, '')), ''),
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id
    and (registered_mail_no is distinct from nullif(trim(coalesce(p_registered_mail_no, '')), '')
      or reception_note is distinct from nullif(trim(coalesce(p_reception_note, '')), ''));

  -- 바뀐 게 있을 때만 기록
  if found then
    insert into public.audit_logs
      (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
    values
      ('user', caller::text, 'applicant.reception_extra_updated', 'applicants',
       p_applicant_id::text, p_applicant_id::text);
  elsif not exists (select 1 from public.applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
end;
$$;

revoke execute on function public.set_applicant_reception_extra(uuid, text, text) from anon;

-- ======================================================================
-- 00082_principal_role_document_view.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — '학교장' 권한 (2026-10-12)
--
-- 교장선생님은 평가 점수는 보지 않되, 지원자 서류는 보고 싶어 하신다.
-- 기존 권한으로는 맞는 게 없다:
--   viewer(열람 전용) → 서류는 못 보고 사정 결과·최종 집계 점수가 보임
--   evaluator         → 채점자로 잡힘, admin → 전부 보임
-- 그래서 principal(학교장) 권한을 새로 둔다.
--   * 지원자 기본 정보(applicants: 이름·전형·출신교·번호) 조회 가능
--   * 연락처·주소(applicants_private)는 조회 불가 — 정책을 주지 않는다
--   * 서류: 관리자 전용(adminOnly)을 뺀 모든 서류 열람(열람 기록은 기존처럼 남는다)
--     위원과 마찬가지로 users.viewable_document_types로 종류를 좁힐 수 있다
--   * 점수·사정 테이블에는 아무 정책도 주지 않으므로 볼 수 없다
--
-- 주의: enum 값 추가는 그 값을 쓰는 문장과 같은 트랜잭션에 있으면 안 된다.
-- psql로 이 파일을 그대로 흘려 넣으면(문장마다 자동 커밋) 문제없다.
-- psql -1 / --single-transaction 으로 돌리지 말 것.

alter type public.app_role add value if not exists 'principal';

-- 지원자 기본 정보 조회
drop policy if exists applicants_select_principal on public.applicants;
create policy applicants_select_principal
  on public.applicants for select
  using (public.is_active_user() and public.has_role('principal'));

-- 서류 열람 규칙(00076)에 학교장 추가
create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator') or public.has_role('principal')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

-- ======================================================================
-- 00083_applicant_basic_list_for_staff.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 지원자 기본 목록 열람(평가위원·정량평가·학교장) (2026-10-13)
--
-- 평가위원·정량평가 위원도 학교장처럼 지원자 목록 정도는 볼 수 있게 한다.
-- 다만 applicants 표를 통째로 열면(RLS는 행 단위라 열을 가릴 수 없음) 가산점·등기번호·
-- 접수 비고 같은 칸까지 보이므로, 필요한 열만 돌려주는 함수로 연다.
--   돌려주는 열: id, 수험번호, 접수번호, 성명, 지원 전형, 학적, 출신 중학교, 접수 상태
--   연락처·주소·보호자(applicants_private)는 여전히 볼 수 없다.
-- 00082에서 학교장에게 준 applicants 표 직접 조회 정책은 이 함수로 대체하고 지운다.

drop policy if exists applicants_select_principal on public.applicants;

create or replace function public.list_applicants_basic(p_year int, p_round admission_round)
returns table (
  id uuid,
  exam_no text,
  receipt_no text,
  name text,
  tracks text[],
  academic_status text,
  school text,
  application_status text
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  perform public._require_any_role(
    array['superadmin','admin','reception','evaluator','quant','principal']::app_role[]
  );
  return query
    select a.id, a.exam_no, a.receipt_no, a.name, a.tracks, a.academic_status, a.school,
           a.application_status::text
    from public.applicants a
    where a.year = p_year and a.round = p_round
      and a.application_status not in ('withdrawn', 'excluded')
    order by a.exam_no nulls last, a.receipt_no;
end;
$$;

revoke execute on function public.list_applicants_basic(int, admission_round) from anon;
grant execute on function public.list_applicants_basic(int, admission_round) to authenticated;

-- ======================================================================
-- 00084_document_result_sms.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 1차(서류평가) 결과 개별 통보 SMS (2026-10-13)
--
-- 요강: "1차 결과 및 2차 대상자 발표 — 개별 통보(SMS)·홈페이지".
-- 최종 결과 문자(00054·00079)와 같은 방식으로, 확정된 1차 사정 결과대로
-- 합격·불합격 안내 문자를 시스템에서 보낸다.
--
-- 안전장치(최종 결과 문자와 동일):
--   * 확정(finalized)된 1차(decision_type='document') 사정 결과만 대상
--   * 합격·불합격 문구는 Edge Function(send-document-result-sms)이 확정 결과를
--     직접 다시 읽어 고른다 — 화면이 판정을 잘못 넘겨도 문구가 뒤바뀌지 않는다
--   * (run, 지원자, 대상)별 발송 이력을 남겨 화면에 "발송완료" 표시, 중복 발송 방지
--   * 이력·감사 로그에 전화번호 원문을 남기지 않는다

create table if not exists public.document_result_sms_log (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.decision_runs(id),
  applicant_id uuid not null references public.applicants(id),
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid not null references public.users(id),
  created_at timestamptz not null default now()
);

create index if not exists document_result_sms_log_run_applicant_idx
  on public.document_result_sms_log (run_id, applicant_id);

comment on table public.document_result_sms_log is
  '1차(서류평가) 결과 개별 통보 SMS 발송 이력. 전화번호 원문은 저장하지 않는다. 직접 SELECT는 막고 RPC로만 조회.';

alter table public.document_result_sms_log enable row level security;
revoke all on public.document_result_sms_log from public, anon, authenticated;

-- 발송 대상: 확정된 1차 사정의 합격·불합격자(합격자 먼저, 수험번호 순)
create or replace function public.get_document_result_sms_recipients(
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
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'document' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 1차 사정 결과가 없습니다. 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'examNo', a.exam_no,
    'name', a.name,
    'outcome', dr.outcome,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.document_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.document_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by (dr.outcome <> 'passed'), a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed');

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$$;

revoke all on function public.get_document_result_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_document_result_sms_recipients(int, admission_round) to authenticated;

-- 발송 결과 기록(Edge Function이 사용자 JWT로 호출)
create or replace function public.record_document_result_sms_sent(
  p_run_id uuid,
  p_applicant_id uuid,
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
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_target not in ('applicant', 'guardian') then
    raise exception 'target은 applicant 또는 guardian이어야 합니다.' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.decision_runs
    where id = p_run_id and decision_type = 'document' and status = 'finalized'
  ) then
    raise exception '확정된 1차 사정(run)만 기록할 수 있습니다.' using errcode = '55000';
  end if;

  insert into public.document_result_sms_log
    (run_id, applicant_id, target, sent, provider_code, provider_message, sent_by)
  values
    (p_run_id, p_applicant_id, p_target, p_sent, p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    ('user', caller::text, 'decision.document.result_sms_sent', 'document_result_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('runId', p_run_id, 'target', p_target, 'sent', p_sent, 'providerCode', p_provider_code));
end;
$$;

revoke all on function public.record_document_result_sms_sent(uuid, uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_document_result_sms_sent(uuid, uuid, text, boolean, text, text) to authenticated;

-- ======================================================================
-- 00085_external_access_sms_mfa.sql
-- ======================================================================

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

-- ======================================================================
-- 00086_mfa_gate_ignore_query.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 교외 인증 관문 고침 (2026-10-13)
--
-- 증상: 교외에서 인증번호를 맞혀도 다시 로그인 화면으로 돌아감.
-- 원인: Caddy forward_auth 가 관문(GET /rest/v1/rpc/mfa_gate)을 부를 때 원래 요청의 주소 뒤
--       조건(?select=*&id=eq.…)이 그대로 따라붙어, PostgREST 가 이를 함수 인자로 보고
--       "그런 인자를 받는 mfa_gate 가 없다"(404)로 거부했다. 그래서 조건이 붙은 조회는 모두 막혔다.
-- 고침: Caddy 는 관문을 ?gate=1 로만 부르고(원래 조건 대신), 함수는 gate 인자를 받아 무시한다.

drop function if exists public.mfa_gate();

create or replace function public.mfa_gate(gate text default null)
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
  -- PT403: PostgREST 가 HTTP 403 으로 돌려준다
  raise exception '교외에서 접속하셨습니다. 휴대폰 인증을 마친 뒤 이용할 수 있습니다.' using errcode = 'PT403';
end;
$$;
grant execute on function public.mfa_gate(text) to anon, authenticated;

-- ======================================================================
-- 00087_interview_display_key.sql
-- ======================================================================

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

-- ======================================================================
-- 00088_interview_call_sms_guardian.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 면접 호출 문자를 보호자 번호로 (2026-10-14)
--
-- 배경: 2027 심층평가 당일 지원자 휴대전화는 사전교육 때 수거한다. 그래서 학생면접 호출(예고·호출)도
--       보호자 번호로 보낸다(Edge Function send-interview-call-sms 가 대상 결정). 보호자 번호가 없으면
--       지원자 번호로 보내고, 그 사실을 로그(fallback_reason)에 남긴다.
-- 바꾸는 것:
--   1) 연락처 조회에 면접 장소·조 이름을 더한다(보호자 문구 "○○로 와 주세요").
--   2) interview_call_sms_log.fallback_reason 열 추가.
--   3) record_interview_call_sms_sent 에 p_fallback_reason 인자(기본 null) 추가 — 예전 형태는 지우고 다시 만든다.

-- 1. 연락처 + 면접 장소
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
  v_team record;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select a.name,
         a.receipt_no,
         r.exam_no,
         p.applicant_phone,
         p.guardian_name,
         p.guardian_phone
  into v_row
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.evaluation_roster r on r.applicant_id = a.id
  where a.id = p_applicant_id;

  if v_row is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select t.team_code, t.location
  into v_team
  from public.interview_schedules s
  join public.interview_teams t on t.id = s.team_id
  where s.year = p_year and s.round = p_round and s.applicant_id = p_applicant_id
  limit 1;

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'name', v_row.name,
    'receiptNo', v_row.receipt_no,
    'examNo', coalesce(v_row.exam_no, v_row.receipt_no),
    'applicantPhone', v_row.applicant_phone,
    'guardianName', v_row.guardian_name,
    'guardianPhone', v_row.guardian_phone,
    'teamCode', v_team.team_code,
    'location', v_team.location
  );
end;
$$;

revoke all on function public.get_interview_call_sms_recipient(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_sms_recipient(int, admission_round, uuid) to authenticated;

-- 2. 로그 열
alter table public.interview_call_sms_log
  add column if not exists fallback_reason text;

comment on column public.interview_call_sms_log.fallback_reason is
  '원래 대상(보호자) 대신 다른 번호로 보낸 이유. 예: 보호자 번호 없음 → 지원자 번호로 발송.';

-- 3. 기록 함수(인자 하나 추가)
drop function if exists public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text);

create or replace function public.record_interview_call_sms_sent(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
  p_section text,
  p_call_type text,
  p_target text,
  p_sent boolean,
  p_provider_code text default null,
  p_provider_message text default null,
  p_fallback_reason text default null
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
     provider_code, provider_message, sent_by, fallback_reason)
  values
    (p_year, p_round, p_applicant_id, p_section, p_call_type, p_target, p_sent,
     p_provider_code, p_provider_message, caller, p_fallback_reason);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.sms_sent',
     'interview_call_sms_log', p_applicant_id::text,
     jsonb_build_object('section', p_section, 'callType', p_call_type,
                        'target', p_target, 'sent', p_sent,
                        'fallbackReason', p_fallback_reason));
end;
$$;

revoke all on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text, text)
  from public, anon;
grant execute on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text, text)
  to authenticated;

-- ======================================================================
-- 00089_group_plan_shifts.sql
-- ======================================================================

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

-- ======================================================================
-- 00090_interview_section_timer.sql
-- ======================================================================

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

-- ======================================================================
-- 00091_evaluation_rubrics.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 서류평가 정성 영역 채점기준표 저장소 (2026-10-16)
--
-- 채점기준표는 대외비다. 화면 코드(자바스크립트)는 로그인 없이도 내려받을 수 있으므로 기준표 문구를
-- 코드에 넣지 않고 이 표에만 둔다. 원문은 저장소에 커밋하지 않는 SQL 파일(supabase/private/)로 넣는다.
--
-- area: 'common'(공통 원칙) / 'essay' / 'opinion' / 'community'
-- 읽기: 관리자, 또는 해당 영역을 배정받은 평가위원·정량위원(학년도 범위 포함).
--       'common'은 essay·opinion·community 중 하나라도 배정된 위원이 읽는다.

create table if not exists public.evaluation_rubrics (
  year int not null,
  area text not null check (area in ('common', 'essay', 'opinion', 'community')),
  content jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'sql',
  primary key (year, area)
);

comment on table public.evaluation_rubrics is
  '서류평가 정성 영역 채점기준표(대외비). get_evaluation_rubric RPC로만 읽는다.';

alter table public.evaluation_rubrics enable row level security;
revoke all on table public.evaluation_rubrics from anon, authenticated;

create or replace function public.get_evaluation_rubric(p_year int, p_area text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_content jsonb;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller and u.active
      and (
        u.roles && array['superadmin', 'admin']::app_role[]
        or (
          u.roles && array['evaluator', 'quant']::app_role[]
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
          and (
            (p_area = 'common' and u.assigned_areas && array['essay', 'opinion', 'community']::evaluation_area[])
            or (p_area in ('essay', 'opinion', 'community') and p_area::evaluation_area = any(u.assigned_areas))
          )
        )
      )
  ) then
    raise exception '이 채점기준표를 볼 권한이 없습니다.' using errcode = '42501';
  end if;

  select content into v_content from public.evaluation_rubrics where year = p_year and area = p_area;
  return v_content; -- 아직 넣지 않았으면 null(화면은 '기준표 미등록'으로 표시)
end;
$$;

revoke all on function public.get_evaluation_rubric(int, text) from public, anon;
grant execute on function public.get_evaluation_rubric(int, text) to authenticated;

-- ======================================================================
-- 00092_community_peer_review.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 공동체 생활 적합성 '상호 검토' 단계 (2026-10-16)
--
-- 채점기준표: "등급을 판정하고 근거를 시스템에 메모(10자 이상)로 남기며, 상호 간 근거와 등급이 맞는지 검토함"
-- 독립 채점 원칙 때문에 평소에는 다른 위원의 등급·메모를 볼 수 없다. 관리자가 '상호 검토'를 연 동안에만,
-- 그 지원자를 이미 제출한 공동체 위원이 같은 지원자의 다른 위원 등급·근거 메모를 볼 수 있다.
-- 등급을 바꿔야 하면 기존 재개방(reopen) 절차로 다시 제출한다(이 단계는 열람만 연다).

create table if not exists public.document_review_settings (
  year int not null,
  round admission_round not null,
  community_peer_review_open boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

comment on table public.document_review_settings is
  '서류평가 운영 설정. community_peer_review_open=true 인 동안만 공동체 위원 간 등급·근거 메모 열람.';

alter table public.document_review_settings enable row level security;
revoke all on table public.document_review_settings from anon, authenticated;

create or replace function public._community_peer_review_open(p_year int, p_round admission_round)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select community_peer_review_open from public.document_review_settings
                   where year = p_year and round = p_round), false);
$$;

revoke all on function public._community_peer_review_open(int, admission_round) from public, anon, authenticated;

-- 1. 관리자: 상호 검토 열기/닫기
create or replace function public.set_community_peer_review(p_year int, p_round admission_round, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  insert into public.document_review_settings (year, round, community_peer_review_open, updated_at, updated_by)
  values (p_year, p_round, p_open, now(), caller::text)
  on conflict (year, round) do update
    set community_peer_review_open = excluded.community_peer_review_open,
        updated_at = now(), updated_by = excluded.updated_by;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text,
          case when p_open then 'community.peer_review.opened' else 'community.peer_review.closed' end,
          'document_review_settings', p_year::text || '_' || p_round::text, '{}'::jsonb);

  return jsonb_build_object('open', p_open);
end;
$$;

revoke all on function public.set_community_peer_review(int, admission_round, boolean) from public, anon;
grant execute on function public.set_community_peer_review(int, admission_round, boolean) to authenticated;

-- 2. 위원: 한 지원자에 대한 다른 위원 등급·메모 (상호 검토가 열려 있고, 본인이 이미 제출한 경우만)
create or replace function public.get_community_peer_review(p_applicant_id uuid)
returns jsonb
language plpgsql
volatile -- 열람 기록(audit_logs)을 남기므로 stable 이 아님
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_is_admin boolean;
  v_items jsonb;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select year, round into v_app from public.applicants where id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select exists (select 1 from public.users where id = caller and active and roles && array['superadmin','admin']::app_role[])
    into v_is_admin;

  if not v_is_admin and not exists (
    select 1 from public.users u
    where u.id = caller and u.active and 'evaluator' = any(u.roles) and 'community' = any(u.assigned_areas)
  ) then
    raise exception '공동체 생활 적합성 위원만 볼 수 있습니다.' using errcode = '42501';
  end if;

  if not public._community_peer_review_open(v_app.year, v_app.round) then
    return jsonb_build_object('open', false);
  end if;

  if not v_is_admin and not exists (
    select 1 from public.scores_community s
    where s.applicant_id = p_applicant_id and s.evaluator_uid = caller and s.submission_state = 'submitted'
  ) then
    return jsonb_build_object('open', true, 'eligible', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'evaluatorName', u.display_name,
           'mine', s.evaluator_uid = caller,
           'grade', (s.inputs ->> 'grade')::int,
           'score', s.server_computed -> 'score',
           'memo', s.inputs ->> 'evidenceMemo',
           'submittedAt', s.submitted_at
         ) order by s.submitted_at), '[]'::jsonb)
    into v_items
  from public.scores_community s
  join public.users u on u.id = s.evaluator_uid
  where s.applicant_id = p_applicant_id and s.submission_state = 'submitted';

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values (v_app.year, v_app.round, 'user', caller::text, 'community.peer_review.viewed',
          'scores_community', p_applicant_id::text, p_applicant_id::text, '{}'::jsonb);

  return jsonb_build_object('open', true, 'eligible', true, 'items', v_items);
end;
$$;

revoke all on function public.get_community_peer_review(uuid) from public, anon;
grant execute on function public.get_community_peer_review(uuid) to authenticated;

-- 3. 관리자: 상호 검토 현황판(등급이 갈린 지원자 먼저)
create or replace function public.get_community_review_board(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);

  select coalesce(jsonb_agg(x.item order by x.mismatch desc, x.exam_no nulls last, x.display_name), '[]'::jsonb)
    into v_items
  from (
    select r.exam_no, r.display_name,
           count(distinct (s.inputs ->> 'grade')) > 1 as mismatch,
           jsonb_build_object(
             'applicantId', r.applicant_id,
             'examNo', r.exam_no,
             'displayName', r.display_name,
             'mismatch', count(distinct (s.inputs ->> 'grade')) > 1,
             'gradeGap', max((s.inputs ->> 'grade')::int) - min((s.inputs ->> 'grade')::int),
             'submissions', jsonb_agg(jsonb_build_object(
               'evaluatorName', u.display_name,
               'grade', (s.inputs ->> 'grade')::int,
               'memo', s.inputs ->> 'evidenceMemo'
             ) order by s.submitted_at)
           ) as item
    from public.scores_community s
    join public.evaluation_roster r on r.applicant_id = s.applicant_id
    join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
    group by r.applicant_id, r.exam_no, r.display_name
  ) x;

  return jsonb_build_object(
    'open', public._community_peer_review_open(p_year, p_round),
    'items', v_items
  );
end;
$$;

revoke all on function public.get_community_review_board(int, admission_round) from public, anon;
grant execute on function public.get_community_review_board(int, admission_round) to authenticated;

-- ======================================================================
-- 00093_document_scoring_quality.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 서류평가 중간 점검용 채점 품질 집계 (2026-10-16)
--
-- 채점기준표 Ⅴ 운영: "중간 점검(10. 23., 10. 30.) — 편차 경보가 잦은 기준과 모든 기준이 같은 점수인
-- 채점을 확인하고, 필요하면 위원 협의를 거침"
--   · 위원별: 제출 건수, 모든 기준을 같은 점수로 준 건수
--   · 기준별: 평균, 위원 간 점수 차가 큰 지원자 수(자기소개서 3점 이상, 소견서 1.5점 이상)
-- 지원자 이름·수험번호는 내보내지 않는다(기준 해석 협의용 집계만).

create or replace function public.get_document_scoring_quality(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb := '{}'::jsonb;
  v_area text;
  v_gap numeric;
  v_evaluators jsonb;
  v_criteria jsonb;
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);

  foreach v_area in array array['essay', 'opinion'] loop
    v_gap := case when v_area = 'essay' then 3 else 1.5 end;

    execute format($q$
      with s as (
        select applicant_id, evaluator_uid, items
        from public.%I
        where year = $1 and round = $2 and submission_state = 'submitted'
      ),
      per_eval as (
        select s.evaluator_uid,
               count(*) as submitted,
               count(*) filter (where (select count(distinct (v)::numeric) from jsonb_each_text(s.items) e(k, v)) = 1) as all_same
        from s group by s.evaluator_uid
      )
      select coalesce(jsonb_agg(jsonb_build_object(
               'evaluatorName', u.display_name, 'submitted', p.submitted, 'allSame', p.all_same)
             order by p.all_same desc, u.display_name), '[]'::jsonb)
      from per_eval p join public.users u on u.id = p.evaluator_uid
    $q$, 'scores_' || v_area)
    into v_evaluators using p_year, p_round;

    execute format($q$
      with s as (
        select applicant_id, evaluator_uid, items
        from public.%I
        where year = $1 and round = $2 and submission_state = 'submitted'
      ),
      cells as (
        select s.applicant_id, e.k as criterion, (e.v)::numeric as score
        from s cross join lateral jsonb_each_text(s.items) e(k, v)
      ),
      per_app as (
        select criterion, applicant_id, max(score) - min(score) as gap, count(*) as n
        from cells group by criterion, applicant_id
      )
      select coalesce(jsonb_agg(jsonb_build_object(
               'key', c.criterion,
               'avg', round(c.avg_score, 2),
               'wideGapCount', c.wide,
               'applicantCount', c.apps)
             order by c.wide desc, c.criterion), '[]'::jsonb)
      from (
        select a.criterion,
               (select avg(score) from cells x where x.criterion = a.criterion) as avg_score,
               count(*) filter (where a.n >= 2 and a.gap >= $3) as wide,
               count(*) filter (where a.n >= 2) as apps
        from per_app a group by a.criterion
      ) c
    $q$, 'scores_' || v_area)
    into v_criteria using p_year, p_round, v_gap;

    v_result := v_result || jsonb_build_object(v_area, jsonb_build_object(
      'gapThreshold', v_gap, 'evaluators', v_evaluators, 'criteria', v_criteria));
  end loop;

  return v_result;
end;
$$;

revoke all on function public.get_document_scoring_quality(int, admission_round) from public, anon;
grant execute on function public.get_document_scoring_quality(int, admission_round) to authenticated;

-- ======================================================================
-- 00094_server_time.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 서버 시각 조회 (2026-10-19)
-- 머리글에 서버 시각을 보여 주기 위한 아주 작은 RPC. 기기 시계가 틀려도 접수 마감(17:00) 등을
-- 서버 기준으로 볼 수 있게 한다. 화면은 응답 왕복 시간의 절반을 보정해 기기 시계와의 차이를 계산한다.

create or replace function public.get_server_time()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

revoke all on function public.get_server_time() from public, anon;
grant execute on function public.get_server_time() to authenticated;

-- ======================================================================
-- 00095_storage_limit_200mb.sql
-- ======================================================================

-- 서류 저장소 한 파일 한도 25MB → 200MB (2026-10-20)
-- 스캔 서류(컬러·300dpi 이상)가 25MB를 쉽게 넘는다. 화질을 낮추는 압축 대신 한도를 올린다.
-- 서류 업로드는 서버 PC에서 교내 주소(https://local.example.org)로만 한다(2026-10-20 결정).
-- 교외 주소(ipsi)는 Cloudflare 터널을 지나 요청당 100MB 제한이 있으므로, 화면에서 95MB 넘는 파일은 교내 주소로 안내한다.
-- ※ 저장소 서비스 자체 한도(storage 컨테이너 FILE_SIZE_LIMIT)도 200MB 이상이어야 한다.
update storage.buckets
set file_size_limit = 209715200
where id = 'admission-documents';

select id, file_size_limit from storage.buckets where id = 'admission-documents';

-- ======================================================================
-- 00096_certificates.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 심층역량평가 대상 확인서 · 합격증서 발급 (2026-10-20)
--
-- 학교에서 인쇄해 전달한다(우편·직접). 발급할 때마다 발급대장에 남기고, 번호는 처음 발급할 때 매긴다.
--   심층역량평가 대상 확인서(deep_eligibility): 1차 사정이 '확정'된 뒤, 그 결과의 합격자만   — 번호 2027-심층-001
--   합격증서(final_pass)                     : 최종 사정이 '확정'된 뒤, 그 결과의 합격자만   — 번호 2027-A-PASS-001
--   두 경우 모두 지원 철회·제외(합격 취소·등록 포기 포함 처리)된 지원자는 뽑을 수 없다.
-- 번호는 학년도·종류별로 이어서 센다(추가모집 회차도 같은 순번을 이어 쓴다 — 번호가 겹치지 않게).
-- 처음 발급하는 사람들끼리는 수험번호 순으로 번호를 받는다. 다시 뽑으면 번호는 그대로, 인쇄 횟수만 는다.

create table if not exists public.certificate_issuances (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  kind text not null check (kind in ('deep_eligibility', 'final_pass')),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  serial int not null check (serial > 0),
  cert_no text not null unique,
  first_issued_at timestamptz not null default now(),
  first_issued_by uuid references public.users (id),
  last_printed_at timestamptz not null default now(),
  last_printed_by uuid references public.users (id),
  print_count int not null default 1,
  unique (year, round, kind, applicant_id),
  unique (year, kind, serial)
);

comment on table public.certificate_issuances is
  '확인서·합격증서 발급대장. 번호(cert_no)는 첫 발급 때 정해지고 바뀌지 않는다. RPC로만 읽고 쓴다.';

alter table public.certificate_issuances enable row level security;
revoke all on table public.certificate_issuances from anon, authenticated;

-- 대상자(확정 결과의 합격자, 철회·제외 제외). 확정 전이면 오류.
create or replace function public._certificate_target_ids(p_year int, p_round admission_round, p_kind text)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_run uuid;
begin
  if p_kind = 'deep_eligibility' then
    select document_decision_run_id into v_run
    from public.admission_rounds where year = p_year and round = p_round;
    if v_run is null then
      raise exception '1차 사정이 아직 확정되지 않았습니다. 확정한 뒤에 심층역량평가 대상 확인서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  elsif p_kind = 'final_pass' then
    select id into v_run
    from public.decision_runs
    where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
    order by finalized_at desc
    limit 1;
    if v_run is null then
      raise exception '최종 사정이 아직 확정되지 않았습니다. 확정한 뒤에 합격증서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  else
    raise exception '알 수 없는 증서 종류입니다: %', p_kind using errcode = '22023';
  end if;

  return query
    select dr.applicant_id
    from public.decision_results dr
    join public.applicants a on a.id = dr.applicant_id
    where dr.run_id = v_run
      and dr.outcome = 'passed'
      and a.application_status not in ('withdrawn', 'excluded');
end;
$$;

revoke all on function public._certificate_target_ids(int, admission_round, text) from public, anon, authenticated;

create or replace function public._certificate_items(p_year int, p_round admission_round, p_kind text, p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'applicantId', a.id,
           'examNo', a.exam_no,
           'name', a.name,
           'nameEnglish', a.name_english,
           'nationality', a.nationality,
           'birthDate', p.birth_date,
           'tracks', a.tracks,
           'school', a.school,
           'academicStatus', a.academic_status,
           'certNo', ci.cert_no,
           'printCount', coalesce(ci.print_count, 0),
           'firstIssuedAt', ci.first_issued_at,
           'lastPrintedAt', ci.last_printed_at
         ) order by a.exam_no nulls last, a.name), '[]'::jsonb)
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.certificate_issuances ci
    on ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind
  where a.id = any(p_ids);
$$;

revoke all on function public._certificate_items(int, admission_round, text, uuid[]) from public, anon, authenticated;

-- 1. 대상 목록(발급 여부·번호 포함). 확정 전이면 ready=false + 사유.
create or replace function public.list_certificate_targets(p_year int, p_round admission_round, p_kind text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);
  begin
    select array_agg(t) into v_ids from public._certificate_target_ids(p_year, p_round, p_kind) t;
  exception when sqlstate '55000' then
    return jsonb_build_object('ready', false, 'reason', sqlerrm);
  end;
  return jsonb_build_object('ready', true, 'items', public._certificate_items(p_year, p_round, p_kind, coalesce(v_ids, '{}')));
end;
$$;

revoke all on function public.list_certificate_targets(int, admission_round, text) from public, anon;
grant execute on function public.list_certificate_targets(int, admission_round, text) to authenticated;

-- 2. 발급(인쇄 직전에 부른다): 처음이면 번호를 매기고, 이미 있으면 인쇄 횟수만 늘린다.
create or replace function public.issue_certificates(p_year int, p_round admission_round, p_kind text, p_applicant_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_bad int;
  v_next int;
  v_new int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);
  if p_applicant_ids is null or cardinality(p_applicant_ids) = 0 then
    raise exception '발급할 지원자를 고르세요.' using errcode = '22023';
  end if;

  -- 대상이 아닌 지원자가 섞였는지(확정 전이면 여기서 오류)
  select count(*) into v_bad
  from unnest(p_applicant_ids) x(id)
  where x.id not in (select t from public._certificate_target_ids(p_year, p_round, p_kind) t);
  if v_bad > 0 then
    raise exception '발급 대상이 아닌 지원자가 %명 섞여 있습니다(확정 결과의 합격자만, 철회·제외 제외).', v_bad using errcode = '42501';
  end if;

  -- 같은 종류 번호를 동시에 매기지 않게
  perform pg_advisory_xact_lock(hashtextextended(format('cert:%s:%s', p_year, p_kind), 0));

  select coalesce(max(serial), 0) + 1 into v_next
  from public.certificate_issuances where year = p_year and kind = p_kind;

  for r in
    select a.id
    from public.applicants a
    where a.id = any(p_applicant_ids)
      and not exists (
        select 1 from public.certificate_issuances ci
        where ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind)
    order by a.exam_no nulls last, a.name
  loop
    insert into public.certificate_issuances
      (year, round, kind, applicant_id, serial, cert_no, first_issued_by, last_printed_by)
    values
      (p_year, p_round, p_kind, r.id, v_next,
       case when p_kind = 'deep_eligibility'
            then format('%s-심층-%s', p_year, lpad(v_next::text, 3, '0'))
            else format('%s-A-PASS-%s', p_year, lpad(v_next::text, 3, '0')) end,
       caller, caller);
    v_next := v_next + 1;
    v_new := v_new + 1;
  end loop;

  update public.certificate_issuances
  set print_count = print_count + 1, last_printed_at = now(), last_printed_by = caller
  where year = p_year and round = p_round and kind = p_kind
    and applicant_id = any(p_applicant_ids)
    and first_issued_at < now(); -- 이번에 새로 만든 행(now() 동일)은 1회 그대로

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text, 'certificate.issued.' || p_kind, 'certificate_issuances',
          p_year::text || '_' || p_round::text,
          jsonb_build_object('count', cardinality(p_applicant_ids), 'newlyNumbered', v_new));

  return jsonb_build_object(
    'issuedAt', now(),
    'items', public._certificate_items(p_year, p_round, p_kind, p_applicant_ids)
  );
end;
$$;

revoke all on function public.issue_certificates(int, admission_round, text, uuid[]) from public, anon;
grant execute on function public.issue_certificates(int, admission_round, text, uuid[]) to authenticated;

-- ======================================================================
-- 00097_certificate_deep_attendance.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 심층역량평가 응시 확인서 (2026-10-21)
--
-- 중학교 출석 인정 제출용. 요청한 학생만 개별 발급한다.
--   대상: 2차 당일 입실 기록(deep_checkins)이 있는 지원자. 응시한 사실은 그 뒤 철회·제외와 무관하므로 상태로 거르지 않는다.
--   번호: 2027-응시-001 (학년도·종류별 연번, 첫 발급 때 정해져 바뀌지 않음)
-- 00096의 발급대장·RPC에 종류(deep_attendance)를 하나 더한다.

alter table public.certificate_issuances drop constraint if exists certificate_issuances_kind_check;
alter table public.certificate_issuances
  add constraint certificate_issuances_kind_check check (kind in ('deep_eligibility', 'final_pass', 'deep_attendance'));

create or replace function public._certificate_target_ids(p_year int, p_round admission_round, p_kind text)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_run uuid;
begin
  if p_kind = 'deep_attendance' then
    if not exists (select 1 from public.deep_checkins where year = p_year and round = p_round) then
      raise exception '아직 심층역량평가 입실 기록이 없습니다. 당일 입실 확인(바코드)을 한 학생만 응시 확인서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
    return query
      select c.applicant_id from public.deep_checkins c
      where c.year = p_year and c.round = p_round;
    return;
  elsif p_kind = 'deep_eligibility' then
    select document_decision_run_id into v_run
    from public.admission_rounds where year = p_year and round = p_round;
    if v_run is null then
      raise exception '1차 사정이 아직 확정되지 않았습니다. 확정한 뒤에 심층역량평가 대상 확인서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  elsif p_kind = 'final_pass' then
    select id into v_run
    from public.decision_runs
    where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
    order by finalized_at desc
    limit 1;
    if v_run is null then
      raise exception '최종 사정이 아직 확정되지 않았습니다. 확정한 뒤에 합격증서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  else
    raise exception '알 수 없는 증서 종류입니다: %', p_kind using errcode = '22023';
  end if;

  return query
    select dr.applicant_id
    from public.decision_results dr
    join public.applicants a on a.id = dr.applicant_id
    where dr.run_id = v_run
      and dr.outcome = 'passed'
      and a.application_status not in ('withdrawn', 'excluded');
end;
$$;

revoke all on function public._certificate_target_ids(int, admission_round, text) from public, anon, authenticated;

-- 항목에 입실 시각(checkedInAt)을 더한다
create or replace function public._certificate_items(p_year int, p_round admission_round, p_kind text, p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'applicantId', a.id,
           'examNo', a.exam_no,
           'name', a.name,
           'nameEnglish', a.name_english,
           'nationality', a.nationality,
           'birthDate', p.birth_date,
           'tracks', a.tracks,
           'school', a.school,
           'academicStatus', a.academic_status,
           'checkedInAt', dc.checked_in_at,
           'certNo', ci.cert_no,
           'printCount', coalesce(ci.print_count, 0),
           'firstIssuedAt', ci.first_issued_at,
           'lastPrintedAt', ci.last_printed_at
         ) order by a.exam_no nulls last, a.name), '[]'::jsonb)
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.deep_checkins dc on dc.applicant_id = a.id and dc.year = p_year and dc.round = p_round
  left join public.certificate_issuances ci
    on ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind
  where a.id = any(p_ids);
$$;

revoke all on function public._certificate_items(int, admission_round, text, uuid[]) from public, anon, authenticated;

-- 발급: 번호 형식에 '응시'를 더한 것 말고는 00096과 같다
create or replace function public.issue_certificates(p_year int, p_round admission_round, p_kind text, p_applicant_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_bad int;
  v_next int;
  v_new int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);
  if p_applicant_ids is null or cardinality(p_applicant_ids) = 0 then
    raise exception '발급할 지원자를 고르세요.' using errcode = '22023';
  end if;

  select count(*) into v_bad
  from unnest(p_applicant_ids) x(id)
  where x.id not in (select t from public._certificate_target_ids(p_year, p_round, p_kind) t);
  if v_bad > 0 then
    raise exception '발급 대상이 아닌 지원자가 %명 섞여 있습니다.', v_bad using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('cert:%s:%s', p_year, p_kind), 0));

  select coalesce(max(serial), 0) + 1 into v_next
  from public.certificate_issuances where year = p_year and kind = p_kind;

  for r in
    select a.id
    from public.applicants a
    where a.id = any(p_applicant_ids)
      and not exists (
        select 1 from public.certificate_issuances ci
        where ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind)
    order by a.exam_no nulls last, a.name
  loop
    insert into public.certificate_issuances
      (year, round, kind, applicant_id, serial, cert_no, first_issued_by, last_printed_by)
    values
      (p_year, p_round, p_kind, r.id, v_next,
       format('%s-%s-%s', p_year,
              case p_kind when 'deep_eligibility' then '심층' when 'deep_attendance' then '응시' else 'A-PASS' end,
              lpad(v_next::text, 3, '0')),
       caller, caller);
    v_next := v_next + 1;
    v_new := v_new + 1;
  end loop;

  update public.certificate_issuances
  set print_count = print_count + 1, last_printed_at = now(), last_printed_by = caller
  where year = p_year and round = p_round and kind = p_kind
    and applicant_id = any(p_applicant_ids)
    and first_issued_at < now();

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text, 'certificate.issued.' || p_kind, 'certificate_issuances',
          p_year::text || '_' || p_round::text,
          jsonb_build_object('count', cardinality(p_applicant_ids), 'newlyNumbered', v_new));

  return jsonb_build_object(
    'issuedAt', now(),
    'items', public._certificate_items(p_year, p_round, p_kind, p_applicant_ids)
  );
end;
$$;

revoke all on function public.issue_certificates(int, admission_round, text, uuid[]) from public, anon;
grant execute on function public.issue_certificates(int, admission_round, text, uuid[]) to authenticated;

-- ======================================================================
-- 00098_checkin_time_correction.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 입실 시각 고치기 · 수기 입실 등록 (2026-10-21)
--
-- 당일 행정 사유(접수처 대기, 바코드 불량, 수험표 미지참 등)로 스캔이 늦거나 못 찍은 경우를 위해.
--   · 고치기: 이미 있는 입실 기록의 시각만 바꾼다. 같은 날 안에서만. 처음 스캔 시각은 original_checked_in_at에 남긴다.
--   · 수기 등록: 미입실 대상자를 시각을 넣어 입실 처리한다(method = 'manual').
--   · 둘 다 사유 필수(2자 이상), 미래 시각 금지, 감사 기록(checkin.corrected / checkin.manual)에 이전·이후 시각과 사유를 남긴다.
--   · 응시 확인서를 이미 뽑았으면 certificateIssued = true를 돌려준다(화면에서 다시 인쇄 안내).

alter table public.deep_checkins add column if not exists original_checked_in_at timestamptz;
alter table public.deep_checkins add column if not exists corrected_at timestamptz;
alter table public.deep_checkins add column if not exists corrected_by uuid references public.users (id);
alter table public.deep_checkins add column if not exists correction_reason text;

alter table public.deep_checkins drop constraint if exists deep_checkins_method_check;
alter table public.deep_checkins
  add constraint deep_checkins_method_check check (method in ('exam_no', 'receipt_no', 'manual'));

comment on column public.deep_checkins.original_checked_in_at is '시각을 처음 고치기 전의 원래 스캔 시각(고친 적 없으면 null)';
comment on column public.deep_checkins.correction_reason is '마지막으로 고치거나 수기 등록한 사유';

-- 1. 입실 시각 고치기
create or replace function public.set_checkin_time(p_applicant_id uuid, p_checked_in_at timestamptz, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_issued boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '고치는 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_checked_in_at is null or p_checked_in_at > now() + interval '1 minute' then
    raise exception '아직 오지 않은 시각으로는 고칠 수 없습니다.' using errcode = '22023';
  end if;

  select * into v_row from public.deep_checkins where applicant_id = p_applicant_id for update;
  if v_row.applicant_id is null then
    raise exception '입실 기록이 없습니다. 수기 입실 등록을 쓰세요.' using errcode = 'P0002';
  end if;

  if (p_checked_in_at at time zone 'Asia/Seoul')::date
     <> (coalesce(v_row.original_checked_in_at, v_row.checked_in_at) at time zone 'Asia/Seoul')::date then
    raise exception '입실 날짜는 바꿀 수 없습니다(같은 날 안에서 시각만 고칠 수 있습니다).' using errcode = '22023';
  end if;

  update public.deep_checkins
  set original_checked_in_at = coalesce(original_checked_in_at, checked_in_at),
      checked_in_at = p_checked_in_at,
      corrected_at = now(),
      corrected_by = caller,
      correction_reason = v_reason
  where applicant_id = p_applicant_id;

  select exists (
    select 1 from public.certificate_issuances
    where applicant_id = p_applicant_id and kind = 'deep_attendance'
  ) into v_issued;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_row.year, v_row.round, 'user', caller::text, 'checkin.corrected', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('from', v_row.checked_in_at, 'to', p_checked_in_at,
                        'original', coalesce(v_row.original_checked_in_at, v_row.checked_in_at),
                        'reason', v_reason, 'certificateIssued', v_issued));

  return jsonb_build_object('checkedInAt', p_checked_in_at, 'certificateIssued', v_issued);
end;
$$;

revoke all on function public.set_checkin_time(uuid, timestamptz, text) from public, anon;
grant execute on function public.set_checkin_time(uuid, timestamptz, text) to authenticated;

-- 2. 수기 입실 등록(대상자만)
create or replace function public.manual_checkin(p_applicant_id uuid, p_checked_in_at timestamptz, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '수기 등록 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_checked_in_at is null or p_checked_in_at > now() + interval '1 minute' then
    raise exception '아직 오지 않은 시각으로는 등록할 수 없습니다.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not (v_app.evaluation_stage in ('documentPassed', 'deep') and v_app.application_status not in ('withdrawn', 'excluded')) then
    raise exception '2차 심층역량평가 대상이 아닙니다.' using errcode = '42501';
  end if;
  if exists (select 1 from public.deep_checkins where applicant_id = p_applicant_id) then
    raise exception '이미 입실 기록이 있습니다. 시각 고치기를 쓰세요.' using errcode = '23505';
  end if;

  insert into public.deep_checkins
    (applicant_id, year, round, checked_in_at, checked_in_by, method, corrected_at, corrected_by, correction_reason)
  values
    (p_applicant_id, v_app.year, v_app.round, p_checked_in_at, caller, 'manual', now(), caller, v_reason);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'checkin.manual', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('checkedInAt', p_checked_in_at, 'reason', v_reason));

  return jsonb_build_object('checkedInAt', p_checked_in_at, 'certificateIssued', false);
end;
$$;

revoke all on function public.manual_checkin(uuid, timestamptz, text) from public, anon;
grant execute on function public.manual_checkin(uuid, timestamptz, text) to authenticated;

-- 3. 입실 현황에 고친 내역을 더한다
create or replace function public.get_checkin_status(
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
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id,
        'examNo', a.exam_no,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'eligible', a.evaluation_stage in ('documentPassed', 'deep')
          and a.application_status not in ('withdrawn', 'excluded'),
        'checkedInAt', c.checked_in_at,
        'method', c.method,
        'originalCheckedInAt', c.original_checked_in_at,
        'correctedAt', c.corrected_at,
        'correctionReason', c.correction_reason
      ) order by coalesce(a.exam_no, a.receipt_no))
      from public.applicants a
      left join public.deep_checkins c on c.applicant_id = a.id
      where a.year = p_year and a.round = p_round
        and (
          (a.evaluation_stage in ('documentPassed', 'deep') and a.application_status not in ('withdrawn', 'excluded'))
          or c.applicant_id is not null
        )
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_checkin_status(int, admission_round) from public, anon;
grant execute on function public.get_checkin_status(int, admission_round) to authenticated;

-- ======================================================================
-- 00099_applicant_quick_lookup.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — QR·번호로 지원자 빠른 조회 (2026-10-21)
--
-- 어느 화면에서든 접수증·수험표·화일 표지의 QR(접수번호/수험번호)을 찍으면 지원자 카드를 띄운다.
--   · 조회 전용: 입실 처리 등 아무 기록도 바꾸지 않는다(입실은 입실 확인 화면에서만).
--   · 최고관리자·관리자·접수 담당만. 평가위원(블라인드 평가)에게는 열지 않는다.
--   · 접수 담당에게는 접수 정보·서류 현황만, 평가 진행 상황(1차·최종 결과, 입실)은 관리자에게만.
--   · 생년월일·성별·연락처는 돌려주지 않는다(필요하면 지원자 정보 창에서).
--   · 조회할 때마다 감사 기록(applicant.lookup)을 남긴다.

create or replace function public.lookup_applicant_by_code(p_year int, p_round admission_round, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_app record;
  v_method text;
  v_admin boolean;
  v_docs jsonb;
  v_checked timestamptz;
begin
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  v_admin := exists (
    select 1 from public.users u
    where u.id = caller and u.roles && array['superadmin', 'admin']::app_role[]
  );

  if v_code = '' then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  -- 지금 차수 먼저, 없으면 같은 학년도 다른 차수
  select a.* into v_app from public.applicants a
  where a.year = p_year and (upper(a.exam_no) = v_code or upper(a.receipt_no) = v_code)
  order by (a.round = p_round) desc
  limit 1;

  if v_app.id is null then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, metadata)
    values (p_year, p_round, 'user', caller::text, 'applicant.lookup.not_found', 'applicants',
            jsonb_build_object('code', v_code));
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  v_method := case when upper(v_app.exam_no) = v_code then 'exam_no' else 'receipt_no' end;

  select coalesce(jsonb_agg(distinct d.document_type), '[]'::jsonb) into v_docs
  from public.admission_documents d
  where d.applicant_id = v_app.id and d.active = true;

  if v_admin then
    select checked_in_at into v_checked from public.deep_checkins where applicant_id = v_app.id;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.lookup', 'applicants',
     v_app.id::text, v_app.id::text, jsonb_build_object('method', v_method));

  return jsonb_build_object(
    'found', true,
    'code', v_code,
    'method', v_method,
    'scope', case when v_admin then 'admin' else 'reception' end,
    'applicant', jsonb_build_object(
      'applicantId', v_app.id,
      'year', v_app.year,
      'round', v_app.round,
      'receiptNo', v_app.receipt_no,
      'examNo', v_app.exam_no,
      'name', v_app.name,
      'tracks', to_jsonb(v_app.tracks),
      'school', v_app.school,
      'academicStatus', v_app.academic_status,
      'receiptDate', v_app.receipt_date,
      'receiptMethod', v_app.receipt_method,
      'applicationStatus', v_app.application_status,
      'documents', v_docs,
      'applicationFormDocId', (
        select d.id from public.admission_documents d
        where d.applicant_id = v_app.id and d.document_type = 'applicationForm' and d.active = true
        order by d.uploaded_at desc limit 1),
      -- 아래는 관리자에게만
      'evaluationStage', case when v_admin then v_app.evaluation_stage end,
      'checkedInAt', v_checked
    )
  );
end;
$$;

revoke all on function public.lookup_applicant_by_code(int, admission_round, text) from public, anon;
grant execute on function public.lookup_applicant_by_code(int, admission_round, text) to authenticated;

-- ======================================================================
-- 00100_change_receipt_date.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 접수일 바꾸기(우편 도착일 소급) + 접수번호 다시 매기기 (2026-10-25)
--
-- 접수번호 = YYMMDD + 전형코드 + 순번(접수일·전형별). 접수일을 바꾸면 번호도 그 날짜 기준으로 다시 매긴다.
--   · 쓰는 경우: 등기가 전날 도착했는데 다음 날 입력한 경우 등 — 도착일로 소급.
--   · 새 번호는 바꾼 날짜·같은 전형의 '다음 순번'(그날 마지막 번호 뒤). 예전 번호는 비어 있는 번호로 남고 다시 쓰지 않는다.
--   · 접수 시각(시:분)은 그대로 두고 날짜만 바꾼다.
--   · 수험번호가 부여되기 전에만. 미래 날짜·같은 날짜는 막는다. 사유 필수.
--   · 최고관리자·관리자만. 감사 기록(applicant.receipt_date_changed)에 이전·새 번호/날짜와 사유를 남긴다.
--   · 00050에서 접수일·접수번호를 '불변'으로 두었던 것을 이 RPC 한 곳으로만 바꿀 수 있게 연다.
-- 바꾼 뒤에는 접수증·화일 표지를 다시 출력해야 한다(번호가 바뀜).

create or replace function public.change_receipt_date(p_applicant_id uuid, p_date date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old_date date;
  v_new_at timestamptz;
  v_track_code text;
  v_new_no text;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '접수일을 바꾸는 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_date is null then
    raise exception '바꿀 날짜를 고르세요.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id for update;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_app.exam_no is not null then
    raise exception '수험번호가 이미 부여되어 접수일을 바꿀 수 없습니다.' using errcode = '55000';
  end if;
  if v_app.receipt_no like 'T%' then
    raise exception '전·편입 지원자는 이 기능을 쓰지 않습니다.' using errcode = '22023';
  end if;

  v_old_date := (v_app.receipt_date at time zone 'Asia/Seoul')::date;
  if p_date = v_old_date then
    raise exception '지금 접수일과 같은 날짜입니다.' using errcode = '22023';
  end if;
  if p_date > (now() at time zone 'Asia/Seoul')::date then
    raise exception '앞으로 올 날짜로는 바꿀 수 없습니다.' using errcode = '22023';
  end if;

  -- 시:분은 그대로, 날짜만 바꾼다(한국 시간 기준)
  v_new_at := (p_date + (v_app.receipt_date at time zone 'Asia/Seoul')::time) at time zone 'Asia/Seoul';

  v_track_code := case
    when 'incheon' = any(v_app.tracks) then 'I'
    when 'social'  = any(v_app.tracks) then 'U'
    else 'G'
  end;
  v_new_no := public._allocate_receipt_no(v_app.year, v_app.round, v_track_code, v_new_at);

  update public.applicants
  set receipt_no = v_new_no, receipt_date = v_new_at, updated_at = now(), updated_by = caller::text
  where id = p_applicant_id;

  update public.evaluation_roster
  set receipt_no = v_new_no, updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.receipt_date_changed', 'applicants',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('oldReceiptNo', v_app.receipt_no, 'newReceiptNo', v_new_no,
                        'oldReceiptDate', v_app.receipt_date, 'newReceiptDate', v_new_at,
                        'reason', v_reason));

  return jsonb_build_object('receiptNo', v_new_no, 'receiptDate', v_new_at, 'oldReceiptNo', v_app.receipt_no);
end;
$$;

revoke all on function public.change_receipt_date(uuid, date, text) from public, anon;
grant execute on function public.change_receipt_date(uuid, date, text) to authenticated;

-- ======================================================================
-- 00101_renumber_receipt_for_tracks.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 지원 전형을 고친 뒤 접수번호 다시 매기기 (2026-10-25)
--
-- 접수번호 가운데 글자는 전형코드(G 일반 / I 일반+인천학생추천 / U 일반+사회통합)다.
-- 접수 때 전형 체크를 빠뜨려 지원자 정보에서 전형을 고치면(update_applicant), 번호의 전형코드와 실제 전형이 어긋난다.
-- 이 RPC는 지금 전형에 맞는 코드로, 같은 접수일·그 전형의 다음 순번을 새로 매긴다.
--   · 예) 261023G001 (인천추천 체크 누락) → 전형 고침 → 261023I004
--   · 접수일은 그대로. 예전 번호는 빈 번호로 남고 다시 쓰지 않는다.
--   · 수험번호 부여 전만, 최고관리자·관리자만, 사유 필수, 감사 기록(applicant.receipt_no_renumbered).

create or replace function public.renumber_receipt_for_tracks(p_applicant_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_code text;
  v_new_no text;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '접수번호를 다시 매기는 사유를 적어 주세요.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id for update;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_app.exam_no is not null then
    raise exception '수험번호가 이미 부여되어 접수번호를 바꿀 수 없습니다.' using errcode = '55000';
  end if;
  if v_app.receipt_no !~ '^\d{6}[GIUMV]\d{3}$' then
    raise exception '이 접수번호(%)는 다시 매길 수 없는 형식입니다.', v_app.receipt_no using errcode = '22023';
  end if;

  v_code := case
    when 'incheon' = any(v_app.tracks) then 'I'
    when 'social'  = any(v_app.tracks) then 'U'
    else 'G'
  end;
  if substr(v_app.receipt_no, 7, 1) = v_code then
    raise exception '접수번호가 이미 지금 전형(%)과 맞습니다. 먼저 지원자 정보에서 전형을 고치세요.', v_code using errcode = '22023';
  end if;

  -- 같은 접수일(한국 시간) 기준으로 새 전형의 다음 순번
  v_new_no := public._allocate_receipt_no(v_app.year, v_app.round, v_code, v_app.receipt_date);

  update public.applicants
  set receipt_no = v_new_no, updated_at = now(), updated_by = caller::text
  where id = p_applicant_id;

  update public.evaluation_roster
  set receipt_no = v_new_no, updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.receipt_no_renumbered', 'applicants',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('oldReceiptNo', v_app.receipt_no, 'newReceiptNo', v_new_no,
                        'tracks', to_jsonb(v_app.tracks), 'reason', v_reason));

  return jsonb_build_object('receiptNo', v_new_no, 'oldReceiptNo', v_app.receipt_no);
end;
$$;

revoke all on function public.renumber_receipt_for_tracks(uuid, text) from public, anon;
grant execute on function public.renumber_receipt_for_tracks(uuid, text) to authenticated;

-- ======================================================================
-- 00102_document_transcriptions.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 자기소개서·학부모 소견서 입력본(문항별 받아 적기) (2026-10-25)
--
-- 손글씨 자기소개서(서식 2, 9문항)·학부모 소견서(서식 3, 7문항)를 접수 담당·관리자가 문항별로 받아 적어 두면,
-- 서류 열람·채점 화면에서 위원이 원본 옆에 '입력본'으로 볼 수 있다.
--   · 입력: 최고관리자·관리자·접수 담당. 저장하면 바로 위원에게 보인다(검수 단계 없음, 2026-10-25 결정).
--   · 접수 담당은 받아 적기 위해 자기소개서·소견서 원본도 열람한다(_can_access_document_v2 보완).
--   · 열람: 위 세 역할 + 그 서류 종류를 열람할 수 있는 위원(평가위원·정량평가·학교장 — 00076/00082 규칙 그대로).
--   · 원문 그대로 옮긴다(맞춤법을 고치지 않음, 읽을 수 없는 글자는 [판독불가]). 원본과 다르면 원본이 우선.
--   · 저장할 때마다 이력(document_transcription_history)을 남긴다. 1차 사정이 확정된 뒤에는 관리자만 고칠 수 있다.
--   · 위원이 입력본을 열면 서류 열람과 같이 감사 기록(transcription.viewed)을 남긴다.

-- 0. 접수 담당도 자기소개서·학부모 소견서 원본을 열람(받아 적기용). 나머지 규칙은 00082 그대로.
create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  -- 2026-10-25(00102): 접수 담당이 자기소개서·학부모 소견서를 받아 적으려면 원본을 봐야 한다
  if p_document_type in ('essay', 'opinion') and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator') or public.has_role('principal')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

create table if not exists public.document_transcriptions (
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  document_type text not null check (document_type in ('essay', 'opinion')),
  answers jsonb not null default '{}'::jsonb,   -- {"1": "…", "2": "…"}
  completed boolean not null default false,     -- 입력 담당이 '입력 끝'으로 표시
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users (id),
  primary key (applicant_id, document_type)
);

create table if not exists public.document_transcription_history (
  id bigserial primary key,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  document_type text not null,
  answers jsonb not null,
  completed boolean not null,
  saved_at timestamptz not null default now(),
  saved_by uuid references public.users (id)
);
create index if not exists document_transcription_history_idx
  on public.document_transcription_history (applicant_id, document_type, saved_at desc);

alter table public.document_transcriptions enable row level security;
alter table public.document_transcription_history enable row level security;
revoke all on public.document_transcriptions from anon, authenticated;
revoke all on public.document_transcription_history from anon, authenticated;

-- 1. 읽기
create or replace function public.get_document_transcription(p_applicant_id uuid, p_document_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff boolean;
  v_row record;
  v_app record;
begin
  if not public.is_active_user() then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if p_document_type not in ('essay', 'opinion') then
    raise exception '입력본이 없는 서류 종류입니다.' using errcode = '22023';
  end if;

  v_staff := public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception');
  if not v_staff and not public._can_access_document_v2(
       p_applicant_id, p_document_type::document_type, 'evaluation'::document_classification, '{}'::evaluation_area[]) then
    raise exception '이 서류를 열람할 권한이 없습니다.' using errcode = '42501';
  end if;

  select * into v_row from public.document_transcriptions
  where applicant_id = p_applicant_id and document_type = p_document_type;

  if not v_staff and v_row.applicant_id is not null then
    select year, round into v_app from public.applicants where id = p_applicant_id;
    insert into public.audit_logs
      (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
    values
      (v_app.year, v_app.round, 'user', auth.uid()::text, 'transcription.viewed', 'document_transcriptions',
       p_applicant_id::text || ':' || p_document_type, p_applicant_id::text);
  end if;

  if v_row.applicant_id is null then
    return jsonb_build_object('exists', false);
  end if;
  return jsonb_build_object(
    'exists', true,
    'answers', v_row.answers,
    'completed', v_row.completed,
    'updatedAt', v_row.updated_at
  );
end;
$$;

revoke all on function public.get_document_transcription(uuid, text) from public, anon;
grant execute on function public.get_document_transcription(uuid, text) to authenticated;

-- 2. 저장(통째로 덮어쓰기 + 이력)
create or replace function public.save_document_transcription(
  p_applicant_id uuid, p_document_type text, p_answers jsonb, p_completed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_clean jsonb := '{}'::jsonb;
  k text;
  v text;
  v_max int;
begin
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  if p_document_type not in ('essay', 'opinion') then
    raise exception '입력본이 없는 서류 종류입니다.' using errcode = '22023';
  end if;
  v_max := case p_document_type when 'essay' then 9 else 7 end;

  select a.id, a.year, a.round into v_app from public.applicants a where a.id = p_applicant_id;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  -- 1차 사정이 확정된 뒤에는 관리자만
  if exists (select 1 from public.admission_rounds r
             where r.year = v_app.year and r.round = v_app.round and r.document_decision_run_id is not null)
     and not (public.has_role('superadmin') or public.has_role('admin')) then
    raise exception '1차 사정이 확정되어 입력본은 관리자만 고칠 수 있습니다.' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_answers, '{}'::jsonb)) <> 'object' then
    raise exception '입력 형식이 올바르지 않습니다.' using errcode = '22023';
  end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_answers, '{}'::jsonb)) loop
    if k !~ '^[0-9]+$' or k::int < 1 or k::int > v_max then
      raise exception '없는 문항 번호입니다: %', k using errcode = '22023';
    end if;
    if char_length(v) > 20000 then
      raise exception '%번 문항이 너무 깁니다.', k using errcode = '22023';
    end if;
    if btrim(v) <> '' then
      v_clean := v_clean || jsonb_build_object(k, v);
    end if;
  end loop;

  insert into public.document_transcriptions (applicant_id, document_type, answers, completed, updated_at, updated_by)
  values (p_applicant_id, p_document_type, v_clean, coalesce(p_completed, false), now(), caller)
  on conflict (applicant_id, document_type) do update
    set answers = excluded.answers, completed = excluded.completed, updated_at = now(), updated_by = caller;

  insert into public.document_transcription_history (applicant_id, document_type, answers, completed, saved_by)
  values (p_applicant_id, p_document_type, v_clean, coalesce(p_completed, false), caller);

  return jsonb_build_object('savedAt', now(), 'filled', (select count(*) from jsonb_object_keys(v_clean)));
end;
$$;

revoke all on function public.save_document_transcription(uuid, text, jsonb, boolean) from public, anon;
grant execute on function public.save_document_transcription(uuid, text, jsonb, boolean) to authenticated;

-- 3. 입력 현황(접수 담당 이상)
create or replace function public.list_transcription_status(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'applicantId', a.id,
      'receiptNo', a.receipt_no,
      'examNo', a.exam_no,
      'name', a.name,
      'hasEssay', exists (select 1 from public.admission_documents d where d.applicant_id = a.id and d.document_type = 'essay' and d.active),
      'hasOpinion', exists (select 1 from public.admission_documents d where d.applicant_id = a.id and d.document_type = 'opinion' and d.active),
      'essay', (select jsonb_build_object('filled', (select count(*) from jsonb_object_keys(t.answers)), 'completed', t.completed, 'updatedAt', t.updated_at)
                from public.document_transcriptions t where t.applicant_id = a.id and t.document_type = 'essay'),
      'opinion', (select jsonb_build_object('filled', (select count(*) from jsonb_object_keys(t.answers)), 'completed', t.completed, 'updatedAt', t.updated_at)
                  from public.document_transcriptions t where t.applicant_id = a.id and t.document_type = 'opinion')
    ) order by coalesce(a.exam_no, a.receipt_no))
    from public.applicants a
    where a.year = p_year and a.round = p_round and a.application_status not in ('withdrawn', 'excluded')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_transcription_status(int, admission_round) from public, anon;
grant execute on function public.list_transcription_status(int, admission_round) to authenticated;

-- ======================================================================
-- 00103_term_stage_wording.sql
-- ======================================================================

-- 새봄고 입학전형 시스템 — 용어 통일: '1차/2차' → '1단계/2단계' (2026-10-26)
--
-- 화면·문자는 프론트에서 바꿨고, 여기서는 DB 함수가 돌려주는 안내·오류 문구를 바꾼다.
-- 함수마다 다시 쓰지 않고, 지금 정의(pg_get_functiondef)에서 문구만 바꿔 그대로 다시 만든다
-- (CREATE OR REPLACE라 권한·인자·동작은 그대로).
--   바꾸는 것: 1차 사정 / 1차 서류(사정·평가·전형) / 1차 결과 / 1차 합격 / 1차 순위 / 1차 대상 / 2차 심층 / 2차 대상
--   안 바꾸는 것: '추가모집(1차)·(2차)' 같은 모집 회차 이름(뒤에 위 낱말이 오지 않으므로 걸리지 않음)
-- 바뀐 함수 이름은 NOTICE로 보여 준다. 두 번 실행해도 안전하다(바꿀 게 없으면 건너뜀).

do $$
declare
  r record;
  v_def text;
  v_new text;
  v_count int := 0;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosrc ~ '[12]차 ?(사정|서류|결과|합격|순위|대상|심층)'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, '([12])차( ?)(사정|서류|결과|합격|순위|대상|심층)', '\1단계\2\3', 'g');
    if v_new <> v_def then
      execute v_new;
      v_count := v_count + 1;
      raise notice '문구 바꿈: %', r.proname;
    end if;
  end loop;
  raise notice '함수 %개의 문구를 바꿨습니다.', v_count;
end $$;

-- ======================================================================
-- 00104_staff_polls.sql
-- ======================================================================

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

NOTIFY pgrst, 'reload schema';
