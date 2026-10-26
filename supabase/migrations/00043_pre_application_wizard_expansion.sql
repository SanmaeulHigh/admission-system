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
