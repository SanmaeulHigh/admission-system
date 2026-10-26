-- 새봄고 입학전형 시스템 — 최종 결과 문자: 불합격자도 시스템에서 발송 (2026-10-01)
--
-- 처음(00054)에는 실수로 불합격자에게 합격 문자가 가는 일을 막으려고 합격자만
-- 시스템 발송 대상으로 두고, 불합격 통보는 CSV로 학교 문자 도구에서 따로 보냈다.
-- 불합격자에게도 정중한 안내 문구를 보내기 위해 시스템 발송 대상에 넣는다.
--
-- 안전장치는 유지한다: 어느 문구를 보낼지는 화면이 아니라 Edge Function
-- (send-final-result-sms)이 확정된 최종 사정 결과(outcome)를 직접 다시 읽어 고른다.
-- 화면이 판정을 잘못 넘겨도 합격·불합격 문구가 바뀌어 나갈 수 없다.
--
-- 바뀐 점: outcome in ('passed','failed')로 확대, 'outcome'·'examNo' 필드 추가,
-- 합격자 먼저(수험번호 순). 제외(excluded)·위원회 결정 필요는 대상이 아니다.

CREATE OR REPLACE FUNCTION public.get_final_result_sms_recipients(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'examNo', a.exam_no,
    'outcome', dr.outcome,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by (dr.outcome <> 'passed'), a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed');

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$function$;
