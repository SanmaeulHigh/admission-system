-- 새봄고 입학전형 시스템 — M6e 종합 채점표 XLSX 원자료 (Sprint 6 계속)
-- 2026학년도 실물 "채점표" 워크북(16시트) 구조를 확인하고 반영한다.
--
-- 확인된 사실(2026 실물 대조):
--   - 서류평가 4영역(공동체/자소서/학부모소견서)+출결·학업은 2026과 2027 config의
--     위원 수가 정확히 일치한다 (공동체 2인, 자소서 5인, 학부모소견서 4인,
--     출결·학업 각 1인). 위원별 개별 시트를 그대로 재현할 수 있다.
--   - 심층평가(모둠/면접/글쓰기)는 다르다. 2026은 모둠활동을 위원 10인 전원이
--     15점씩 채점해 합산(150점)했지만, 2027은 승인 요강 문구("2인의 관찰교사")
--     그대로 관찰교사 2인 체제로 이미 구현되어 있다(M5a/b). 면접도 2026의
--     4인조×2팀 로테이션과 달리 2027은 학생/학부모 각 2인이다. 이 RPC는 2027
--     실제 위원 수(모둠 2, 학생면접 2, 학부모면접 2, 글쓰기 2)를 기준으로 한다.
--   - 서류평가 개별위원 점수의 server_computed 키는 영역별로 다르다
--     (attendance/academic/community는 'score', essay/opinion은 'total').
--
-- 이 RPC는 원자료를 최대한 평탄하게(flat) 반환하고, 시트별 컬럼 구성은
-- 클라이언트(exportFinalScoresheetXlsx.js)에서 담당한다 — SQL 쪽 복잡도를
-- 낮추고 시트 레이아웃 변경 시 SQL을 다시 배포할 필요가 없게 하기 위함.

create or replace function public.get_m6e_scoresheet_data(
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
  v_final_run record;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  select * into v_final_run
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final'
    and status in ('completed', 'finalized')
  order by created_at desc
  limit 1;

  return jsonb_build_object(
    'ready', true,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'finalRunId', v_final_run.id,
    'finalRunMode', v_final_run.mode,

    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id, 'receiptNo', a.receipt_no, 'name', a.name,
        'examNo', er.exam_no, 'tracks', a.tracks,
        'bonusEligible', a.bonus_eligible, 'bonusReason', a.bonus_reason
      ) order by coalesce(er.exam_no, a.receipt_no))
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.evaluation_roster er on er.applicant_id = a.id
      where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    ), '[]'::jsonb),

    -- 서류평가 개별위원 원점수 (area별 evaluator_uid 단위 1행)
    'documentIndividualScores', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'attendance',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        ) as x
        from public.scores_attendance s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'academic',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        )
        from public.scores_academic s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'community',
          'evaluatorName', u.display_name, 'inputs', s.inputs,
          'score', (s.server_computed ->> 'score')::numeric
        )
        from public.scores_community s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'essay',
          'evaluatorName', u.display_name, 'inputs', s.items,
          'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_essay s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'opinion',
          'evaluatorName', u.display_name, 'inputs', s.items,
          'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_opinion s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
      ) t
    ),

    -- 서류평가 종합(영역별 breakdown은 _compute_document_aggregate 재계산 — 확정 스냅샷
    -- total_score/rank/outcome은 decision_results 그대로, opinion을 포함한 영역별
    -- 분해값은 decision_results.tiebreak_values에 없어 부득이 현재 값을 다시 계산한다.
    -- 확정 후 재제출이 없었다면 스냅샷과 동일하다.)
    'documentAggregate', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'totalScore', dr.total_score,
        'rank', dr.rank,
        'outcome', dr.outcome,
        'breakdown', public._compute_document_aggregate(dr.applicant_id)
      ) order by dr.rank nulls last)
      from public.decision_results dr
      where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    ), '[]'::jsonb),

    -- 심층평가 개별위원 원점수
    'deepIndividualScores', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'group', 'evaluatorName', u.display_name,
          'observerRole', s.observer_role, 'score', (s.server_computed ->> 'total')::numeric
        ) as x
        from public.scores_group s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'interviewStudent', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.student_server_computed ->> 'total')::numeric
        )
        from public.scores_interview s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.student_submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'interviewParent', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.parent_server_computed ->> 'total')::numeric
        )
        from public.scores_interview s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.parent_submission_state = 'submitted'
        union all
        select jsonb_build_object(
          'applicantId', s.applicant_id, 'area', 'writing', 'evaluatorName', u.display_name,
          'observerRole', null, 'score', (s.server_computed ->> 'total')::numeric
        )
        from public.scores_writing s join public.users u on u.id = s.evaluator_uid
        where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
      ) t
    ),

    -- 최종 종합 (M6b final run 기준, 없으면 빈 배열 — simulation만 있어도 표시)
    'finalAggregate', case when v_final_run.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'documentScore', fa.document_score,
        'documentCarry', fa.document_carry,
        'groupScore', fa.group_score,
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentScore', fa.interview_parent_score,
        'writingScore', fa.writing_score,
        'finalTotal', dr.total_score,
        'rank', dr.rank,
        'outcome', dr.outcome,
        'trackResult', dr.track_result
      ) order by dr.rank nulls last)
      from public.decision_results dr
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_final_run.id and dr.outcome <> 'excluded'
    ), '[]'::jsonb) end
  );
end;
$$;

revoke all on function public.get_m6e_scoresheet_data(int, admission_round) from public, anon;
grant execute on function public.get_m6e_scoresheet_data(int, admission_round) to authenticated;
