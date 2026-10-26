-- 새봄고 입학전형 시스템 — M8c 파기 후 상태조회 가능하도록 수정 (회귀 테스트 작성 중 발견된 버그)
--
-- 문제: 00029 get_pre_application_status는 "private 행이 파기된 뒤에도 입력한
-- 성명으로 마스킹해 응답한다"는 fallback을 갖고 있었지만, 인증을 담당하는
-- 00024 verify_pre_application_access가 pre_applications_private를 INNER JOIN
-- 하기 때문에 private 행이 삭제되면(=30일 자동 파기 이후) 인증 자체가 무조건
-- 실패해서 그 fallback에 절대 도달하지 못했다 — 즉 파기 후에는 지원자가 정확한
-- 이름/조회코드를 입력해도 상태조회가 완전히 막히는 버그였다.
--
-- 결정: 파기 후에도 "접수기간 만료"라는 최소 상태는 조회 가능해야 한다(제품
-- 결정, 2026-07-10). 다만 파기의 목적(주소·연락처·보호자 등 민감정보 삭제)은
-- 그대로 지킨다 — 이름은 원문이 아니라 해시로만 남겨서 이름 검증을 계속
-- 가능하게 하고, 조회코드 검증에 필요한 pre_application_secrets는 이제 파기
-- 시점에 삭제하지 않는다(주소/연락처/보호자 등 민감정보가 아니므로).
--
-- 변경 사항:
--   1. pre_applications.purged_name_hash 컬럼 추가(파기 시점에만 채워짐).
--   2. _hash_pre_application_name(name) — 조회코드 해시와 동일한 pepper/HMAC
--      방식으로 성명을 해시. 원문 복원 불가.
--   3. verify_pre_application_access를 LEFT JOIN으로 바꿔 private이 없어도
--      진행하고, private.name이 없으면 purged_name_hash와 비교한다.
--   4. _purge_expired_pre_applications: private 삭제 *직전*에 이름을 해시로
--      저장. pre_application_secrets는 더 이상 삭제하지 않는다(조회코드 검증을
--      계속 쓸 수 있어야 하므로 — 5회 실패시 10분 잠금 로직도 계속 유효).

-- ============================================================
-- 1. 컬럼 추가
-- ============================================================

alter table public.pre_applications
  add column if not exists purged_name_hash text;

comment on column public.pre_applications.purged_name_hash is
  '30일 자동 파기로 pre_applications_private.name이 삭제된 뒤에도 상태조회
   인증(verify_pre_application_access)이 이름을 확인할 수 있도록 남겨두는
   해시. 원문 성명은 복원 불가(HMAC + pepper, 00024와 동일 방식).';

-- ============================================================
-- 2. 성명 해시 helper
-- ============================================================

create or replace function public._hash_pre_application_name(p_name text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select encode(hmac(trim(coalesce(p_name, '')), public._pre_application_pepper(), 'sha256'), 'hex');
$$;

revoke execute on function public._hash_pre_application_name(text) from public, anon, authenticated;

-- ============================================================
-- 3. verify_pre_application_access 재정의 (LEFT JOIN + 해시 fallback)
-- ============================================================

create or replace function public.verify_pre_application_access(
  p_pre_application_no text,
  p_name text,
  p_raw_code text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  sec_row record;
  name_ok boolean;
  code_ok boolean;
begin
  -- private이 파기돼 없어도(=purged_name_hash로 대체 검증) 진행할 수 있도록
  -- INNER JOIN 대신 LEFT JOIN으로 바꾼다.
  select pa.id, pa.pre_application_no, pp.name, pa.purged_name_hash
  into app_row
  from public.pre_applications pa
  left join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    perform public._record_pre_application_event(
      null, p_pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'not_found'));
    return false;
  end if;

  select * into sec_row
  from public.pre_application_secrets
  where pre_application_id = app_row.id
  for update;

  if sec_row is null then
    -- private/secrets 둘 다 없는 데이터 정합성 이상 — 일반 실패로 처리
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'no_secret_row'));
    return false;
  end if;

  if sec_row.locked_until is not null and sec_row.locked_until > now() then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.locked_attempt', 'applicant',
      null, jsonb_build_object('lockedUntil', sec_row.locked_until));
    return false;
  end if;

  if app_row.name is not null then
    name_ok := trim(app_row.name) = trim(p_name);
  elsif app_row.purged_name_hash is not null then
    -- 파기 후: 원문 이름 대신 해시로 비교.
    name_ok := app_row.purged_name_hash = public._hash_pre_application_name(p_name);
  else
    name_ok := false;
  end if;

  code_ok := sec_row.access_code_verifier = public._hash_pre_application_code(p_raw_code);

  if name_ok and code_ok then
    update public.pre_application_secrets
    set failed_attempts = 0, locked_until = null, last_failed_at = null
    where pre_application_id = app_row.id;

    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.succeeded', 'applicant');
    return true;
  end if;

  update public.pre_application_secrets
  set failed_attempts = sec_row.failed_attempts + 1,
      last_failed_at = now(),
      locked_until = case
        when sec_row.failed_attempts + 1 >= 5 then now() + interval '10 minutes'
        else locked_until
      end
  where pre_application_id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
    null,
    jsonb_build_object(
      'reason', case when not name_ok and not code_ok then 'name_and_code_mismatch'
                     when not name_ok then 'name_mismatch'
                     else 'code_mismatch' end,
      'failedAttempts', sec_row.failed_attempts + 1
    ));

  return false;
end;
$$;

revoke execute on function public.verify_pre_application_access(text, text, text) from public, anon, authenticated;

comment on function public.verify_pre_application_access(text, text, text) is
  '반환값은 boolean 하나뿐이며 실패 사유를 절대 노출하지 않는다. 파기(30일 경과)
   이후에는 pre_applications_private.name 대신 pre_applications.purged_name_hash로
   이름을 검증한다(00031) — 조회코드 검증은 pre_application_secrets를 그대로 쓴다
   (파기 시점에 더 이상 삭제하지 않음).';

-- ============================================================
-- 4. _purge_expired_pre_applications 재정의 (이름 해시 저장 + secrets 보존)
-- ============================================================

create or replace function public._purge_expired_pre_applications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  v_name text;
begin
  for rec in
    select id, pre_application_no
    from public.pre_applications
    where status not in ('converted', 'expired')
      and expires_at < now()
    for update skip locked
  loop
    select name into v_name
    from public.pre_applications_private
    where pre_application_id = rec.id;

    update public.pre_applications
    set status = 'expired',
        purged_name_hash = case
          when v_name is not null then public._hash_pre_application_name(v_name)
          else purged_name_hash
        end
    where id = rec.id;

    delete from public.pre_applications_private where pre_application_id = rec.id;
    -- pre_application_secrets는 의도적으로 유지한다(00031) — 조회코드
    -- 검증(access_code_verifier)과 5회 실패 잠금 로직이 파기 후에도 계속
    -- 동작해야 상태조회(get_pre_application_status)가 가능하다. 주소·연락처·
    -- 보호자 등 실제 민감정보는 pre_applications_private 삭제만으로 충분히
    -- 제거된다 — 조회코드 해시는 원문 복원이 불가능하므로 민감정보로 보지
    -- 않는다(00024와 동일한 판단).

    perform public._record_pre_application_event(
      rec.id, rec.pre_application_no, 'preApplication.purged', 'system'
    );
  end loop;
end;
$$;

comment on function public._purge_expired_pre_applications() is
  'pg_cron 전용. expires_at은 create_pre_application 시점에 이미
   "접수마감+30일"로 계산돼 있다(00025). private(주소·연락처·보호자 등)은
   삭제하되 이름은 해시로만 남기고(purged_name_hash), 조회코드 secrets는
   삭제하지 않는다(00031) — 파기 후에도 최소 상태("접수기간 만료")는
   지원자 본인이 조회할 수 있어야 하기 때문.';
