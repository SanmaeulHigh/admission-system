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
