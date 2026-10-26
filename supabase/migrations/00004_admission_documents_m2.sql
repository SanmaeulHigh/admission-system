-- 새봄고 입학전형 시스템 — M2 평가서류 열람 (Sprint 2)
-- 마스터 스펙 v1.2 섹션 3.8(admissionDocuments), 6.6(접근통제) 대응.
--
-- 핵심 설계:
--   - admission_documents: 메타데이터만. 실제 바이너리는 Supabase Storage.
--   - classification 3단계 + evaluation은 accessAreas ∩ assignedAreas 교집합.
--   - "장시간 공개 URL 금지" → 파일은 항상 createSignedUrl(단시간)로만 접근.
--     그 서명 URL 발급 자체가 storage.objects의 SELECT RLS를 통과해야
--     하므로 (Supabase 표준 동작), Storage 레벨에서도 동일한 접근규칙을
--     강제한다 — 메타데이터만 막고 파일은 못 막는 구멍을 없앤다.
--   - "열람 감사 로그": 서명 URL 발급 전 클라이언트가 log_document_view
--     RPC를 먼저 호출해 감사 기록을 남기고 storage_path를 받는다.
--     (Storage API 호출 자체는 Postgres RPC를 거치지 않아 자동 로깅이
--     안 되므로, 이 순서를 프론트엔드 계약으로 강제한다.)

-- ============================================================
-- 1. document_type, classification 값 집합 (섹션 3.8)
-- ============================================================

create type document_type as enum (
  'applicationForm', 'studentRecordSource', 'studentRecordAttendanceView',
  'studentRecordAcademicView', 'studentRecordCommunityView', 'essay',
  'opinion', 'portfolio', 'writingAnswer', 'trackEvidence', 'consent'
);

create type document_classification as enum ('adminOnly', 'reception', 'evaluation');

-- ============================================================
-- 2. admission_documents (메타데이터)
-- ============================================================

create table public.admission_documents (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  document_type document_type not null,
  storage_path text not null unique,
  mime_type text not null default 'application/pdf',
  file_size int,
  checksum text,
  version int not null default 1,
  active boolean not null default true,
  classification document_classification not null,
  access_areas evaluation_area[] not null default '{}',
  source_document_id uuid references public.admission_documents (id),
  replaced_by_document_id uuid references public.admission_documents (id),
  uploaded_at timestamptz not null default now(),
  uploaded_by text not null
);

comment on table public.admission_documents is
  '평가서류 메타데이터. classification=evaluation인 문서만 access_areas 교집합으로 evaluator/quant에게 노출된다 (섹션 6.6). 학생부 전체 원본(studentRecordSource)은 항상 adminOnly.';

create index idx_admission_documents_applicant on public.admission_documents (applicant_id);

-- ============================================================
-- 3. 접근 판정 helper (admission_documents RLS와 Storage RLS 양쪽에서 재사용)
-- ============================================================

create or replace function public._can_access_document(
  doc_classification document_classification,
  doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if doc_classification = 'adminOnly' then
    return false;
  end if;
  if doc_classification = 'reception' then
    return public.has_role('reception');
  end if;
  -- classification = 'evaluation'
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;
  return exists (
    select 1 from public.users
    where id = auth.uid() and assigned_areas && doc_access_areas
  );
end;
$$;

revoke execute on function public._can_access_document(document_classification, evaluation_area[]) from anon;

-- ============================================================
-- 4. admission_documents RLS
-- ============================================================

alter table public.admission_documents enable row level security;

create policy admission_documents_select_by_classification
  on public.admission_documents for select
  using (public._can_access_document(classification, access_areas));

-- write는 정책 없음 = 아래 RPC로만 (섹션 2.12)

-- ============================================================
-- 5. 열람 감사로그 RPC — 파일 접근 직전에 클라이언트가 반드시 호출
-- ============================================================

create or replace function public.log_document_view(p_document_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  doc record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into doc from public.admission_documents where id = p_document_id and active = true;
  if doc is null then
    raise exception '문서를 찾을 수 없습니다.';
  end if;

  if not public._can_access_document(doc.classification, doc.access_areas) then
    raise exception '이 문서에 접근할 권한이 없습니다.';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.viewed', 'admission_documents',
     doc.id::text, doc.applicant_id::text,
     case when array_length(doc.access_areas, 1) = 1 then doc.access_areas[1] else null end);

  return json_build_object('storagePath', doc.storage_path, 'documentType', doc.document_type);
end;
$$;

revoke execute on function public.log_document_view(uuid) from anon;

-- ============================================================
-- 6. 문서 메타데이터 등록 RPC (실제 바이트는 Storage에 별도 업로드)
-- ============================================================

create or replace function public.register_admission_document(
  p_applicant_id uuid,
  p_document_type document_type,
  p_storage_path text,
  p_classification document_classification,
  p_access_areas evaluation_area[] default '{}',
  p_mime_type text default 'application/pdf',
  p_file_size int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
  new_id uuid;
begin
  -- 문서 등록은 접수 담당 이상 (섹션 6.6 reception 이상이 업로드 주체)
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  -- 학생부 전체 원본은 반드시 adminOnly (섹션 3.8 불변조건)
  if p_document_type = 'studentRecordSource' and p_classification <> 'adminOnly' then
    raise exception 'studentRecordSource는 반드시 classification=adminOnly 이어야 합니다.';
  end if;

  insert into public.admission_documents
    (applicant_id, year, round, document_type, storage_path, mime_type, file_size,
     classification, access_areas, uploaded_by)
  values
    (p_applicant_id, app.year, app.round, p_document_type, p_storage_path, p_mime_type,
     p_file_size, p_classification, p_access_areas, caller::text)
  returning id into new_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (app.year, app.round, 'user', caller::text, 'document.registered', 'admission_documents',
     new_id::text, p_applicant_id::text);

  return new_id;
end;
$$;

revoke execute on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) from anon;

-- ============================================================
-- 7. Storage 버킷 + RLS (실제 파일 접근 통제)
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('admission-documents', 'admission-documents', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

-- SELECT: admission_documents 메타데이터와 동일한 규칙으로만 서명URL 발급 허용.
-- (storage.objects.name이 admission_documents.storage_path와 일치하는 행을 찾아 판정)
create policy admission_documents_storage_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'admission-documents'
    and exists (
      select 1 from public.admission_documents d
      where d.storage_path = storage.objects.name
        and d.active = true
        and public._can_access_document(d.classification, d.access_areas)
    )
  );

-- INSERT: reception 이상만 업로드 가능 (evaluator/quant는 절대 업로드 불가)
-- 주의: INSERT 전용 정책은 WITH CHECK만 허용된다 (USING은 INSERT에 쓸 수 없음).
create policy admission_documents_storage_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'admission-documents'
    and (public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception'))
  );

-- UPDATE/DELETE: 정책 없음 = 전면 거부. 문서 교체는 새 버전 업로드 +
-- register_admission_document로 새 행 생성 + 이전 행에 replaced_by 연결
-- (Function으로 확장 예정, 원본 삭제는 하지 않는 append-only 원칙).
