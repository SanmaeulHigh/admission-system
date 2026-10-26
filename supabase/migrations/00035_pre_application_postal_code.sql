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
