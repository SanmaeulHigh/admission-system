-- 새봄고 입학전형 시스템 — 글쓰기 목록을 수험번호 순으로 (2026-10-01)
--
-- 글쓰기 준비(관리자)와 글쓰기 채점(위원) 목록이 1차 서류사정 순위(dr.rank) 순이었다.
--   · 관리자: 시험 당일 스캔한 답안을 수험번호 순으로 올리기 어렵다.
--   · 위원: 목록 순서만으로 지원자의 서류 성적 순위를 짐작할 수 있다.
-- 둘 다 수험번호 순(같으면 접수번호·이름)으로 바꾼다. 서버 DB의 현재 정의에서 ORDER BY만 바꿨다.

CREATE OR REPLACE FUNCTION public.get_m5d_writing_plan_admin(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round record;
  v_plan_config_revision_id uuid;
  v_validation jsonb;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select config_revision_id into v_plan_config_revision_id
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;

  if found then
    v_validation := public._m5d_validate_writing_plan(p_year, p_round);
  else
    v_validation := jsonb_build_object('complete', false, 'blockingIssues', '[]'::jsonb, 'status', null, 'revision', 0);
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'config', case
      when coalesce(v_plan_config_revision_id, v_round.config_revision_id) is null then null
      else public._m5d_writing_params(coalesce(v_plan_config_revision_id, v_round.config_revision_id))
    end,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id,
        'displayName', u.display_name,
        'email', u.email
      ) order by u.display_name, u.email)
      from public.users u
      where u.active = true
        and 'evaluator' = any(u.roles)
        and 'writing' = any(u.assigned_areas)
        and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
        and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    ), '[]'::jsonb),
    'memberUids', coalesce((
      select jsonb_agg(m.evaluator_uid order by m.member_slot)
      from public.writing_plan_members m
      where m.year = p_year and m.round = p_round
    ), '[]'::jsonb),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'documentScore', dr.total_score,
        'answerDocumentId', answer_doc.id,
        'answerVersion', answer_doc.version
      ) order by er.exam_no, er.receipt_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      left join lateral (
        select d.id, d.version
        from public.admission_documents d
        where d.applicant_id = dr.applicant_id
          and d.document_type = 'writingAnswer'
          and d.active = true
          and d.classification = 'evaluation'
          and 'writing'::evaluation_area = any(d.access_areas)
        order by d.version desc, d.uploaded_at desc
        limit 1
      ) answer_doc on true
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb),
    'validation', v_validation
  );
end;
$function$

;

CREATE OR REPLACE FUNCTION public.get_m5d_writing_workspace(p_year integer, p_round admission_round)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller uuid;
  v_round record;
  v_plan record;
  v_config jsonb;
  v_candidates jsonb;
begin
  caller := public._m5d_require_writing_user(p_year, p_round);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select p.* into v_plan
  from public.writing_evaluation_plans p
  join public.writing_plan_members m
    on m.year = p.year and m.round = p.round
  where p.year = p_year and p.round = p_round
    and p.status = 'finalized'
    and m.evaluator_uid = caller;
  if not found then
    raise exception '현재 평가자에게 최종확정된 글쓰기 평가 배정이 없습니다.' using errcode = '42501';
  end if;

  v_config := public._m5d_writing_params(v_plan.config_revision_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', er.applicant_id,
    'examNo', er.exam_no,
    'displayName', er.display_name,
    'rankOrder', dr.rank,
    'answerDocument', case when answer_doc.id is null then null else jsonb_build_object(
      'documentId', answer_doc.id,
      'version', answer_doc.version,
      'mimeType', answer_doc.mime_type
    ) end,
    'myScore', case when sw.id is null then null else jsonb_build_object(
      'scoreId', sw.id,
      'responses', sw.responses,
      'memo', sw.memo,
      'submissionState', sw.submission_state,
      'revision', sw.revision,
      'serverComputed', sw.server_computed,
      'clientUpdatedAt', sw.client_updated_at,
      'submittedAt', sw.submitted_at
    ) end
  ) order by er.exam_no, er.receipt_no, er.display_name), '[]'::jsonb)
  into v_candidates
  from public.decision_results dr
  join public.evaluation_roster er on er.applicant_id = dr.applicant_id
  left join lateral (
    select d.id, d.version, d.mime_type
    from public.admission_documents d
    where d.applicant_id = dr.applicant_id
      and d.document_type = 'writingAnswer'
      and d.active = true
      and d.classification = 'evaluation'
      and 'writing'::evaluation_area = any(d.access_areas)
    order by d.version desc, d.uploaded_at desc
    limit 1
  ) answer_doc on true
  left join public.scores_writing sw
    on sw.applicant_id = dr.applicant_id and sw.evaluator_uid = caller
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'serverNow', now(),
    'areaOpen', v_round.stage_status = 'open' and 'writing'::evaluation_area = any(v_round.open_evaluation_areas),
    'configRevisionId', v_plan.config_revision_id,
    'config', v_config,
    'candidates', v_candidates
  );
end;
$function$

;

