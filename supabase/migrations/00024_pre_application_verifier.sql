-- 새봄고 입학전형 시스템 — M8 조회코드 verifier·잠금 로직 (Sprint 1B #2)
-- 마스터 스펙 v1.2 섹션 3.4(preApplicationSecrets), 1330행 M8 보안 불변 원칙 대응.
-- `M8_아키텍처_결정_2026-07-10.md` 3.4 대응.
--
-- 이번 마이그레이션 범위(7절 스프린트 분해 2번): "Edge Function 없이도 RPC
-- 레벨에서 먼저 단위 검증 가능"한 조회코드 verifier + 잠금 로직만. 실제
-- 익명(anon) 호출 경로(Edge Function + Turnstile)는 3번 단계에서 붙인다.
-- 그때까지 이 함수들은 anon/authenticated에서 호출 불가 — postgres/service_role
-- 에서만 (SQL Editor로 직접 단위 테스트 가능, Edge Function은 service_role로
-- 동일하게 호출할 예정).
--
-- 불변조건(결정 문서 9절 재확인):
--   3. 6자리 조회코드는 원문 미저장, pepper 기반 HMAC verifier만 저장.
--   4. 5회 연속 인증실패 → 10분 잠금. 실패 사유(존재안함/이름불일치/코드불일치)는
--      공개 응답에서 구분하지 않는다 — 이 함수들도 결과를 boolean 하나로만
--      돌려주고, 실패 종류에 따라 다른 값/에러를 던지지 않는다.
--
-- 액션 아이템(담당 교사이 직접 해야 함 — Claude가 대신 못 함, 결정 문서 8절과 동일 성격):
--   (최초 시도했던 "alter database ... set app.settings.xxx"는 Supabase 호스팅
--   프로젝트에서 권한 오류로 막힌다 — DB 전역 GUC는 클라이언트가 못 바꾼다.
--   대신 Supabase 공식 비밀값 저장소인 Vault 확장을 쓴다.)
--
--   SQL Editor에서 딱 1회만 실행(pepper 값 자체는 git에 올리지 말 것):
--
--     select vault.create_secret(
--       '<32바이트 이상의 무작위 문자열>',
--       'pre_application_pepper',
--       'M8 조회코드 HMAC pepper'
--     );
--
--   무작위 값은 이 마이그레이션 실행 후 SQL Editor에서
--     select encode(gen_random_bytes(32), 'base64');
--   로 만들어서 그대로 위 문장에 붙여넣으면 된다.
--
--   미설정 시 verify/set 함수가 조용히 넘어가지 않고 바로 예외를 던지도록
--   만들어뒀다(약한 기본값으로 동작하는 것보다 안전).

-- ============================================================
-- 1. pgcrypto 확장 (hmac 함수용)
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 2. pepper 조회 helper — Supabase Vault에서 읽는다.
--    (미설정 시 조용히 넘어가지 않고 예외 — 위 액션 아이템 참고)
-- ============================================================

create or replace function public._pre_application_pepper()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pepper text;
begin
  select decrypted_secret into pepper
  from vault.decrypted_secrets
  where name = 'pre_application_pepper'
  limit 1;

  if pepper is null or length(pepper) < 16 then
    raise exception 'Vault에 pre_application_pepper 비밀값이 없거나 너무 짧습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;
  return pepper;
end;
$$;

revoke execute on function public._pre_application_pepper() from public, anon, authenticated;

-- ============================================================
-- 3. 조회코드 해시 helper (HMAC-SHA256 + pepper, hex 인코딩)
-- ============================================================

create or replace function public._hash_pre_application_code(raw_code text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select encode(hmac(raw_code, public._pre_application_pepper(), 'sha256'), 'hex');
$$;

revoke execute on function public._hash_pre_application_code(text) from public, anon, authenticated;

-- ============================================================
-- 4. 이벤트 기록 helper (내부 전용 — 원문 개인정보 복제 금지)
-- ============================================================

create or replace function public._record_pre_application_event(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_event_type text,
  p_actor_type text,
  p_actor_uid uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.pre_application_events
    (pre_application_id, pre_application_no, event_type, actor_type, actor_uid, metadata, function_version)
  values
    (p_pre_application_id, p_pre_application_no, p_event_type, p_actor_type, p_actor_uid, p_metadata, 'v1');
end;
$$;

revoke execute on function public._record_pre_application_event(uuid, text, text, text, uuid, jsonb) from public, anon, authenticated;

-- ============================================================
-- 5. 조회코드 설정 (createPreApplication에서 사용 — 3번 단계에서 호출)
--    호출자가 6자리 원문을 만들어 넘기면, 여기서 해시만 저장하고 원문은
--    반환하지 않는다(원문은 완료 화면에 1회만 보여주고 저장하지 않음).
-- ============================================================

create or replace function public.set_pre_application_access_code(
  p_pre_application_id uuid,
  p_raw_code text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_raw_code is null or p_raw_code !~ '^[0-9]{6}$' then
    raise exception '조회코드는 6자리 숫자여야 합니다.';
  end if;

  insert into public.pre_application_secrets
    (pre_application_id, access_code_verifier, verifier_version, failed_attempts, locked_until, last_failed_at)
  values
    (p_pre_application_id, public._hash_pre_application_code(p_raw_code), 1, 0, null, null)
  on conflict (pre_application_id) do update set
    access_code_verifier = excluded.access_code_verifier,
    verifier_version = public.pre_application_secrets.verifier_version + 1,
    failed_attempts = 0,
    locked_until = null,
    last_failed_at = null;
end;
$$;

revoke execute on function public.set_pre_application_access_code(uuid, text) from public, anon, authenticated;

-- ============================================================
-- 6. 조회 인증 — 임시접수번호 + 성명 + 6자리 조회코드
--    성공/실패 boolean만 반환. 실패 사유(미존재/이름불일치/코드불일치/잠금)는
--    호출자에게 절대 구분해서 알려주지 않는다(결정 문서 9절 4번).
--    내부 이벤트 로그에는 감사 목적으로 사유를 남기되, 원문 개인정보는 넣지 않는다.
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
  -- 대상 pre_application + private + secrets를 한 번에 잠금 조회
  -- (FOR UPDATE로 동시 요청 간 failed_attempts 경합을 막는다)
  select pa.id, pa.pre_application_no, pp.name
  into app_row
  from public.pre_applications pa
  join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    -- 존재하지 않음 — 잠글 secrets 행 자체가 없으므로 실패만 기록하고 반환.
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
    -- 데이터 정합성 이상(사전작성은 있는데 secrets가 없음) — 역시 일반 실패로 처리
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.failed', 'applicant',
      null, jsonb_build_object('reason', 'no_secret_row'));
    return false;
  end if;

  -- 잠금 상태면 코드 검증 자체를 하지 않고 즉시 실패(추가 시도로 잠금이
  -- 갱신되지 않도록 failed_attempts도 건드리지 않는다)
  if sec_row.locked_until is not null and sec_row.locked_until > now() then
    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.locked_attempt', 'applicant',
      null, jsonb_build_object('lockedUntil', sec_row.locked_until));
    return false;
  end if;

  name_ok := trim(app_row.name) = trim(p_name);
  code_ok := sec_row.access_code_verifier = public._hash_pre_application_code(p_raw_code);

  if name_ok and code_ok then
    update public.pre_application_secrets
    set failed_attempts = 0, locked_until = null, last_failed_at = null
    where pre_application_id = app_row.id;

    perform public._record_pre_application_event(
      app_row.id, app_row.pre_application_no, 'preApplication.auth.succeeded', 'applicant');
    return true;
  end if;

  -- 실패: 시도 횟수 증가. 5회 도달 시 10분 잠금(결정 문서 9절 4번).
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
  '반환값은 boolean 하나뿐이며 실패 사유를 절대 노출하지 않는다. 이 함수를 감싸는 Edge Function(3번 단계)도 이 원칙을 그대로 지켜야 한다 — 사유별로 다른 HTTP 상태코드/메시지를 만들지 말 것.';
