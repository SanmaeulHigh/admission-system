-- 새봄고 입학전형 시스템 — 학생부를 영역별 발췌 대신 전체 1건으로 (2026-09-16)
--
-- 기존 설계(마스터스펙 735행): 학생부 전체 원본(studentRecordSource)은 항상
-- adminOnly로 두고, 평가위원에게는 출결·학업·공동체 영역별로 발췌한 파생자료
-- (studentRecordAttendanceView / AcademicView / CommunityView)만 제공한다.
-- 평가위원이 자기 영역과 무관한 정보까지 보지 않게 하려는 최소노출 원칙이었다.
--
-- 바꾸는 이유(2026-09-16 운영 판단): 지원자 1명마다 발췌본 3종을 사람이 만들어야
-- 해서, 지원자 수가 늘면 접수 담당자 혼자 감당할 수 없는 분량이 된다. 발췌본
-- 제작이 밀리면 오히려 채점 자체가 지연되어 전형 일정이 위태로워진다.
-- 그래서 학생부를 전체 1건으로 올리고, 출결·학업·공동체 채점자가 그 한 건을
-- 함께 열람하도록 바꾼다.
--
-- 이 변경으로 평가위원의 열람 범위가 넓어진다는 점은 분명히 인지하고 내린 결정이다.
-- 보완책:
--   · 열람은 여전히 log_document_view로 전건 기록된다(누가 언제 무엇을 열었는지).
--   · 자기소개서·학부모소견서 담당 위원에게는 학생부를 주지 않는다
--     (업로드 시 access_areas를 attendance/academic/community로 한정).
--   · 평가위원 보안서약·사전교육에서 학생부 열람 범위를 안내한다.
--
-- ※ 마스터스펙 735행("평가위원에게는 영역별 파생 평가자료만 제공한다")은 이
--   결정에 맞춰 갱신이 필요하다. 개인정보처리방침·내부결재 문서에는 발췌본
--   관련 문구가 없어 그대로 두어도 상충하지 않는다.
--
-- 기술적으로는 register_admission_document의 "studentRecordSource는 반드시
-- adminOnly" 강제 검사만 걷어낸다. 발췌 문서 유형은 enum에 그대로 남겨둔다
-- (이미 올라간 데이터가 있을 수 있고, 필요하면 언제든 다시 쓸 수 있다).

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

  -- 2026-09-16: studentRecordSource의 adminOnly 강제 검사를 제거했다.
  -- (위 주석의 운영 판단 참고 — 학생부를 전체 1건으로 올려 정량평가 담당자가
  --  함께 열람한다. 대신 evaluation으로 올릴 때는 배정영역을 반드시 지정해야
  --  한다 — 영역 없이 올리면 아무도 못 보는 문서가 되어 사고로 이어진다.)
  if p_classification = 'evaluation'
     and coalesce(array_length(p_access_areas, 1), 0) = 0 then
    raise exception '평가용 문서는 배정영역을 1개 이상 지정해야 합니다.';
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

revoke all on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) from public, anon;
grant execute on function public.register_admission_document(
  uuid, document_type, text, document_classification, evaluation_area[], text, int
) to authenticated;
