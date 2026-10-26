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
