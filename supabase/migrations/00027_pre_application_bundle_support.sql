-- 새봄고 입학전형 시스템 — M8b 제출서류 병합 PDF 지원 (Sprint 1B #5 전반부)
-- 마스터 스펙 1368행 M8b, `M8_아키텍처_결정_2026-07-10.md` 3.5/3.6/3.24/3.25 대응.
--
-- 이번 마이그레이션 범위:
--   1. Storage 버킷(pre-application-bundles) — 정책 없음(전면 차단), 접근은
--      전부 generate-application-bundle Edge Function(service_role)이 발급하는
--      15분 signed URL을 통해서만(3.6).
--   2. record_pre_application_bundle_generated RPC — 병합 PDF 생성 완료 후
--      pre_applications.print_bundle/checklist_ack/status를 원자적으로 갱신하고
--      감사 이벤트를 남긴다. Edge Function이 PDF를 만들고 Storage에 올린 *다음*
--      이 RPC를 호출하는 순서로 쓴다(PDF 생성 자체는 RPC 밖, Deno 쪽 책임).
--
-- 불변조건 재확인:
--   2. 이 RPC는 public/anon/authenticated에서 실행 금지 — service_role
--      (Edge Function)만 호출한다.
--   5. print_bundle에는 파일 원문이나 개인정보를 담지 않는다 — 경로·시각·횟수만.

-- ============================================================
-- 1. Storage 버킷
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pre-application-bundles', 'pre-application-bundles', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

-- 의도적으로 storage.objects 정책을 하나도 만들지 않는다 — RLS enabled +
-- 정책 없음 = anon/authenticated 전면 차단. 모든 읽기는 service_role이
-- Edge Function 안에서 만드는 15분 signed URL로만 이뤄진다(3.6 원칙,
-- 00023의 pre_applications 4테이블과 동일한 패턴).

-- ============================================================
-- 2. record_pre_application_bundle_generated
-- ============================================================

create or replace function public.record_pre_application_bundle_generated(
  p_pre_application_id uuid,
  p_pre_application_no text,
  p_storage_path text,
  p_checklist_version text,
  p_acknowledged_at timestamptz
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  is_first boolean;
  new_status text;
  prev_count int;
  new_bundle jsonb;
begin
  select * into app_row
  from public.pre_applications
  where id = p_pre_application_id
  for update;

  if not found then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  is_first := (app_row.print_bundle ->> 'firstGeneratedAt') is null;
  prev_count := coalesce((app_row.print_bundle ->> 'generationCount')::int, 0);

  -- 접수마감 이후(만료) 상태는 재생성 자체를 허용하지 않는다.
  if app_row.status = 'expired' then
    raise exception '이미 만료된 사전작성입니다.';
  end if;

  -- completed 상태에서 최초 생성 시에만 상태를 bundleGenerated로 올린다.
  -- 도착확인/검수/전환 이후 단계에서 재출력해도 상태는 그대로 유지한다
  -- (마스터스펙 1410행 — 재출력은 상태 전이가 아니다).
  new_status := case
    when app_row.status = 'completed' then 'bundleGenerated'
    else app_row.status
  end;

  new_bundle := jsonb_build_object(
    'version', p_checklist_version,
    'firstGeneratedAt', coalesce(app_row.print_bundle ->> 'firstGeneratedAt', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
    'lastGeneratedAt', now(),
    'generationCount', prev_count + 1,
    'storagePath', p_storage_path
  );

  update public.pre_applications
  set status = new_status,
      print_bundle = new_bundle,
      checklist_ack = jsonb_build_object('version', p_checklist_version, 'acknowledgedAt', p_acknowledged_at)
  where id = p_pre_application_id;

  perform public._record_pre_application_event(
    p_pre_application_id,
    p_pre_application_no,
    case when is_first then 'preApplication.bundle.generated' else 'preApplication.bundle.reprinted' end,
    'applicant',
    null,
    jsonb_build_object('checklistVersion', p_checklist_version, 'generationCount', prev_count + 1)
  );

  return json_build_object(
    'status', new_status,
    'firstGenerated', is_first,
    'generationCount', prev_count + 1
  );
end;
$$;

revoke execute on function public.record_pre_application_bundle_generated(
  uuid, text, text, text, timestamptz
) from public, anon, authenticated;

comment on function public.record_pre_application_bundle_generated(uuid, text, text, text, timestamptz) is
  'generate-application-bundle Edge Function이 PDF를 Storage에 올린 *다음* 호출한다.
   PDF 생성 자체(pdf-lib)는 이 함수 밖 Deno 코드 책임 — 이 함수는 메타데이터
   갱신·상태 전이·감사로그만 담당한다.';
