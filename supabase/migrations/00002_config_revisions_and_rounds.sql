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
