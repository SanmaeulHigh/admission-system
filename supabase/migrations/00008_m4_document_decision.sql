-- 새봄고 입학전형 시스템 — M4 1차 사정 (Sprint 4)
-- 마스터 스펙 v1.2 섹션 3.19(decisionRuns/decisionResults/committeeDecisions),
-- 5.2(집계), 5.3(사정로직), 5.6(decisionRuns 실행원칙) 대응.
--
-- 단순화(문서화): 스펙은 aggregates/{applicantId}를 트리거로 반응형 유지하는
-- 컬렉션으로 설계했지만, 이 구현은 사정 실행(run_document_decision) 시점에
-- _compute_document_aggregate로 즉석 계산한다. 이 학교 규모(지원자 수십 명)
-- 에서는 트리거 기반 상시 집계 인프라 없이도 충분히 빠르고, source-of-truth
-- (scoresXxx 제출값)만 보고 항상 최신값을 계산하므로 staleness 문제 자체가
-- 없다. 성능이 실제로 문제가 되면 그때 캐시 테이블+트리거로 전환한다.

-- ============================================================
-- 1. decision_runs / decision_results / committee_decisions
-- ============================================================

create type decision_type as enum ('document', 'final');
create type decision_mode as enum ('simulation', 'final');
create type decision_run_status as enum ('running', 'completed', 'finalized', 'failed');
create type decision_outcome as enum ('passed', 'failed', 'excluded', 'manualDecisionRequired');

create table public.decision_runs (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  decision_type decision_type not null,
  mode decision_mode not null,
  status decision_run_status not null default 'running',
  config_revision_id uuid not null references public.config_revisions (id),
  aggregate_snapshot_at timestamptz not null default now(),
  candidate_count int not null default 0,
  result_count int not null default 0,
  unresolved_tie_count int not null default 0,
  blocking_alert_count int not null default 0,
  created_at timestamptz not null default now(),
  created_by text not null,
  finalized_at timestamptz,
  finalized_by text
);

create table public.decision_results (
  run_id uuid not null references public.decision_runs (id) on delete cascade,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  decision_type decision_type not null,
  total_score numeric,
  rank int,
  tiebreak_values jsonb not null default '{}'::jsonb,
  track_result jsonb not null default '{}'::jsonb,
  outcome decision_outcome not null,
  committee_decision_applied boolean not null default false,
  committee_decision_code text,
  created_at timestamptz not null default now(),
  primary key (run_id, applicant_id)
);

create table public.committee_decisions (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  decision_type text not null check (decision_type in
    ('violenceReview', 'exclusion', 'unresolvedTie', 'evaluationOverride', 'other')),
  outcome_code text not null,
  meeting_date date,
  rationale text not null,
  evidence_document_ids uuid[] not null default '{}',
  recorded_at timestamptz not null default now(),
  recorded_by text not null,
  related_decision_run_id uuid references public.decision_runs (id)
);

comment on table public.decision_runs is
  'simulation은 몇 번이든 실행 가능하며 발표·상태변경 근거로 쓸 수 없다. final은 검증 통과 시에만 applicants/evaluation_roster를 실제로 변경한다.';
comment on table public.committee_decisions is
  '학폭·부적합·동점 등 사람이 결정해야 하는 사안의 기록. 시스템은 자동 감점·자동 제외하지 않는다 (섹션 5.3.4).';

alter table public.decision_runs enable row level security;
alter table public.decision_results enable row level security;
alter table public.committee_decisions enable row level security;

create policy decision_runs_select_admins
  on public.decision_runs for select
  using (public.has_role('superadmin') or public.has_role('admin') or public.has_role('viewer'));

create policy decision_results_select_admins
  on public.decision_results for select
  using (public.has_role('superadmin') or public.has_role('admin') or public.has_role('viewer'));

create policy committee_decisions_select_admins
  on public.committee_decisions for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = RPC로만

-- ============================================================
-- 2. 문서평가 집계 (섹션 5.2 산식 그대로, 즉석 계산)
-- ============================================================

create or replace function public._compute_document_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  app record;
  rev_id uuid;
  params jsonb;
  attendance_score numeric;
  academic_score numeric;
  community_score numeric;
  community_count int;
  essay_score numeric;
  essay_count int;
  opinion_score numeric;
  opinion_count int;
  raw_total numeric;
  final_total numeric;
  is_complete boolean;
  bonus_applied boolean := false;
  bonus_amount numeric := 0;
begin
  select id, year, round, tracks, bonus_eligible, bonus_reason
    into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- 출결 (5.2.1): 필수 1건, 없으면 null/미확정
  select (server_computed ->> 'score')::numeric into attendance_score
    from public.scores_attendance
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 학업성실도 (5.2.2)
  select (server_computed ->> 'score')::numeric into academic_score
    from public.scores_academic
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 공동체 (5.2.3): 정확히 2인 제출 필요, 아니면 미확정
  select count(*), avg((server_computed ->> 'score')::numeric)
    into community_count, community_score
    from public.scores_community
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if community_count <> 2 then
    community_score := null;
  end if;

  -- 자소서 (5.2.4): 정확히 5인 제출 필요
  select count(*), sum((server_computed ->> 'total')::numeric)
    into essay_count, essay_score
    from public.scores_essay
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if essay_count <> 5 then
    essay_score := null;
  end if;

  -- 소견서 (5.2.5): 정확히 4인 제출 필요
  select count(*), sum((server_computed ->> 'total')::numeric)
    into opinion_count, opinion_score
    from public.scores_opinion
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if opinion_count <> 4 then
    opinion_score := null;
  end if;

  -- 서류평가 원점수 (5.2.6): 5개 영역 전부 확정일 때만
  is_complete := attendance_score is not null and academic_score is not null
    and community_score is not null and essay_score is not null and opinion_score is not null;

  if is_complete then
    raw_total := attendance_score + academic_score + community_score + essay_score + opinion_score;

    -- 가산점 (5.2.7, applyLevel='total' 기본값 — 섹션 5.8 D 확인 전까지 이 값 사용)
    -- config에 bonus 파라미터가 아직 없으면(설정 전 단계) 안전하게 가산점 미적용으로 처리.
    if params -> 'bonus' is not null
       and 'incheon' = any(app.tracks)
       and app.bonus_eligible = true
       and app.bonus_reason = any(
         array(select jsonb_array_elements_text(coalesce(params -> 'bonus' -> 'eligibleReasons', '[]'::jsonb)))
       )
    then
      bonus_applied := true;
      final_total := least(
        coalesce((params -> 'bonus' ->> 'cap')::numeric, raw_total),
        raw_total * (1 + coalesce((params -> 'bonus' ->> 'rate')::numeric, 0))
      );
      bonus_amount := final_total - raw_total;
    else
      final_total := raw_total;
    end if;
  end if;

  return jsonb_build_object(
    'attendance', attendance_score,
    'academic', academic_score,
    'community', community_score,
    'essay', essay_score,
    'opinion', opinion_score,
    'complete', is_complete,
    'rawTotal', raw_total,
    'bonusApplied', bonus_applied,
    'bonusAmount', bonus_amount,
    'finalTotal', final_total
  );
end;
$$;

revoke execute on function public._compute_document_aggregate(uuid) from anon, authenticated;

-- ============================================================
-- 3. run_document_decision — 1차 사정 실행 (simulation | final)
--    섹션 5.3(정렬·동점), 5.6(실행 원칙) 그대로 구현.
-- ============================================================

create or replace function public.run_document_decision(
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
  rev_id uuid;
  quota jsonb;
  pass_limit int;
  v_run_id uuid;
  blocking_count int;
  applicant_row record;
  agg jsonb;
  boundary_rank int;
  v_candidate_count int := 0;
  v_result_count int := 0;
  unresolved_count int := 0;
  next_exam_seq int;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(p_year, p_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params -> 'quota' into quota from public.config_revisions where id = rev_id;
  if quota is null then
    raise exception 'config에 quota 파라미터가 없습니다. setup 스크립트를 먼저 실행하세요.';
  end if;
  pass_limit := floor((quota ->> 'total')::numeric * (quota ->> 'screeningMultiple')::numeric);

  select count(*) into blocking_count from public.evaluation_alerts
    where year = p_year and round = p_round and severity = 'blocking' and status = 'open';

  insert into public.decision_runs
    (year, round, decision_type, mode, status, config_revision_id, created_by)
  values
    (p_year, p_round, 'document', p_mode, 'running', rev_id, caller::text)
  returning id into v_run_id;

  -- 후보군: 접수완료 + 사정제외 아님 (섹션 5.3.1 — evaluationStage 게이트는
  -- 아직 별도 전환 단계를 만들지 않아 이번 구현에서는 생략, 검토메모 기록)
  create temp table tmp_candidates (
    applicant_id uuid primary key,
    document_final numeric,
    community numeric,
    essay numeric,
    attendance numeric,
    academic numeric
  ) on commit drop;

  for applicant_row in
    select a.id from public.applicants a
    left join public.applicants_admin aa on aa.applicant_id = a.id
    where a.year = p_year and a.round = p_round and a.application_status = 'complete'
      and coalesce(aa.exclusion_status, 'none') <> 'excluded'
  loop
    agg := public._compute_document_aggregate(applicant_row.id);
    if (agg ->> 'complete')::boolean then
      insert into tmp_candidates values (
        applicant_row.id,
        (agg ->> 'finalTotal')::numeric,
        (agg ->> 'community')::numeric,
        (agg ->> 'essay')::numeric,
        (agg ->> 'attendance')::numeric,
        (agg ->> 'academic')::numeric
      );
      v_candidate_count := v_candidate_count + 1;
    end if;
  end loop;

  -- 순위 산정 (섹션 5.3.3 정렬 기준 그대로) + 동점 경계 판정
  create temp table tmp_ranked on commit drop as
  select *,
    rank() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rnk,
    row_number() over (order by document_final desc, community desc, essay desc, attendance desc, academic desc) as rn
  from tmp_candidates;

  select rnk into boundary_rank from tmp_ranked where rn = pass_limit;

  -- decision_results 기록
  for applicant_row in select * from tmp_ranked loop
    declare
      this_outcome decision_outcome;
    begin
      if boundary_rank is not null and applicant_row.rnk = boundary_rank
         and (select count(*) from tmp_ranked where rnk = boundary_rank and rn > pass_limit) > 0 then
        this_outcome := 'manualDecisionRequired';
        unresolved_count := unresolved_count + 1;
      elsif applicant_row.rnk <= coalesce(boundary_rank, pass_limit) then
        this_outcome := 'passed';
      else
        this_outcome := 'failed';
      end if;

      insert into public.decision_results
        (run_id, applicant_id, year, round, decision_type, total_score, rank, tiebreak_values, outcome)
      values
        (v_run_id, applicant_row.applicant_id, p_year, p_round, 'document', applicant_row.document_final,
         applicant_row.rnk,
         jsonb_build_object(
           'community', applicant_row.community, 'essay', applicant_row.essay,
           'attendance', applicant_row.attendance, 'academic', applicant_row.academic
         ),
         this_outcome);
      v_result_count := v_result_count + 1;
    end;
  end loop;

  update public.decision_runs
  set candidate_count = v_candidate_count, result_count = v_result_count,
      unresolved_tie_count = unresolved_count, blocking_alert_count = blocking_count,
      status = 'completed'
  where id = v_run_id;

  -- ── final 모드: 검증 통과 시에만 실제 반영 ──────────────────
  if p_mode = 'final' then
    if blocking_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception 'blocking 경보가 %건 있어 final 확정을 진행할 수 없습니다.', blocking_count;
    end if;
    if unresolved_count > 0 then
      update public.decision_runs set status = 'failed' where id = v_run_id;
      raise exception '미해결 동점(%건)이 있어 final 확정을 진행할 수 없습니다. 입학전형위원회 결정을 먼저 기록하세요.', unresolved_count;
    end if;

    -- 합격자 수험번호 채번 (섹션 5.6 — 서버 transaction 일괄 발급)
    select coalesce(max(substring(exam_no from '\d+$')::int), 0) into next_exam_seq
      from public.evaluation_roster where year = p_year and round = p_round and exam_no is not null;

    for applicant_row in
      select dr.applicant_id from public.decision_results dr
      where dr.run_id = v_run_id and dr.outcome = 'passed'
      order by dr.rank
    loop
      next_exam_seq := next_exam_seq + 1;
      update public.applicants set evaluation_stage = 'documentPassed', updated_at = now(), updated_by = caller::text
        where id = applicant_row.applicant_id;
      update public.evaluation_roster
        set exam_no = p_year::text || '-' || lpad(next_exam_seq::text, 3, '0'),
            evaluation_stage = 'documentPassed', updated_at = now()
        where applicant_id = applicant_row.applicant_id;
    end loop;

    update public.applicants set evaluation_stage = 'documentFailed', updated_at = now(), updated_by = caller::text
      where id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');
    update public.evaluation_roster set evaluation_stage = 'documentFailed', updated_at = now()
      where applicant_id in (select dr.applicant_id from public.decision_results dr where dr.run_id = v_run_id and dr.outcome = 'failed');

    update public.decision_runs
    set status = 'finalized', finalized_at = now(), finalized_by = caller::text
    where id = v_run_id;

    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.finalized', 'decision_runs', v_run_id::text);
  else
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
    values (p_year, p_round, 'user', caller::text, 'decision.document.simulated', 'decision_runs', v_run_id::text);
  end if;

  return v_run_id;
end;
$$;

revoke execute on function public.run_document_decision(int, admission_round, decision_mode) from anon;

-- ============================================================
-- 4. record_committee_decision — 위원회 결정 기록 (사정제외·동점 등)
-- ============================================================

create or replace function public.record_committee_decision(
  p_applicant_id uuid,
  p_decision_type text,
  p_outcome_code text,
  p_rationale text,
  p_meeting_date date default null,
  p_related_decision_run_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
  new_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_rationale is null or length(trim(p_rationale)) < 5 then
    raise exception '결정 사유(rationale)는 최소 5자 이상 입력해야 합니다.';
  end if;

  select year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.committee_decisions
    (year, round, applicant_id, decision_type, outcome_code, meeting_date, rationale,
     related_decision_run_id, recorded_by)
  values
    (app.year, app.round, p_applicant_id, p_decision_type, p_outcome_code, p_meeting_date, p_rationale,
     p_related_decision_run_id, caller::text)
  returning id into new_id;

  -- exclusion 결정이면 applicantsAdmin에 즉시 반영 (시스템 자동판단 아님 — 위원회 결정 기록만 반영)
  if p_decision_type = 'exclusion' and p_outcome_code = 'excluded' then
    update public.applicants_admin
    set exclusion_status = 'excluded', updated_at = now(), updated_by = caller::text
    where applicant_id = p_applicant_id;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (app.year, app.round, 'user', caller::text, 'committee_decision.recorded', 'committee_decisions',
     new_id::text, p_applicant_id::text);

  return new_id;
end;
$$;

revoke execute on function public.record_committee_decision(uuid, text, text, text, date, uuid) from anon;
