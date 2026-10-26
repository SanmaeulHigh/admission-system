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
