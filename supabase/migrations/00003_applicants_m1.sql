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
