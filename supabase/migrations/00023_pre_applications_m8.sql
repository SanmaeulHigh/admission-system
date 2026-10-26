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
