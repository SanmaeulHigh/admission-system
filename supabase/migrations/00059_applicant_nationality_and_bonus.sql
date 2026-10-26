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
