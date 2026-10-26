-- 새봄고 입학전형 시스템 — M6d 전형평가회의 자료 (Sprint 6 계속)
-- 마스터 스펙 v1.2 M6 모듈, 검토메모 "M6 회의자료 PDF와 종합 채점표 XLSX는
-- M5e 종이 백업과 역할이 다름" 근거.
--
-- M6b(get_final_decision_blockers)/M6c(get_final_pass_list)와 달리 이 RPC는
-- "확정된 final" 하나로 제한하지 않는다 — 입학전형위원회는 보통 simulation
-- 결과를 미리 보고 동점·제외 여부를 논의한 뒤에 최종 확정하므로, 가장 최근
-- (year,round,decision_type='final') run을 상태(completed 또는 finalized)
-- 관계없이 사용한다. 개별 위원 채점은 노출하지 않고 확정된 집계 점수만 보여준다.
--
-- 익명화는 서버가 아니라 화면(인쇄 미리보기)에서 토글한다 — 이 RPC를 호출할
-- 수 있는 사람은 이미 superadmin/admin이라 성명을 볼 권한이 있고, 익명화는
-- 위원회 회의 중 편향을 줄이기 위한 표시 옵션일 뿐 접근통제가 아니다.

create or replace function public.get_m6_committee_packet(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_run record;
  quota jsonb;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  select * into v_run
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final'
    and status in ('completed', 'finalized')
  order by created_at desc
  limit 1;

  if v_run is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_FINAL_RUN_YET');
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';
  select count(*) into excluded_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'excluded';
  select count(*) into review_pending_count
  from public.decision_results dr join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed' and aa.exclusion_status = 'reviewPending';
  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  return jsonb_build_object(
    'ready', true,
    'runId', v_run.id,
    'runMode', v_run.mode,
    'runStatus', v_run.status,
    'generatedAt', v_run.aggregate_snapshot_at,
    'finalizedAt', v_run.finalized_at,
    'quota', quota,
    'blockers', jsonb_build_object(
      'blockingAlertCount', blocking_count,
      'incompleteDeepCount', incomplete_count,
      'reviewPendingCount', review_pending_count,
      'excludedCount', excluded_count,
      'unresolvedTieCount', v_run.unresolved_tie_count
    ),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'tracks', a.tracks,
        'primaryTrack', case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 'incheon'
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 'social'
          else 'general'
        end,
        'documentScore', fa.document_score,
        'documentCarry', fa.document_carry,
        'groupScore', fa.group_score,
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentScore', fa.interview_parent_score,
        'writingScore', fa.writing_score,
        'finalTotal', dr.total_score,
        'rank', dr.rank,
        'trackResult', dr.track_result,
        'outcome', dr.outcome,
        'tiebreakValues', dr.tiebreak_values
      ) order by
        (case
          when dr.track_result ->> 'incheon' in ('passed','manualDecisionRequired') then 0
          when dr.track_result ->> 'social' in ('passed','manualDecisionRequired') then 1
          else 2
        end),
        dr.rank nulls last
      )
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome <> 'excluded'
    ), '[]'::jsonb),
    'excludedCandidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'adminNote', aa.admin_note
      ) order by a.receipt_no)
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome = 'excluded'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m6_committee_packet(int, admission_round) from public, anon;
grant execute on function public.get_m6_committee_packet(int, admission_round) to authenticated;
