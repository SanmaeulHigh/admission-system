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
