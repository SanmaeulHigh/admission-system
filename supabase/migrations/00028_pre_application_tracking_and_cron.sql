-- 새봄고 입학전형 시스템 — M8b/c 마무리: 등기 발송정보 등록 + 자동 파기/정리 (Sprint 1B #5 후반부)
-- 마스터 스펙 1389행 M8c(등기 발송정보 등록), `M8_아키텍처_결정_2026-07-10.md` 3.6/3.7 대응.
--
-- 이번 마이그레이션 범위:
--   1. register_pre_application_tracking_number RPC — 등기우편(receipt_method='M')
--      선택자만 등기번호를 등록할 수 있다. registerTrackingNumber Edge Function이
--      호출한다.
--   2. pg_cron 자동 정리 2건:
--      a) 임시 PDF 24시간 삭제(3.6) — pre-application-bundles 버킷 오브젝트
--      b) 미전환 사전작성 30일 후 자동 파기(3.7, Sprint 1B DoD) — 이미
--         expires_at 자체가 "접수마감+30일" 시점으로 계산되어 있으므로
--         (00025 create_pre_application), expires_at이 지난 미전환 건의
--         개인정보(pre_applications_private/secrets)를 삭제하고 상태만
--         'expired'로 남긴다 — 통계·감사 목적의 비민감 정보는 유지.
--
-- ⚠️ 이 마이그레이션은 pg_cron 확장이 프로젝트에 이미 활성화돼 있어야
-- 한다. Supabase 대시보드 → Database → Extensions에서 "pg_cron"을 먼저
-- 켜야 할 수 있다(Vault 때와 마찬가지로, 없으면 CREATE EXTENSION 구문이
-- 권한 오류를 낼 수 있음 — 그때는 대시보드에서 켠 다음 이 파일만 다시
-- 실행하면 된다).

create extension if not exists pg_cron;

-- ============================================================
-- 1. 등기 발송정보 등록
-- ============================================================

create or replace function public.register_pre_application_tracking_number(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_tracking_number text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  cleaned text;
begin
  select * into app_row
  from public.pre_applications
  where id = p_pre_application_id
  for update;

  if not found then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  if app_row.status = 'expired' then
    raise exception '이미 만료된 사전작성입니다.';
  end if;

  if app_row.receipt_method <> 'M' then
    -- 마스터스펙 1408행: 등기우편 선택자만 이 기능을 쓸 수 있다.
    raise exception '등기우편으로 접수하는 경우에만 등기 발송정보를 등록할 수 있습니다.';
  end if;

  cleaned := regexp_replace(coalesce(p_tracking_number, ''), '\s', '', 'g');
  if length(cleaned) < 8 or length(cleaned) > 20 or cleaned !~ '^[0-9A-Za-z-]+$' then
    raise exception '등기번호 형식이 올바르지 않습니다.';
  end if;

  update public.pre_applications
  set shipping = jsonb_build_object('trackingNumber', cleaned, 'registeredAt', now())
  where id = p_pre_application_id;

  perform public._record_pre_application_event(
    p_pre_application_id, p_pre_application_no,
    'preApplication.shipping.trackingRegistered', 'applicant',
    null, jsonb_build_object('hasTrackingNumber', true)
  );

  return json_build_object('registeredAt', now());
end;
$$;

revoke execute on function public.register_pre_application_tracking_number(uuid, text, text)
  from public, anon, authenticated;

comment on function public.register_pre_application_tracking_number(uuid, text, text) is
  '등기번호 원문은 shipping jsonb에만 저장한다(마스터스펙 1408행 — 1차년도에는
   배송조회 API 연동 없음, 등록 자체가 원서접수 완료를 의미하지 않음).';

-- ============================================================
-- 2a. 임시 PDF 24시간 삭제
-- ============================================================

create or replace function public._cleanup_expired_pre_application_bundles()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from storage.objects
  where bucket_id = 'pre-application-bundles'
    and created_at < now() - interval '24 hours';
end;
$$;

comment on function public._cleanup_expired_pre_application_bundles() is
  'pg_cron 전용. Storage 오브젝트만 지운다 — pre_applications.print_bundle
   메타데이터(경로·시각·횟수)는 감사 목적으로 그대로 남긴다.';

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-expired-pre-application-bundles') then
    perform cron.unschedule('cleanup-expired-pre-application-bundles');
  end if;
end;
$$;

select cron.schedule(
  'cleanup-expired-pre-application-bundles',
  '0 * * * *', -- 매시 정각
  $$select public._cleanup_expired_pre_application_bundles();$$
);

-- ============================================================
-- 2b. 미전환 사전작성 30일 후 자동 파기
-- ============================================================

create or replace function public._purge_expired_pre_applications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
begin
  for rec in
    select id, pre_application_no
    from public.pre_applications
    where status not in ('converted', 'expired')
      and expires_at < now()
    for update skip locked
  loop
    delete from public.pre_applications_private where pre_application_id = rec.id;
    delete from public.pre_application_secrets where pre_application_id = rec.id;

    update public.pre_applications
    set status = 'expired'
    where id = rec.id;

    perform public._record_pre_application_event(
      rec.id, rec.pre_application_no, 'preApplication.purged', 'system'
    );
  end loop;
end;
$$;

comment on function public._purge_expired_pre_applications() is
  'pg_cron 전용. expires_at은 create_pre_application 시점에 이미
   "접수마감+30일"로 계산돼 있다(00025) — 이 함수는 그 시점이 지난
   미전환 건의 개인정보만 삭제하고 pre_applications 행 자체와 이벤트
   로그는 통계·감사 목적으로 남긴다.';

do $$
begin
  if exists (select 1 from cron.job where jobname = 'purge-expired-pre-applications') then
    perform cron.unschedule('purge-expired-pre-applications');
  end if;
end;
$$;

select cron.schedule(
  'purge-expired-pre-applications',
  '0 3 * * *', -- 매일 새벽 3시
  $$select public._purge_expired_pre_applications();$$
);
