-- 새봄고 입학전형 시스템 — M6c 최종 발표 산출물 (Sprint 6 계속)
-- 요강 승인본(공고 제2026-42호) "5. 전형 일정 — 최종 합격자 발표: 개별 통보(SMS)
-- 및 홈페이지" 근거.
--
-- 용도(purpose)별 필드를 서버에서 강제로 최소화한다 — 클라이언트가 실수로
-- 과다노출하는 것을 원천 차단(스펙 6.1 "클라이언트 어떤 분기도 보안장치가
-- 아니다" 원칙과 동일선상).
--
-- 담당 교사 확인 필요 사항(가정으로 진행, 확인 후 조정):
--   1. SMS 대상: 지원자 본인 연락처 + 보호자 연락처 둘 다 내려준다(실제 발송 시
--      어느 쪽으로 보낼지는 학교 문자발송 도구에서 선택). 합격/불합격 전원 포함.
--   2. 홈페이지 게시: 접수번호 + 판정만 내려준다(성명·연락처·전형 전부 제외).
--      또한 불합격자는 아예 포함하지 않는다(합격자 명단만 게시하는 일반적 관행).
--   3. 반드시 finalized 상태인 최종(decision_type='final') run만 사용한다.
--      simulation 결과로는 절대 발표 자료를 만들 수 없다.

create or replace function public.get_final_pass_list(
  p_year int,
  p_round admission_round,
  p_purpose text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_purpose not in ('sms', 'website') then
    raise exception '지원하지 않는 purpose입니다: % (sms | website 중 하나)', p_purpose
      using errcode = '55000';
  end if;

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다. simulation 결과로는 발표 자료를 만들 수 없습니다.'
      using errcode = '55000';
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (p_year, p_round, 'user', caller::text, 'decision.final.pass_list_exported.' || p_purpose, 'decision_runs', v_run_id::text);

  if p_purpose = 'sms' then
    return jsonb_build_object(
      'purpose', 'sms',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'name', a.name,
          'applicantPhone', ap.applicant_phone,
          'guardianName', ap.guardian_name,
          'guardianPhone', ap.guardian_phone,
          'outcome', dr.outcome,
          'outcomeLabel', case dr.outcome
            when 'passed' then '합격' when 'failed' then '불합격'
            when 'excluded' then '제외' else '판정보류' end,
          'trackLabel', case
            when dr.track_result ->> 'incheon' = 'passed' then '인천학생추천'
            when dr.track_result ->> 'social' = 'passed' then '사회통합'
            when dr.track_result ->> 'general' = 'passed' then '일반'
            else null
          end
        ) order by a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        left join public.applicants_private ap on ap.applicant_id = a.id
        where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed')
      ), '[]'::jsonb)
    );
  else
    return jsonb_build_object(
      'purpose', 'website',
      'runId', v_run_id,
      'finalizedAt', v_finalized_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receiptNo', a.receipt_no,
          'outcomeLabel', '합격'
        ) order by a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        where dr.run_id = v_run_id and dr.outcome = 'passed'
      ), '[]'::jsonb)
    );
  end if;
end;
$$;

revoke all on function public.get_final_pass_list(int, admission_round, text) from public, anon;
grant execute on function public.get_final_pass_list(int, admission_round, text) to authenticated;
