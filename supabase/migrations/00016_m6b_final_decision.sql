-- 새봄고 입학전형 시스템 — M6b 최종 사정 simulation/final (Sprint 6 계속)
-- 마스터 스펙 v1.2 섹션 5.5(최종 사정 로직), 5.6(decisionRuns 실행 원칙) 대응.
-- M4 run_document_decision(00008)과 동일한 엔진 철학을 그대로 확장한다:
-- decision_runs/decision_results 테이블 재사용, simulation은 몇 번이든 실행 가능,
-- final은 검증 통과 시에만 확정, 기존 확정 run은 절대 UPDATE하지 않는다(불변).
--
-- 요강 승인본(공고 제2026-42호, 2026.7.6) "(3) 최종 합격자 사정" 근거:
--   1. 인천학생추천전형 상위 3명 우선 사정
--   2. 사회통합전형 상위 1명 우선 사정
--   3. 두 특별전형 미선발자 + 일반전형만 지원한 자를 일반전형 풀에서 합산 경쟁,
--      상위 16명 사정
--   4. 최종 동점: 모둠+면접(deepGroupInterview) → 글쓰기 → 자기소개서 → 출결 → 학업성실도
--
-- 담당 교사 정책 결정(2026-07-08):
--   - unfilledTrackPolicy = carryToGeneral (특별전형 미충원 인원은 일반전형으로 이월)
--   - evaluationStage 상태 전이는 이번 단계에서 건드리지 않는다 (M5 시리즈와 동일하게
--     decision_results 스냅샷 멤버십을 후보 판정의 단일 기준으로 사용)
--
-- M6a와의 관계: documentCarry/finalTotal/4영역 완료여부는 전부 deep_final_aggregates
-- 캐시를 그대로 읽는다. 이 마이그레이션은 새 점수 계산 로직을 추가하지 않는다.

-- ============================================================
-- 1. run_final_decision — 최종 사정 실행 (simulation | final)
-- ============================================================

create or replace function public.run_final_decision(
  p_year int,
  p_round admission_round,
  p_mode decision_mode
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  quota jsonb;
  q_general int;
  q_incheon int;
  q_social int;
  unfilled_policy text;
  policy_recognized boolean;
  v_run_id uuid;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  incheon_passed int := 0;
  social_passed int := 0;
  general_quota_effective int;
  applicant_row record;
  boundary_rank int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    raise exception '이 라운드에는 확정된 M4 1차 서류사정(document final run)이 없습니다.'
      using errcode = '55000';
  end if;
  if v_round.config_revision_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.' using errcode = '55000';
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다.' using errcode = '55000';
  end if;

  q_general := (quota ->> 'general')::int;
  q_incheon := (quota ->> 'incheon')::int;
  q_social := (quota ->> 'social')::int;
  unfilled_policy := quota ->> 'unfilledTrackPolicy';
  policy_recognized := unfilled_policy in ('carryToGeneral', 'remainVacant');

  if q_general is null or q_incheon is null or q_social is null then
    raise exception 'config quota.general/incheon/social 값이 올바르지 않습니다: %', quota
      using errcode = '55000';
  end if;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  -- ── 후보 분류: 1차 서류 합격자 전원을 제외/보류/미완료/유효후보로 분류 ──────
  select count(*) into excluded_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  select count(*) into review_pending_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'reviewPending';

  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  -- ── 유효 후보 pool (제외/보류/미완료 아닌 전원, 4영역 complete 확정) ────────
  drop table if exists tmp_candidates;
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    tracks text[],
    final_total numeric,
    deep_group_interview numeric,
    writing numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  insert into tmp_candidates
  select
    dr.applicant_id, a.tracks, fa.final_total,
    (fa.group_score + fa.interview_student_score + fa.interview_parent_score),
    fa.writing_score,
    (dr.tiebreak_values ->> 'essay')::numeric,
    (dr.tiebreak_values ->> 'attendance')::numeric,
    (dr.tiebreak_values ->> 'academic')::numeric
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  select count(*) into v_candidate_count from tmp_candidates;

  -- ── 인천학생추천전형 사정 ────────────────────────────────────
  drop table if exists tmp_incheon_result;
  create temp table tmp_incheon_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_incheon_ranked;
  create temp table tmp_incheon_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'incheon' = any(tracks);

  select rnk into boundary_rank from tmp_incheon_ranked where rn = q_incheon;

  insert into tmp_incheon_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_incheon_ranked where rnk = boundary_rank and rn > q_incheon)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_incheon) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_incheon_ranked;

  select count(*) into incheon_passed from tmp_incheon_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_incheon_result where outcome = 'manualDecisionRequired');

  -- ── 사회통합전형 사정 (동일 패턴, incheon과 tracks가 겹치지 않으므로 독립) ──
  drop table if exists tmp_social_result;
  create temp table tmp_social_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_social_ranked;
  create temp table tmp_social_ranked on commit drop as
  select applicant_id,
    rank() over (order by final_total desc, deep_group_interview desc, writing desc,
                  essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by final_total desc, deep_group_interview desc, writing desc,
                        essay desc, attendance desc, academic desc) as rn
  from tmp_candidates
  where 'social' = any(tracks);

  boundary_rank := null;
  select rnk into boundary_rank from tmp_social_ranked where rn = q_social;

  insert into tmp_social_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_social_ranked where rnk = boundary_rank and rn > q_social)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, q_social) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_social_ranked;

  select count(*) into social_passed from tmp_social_result where outcome = 'passed';
  unresolved_count := unresolved_count
    + (select count(*) from tmp_social_result where outcome = 'manualDecisionRequired');

  -- ── 일반전형 유효 정원 (unfilledTrackPolicy) ────────────────────
  if unfilled_policy = 'carryToGeneral' then
    general_quota_effective := q_general + (q_incheon - incheon_passed) + (q_social - social_passed);
  else
    -- 'remainVacant' 또는 미확정('pending'/기타) — simulation 미리보기는 보수적으로
    -- 이월 없이 기본 정원만 사용한다. final 확정은 policy_recognized=false면 아래에서 차단.
    general_quota_effective := q_general;
  end if;

  -- ── 일반전형 pool: 특별전형에서 이미 passed/manualDecisionRequired인 사람 제외 ──
  drop table if exists tmp_general_result;
  create temp table tmp_general_result (applicant_id uuid primary key, outcome text not null, rnk int not null)
    on commit drop;

  drop table if exists tmp_general_ranked;
  create temp table tmp_general_ranked on commit drop as
  select c.applicant_id,
    rank() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                  c.essay desc, c.attendance desc, c.academic desc) as rnk,
    row_number() over (order by c.final_total desc, c.deep_group_interview desc, c.writing desc,
                        c.essay desc, c.attendance desc, c.academic desc) as rn
  from tmp_candidates c
  where c.applicant_id not in (
    select applicant_id from tmp_incheon_result where outcome in ('passed', 'manualDecisionRequired')
  )
  and c.applicant_id not in (
    select applicant_id from tmp_social_result where outcome in ('passed', 'manualDecisionRequired')
  );

  boundary_rank := null;
  select rnk into boundary_rank from tmp_general_ranked where rn = general_quota_effective;

  insert into tmp_general_result
  select applicant_id,
    case
      when boundary_rank is not null and rnk = boundary_rank
           and exists (select 1 from tmp_general_ranked where rnk = boundary_rank and rn > general_quota_effective)
        then 'manualDecisionRequired'
      when rnk <= coalesce(boundary_rank, general_quota_effective) then 'passed'
      else 'failed'
    end,
    rnk
  from tmp_general_ranked;

  unresolved_count := unresolved_count
    + (select count(*) from tmp_general_result where outcome = 'manualDecisionRequired');

  -- ── decision_runs 생성 (M4와 동일하게 먼저 running으로 생성) ─────────
  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'final', p_mode, 'running', v_round.config_revision_id, caller::text)
  returning id into v_run_id;

  -- ── decision_results 기록: 제외자(위원회 exclusion 결정) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, outcome,
     committee_decision_applied, track_result)
  select
    v_run_id, dr.applicant_id, p_year, p_round, 'final', fa.final_total, 'excluded'::decision_outcome, true,
    jsonb_build_object('incheon', 'notApplicable', 'social', 'notApplicable', 'general', 'notApplicable')
  from public.decision_results dr
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  -- ── decision_results 기록: 유효 후보 전원(전형 결합 결과) ───────────────
  insert into public.decision_results
    (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values,
     track_result, outcome)
  select
    v_run_id, c.applicant_id, p_year, p_round, 'final', c.final_total,
    coalesce(gr.rnk, ir.rnk, sr.rnk),
    jsonb_build_object(
      'deepGroupInterview', c.deep_group_interview, 'writing', c.writing,
      'essay', c.essay, 'attendance', c.attendance, 'academic', c.academic
    ),
    jsonb_build_object(
      'incheon', case when 'incheon' = any(c.tracks) then ir.outcome else 'notApplicable' end,
      'social', case when 'social' = any(c.tracks) then sr.outcome else 'notApplicable' end,
      'general', coalesce(gr.outcome, 'notApplicable')
    ),
    (case
      when ir.outcome = 'manualDecisionRequired' or sr.outcome = 'manualDecisionRequired'
           or gr.outcome = 'manualDecisionRequired' then 'manualDecisionRequired'
      when ir.outcome = 'passed' or sr.outcome = 'passed' or gr.outcome = 'passed' then 'passed'
      else 'failed'
    end)::decision_outcome
  from tmp_candidates c
  left join tmp_incheon_result ir on ir.applicant_id = c.applicant_id
  left join tmp_social_result sr on sr.applicant_id = c.applicant_id
  left join tmp_general_result gr on gr.applicant_id = c.applicant_id;

  select count(*) into v_result_count from public.decision_results where run_id = v_run_id;

  update public.decision_runs
  set candidate_count = v_candidate_count,
      result_count = v_result_count,
      unresolved_tie_count = unresolved_count,
      blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 확정 ─────────────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if incomplete_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '심층역량평가 4영역이 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', incomplete_count;
    end if;
    if review_pending_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '학폭 등 소명 절차가 아직 완료되지 않은 지원자가 %명 있어 final 확정을 진행할 수 없습니다.', review_pending_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;
    if not policy_recognized then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'config quota.unfilledTrackPolicy가 확정되지 않았습니다(현재: %). 입학전형위원회 결정 후 final 확정이 가능합니다.', unfilled_policy;
    end if;

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.final.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.final.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;

revoke all on function public.run_final_decision(int, admission_round, decision_mode) from public, anon;
grant execute on function public.run_final_decision(int, admission_round, decision_mode) to authenticated;

-- ============================================================
-- 2. get_final_decision_blockers — final 확정 전 관리자 확인용 사전 점검
--    (React 확인 dialog에서 blocking 0건 여부를 실행 전에 미리 보여주기 위함)
-- ============================================================

create or replace function public.get_final_decision_blockers(
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
  quota jsonb;
  blocking_count int;
  incomplete_count int;
  review_pending_count int;
  excluded_count int;
  candidate_count int;
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object(
      'ready', false, 'reason', 'NO_DOCUMENT_FINAL_RUN'
    );
  end if;

  select scoring_params -> 'quota' into quota
  from public.config_revisions where id = v_round.config_revision_id;

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  select count(*) into excluded_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'excluded';

  select count(*) into review_pending_count
  from public.decision_results dr
  join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and aa.exclusion_status = 'reviewPending';

  select count(*) into incomplete_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending')
    and coalesce(fa.complete, false) = false;

  select count(*) into candidate_count
  from public.decision_results dr
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  return jsonb_build_object(
    'ready', blocking_count = 0 and incomplete_count = 0 and review_pending_count = 0
      and (quota ->> 'unfilledTrackPolicy') in ('carryToGeneral', 'remainVacant'),
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', candidate_count,
    'blockingAlertCount', blocking_count,
    'incompleteDeepCount', incomplete_count,
    'reviewPendingCount', review_pending_count,
    'excludedCount', excluded_count,
    'unfilledTrackPolicy', quota ->> 'unfilledTrackPolicy',
    'quota', quota
  );
end;
$$;

revoke all on function public.get_final_decision_blockers(int, admission_round) from public, anon;
grant execute on function public.get_final_decision_blockers(int, admission_round) to authenticated;
