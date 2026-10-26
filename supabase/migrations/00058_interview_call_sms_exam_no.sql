-- 면접 호출 문자에 수험번호(exam_no)를 쓰도록 수정 (2026-07-31)
--
-- 00056의 get_interview_call_sms_recipient는 applicants.receipt_no(접수번호,
-- 예: 260731V001)를 내려주고 Edge Function이 이를 "수험번호"라고 안내했다.
-- 그런데 대기실 프로젝터 화면은 evaluation_roster.exam_no(예: 2027-001)를
-- 띄운다. 지원자 입장에서 문자와 화면의 번호가 서로 달라 혼란스럽다.
--
-- 1차 서류사정 확정 시점에 exam_no가 부여되고 면접은 그 이후이므로, 면접
-- 호출에서는 항상 exam_no를 기준으로 통일한다. exam_no가 아직 없으면
-- 접수번호로 대체한다(방어적 처리).

create or replace function public.get_interview_call_sms_recipient(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select a.name,
         a.receipt_no,
         r.exam_no,
         p.applicant_phone,
         p.guardian_name,
         p.guardian_phone
  into v_row
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.evaluation_roster r on r.applicant_id = a.id
  where a.id = p_applicant_id;

  if v_row is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'name', v_row.name,
    'receiptNo', v_row.receipt_no,
    -- 면접 단계에서는 수험번호가 기준이다(프로젝터 화면과 동일).
    'examNo', coalesce(v_row.exam_no, v_row.receipt_no),
    'applicantPhone', v_row.applicant_phone,
    'guardianName', v_row.guardian_name,
    'guardianPhone', v_row.guardian_phone
  );
end;
$$;

revoke all on function public.get_interview_call_sms_recipient(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_sms_recipient(int, admission_round, uuid) to authenticated;
