-- 새봄고 입학전형 시스템 — M6a 심층역량평가 최종 집계 (Sprint 6 시작)
-- 마스터 스펙 v1.2 섹션 5.4.1(서류평가 400점 환산), 5.4.6(최종 총점) 대응.
-- 요강 승인본(새봄고 공고 제2026-42호, 2026.7.6) "(2) 2차 심층역량평가 ① 1차 서류평가
-- 획득 점수(400점 만점): 1차 서류평가 획득 점수(1,000점 만점)의 4/10를 반영함" 근거로,
-- documentCarry는 가산점 포함·1,000점 cap 적용 후의 "1차 서류평가 점수"
-- (= decision_results.total_score, 요강이 1차 합불 판정에도 그대로 쓰는 바로 그 값)를
-- 그대로 0.4배 환산해 사용한다 (담당 교사 확인, 2026-07-08). 가산 전 원점수 별도 이월 아님.
--
-- 핵심 불변조건
--   1) documentCarry의 근거는 admission_rounds.document_decision_run_id가 가리키는
--      M4 final decisionRun의 decision_results.total_score 스냅샷만 사용한다(재계산 금지).
--   2) 심층 4영역(group/interviewStudent/interviewParent/writing) 중 하나라도 미완료면
--      finalTotal은 null이다. 미채점을 0점으로 치환하지 않는다.
--   3) 이 마이그레이션이 만드는 트리거는 scores_group/scores_interview/scores_writing
--      "제출"이라는 무관한 작업의 부작용으로 실행된다. deep.documentCarry config가
--      아직 없다는 이유로 예외를 던지면 그 무관한 제출 자체가 실패한다 — 그래서
--      config 부재는 예외가 아니라 "documentCarry 영역 자체가 미확정"으로 완만하게
--      처리한다(fail-soft). 강제 예외는 관리자가 명시적으로 호출하는
--      recompute_final_aggregates에서도 던지지 않는다 — 동일한 이유.
--   4) 클라이언트는 finalTotal을 계산하지 않는다. 이 집계는 캐시 테이블(트리거 갱신)
--      이며 M5b deep_group_aggregates와 동일한 패턴을 따른다.

-- ============================================================
-- 1. deep_final_aggregates
-- ============================================================

create table public.deep_final_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  document_decision_run_id uuid not null references public.decision_runs (id),

  document_score numeric not null,
  document_carry numeric,

  group_score numeric,
  group_complete boolean not null default false,

  interview_student_score numeric,
  interview_student_complete boolean not null default false,

  interview_parent_score numeric,
  interview_parent_complete boolean not null default false,

  writing_score numeric,
  writing_complete boolean not null default false,

  missing_areas text[] not null default '{}',
  complete boolean not null default false,
  final_total numeric,

  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.deep_final_aggregates is
  'M6a 서버 집계 캐시. documentCarry는 decision_results(document, final, finalized) 스냅샷 기준.
   group/interviewStudent/interviewParent/writing 4영역 전부 complete=true이고
   deep.documentCarry config가 존재할 때만 complete=true, final_total 확정.
   하나라도 미충족이면 complete=false, final_total=null, missing_areas에 사유 기록.';

alter table public.deep_final_aggregates enable row level security;

create policy deep_final_aggregates_select_admin_viewer
  on public.deep_final_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- write 정책 없음: 트리거·RPC 전용.

-- ============================================================
-- 2. _compute_final_aggregate — 즉석 계산 (내부 전용)
-- ============================================================

create or replace function public._compute_final_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_app record;
  v_round record;
  v_carry_params jsonb;
  v_multiplier numeric;
  v_max numeric;
  v_doc_score numeric;
  v_doc_carry numeric;
  v_group_complete boolean;
  v_group_score numeric;
  v_int_student_complete boolean;
  v_int_student_score numeric;
  v_int_parent_complete boolean;
  v_int_parent_score numeric;
  v_writing_complete boolean;
  v_writing_score numeric;
  v_missing text[] := '{}';
  v_complete boolean;
  v_final_total numeric;
  v_summary jsonb;
begin
  select a.id, a.year, a.round into v_app
  from public.applicants a
  where a.id = p_applicant_id;

  if v_app is null then
    return jsonb_build_object('applicable', false, 'reason', 'APPLICANT_NOT_FOUND');
  end if;

  select * into v_round
  from public.admission_rounds
  where year = v_app.year and round = v_app.round;

  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object('applicable', false, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  -- documentCarry의 유일한 근거: 확정된 M4 final decisionRun 스냅샷.
  -- 현재 aggregate/원자료를 다시 계산하지 않는다.
  select dr.total_score into v_doc_score
  from public.decision_results dr
  where dr.run_id = v_round.document_decision_run_id
    and dr.applicant_id = p_applicant_id
    and dr.outcome = 'passed';

  if v_doc_score is null then
    return jsonb_build_object('applicable', false, 'reason', 'NOT_DOCUMENT_PASSED');
  end if;

  select scoring_params #> '{deep,documentCarry}' into v_carry_params
  from public.config_revisions
  where id = v_round.config_revision_id;

  v_missing := '{}';

  if v_carry_params is null
     or coalesce((v_carry_params ->> 'multiplier')::numeric, 0) <= 0
     or coalesce((v_carry_params ->> 'max')::numeric, 0) <= 0 then
    -- fail-soft: config 부재/불완전은 예외가 아니라 documentCarry 영역 자체를
    -- 미확정으로 표시한다 (주석 3번 참조).
    v_doc_carry := null;
    v_missing := array_append(v_missing, 'documentCarry');
  else
    v_multiplier := (v_carry_params ->> 'multiplier')::numeric;
    v_max := (v_carry_params ->> 'max')::numeric;
    v_doc_carry := least(v_max, v_doc_score * v_multiplier);
  end if;

  select complete, score into v_group_complete, v_group_score
  from public.deep_group_aggregates
  where applicant_id = p_applicant_id;

  select student_complete, student_score, parent_complete, parent_score
    into v_int_student_complete, v_int_student_score, v_int_parent_complete, v_int_parent_score
  from public.deep_interview_aggregates
  where applicant_id = p_applicant_id;

  select complete, score into v_writing_complete, v_writing_score
  from public.deep_writing_aggregates
  where applicant_id = p_applicant_id;

  if not coalesce(v_group_complete, false) then
    v_missing := array_append(v_missing, 'group');
  end if;
  if not coalesce(v_int_student_complete, false) then
    v_missing := array_append(v_missing, 'interviewStudent');
  end if;
  if not coalesce(v_int_parent_complete, false) then
    v_missing := array_append(v_missing, 'interviewParent');
  end if;
  if not coalesce(v_writing_complete, false) then
    v_missing := array_append(v_missing, 'writing');
  end if;

  v_complete := (array_length(v_missing, 1) is null);

  if v_complete then
    v_final_total := v_doc_carry + v_group_score + v_int_student_score
      + v_int_parent_score + v_writing_score;
  else
    v_final_total := null;
  end if;

  v_summary := jsonb_build_object(
    'documentDecisionRunId', v_round.document_decision_run_id,
    'configRevisionId', v_round.config_revision_id,
    'groupComputedAt', (select computed_at from public.deep_group_aggregates where applicant_id = p_applicant_id),
    'interviewComputedAt', (select computed_at from public.deep_interview_aggregates where applicant_id = p_applicant_id),
    'writingComputedAt', (select computed_at from public.deep_writing_aggregates where applicant_id = p_applicant_id)
  );

  return jsonb_build_object(
    'applicable', true,
    'documentScore', v_doc_score,
    'documentCarry', v_doc_carry,
    'groupScore', v_group_score,
    'groupComplete', coalesce(v_group_complete, false),
    'interviewStudentScore', v_int_student_score,
    'interviewStudentComplete', coalesce(v_int_student_complete, false),
    'interviewParentScore', v_int_parent_score,
    'interviewParentComplete', coalesce(v_int_parent_complete, false),
    'writingScore', v_writing_score,
    'writingComplete', coalesce(v_writing_complete, false),
    'missingAreas', to_jsonb(v_missing),
    'complete', v_complete,
    'finalTotal', v_final_total,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm6a-final-aggregate-v1'
  );
end;
$$;

revoke all on function public._compute_final_aggregate(uuid) from public, anon, authenticated;

-- ============================================================
-- 3. _refresh_final_aggregate — 캐시 upsert (내부 전용)
-- ============================================================

create or replace function public._refresh_final_aggregate(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_agg jsonb;
  v_missing text[];
begin
  v_agg := public._compute_final_aggregate(p_applicant_id);

  if not (v_agg ->> 'applicable')::boolean then
    delete from public.deep_final_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select array(select jsonb_array_elements_text(v_agg -> 'missingAreas')) into v_missing;

  insert into public.deep_final_aggregates (
    applicant_id, year, round, config_revision_id, document_decision_run_id,
    document_score, document_carry,
    group_score, group_complete,
    interview_student_score, interview_student_complete,
    interview_parent_score, interview_parent_complete,
    writing_score, writing_complete,
    missing_areas, complete, final_total,
    function_version, computed_at
  )
  select
    p_applicant_id, a.year, a.round,
    (v_agg #>> '{sourceRevisionSummary,configRevisionId}')::uuid,
    (v_agg #>> '{sourceRevisionSummary,documentDecisionRunId}')::uuid,
    (v_agg ->> 'documentScore')::numeric,
    (v_agg ->> 'documentCarry')::numeric,
    (v_agg ->> 'groupScore')::numeric,
    (v_agg ->> 'groupComplete')::boolean,
    (v_agg ->> 'interviewStudentScore')::numeric,
    (v_agg ->> 'interviewStudentComplete')::boolean,
    (v_agg ->> 'interviewParentScore')::numeric,
    (v_agg ->> 'interviewParentComplete')::boolean,
    (v_agg ->> 'writingScore')::numeric,
    (v_agg ->> 'writingComplete')::boolean,
    v_missing,
    (v_agg ->> 'complete')::boolean,
    (v_agg ->> 'finalTotal')::numeric,
    v_agg ->> 'functionVersion', now()
  from public.applicants a
  where a.id = p_applicant_id
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    document_decision_run_id = excluded.document_decision_run_id,
    document_score = excluded.document_score,
    document_carry = excluded.document_carry,
    group_score = excluded.group_score,
    group_complete = excluded.group_complete,
    interview_student_score = excluded.interview_student_score,
    interview_student_complete = excluded.interview_student_complete,
    interview_parent_score = excluded.interview_parent_score,
    interview_parent_complete = excluded.interview_parent_complete,
    writing_score = excluded.writing_score,
    writing_complete = excluded.writing_complete,
    missing_areas = excluded.missing_areas,
    complete = excluded.complete,
    final_total = excluded.final_total,
    function_version = excluded.function_version,
    computed_at = now();
end;
$$;

revoke all on function public._refresh_final_aggregate(uuid) from public, anon, authenticated;

-- ============================================================
-- 4. 트리거 — group/interview/writing aggregate 변경 시 자동 갱신
--    세 테이블 모두 applicant_id 컬럼을 가지므로 트리거 함수 1개를 공유한다.
-- ============================================================

create or replace function public._trg_refresh_final_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_final_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_final_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._trg_refresh_final_aggregate() from public, anon, authenticated;

drop trigger if exists trg_final_aggregate_from_group on public.deep_group_aggregates;
create trigger trg_final_aggregate_from_group
  after insert or update or delete on public.deep_group_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

drop trigger if exists trg_final_aggregate_from_interview on public.deep_interview_aggregates;
create trigger trg_final_aggregate_from_interview
  after insert or update or delete on public.deep_interview_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

drop trigger if exists trg_final_aggregate_from_writing on public.deep_writing_aggregates;
create trigger trg_final_aggregate_from_writing
  after insert or update or delete on public.deep_writing_aggregates
  for each row execute function public._trg_refresh_final_aggregate();

-- 주의: document_decision_run_id 자체가 (재사정 등으로) 바뀌는 경우는 이 트리거의
-- 대상이 아니다 — 그 경로는 STALE_AFTER_FINALIZATION 상당 처리가 시스템 전체에
-- 아직 없다는 기존 gap과 동일 선상에 있으며, M6b에서 별도로 다룬다.

-- ============================================================
-- 5. recompute_final_aggregates — 관리자 수동 재계산 (config 최초 반영 후 1회 실행 등)
-- ============================================================

create or replace function public.recompute_final_aggregates(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_processed int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;
  if v_round is null then
    raise exception '해당 연도/차수의 admission_round가 없습니다.' using errcode = '55000';
  end if;
  if v_round.document_decision_run_id is null then
    return jsonb_build_object('processed', 0, 'reason', 'NO_DOCUMENT_FINAL_RUN');
  end if;

  for r in
    select dr.applicant_id
    from public.decision_results dr
    where dr.run_id = v_round.document_decision_run_id
      and dr.outcome = 'passed'
  loop
    perform public._refresh_final_aggregate(r.applicant_id);
    v_processed := v_processed + 1;
  end loop;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type)
  values (p_year, p_round, 'user', caller::text, 'deep_final_aggregates.recomputed', 'deep_final_aggregates');

  return jsonb_build_object('processed', v_processed);
end;
$$;

revoke all on function public.recompute_final_aggregates(int, admission_round) from public, anon;
grant execute on function public.recompute_final_aggregates(int, admission_round) to authenticated;

-- ============================================================
-- 6. get_m6_final_progress — 관리자 진행률 조회. 개별 위원 점수는 노출하지 않는다.
-- ============================================================

create or replace function public.get_m6_final_progress(
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
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  select * into v_round from public.admission_rounds where year = p_year and round = p_round;

  if v_round is null or v_round.document_decision_run_id is null then
    return jsonb_build_object(
      'year', p_year, 'round', p_round,
      'documentDecisionRunId', null,
      'items', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'year', p_year, 'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', dr.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'tracks', a.tracks,
        'documentScore', dr.total_score,
        'documentCarry', fa.document_carry,
        'groupComplete', coalesce(fa.group_complete, false),
        'groupScore', fa.group_score,
        'interviewStudentComplete', coalesce(fa.interview_student_complete, false),
        'interviewStudentScore', fa.interview_student_score,
        'interviewParentComplete', coalesce(fa.interview_parent_complete, false),
        'interviewParentScore', fa.interview_parent_score,
        'writingComplete', coalesce(fa.writing_complete, false),
        'writingScore', fa.writing_score,
        'missingAreas', case
          when fa.applicant_id is null
            then to_jsonb(array['group','interviewStudent','interviewParent','writing']::text[])
          else to_jsonb(fa.missing_areas)
        end,
        'complete', coalesce(fa.complete, false),
        'finalTotal', fa.final_total,
        'computedAt', fa.computed_at
      ) order by er.exam_no, er.display_name)
      from public.decision_results dr
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      join public.applicants a on a.id = dr.applicant_id
      left join public.deep_final_aggregates fa on fa.applicant_id = dr.applicant_id
      where dr.run_id = v_round.document_decision_run_id
        and dr.outcome = 'passed'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m6_final_progress(int, admission_round) from public, anon;
grant execute on function public.get_m6_final_progress(int, admission_round) to authenticated;
