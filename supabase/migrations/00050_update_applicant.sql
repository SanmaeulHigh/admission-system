-- 새봄고 입학전형 시스템 — 지원자 정보 수정 RPC (00003 register_applicant 보완)
--
-- 2026-07-14 요청: 접수 담당자가 수기접수 중 오타/입력 실수를 했을 경우
-- 지원자 목록에서 정보를 고칠 수단이 전혀 없었음(상태 변경/삭제만 가능).
-- register_applicant와 동일한 편집 가능 필드 집합을 그대로 받아 applicants +
-- applicants_private를 함께 갱신한다.
--
-- 편집 불가(이 RPC로는 못 바꿈) — 다른 전용 RPC/흐름으로만 변경:
--   receipt_no, year, round, receipt_date : 접수번호 채번과 얽혀있어 불변
--   application_status                    : update_application_status RPC
--   evaluation_stage 이후 필드들           : M4~M6 사정 RPC들
--
-- register_applicant처럼 "전체 스냅샷을 받아서 그대로 덮어쓰는" 방식이다
-- (coalesce로 부분 수정하지 않음) — 편집 폼이 현재 값을 미리 채워서 보여주고
-- 담당자가 고친 뒤 전체를 다시 제출하는 흐름과 맞다. 즉 필드를 비우면
-- 실제로 null/빈 값으로 저장된다(의도적인 삭제도 가능해야 하므로).

create or replace function public.update_applicant(
  p_applicant_id uuid,
  p_name text,
  p_tracks text[],
  p_academic_status text,
  p_receipt_method text,
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
  p_guardian_phone text default null,
  p_guardian_address text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;

  update public.applicants
  set name = trim(p_name),
      tracks = p_tracks,
      academic_status = p_academic_status,
      school = p_school,
      grade_class_no = p_grade_class_no,
      semester_choice = p_semester_choice,
      receipt_method = p_receipt_method,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  update public.applicants_private
  set gender = p_gender,
      birth_date = p_birth_date,
      applicant_phone = p_applicant_phone,
      email = p_email,
      address = p_address,
      guardian_name = p_guardian_name,
      guardian_relation = p_guardian_relation,
      guardian_phone = p_guardian_phone,
      guardian_address = p_guardian_address,
      updated_at = now()
  where applicant_id = p_applicant_id;

  -- evaluation_roster.display_name도 같이 맞춰준다(평가위원 화면 표시용).
  update public.evaluation_roster
  set display_name = trim(p_name),
      updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'applicant.updated', 'applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_applicant(
  uuid, text, text[], text, text, text, text, text, text, date,
  text, text, text, text, text, text, text
) from anon;
