-- 새봄고 입학전형 시스템 — 사전작성(M8) 온라인 포털 완전 제거
--
-- 2026-07-13 결정(docs/로컬서버_설치절차_2026-07.md): 이원화(클라우드+로컬 동시
-- 운영)로 인한 학교 측 운영 부담이 너무 크다고 판단, 온라인 사전작성 포털을
-- 포기하고 등기우편·방문 접수(M1 수기접수)만 운영하기로 확정. 이 마이그레이션은
-- 00023~00048에서 만든 pre_applications 관련 테이블·함수·스토리지 버킷·cron
-- 작업을 전부 제거한다.
--
-- 기존 migrations(00023~00048) 파일 자체는 수정하지 않는다(이 프로젝트의
-- "이미 적용된 마이그레이션은 손대지 않는다" 원칙 — 검토메모_2026-07-06 참고).
-- 대신 이 신규 migration으로 되돌린다.

-- ============================================================
-- 1. cron 작업 해제
-- ============================================================

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-expired-pre-application-bundles') then
    perform cron.unschedule('cleanup-expired-pre-application-bundles');
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-expired-pre-applications') then
    perform cron.unschedule('purge-expired-pre-applications');
  end if;
end $$;

-- ============================================================
-- 2. applicants 테이블에 붙어있던 M8 연결 컬럼 제거
-- ============================================================

alter table public.applicants
  drop constraint if exists fk_applicants_source_pre_application;

alter table public.applicants
  drop column if exists source_pre_application_id;

alter table public.applicants
  drop column if exists source_pre_application_no;

-- ============================================================
-- 3. pre_application 관련 함수 전부 제거 (시그니처를 pg_catalog에서
--    동적으로 찾아서 삭제 — 오버로드/인자 목록을 일일이 안 적어도 됨)
-- ============================================================

do $$
declare
  fn_names text[] := array[
    '_allocate_pre_application_no',
    '_check_pre_application_rate_limit',
    '_cleanup_expired_pre_application_bundles',
    '_generate_instant_bundle_token',
    '_generate_pre_application_access_code',
    '_hash_instant_bundle_token',
    '_hash_pre_application_code',
    '_hash_pre_application_name',
    '_pre_application_pepper',
    '_purge_expired_pre_applications',
    '_record_pre_application_event',
    '_set_pre_application_instant_bundle_token',
    'admin_cancel_pre_application',
    'admin_export_pre_application_for_bridge',
    'admin_get_pre_application_detail',
    'admin_import_applicant_from_pre_application_bridge',
    'admin_list_pre_applications',
    'admin_mark_pre_application_bridged',
    'admin_permanently_delete_pre_application',
    'admin_update_pre_application_school',
    'convert_pre_application_to_applicant',
    'create_pre_application',
    'get_pre_application_status',
    'list_expired_pre_application_bundle_paths',
    'mark_pre_application_arrived',
    'mark_pre_application_reviewing',
    'record_pre_application_bundle_generated',
    'redeem_instant_bundle_token',
    'register_pre_application_tracking_number',
    'reissue_pre_application_access_code',
    'set_pre_application_access_code',
    'update_pre_application_document_review',
    'verify_pre_application_access'
  ];
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any(fn_names)
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- ============================================================
-- 4. pre_application 테이블 전부 제거
-- ============================================================

drop table if exists public.pre_application_events cascade;
drop table if exists public.pre_application_secrets cascade;
drop table if exists public.pre_application_rate_limits cascade;
drop table if exists public.pre_application_counters cascade;
drop table if exists public.pre_applications_private cascade;
drop table if exists public.pre_applications cascade;

-- ============================================================
-- 5. Storage 버킷 제거 (오브젝트 먼저, 버킷은 나중에)
-- ============================================================

delete from storage.objects
where bucket_id in ('pre-application-assets', 'pre-application-bundles');

delete from storage.buckets
where id in ('pre-application-assets', 'pre-application-bundles');

comment on table public.applicants is
  '지원자 기본정보(M1). 2026-07-13: 온라인 사전작성(M8) 포기 결정으로 source_pre_application_id/no 컬럼 제거 — 등기우편·방문 접수(수기등록)만 운영.';
