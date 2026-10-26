-- 새봄고 입학전형 시스템 — 잘못 올린 서류 내리기 (2026-09-16)
--
-- 배경: 접수 중 실수로 엉뚱한 파일을 올리거나 같은 서류를 중복으로 올리는 일이
-- 생기는데, 지금까지는 한 번 올린 서류를 내릴 방법이 없었다.
--
-- "삭제"가 아니라 "비활성화(active=false)"로 구현하는 이유:
--   admission_documents는 append-only 설계다(00004 — UPDATE/DELETE 정책 자체가
--   없어 클라이언트는 손댈 수 없다). 입시 서류는 "언제 무엇이 올라왔고 언제
--   내려갔는가"가 나중에 이의제기·감사에서 근거가 되므로, 행을 지워 흔적을
--   없애는 것보다 남겨두고 감춘 뒤 사유를 기록하는 편이 안전하다.
--
--   비활성화된 문서는 active=true 조건으로 걸러지는 모든 화면(평가위원 열람,
--   서류 목록, 수험표 사진 조회)에서 즉시 사라진다. 실제 파일도 storage RLS가
--   admission_documents의 active=true 행을 참조하므로 서명 URL이 더는 발급되지
--   않는다 — 링크를 알고 있어도 열 수 없다.
--
-- 스토리지의 파일 바이트 자체는 남는다(스토리지 DELETE 정책이 없다). 운영 종료
-- 후 일괄 정리는 담당자가 별도로 수행한다.

create or replace function public.deactivate_admission_document(
  p_document_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  doc record;
begin
  -- 올리는 주체와 같은 권한 범위(접수 담당 이상)
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 2 then
    raise exception '내리는 사유를 입력해야 합니다.';
  end if;

  select * into doc from public.admission_documents where id = p_document_id;
  if doc is null then
    raise exception '문서를 찾을 수 없습니다.';
  end if;
  if not doc.active then
    raise exception '이미 내려간 문서입니다.';
  end if;

  update public.admission_documents
  set active = false
  where id = p_document_id;

  -- audit_logs에는 reason_text 컬럼이 없다(reason_code + metadata 구조).
  -- 자유서술 사유는 metadata에 담는다.
  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id,
     applicant_id, reason_code, metadata)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.deactivated',
     'admission_documents', p_document_id::text, doc.applicant_id::text, '서류 내림',
     jsonb_build_object(
       'documentType', doc.document_type,
       'storagePath', doc.storage_path,
       'reason', trim(p_reason)));
end;
$$;

revoke all on function public.deactivate_admission_document(uuid, text) from public, anon;
grant execute on function public.deactivate_admission_document(uuid, text) to authenticated;
