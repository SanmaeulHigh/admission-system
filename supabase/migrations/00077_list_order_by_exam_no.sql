-- 새봄고 입학전형 시스템 — 목록을 수험번호 순으로 정렬 (2026-10-01)
--
-- 수험번호가 부여된 뒤에도 일부 목록이 접수번호(receipt_no) 순으로 나와,
-- 전형별 접수번호(M·V 계열)가 섞여 수험번호 순서가 뒤죽박죽으로 보였다
-- (예: 관리자 대리 채점 화면 A1003, A1006, A1009, A1001 …).
-- 화면용 목록은 "수험번호 순, 수험번호가 아직 없으면 그 뒤에 접수번호 순"으로 맞춘다.
-- (exam_no 오름차순은 NULL을 마지막에 둔다.)
--
-- 바꾸지 않는 것: assign_exam_numbers — 수험번호를 매기는 순서 자체라 접수 기준 유지.
-- 아래 함수는 서버 DB의 현재 정의(pg_get_functiondef)에서 ORDER BY만 바꿨다.

CREATE OR REPLACE FUNCTION public.admin_get_document_score_entry_context(p_year integer, p_round admission_round, p_area evaluation_area, p_target_evaluator_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_role app_role;
  v_table text;
  v_items jsonb;
  v_area_open boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '이 화면은 서류평가 5개 영역만 지원합니다 (입력값: %).', p_area
      using errcode = '22023';
  end if;

  v_role := public._score_area_required_role(p_area);
  if not exists (
    select 1 from public.users u
    where u.id = p_target_evaluator_uid and u.active = true
      and v_role = any(u.roles) and p_area = any(u.assigned_areas)
  ) then
    raise exception '대상 평가위원이 해당 영역 담당으로 등록되어 있지 않습니다.' using errcode = '42501';
  end if;

  select (stage_status = 'open' and p_area = any(open_evaluation_areas))
  into v_area_open
  from public.admission_rounds
  where year = p_year and round = p_round;

  -- 영역마다 점수 테이블이 다르다. 위에서 영역을 5개로 좁혀 검증했으므로
  -- 테이블명 조립은 안전하다(사용자 입력이 그대로 들어가지 않는다).
  v_table := 'scores_' || p_area::text;

  -- 값은 문자열로 끼워 넣지 않고 USING으로 넘긴다(따옴표·형변환 사고 방지).
  -- 테이블명만 %I로 조립하며, 위에서 영역을 5개로 좁혀 검증했으므로 안전하다.
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', r.applicant_id,
      'examNo', r.exam_no,
      'displayName', r.display_name,
      'receiptNo', r.receipt_no,
      'submissionState', s.submission_state,
      'serverComputed', s.server_computed,
      'submittedAt', s.submitted_at
    ) order by r.exam_no, r.receipt_no), '[]'::jsonb)
    from public.evaluation_roster r
    left join public.%I s
      on s.applicant_id = r.applicant_id and s.evaluator_uid = $1
    where r.year = $2 and r.round = $3 and r.evaluation_active = true
  $q$, v_table)
  into v_items
  using p_target_evaluator_uid, p_year, p_round;

  return jsonb_build_object(
    'area', p_area,
    'areaOpen', coalesce(v_area_open, false),
    'targetEvaluatorUid', p_target_evaluator_uid,
    'items', v_items
  );
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_evaluation_progress(target_year integer, target_round admission_round)
 RETURNS TABLE(applicant_id uuid, receipt_no text, display_name text, area text, required integer, submitted integer, complete boolean, open_alerts integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  return query
  select
    er.applicant_id,
    er.receipt_no,
    er.display_name,
    area_key.area,
    public._document_required_submissions(target_year, target_round, area_key.area) as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= public._document_required_submissions(target_year, target_round, area_key.area) as complete,
    (select count(*)::int from public.evaluation_alerts ea
      where ea.applicant_id = er.applicant_id and ea.area::text = area_key.area and ea.status = 'open') as open_alerts
  from public.evaluation_roster er
  cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
  left join lateral (
    select count(*) as submitted from (
      select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
      union all
      select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
      union all
      select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
      union all
      select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
      union all
      select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
    ) x
  ) cnt on true
  where er.year = target_year and er.round = target_round and er.evaluation_active = true
  order by er.exam_no, er.receipt_no, area_key.area;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_final_pass_list(p_year integer, p_round admission_round, p_purpose text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        ) order by a.exam_no, a.receipt_no)
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
        ) order by a.exam_no, a.receipt_no)
        from public.decision_results dr
        join public.applicants a on a.id = dr.applicant_id
        where dr.run_id = v_run_id and dr.outcome = 'passed'
      ), '[]'::jsonb)
    );
  end if;
end;
$function$

;

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
  ) order by a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome = 'passed';

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_m6_committee_packet(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      ) order by a.exam_no, a.receipt_no)
      from public.decision_results dr
      join public.applicants a on a.id = dr.applicant_id
      left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
      where dr.run_id = v_run.id and dr.outcome = 'excluded'
    ), '[]'::jsonb)
  );
end;
$function$

;

