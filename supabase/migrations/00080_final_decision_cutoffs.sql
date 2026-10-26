-- 새봄고 입학전형 시스템 — 최종 사정 합격선·과락선 (2026-10-01)
--
-- 지금까지 최종 사정은 전형별 모집정원만큼 총점 순으로 합격시켰다. 지원자가 정원보다
-- 적으면 점수와 관계없이 전원 합격이었다. 회차별로 합격선·과락선을 두어, 기준에
-- 못 미친 지원자는 정원 안이어도 불합격시킨다.
--
-- 기준(모두 선택, 비우면 미적용, 전 전형 공통):
--   finalTotal(최종 총점 합격선), document(서류평가 점수), group(모둠활동),
--   interview(학생+학부모 면접 합계), writing(글쓰기) — 각각 "이 점수 미만이면 불합격".
--
-- 사정 방식: 기준에 걸린 지원자는 순위 경쟁 전에 불합격(사유를 track_result.cutoffReason에
-- 남김). 나머지끼리 기존 정원·순위·동점 규칙으로 사정하고, 못 채운 자리는 미충원으로 남는다
-- (특별전형 미충원의 일반전형 이월 정책은 기존 그대로).
-- 사정할 때 쓴 기준값은 decision_runs.cutoffs와 감사 기록에 함께 남긴다.

alter table public.admission_rounds
  add column if not exists final_cutoffs jsonb not null default '{}'::jsonb;
alter table public.decision_runs
  add column if not exists cutoffs jsonb;

comment on column public.admission_rounds.final_cutoffs is
  '최종 사정 합격선·과락선. 키: finalTotal, document, group, interview, writing(값 미만이면 불합격). 빈 객체=미적용.';
comment on column public.decision_runs.cutoffs is '이 사정에 적용된 합격선·과락선(admission_rounds.final_cutoffs 사본).';

-- 슈퍼관리자가 합격선·과락선을 정한다. 최종 사정이 이미 확정된 회차는 바꿀 수 없다.
create or replace function public.set_final_cutoffs(
  p_year int,
  p_round admission_round,
  p_cutoffs jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  k text;
  v jsonb;
  clean jsonb := '{}'::jsonb;
begin
  caller := public._require_superadmin();

  if jsonb_typeof(coalesce(p_cutoffs, '{}'::jsonb)) <> 'object' then
    raise exception '기준값 형식이 올바르지 않습니다.' using errcode = '22023';
  end if;
  for k, v in select key, value from jsonb_each(coalesce(p_cutoffs, '{}'::jsonb))
  loop
    if k not in ('finalTotal', 'document', 'group', 'interview', 'writing') then
      raise exception '알 수 없는 기준입니다: %', k using errcode = '22023';
    end if;
    if v is null or jsonb_typeof(v) = 'null' then
      continue; -- 빈칸 = 미적용
    end if;
    if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 then
      raise exception '% 기준은 0 이상의 숫자여야 합니다.', k using errcode = '22023';
    end if;
    clean := clean || jsonb_build_object(k, v);
  end loop;

  if exists (
    select 1 from public.decision_runs
    where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  ) then
    raise exception '최종 사정이 이미 확정된 회차라 합격선을 바꿀 수 없습니다.' using errcode = '55000';
  end if;

  update public.admission_rounds set final_cutoffs = clean, updated_at = now(), updated_by = caller::text
  where year = p_year and round = p_round;
  if not found then
    raise exception '회차(%, %)를 찾을 수 없습니다.', p_year, p_round using errcode = 'P0002';
  end if;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text, 'decision.final.cutoffs_set', 'admission_rounds',
          p_year::text || '_' || p_round::text, jsonb_build_object('cutoffs', clean));

  return clean;
end;
$$;

revoke all on function public.set_final_cutoffs(int, admission_round, jsonb) from public, anon;
grant execute on function public.set_final_cutoffs(int, admission_round, jsonb) to authenticated;

-- 최종 사정: 서버 DB의 현재 정의에 합격선·과락선 적용만 더했다.
CREATE OR REPLACE FUNCTION public.run_final_decision(p_year integer, p_round admission_round, p_mode decision_mode)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_cut jsonb;
  below_cutoff_count int := 0;
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
  -- 합격선·과락선(00080). 빈 객체면 지금까지와 똑같이 동작한다.
  v_cut := coalesce(v_round.final_cutoffs, '{}'::jsonb);

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
    academic numeric,
    document_score numeric,
    group_score numeric,
    interview_score numeric,
    cutoff_reason text
  ) on commit drop;

  insert into tmp_candidates
  select
    dr.applicant_id, a.tracks, fa.final_total,
    (fa.group_score + fa.interview_student_score + fa.interview_parent_score),
    fa.writing_score,
    (dr.tiebreak_values ->> 'essay')::numeric,
    (dr.tiebreak_values ->> 'attendance')::numeric,
    (dr.tiebreak_values ->> 'academic')::numeric,
    fa.document_score,
    fa.group_score,
    (fa.interview_student_score + fa.interview_parent_score),
    null
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id and fa.complete = true
  left join public.applicants_admin aa on aa.applicant_id = dr.applicant_id
  where dr.run_id = v_round.document_decision_run_id and dr.outcome = 'passed'
    and coalesce(aa.exclusion_status, 'none') not in ('excluded', 'reviewPending');

  select count(*) into v_candidate_count from tmp_candidates;

  -- ── 합격선·과락선 적용(00080): 걸린 지원자는 순위 경쟁 전에 불합격 처리 ──────
  -- 기준을 넘은 지원자끼리만 정원을 채우고, 못 채운 자리는 미충원으로 남는다.
  update tmp_candidates c set cutoff_reason = nullif(concat_ws(' · ',
    case when v_cut ? 'finalTotal' and c.final_total < (v_cut ->> 'finalTotal')::numeric
      then format('최종 총점 합격선 미달(%s < %s)', round(c.final_total, 2), v_cut ->> 'finalTotal') end,
    case when v_cut ? 'document' and c.document_score < (v_cut ->> 'document')::numeric
      then format('서류평가 과락(%s < %s)', round(c.document_score, 2), v_cut ->> 'document') end,
    case when v_cut ? 'group' and c.group_score < (v_cut ->> 'group')::numeric
      then format('모둠활동 과락(%s < %s)', round(c.group_score, 2), v_cut ->> 'group') end,
    case when v_cut ? 'interview' and c.interview_score < (v_cut ->> 'interview')::numeric
      then format('면접 과락(%s < %s)', round(c.interview_score, 2), v_cut ->> 'interview') end,
    case when v_cut ? 'writing' and c.writing < (v_cut ->> 'writing')::numeric
      then format('글쓰기 과락(%s < %s)', round(c.writing, 2), v_cut ->> 'writing') end
  ), '')
  -- 모든 후보 행이 대상이지만 WHERE를 명시한다: API 접속(authenticator)에는
  -- pg_safeupdate가 걸려 있어 WHERE 없는 UPDATE를 거부한다.
  where c.applicant_id is not null;
  select count(*) into below_cutoff_count from tmp_candidates where cutoff_reason is not null;

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
  where 'incheon' = any(tracks) and cutoff_reason is null;

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
  where 'social' = any(tracks) and cutoff_reason is null;

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
  where c.cutoff_reason is null
  and c.applicant_id not in (
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
    (year, round, decision_type, mode, status, config_revision_id, created_by, cutoffs)
  values
    (p_year, p_round, 'final', p_mode, 'running', v_round.config_revision_id, caller::text, v_cut)
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
      'general', coalesce(gr.outcome, 'notApplicable'),
      'cutoffReason', c.cutoff_reason
    ),
    (case
      when c.cutoff_reason is not null then 'failed'
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

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'decision.final.finalized', 'decision_runs', v_run_id::text,
            jsonb_build_object('cutoffs', v_cut, 'belowCutoffCount', below_cutoff_count));
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'decision.final.simulated', 'decision_runs', v_run_id::text,
            jsonb_build_object('cutoffs', v_cut, 'belowCutoffCount', below_cutoff_count));
  end if;

  return v_run_id;
end;
$function$;
