-- 새봄고 입학전형 시스템 — M8b 24시간 PDF 정리 방식 수정 (회귀 테스트 실행 중 발견된 버그)
--
-- 문제: 00028의 _cleanup_expired_pre_application_bundles()는
-- "delete from storage.objects where ..."로 24시간 지난 병합 PDF를 직접
-- 지우도록 만들어져 있었다. 그런데 Supabase가 storage.objects에
-- protect_delete() 트리거를 걸어놔서 SQL로 직접 DELETE하는 것 자체를
-- 전면 차단한다:
--   ERROR: 42501: Direct deletion from storage tables is not allowed.
--   Use the Storage API instead.
-- 즉 00028 이후 매시 정각 실행된 pg_cron 잡이 실제로는 매번 이 오류로
-- 조용히(사람이 안 보고 있으면 못 알아챌 정도로) 실패해왔다 — 병합 PDF가
-- 24시간 뒤에도 전혀 지워지지 않고 있었다는 뜻이다.
--
-- 원인: storage.objects 메타데이터 행만 지우면 실제 파일(S3 백엔드)이
-- 고아 상태로 남기 때문에, Supabase는 메타데이터+실제 파일을 함께 지우는
-- Storage API(스토리지 REST 엔드포인트, supabase-js의 storage.remove())를
-- 통해서만 삭제를 허용한다.
--
-- 수정 방향: SQL에서는 "무엇을 지울지 목록만 고르고", 실제 삭제는
-- cleanup-expired-bundles Edge Function이 Storage API로 수행하게 한다.
--   1. list_expired_pre_application_bundle_paths() — SELECT만, DELETE 없음.
--   2. _cleanup_expired_pre_application_bundles() — pg_net으로 Edge Function을
--      비동기 호출하도록 재정의(같은 이름 유지 — pg_cron 잡 재등록 불필요).
--
-- ⚠️ 실행 전/후 액션 아이템(담당 교사이 직접 해야 함 — 8/9절과 동일 성격):
--   1) pg_net 확장이 꺼져 있으면 Supabase 대시보드 → Database → Extensions에서
--      "pg_net"을 먼저 켜야 할 수 있다(pg_cron 때와 동일한 이유).
--   2) 이 마이그레이션 실행 후, SQL Editor에서 아래 두 값을 Vault에 등록한다
--      (원문은 git에 올리지 않는다):
--
--        select vault.create_secret(
--          'https://<프로젝트-ref>.supabase.co/functions/v1',
--          'pre_application_edge_functions_base_url',
--          'M8b cleanup-expired-bundles Edge Function base URL'
--        );
--
--        select vault.create_secret(
--          '<32바이트 이상의 무작위 문자열>',
--          'pre_application_cron_secret',
--          'M8b cleanup-expired-bundles 호출 인증용 공유 비밀'
--        );
--
--      무작위 값은 select encode(gen_random_bytes(32), 'base64'); 로 만든다.
--   3) 같은 pre_application_cron_secret 값을 Edge Function 환경변수로도 설정
--      한다(터미널에서):
--        supabase secrets set PRE_APPLICATION_CRON_SECRET=<위와 동일한 값>
--   4) cleanup-expired-bundles Edge Function을 배포한다(아래 8절 참고).

-- ============================================================
-- 1. pg_net 확장
-- ============================================================

create extension if not exists pg_net;

-- ============================================================
-- 2. 정리 대상 경로만 골라주는 RPC (DELETE 없음)
-- ============================================================

create or replace function public.list_expired_pre_application_bundle_paths()
returns text[]
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(array_agg(name), array[]::text[])
  from storage.objects
  where bucket_id = 'pre-application-bundles'
    and created_at < now() - interval '24 hours';
$$;

revoke execute on function public.list_expired_pre_application_bundle_paths()
  from public, anon, authenticated;

comment on function public.list_expired_pre_application_bundle_paths() is
  '실제 삭제는 하지 않는다 — storage.objects 직접 DELETE는 Supabase가 차단한다
   ("Direct deletion from storage tables is not allowed. Use the Storage API
   instead."). cleanup-expired-bundles Edge Function이 이 목록을 받아
   storage.remove()(Storage API)로 실제 삭제한다(00032).';

-- ============================================================
-- 3. _cleanup_expired_pre_application_bundles 재정의
--    (더 이상 DELETE하지 않는다 — pg_net으로 Edge Function을 비동기 호출)
-- ============================================================

create or replace function public._cleanup_expired_pre_application_bundles()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  base_url text;
  cron_secret text;
begin
  select decrypted_secret into base_url
  from vault.decrypted_secrets
  where name = 'pre_application_edge_functions_base_url';

  select decrypted_secret into cron_secret
  from vault.decrypted_secrets
  where name = 'pre_application_cron_secret';

  if base_url is null or cron_secret is null then
    raise exception 'Vault에 pre_application_edge_functions_base_url/pre_application_cron_secret이 없습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;

  -- 비동기(fire-and-forget) 호출 — 응답을 기다리지 않는다. 실행 결과는
  -- Edge Function 로그(cleanup-expired-bundles) 또는 net._http_response
  -- 테이블에서 확인할 수 있다.
  perform net.http_post(
    url => base_url || '/cleanup-expired-bundles',
    body => '{}'::jsonb,
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cron_secret
    ),
    timeout_milliseconds => 10000
  );
end;
$$;

comment on function public._cleanup_expired_pre_application_bundles() is
  'pg_cron 전용(매시 정각). 더 이상 storage.objects를 직접 DELETE하지 않는다
   (Supabase가 차단 — 00032 상단 주석 참고). 대신 pg_net으로
   cleanup-expired-bundles Edge Function을 비동기 호출하고, 그 함수가
   list_expired_pre_application_bundle_paths()로 목록을 받아 storage.remove()
   (Storage API)로 실제 삭제한다. 기존 cron.job(00028에서 등록, 매시 정각)은
   함수 이름이 그대로라 재등록할 필요 없다.';
