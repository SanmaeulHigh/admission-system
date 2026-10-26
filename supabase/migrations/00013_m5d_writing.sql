begin;

-- 새봄고 입학전형 시스템 — M5d 지원자 글쓰기 독립채점
-- 마스터 스펙 v1.2 섹션 2.6, 3.16, 5.4.5, 6.8, M5d 대응.
--
-- 핵심 불변조건
--   1) writing evaluator + area + scope + finalized writing plan membership이 모두 필요하다.
--   2) 글쓰기 위원 2인은 동일한 M4 final 합격자 풀을 각자 독립 채점하며 서로의 점수는 읽지 못한다.
--   3) 지원자는 config에 정의된 3문항 중 정확히 2문항을 선택하고, 각 문항의 필수 4영역을 모두 채점한다.
--   4) 서버가 questionId 중복·criterion key·허용 단계값·문항/위원 상한을 검증하고 총점을 재계산한다.
--   5) 2인 모두 제출 전 writing aggregate는 score=null, complete=false다.
--   6) plan의 document decision run/config revision을 snapshot으로 고정해 재현성을 보장한다.
--   7) writingAnswer 문서는 finalized writing plan의 실제 위원만 열람할 수 있도록 M2 문서 RLS를 보강한다.

-- ============================================================
-- 1. 글쓰기 평가계획 / 위원 2인
-- ============================================================

create table public.writing_evaluation_plans (
  year int not null,
  round admission_round not null,
  status text not null default 'draft' check (status in ('draft', 'finalized')),
  document_source_run_id uuid not null references public.decision_runs (id),
  config_revision_id uuid not null references public.config_revisions (id),
  revision int not null default 1 check (revision >= 1),
  finalized_at timestamptz,
  finalized_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

create table public.writing_plan_members (
  year int not null,
  round admission_round not null,
  evaluator_uid uuid not null references public.users (id),
  member_slot smallint not null check (member_slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (year, round, member_slot),
  unique (year, round, evaluator_uid),
  foreign key (year, round)
    references public.writing_evaluation_plans (year, round) on delete cascade
);

comment on table public.writing_evaluation_plans is
  'M5d 글쓰기 2인 독립채점 계획. M4 final passed 풀과 config revision을 snapshot으로 고정한다.';
comment on table public.writing_plan_members is
  '해당 연도/차수의 글쓰기 답안 전체를 독립 채점하는 위원 2인. slot 1/2 고정.';

alter table public.writing_evaluation_plans enable row level security;
alter table public.writing_plan_members enable row level security;

create policy writing_evaluation_plans_select_staff
  on public.writing_evaluation_plans for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      public.has_role('evaluator') and public.has_area('writing')
      and exists (
        select 1 from public.users u
        where u.id = auth.uid()
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or writing_evaluation_plans.year = any(u.year_scopes))
          and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or writing_evaluation_plans.round = any(u.round_scopes))
      )
    )
  );

create policy writing_plan_members_select_own_or_admin
  on public.writing_plan_members for select
  using (
    public.has_role('superadmin') or public.has_role('admin')
    or (
      evaluator_uid = auth.uid()
      and public.has_role('evaluator')
      and public.has_area('writing')
    )
  );

-- write 정책 없음: RPC 전용.

-- ============================================================
-- 2. 개별 점수 / 서버 집계
-- ============================================================

create table public.scores_writing (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  responses jsonb not null default '[]'::jsonb,
  memo text,
  server_computed jsonb,
  submission_state text not null default 'draft'
    check (submission_state in ('draft', 'submitted', 'reopened')),
  revision int not null default 0 check (revision >= 0),
  client_updated_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.deep_writing_aggregates (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  complete boolean not null default false,
  score numeric,
  required int not null,
  submitted int not null,
  gap numeric,
  source_revision_summary jsonb not null default '[]'::jsonb,
  function_version text not null,
  computed_at timestamptz not null default now()
);

comment on table public.scores_writing is
  'M5d 위원별 독립 글쓰기 채점. responses는 선택문항 2개와 문항별 criterion 점수만 보관하고 총점은 서버 재계산.';
comment on table public.deep_writing_aggregates is
  'M5d 서버 집계. 필수 2인 제출 전 score=null/complete=false, 충족 후 위원별 200점 총점 평균.';

alter table public.scores_writing enable row level security;
alter table public.deep_writing_aggregates enable row level security;

create policy scores_writing_select_own
  on public.scores_writing for select
  using (evaluator_uid = auth.uid());

create policy deep_writing_aggregates_select_admin_viewer
  on public.deep_writing_aggregates for select
  using (
    public.has_role('superadmin')
    or public.has_role('admin')
    or public.has_role('viewer')
  );

-- ============================================================
-- 3. config / 권한 / 점수 검증 private helpers
-- ============================================================

create or replace function public._m5d_writing_params(
  p_revision_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb;
  v_rule jsonb;
  v_questions jsonb;
  v_question jsonb;
  v_criteria jsonb;
  v_criterion jsonb;
  v_sum_max numeric;
begin
  select scoring_params #> '{deep,writing}'
    into v_params
  from public.config_revisions
  where id = p_revision_id;

  if v_params is null then
    raise exception 'config revision에 deep.writing 파라미터가 없습니다. M5d 배점 설정을 먼저 반영하세요.'
      using errcode = '55000';
  end if;

  v_rule := v_params -> 'questionRule';
  v_questions := v_params -> 'questions';

  if coalesce((v_params ->> 'max')::numeric, 0) <= 0
     or coalesce((v_params ->> 'perEvaluatorMax')::numeric, 0) <= 0
     or coalesce((v_params ->> 'requiredSubmissions')::int, 0) <= 0
     or v_params ->> 'combine' <> 'avg'
     or coalesce((v_params ->> 'alertGap')::numeric, -1) < 0
     or jsonb_typeof(v_rule) is distinct from 'object'
     or coalesce((v_rule ->> 'pick')::int, 0) <= 0
     or coalesce((v_rule ->> 'of')::int, 0) <= 0
     or coalesce((v_rule ->> 'each')::numeric, 0) <= 0
     or coalesce((v_rule ->> 'criteriaPerQuestion')::int, 0) <= 0
     or jsonb_typeof(v_questions) is distinct from 'array'
     or jsonb_array_length(v_questions) = 0 then
    raise exception 'deep.writing 파라미터 구조가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  if (v_rule ->> 'pick')::int > (v_rule ->> 'of')::int
     or jsonb_array_length(v_questions) <> (v_rule ->> 'of')::int
     or (v_rule ->> 'pick')::numeric * (v_rule ->> 'each')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric
     or (v_params ->> 'max')::numeric <> (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception 'writing questionRule / perEvaluatorMax / max 관계가 올바르지 않습니다: %', v_params using errcode = '23514';
  end if;

  if (select count(*) from jsonb_array_elements(v_questions)) <>
     (select count(distinct q.value ->> 'id') from jsonb_array_elements(v_questions) q) then
    raise exception 'writing question id가 중복되었습니다.' using errcode = '23514';
  end if;

  for v_question in select value from jsonb_array_elements(v_questions)
  loop
    v_criteria := v_question -> 'criteria';
    if jsonb_typeof(v_question) is distinct from 'object'
       or coalesce(length(trim(v_question ->> 'id')), 0) = 0
       or coalesce(length(trim(v_question ->> 'label')), 0) = 0
       or jsonb_typeof(v_criteria) is distinct from 'array'
       or jsonb_array_length(v_criteria) <> (v_rule ->> 'criteriaPerQuestion')::int then
      raise exception 'writing question 구조가 올바르지 않습니다: %', v_question using errcode = '23514';
    end if;

    if (select count(*) from jsonb_array_elements(v_criteria)) <>
       (select count(distinct c.value ->> 'key') from jsonb_array_elements(v_criteria) c) then
      raise exception 'writing criterion key가 중복되었습니다: %', v_question ->> 'id' using errcode = '23514';
    end if;

    v_sum_max := 0;
    for v_criterion in select value from jsonb_array_elements(v_criteria)
    loop
      if jsonb_typeof(v_criterion) is distinct from 'object'
         or coalesce(length(trim(v_criterion ->> 'key')), 0) = 0
         or coalesce(length(trim(v_criterion ->> 'label')), 0) = 0
         or coalesce((v_criterion ->> 'max')::numeric, 0) <= 0
         or jsonb_typeof(v_criterion -> 'scoreValues') is distinct from 'array'
         or jsonb_array_length(v_criterion -> 'scoreValues') = 0 then
        raise exception 'writing criterion 구조가 올바르지 않습니다: %', v_criterion using errcode = '23514';
      end if;
      if exists (
        select 1
        from jsonb_array_elements_text(v_criterion -> 'scoreValues') score_value
        where score_value::numeric < 0
           or score_value::numeric > (v_criterion ->> 'max')::numeric
      ) then
        raise exception 'writing criterion scoreValues가 max 범위를 벗어납니다: %', v_criterion using errcode = '23514';
      end if;
      v_sum_max := v_sum_max + (v_criterion ->> 'max')::numeric;
    end loop;

    if v_sum_max <> (v_rule ->> 'each')::numeric then
      raise exception '문항 %의 criterion max 합계가 문항당 상한 %와 일치하지 않습니다.',
        v_question ->> 'id', v_rule ->> 'each' using errcode = '23514';
    end if;
  end loop;

  return v_params;
end;
$$;

create or replace function public._m5d_require_writing_user(
  p_year int,
  p_round admission_round
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'writing' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '글쓰기 평가 권한이 없습니다 (evaluator + writing 배정 및 scope 필요).' using errcode = '42501';
  end if;

  return caller;
end;
$$;

create or replace function public._m5d_require_writer(
  p_applicant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_active boolean;
begin
  select er.year, er.round, er.evaluation_active
    into v_year, v_round, v_active
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  caller := public._m5d_require_writing_user(v_year, v_round);

  if not v_active then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.' using errcode = '55000';
  end if;

  if not exists (
    select 1
    from public.writing_evaluation_plans p
    join public.writing_plan_members m
      on m.year = p.year and m.round = p.round
    join public.decision_results dr
      on dr.run_id = p.document_source_run_id
     and dr.applicant_id = p_applicant_id
     and dr.outcome = 'passed'
    where p.year = v_year and p.round = v_round
      and p.status = 'finalized'
      and m.evaluator_uid = caller
  ) then
    raise exception '이 지원자는 현재 평가자의 글쓰기 채점 대상이 아닙니다.' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.admission_documents d
    where d.applicant_id = p_applicant_id
      and d.document_type = 'writingAnswer'
      and d.active = true
      and d.classification = 'evaluation'
      and 'writing'::evaluation_area = any(d.access_areas)
  ) then
    raise exception '지원자의 글쓰기 답안 평가문서가 준비되지 않았습니다.' using errcode = '55000';
  end if;

  return caller;
end;
$$;

create or replace function public._m5d_validate_and_total(
  p_revision_id uuid,
  p_responses jsonb,
  p_require_complete boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_params jsonb := public._m5d_writing_params(p_revision_id);
  v_rule jsonb := v_params -> 'questionRule';
  v_questions jsonb := v_params -> 'questions';
  v_response jsonb;
  v_question jsonb;
  v_criterion jsonb;
  v_items jsonb;
  v_question_id text;
  v_key text;
  v_raw_value text;
  v_value numeric;
  v_question_total numeric;
  v_total numeric := 0;
  v_question_totals jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_responses) is distinct from 'array' then
    raise exception 'responses는 JSON array여야 합니다.' using errcode = '22023';
  end if;

  if jsonb_array_length(p_responses) > (v_rule ->> 'pick')::int then
    raise exception '글쓰기 응답은 최대 %개 문항까지만 입력할 수 있습니다.', v_rule ->> 'pick' using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_responses) response_item
    group by response_item ->> 'questionId'
    having count(*) > 1
  ) then
    raise exception '동일 questionId를 중복 선택할 수 없습니다.' using errcode = '23514';
  end if;

  if p_require_complete and jsonb_array_length(p_responses) <> (v_rule ->> 'pick')::int then
    raise exception '글쓰기 제출은 %개 문항을 정확히 선택해야 합니다.', v_rule ->> 'pick' using errcode = '23514';
  end if;

  for v_response in select value from jsonb_array_elements(p_responses)
  loop
    if jsonb_typeof(v_response) is distinct from 'object' then
      raise exception '각 response는 JSON object여야 합니다.' using errcode = '22023';
    end if;

    v_question_id := trim(coalesce(v_response ->> 'questionId', ''));
    select value into v_question
    from jsonb_array_elements(v_questions)
    where value ->> 'id' = v_question_id
    limit 1;
    if not found then
      raise exception '허용되지 않은 writing questionId입니다: %', v_question_id using errcode = '23514';
    end if;

    v_items := coalesce(v_response -> 'items', '{}'::jsonb);
    if jsonb_typeof(v_items) is distinct from 'object' then
      raise exception '% items는 JSON object여야 합니다.', v_question_id using errcode = '22023';
    end if;

    if p_require_complete then
      for v_criterion in select value from jsonb_array_elements(v_question -> 'criteria')
      loop
        if not (v_items ? (v_criterion ->> 'key')) then
          raise exception '% · % 점수가 없습니다. 모든 글쓰기 기준을 입력해야 제출할 수 있습니다.',
            v_question ->> 'label', v_criterion ->> 'label' using errcode = '23514';
        end if;
      end loop;
      if (select count(*) from jsonb_object_keys(v_items)) <> jsonb_array_length(v_question -> 'criteria') then
        raise exception '%의 허용되지 않은 추가 기준이 있거나 기준 수가 일치하지 않습니다.',
          v_question ->> 'label' using errcode = '23514';
      end if;
    end if;

    v_question_total := 0;
    for v_key, v_raw_value in select key, value from jsonb_each_text(v_items)
    loop
      select value into v_criterion
      from jsonb_array_elements(v_question -> 'criteria')
      where value ->> 'key' = v_key
      limit 1;
      if not found then
        raise exception '%에서 알 수 없는 글쓰기 채점 기준: %', v_question ->> 'label', v_key using errcode = '23514';
      end if;

      begin
        v_value := v_raw_value::numeric;
      exception when others then
        raise exception '% · % 점수는 숫자여야 합니다.', v_question ->> 'label', v_criterion ->> 'label' using errcode = '22023';
      end;

      if not exists (
        select 1
        from jsonb_array_elements_text(v_criterion -> 'scoreValues') score_value
        where score_value::numeric = v_value
      ) then
        raise exception '% · % 점수는 허용 단계 % 중 하나여야 합니다 (입력값: %).',
          v_question ->> 'label', v_criterion ->> 'label', v_criterion -> 'scoreValues', v_value
          using errcode = '23514';
      end if;

      v_question_total := v_question_total + v_value;
    end loop;

    if v_question_total > (v_rule ->> 'each')::numeric then
      raise exception '% 총점은 문항당 %점을 초과할 수 없습니다 (입력 합계: %).',
        v_question ->> 'label', v_rule ->> 'each', v_question_total using errcode = '23514';
    end if;

    v_question_totals := v_question_totals || jsonb_build_object(v_question_id, v_question_total);
    v_total := v_total + v_question_total;
  end loop;

  if v_total > (v_params ->> 'perEvaluatorMax')::numeric then
    raise exception '위원별 글쓰기 총점은 %점을 초과할 수 없습니다 (입력 합계: %).',
      v_params ->> 'perEvaluatorMax', v_total using errcode = '23514';
  end if;

  return jsonb_build_object(
    'total', v_total,
    'questionTotals', v_question_totals,
    'valid', p_require_complete
  );
end;
$$;

revoke all on function public._m5d_writing_params(uuid) from public, anon, authenticated;
revoke all on function public._m5d_require_writing_user(int, admission_round) from public, anon, authenticated;
revoke all on function public._m5d_require_writer(uuid) from public, anon, authenticated;
revoke all on function public._m5d_validate_and_total(uuid, jsonb, boolean) from public, anon, authenticated;

-- ============================================================
-- 4. 글쓰기 계획 validator / admin RPC
-- ============================================================

create or replace function public._m5d_validate_writing_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_round record;
  v_plan record;
  v_candidate_count int := 0;
  v_member_count int := 0;
  v_missing_answer_count int := 0;
  v_invalid_member_count int := 0;
  v_issues jsonb := '[]'::jsonb;
begin
  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;
  if not found then
    return jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object(
        'code', 'PLAN_MISSING', 'message', '글쓰기 평가계획 draft가 없습니다.'
      )),
      'candidateCount', 0, 'memberCount', 0, 'missingAnswerCount', 0
    );
  end if;

  if v_round.document_decision_run_id is null then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_FINAL_MISSING', 'message', '확정된 M4 1차 사정 run이 없습니다.'
    ));
  elsif v_plan.document_source_run_id <> v_round.document_decision_run_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'DOCUMENT_SOURCE_STALE', 'message', '글쓰기 계획의 1차 합격자 기준 run이 현재 확정 run과 다릅니다. 계획을 다시 저장하세요.'
    ));
  end if;

  if v_plan.config_revision_id <> v_round.config_revision_id then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CONFIG_SOURCE_STALE', 'message', '글쓰기 계획의 배점 config revision이 현재 전형 config와 다릅니다. 최종확정 전 계획을 다시 저장하세요.'
    ));
  end if;

  perform public._m5d_writing_params(v_plan.config_revision_id);

  select count(*)::int into v_candidate_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed';

  if v_candidate_count = 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'CANDIDATE_MISSING', 'message', 'M4 final 합격자가 없어 글쓰기 평가계획을 확정할 수 없습니다.'
    ));
  end if;

  select count(*)::int into v_member_count
  from public.writing_plan_members m
  where m.year = p_year and m.round = p_round;
  if v_member_count <> 2 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'WRITING_MEMBER_COUNT', 'message', format('글쓰기 평가위원은 정확히 2명이어야 합니다 (현재 %s명).', v_member_count)
    ));
  end if;

  select count(*)::int into v_invalid_member_count
  from public.writing_plan_members m
  left join public.users u on u.id = m.evaluator_uid
  where m.year = p_year and m.round = p_round
    and (
      u.id is null or u.active = false
      or not ('evaluator' = any(u.roles))
      or not ('writing' = any(u.assigned_areas))
      or not (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      or not (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
    );
  if v_invalid_member_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_WRITING_MEMBER', 'message', format('writing evaluator 권한·scope가 유효하지 않은 위원이 %s명 있습니다.', v_invalid_member_count)
    ));
  end if;

  select count(*)::int into v_missing_answer_count
  from public.decision_results dr
  where dr.run_id = v_plan.document_source_run_id
    and dr.outcome = 'passed'
    and not exists (
      select 1 from public.admission_documents d
      where d.applicant_id = dr.applicant_id
        and d.document_type = 'writingAnswer'
        and d.active = true
        and d.classification = 'evaluation'
        and 'writing'::evaluation_area = any(d.access_areas)
    );
  if v_missing_answer_count > 0 then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object(
      'code', 'WRITING_ANSWER_MISSING', 'message', format('평가용 글쓰기 답안이 준비되지 않은 1차 합격자가 %s명 있습니다.', v_missing_answer_count)
    ));
  end if;

  return jsonb_build_object(
    'complete', jsonb_array_length(v_issues) = 0,
    'blockingIssues', v_issues,
    'status', v_plan.status,
    'revision', v_plan.revision,
    'documentSourceRunId', v_plan.document_source_run_id,
    'configRevisionId', v_plan.config_revision_id,
    'candidateCount', v_candidate_count,
    'memberCount', v_member_count,
    'missingAnswerCount', v_missing_answer_count
  );
end;
$$;

revoke all on function public._m5d_validate_writing_plan(int, admission_round) from public, anon, authenticated;

create or replace function public.validate_m5d_writing_plan(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);
  return public._m5d_validate_writing_plan(p_year, p_round);
end;
$$;

revoke all on function public.validate_m5d_writing_plan(int, admission_round) from public, anon;
grant execute on function public.validate_m5d_writing_plan(int, admission_round) to authenticated;

create or replace function public.get_m5d_writing_plan_admin(
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
      ) order by dr.rank, er.exam_no, er.display_name)
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
$$;

revoke all on function public.get_m5d_writing_plan_admin(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_plan_admin(int, admission_round) to authenticated;

create or replace function public.save_m5d_writing_plan(
  p_year int,
  p_round admission_round,
  p_member_uids jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_round record;
  v_existing_status text;
  v_member_text text;
  v_member_order bigint;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  if jsonb_typeof(p_member_uids) is distinct from 'array' then
    raise exception 'memberUids는 JSON array여야 합니다.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_member_uids) > 2 then
    raise exception '글쓰기 평가위원은 최대 2명까지만 저장할 수 있습니다.' using errcode = '23514';
  end if;
  if (select count(*) from jsonb_array_elements_text(p_member_uids)) <>
     (select count(distinct value) from jsonb_array_elements_text(p_member_uids)) then
    raise exception '같은 글쓰기 평가위원을 중복 배정할 수 없습니다.' using errcode = '23514';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  perform public._m5d_writing_params(v_round.config_revision_id);

  select status into v_existing_status
  from public.writing_evaluation_plans
  where year = p_year and round = p_round
  for update;
  if found and v_existing_status = 'finalized' then
    raise exception '이미 최종확정된 글쓰기 평가계획입니다. 대체위원 지정은 별도 superadmin RPC를 사용하세요.' using errcode = '55000';
  end if;

  insert into public.writing_evaluation_plans
    (year, round, status, document_source_run_id, config_revision_id, revision, created_by, updated_by)
  values
    (p_year, p_round, 'draft', v_round.document_decision_run_id, v_round.config_revision_id, 1, caller::text, caller::text)
  on conflict (year, round) do update set
    status = 'draft',
    document_source_run_id = excluded.document_source_run_id,
    config_revision_id = excluded.config_revision_id,
    revision = public.writing_evaluation_plans.revision + 1,
    updated_at = now(),
    updated_by = caller::text;

  delete from public.writing_plan_members
  where year = p_year and round = p_round;

  for v_member_text, v_member_order in
    select value, ordinality
    from jsonb_array_elements_text(p_member_uids) with ordinality
  loop
    insert into public.writing_plan_members
      (year, round, evaluator_uid, member_slot)
    values
      (p_year, p_round, trim(v_member_text)::uuid, v_member_order::smallint);
  end loop;

  v_validation := public._m5d_validate_writing_plan(p_year, p_round);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.saved', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing',
     jsonb_build_object('memberCount', jsonb_array_length(p_member_uids), 'complete', v_validation -> 'complete'));

  return v_validation || jsonb_build_object('status', 'draft');
end;
$$;

revoke all on function public.save_m5d_writing_plan(int, admission_round, jsonb) from public, anon;
grant execute on function public.save_m5d_writing_plan(int, admission_round, jsonb) to authenticated;

create or replace function public.finalize_m5d_writing_plan(
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
  v_plan_status text;
  v_validation jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);
  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  select status into v_plan_status
  from public.writing_evaluation_plans
  where year = p_year and round = p_round
  for update;
  if not found then
    raise exception '최종확정할 글쓰기 평가계획 draft가 없습니다.' using errcode = 'P0002';
  end if;
  if v_plan_status = 'finalized' then
    raise exception '이미 최종확정된 글쓰기 평가계획입니다.' using errcode = '55000';
  end if;

  v_validation := public._m5d_validate_writing_plan(p_year, p_round);
  if coalesce((v_validation ->> 'complete')::boolean, false) = false then
    raise exception '글쓰기 평가계획에 blocking 문제가 있어 확정할 수 없습니다: %', v_validation -> 'blockingIssues' using errcode = '23514';
  end if;

  update public.writing_evaluation_plans
  set status = 'finalized',
      revision = revision + 1,
      finalized_at = now(),
      finalized_by = caller::text,
      updated_at = now(),
      updated_by = caller::text
  where year = p_year and round = p_round;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.finalized', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing',
     jsonb_build_object('candidateCount', v_validation -> 'candidateCount', 'memberCount', v_validation -> 'memberCount'));

  return public._m5d_validate_writing_plan(p_year, p_round) || jsonb_build_object('status', 'finalized');
end;
$$;

revoke all on function public.finalize_m5d_writing_plan(int, admission_round) from public, anon;
grant execute on function public.finalize_m5d_writing_plan(int, admission_round) to authenticated;

-- ============================================================
-- 5. writingAnswer 문서 접근을 finalized plan membership까지 제한
-- ============================================================

create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' then
    return public.has_role('reception');
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = auth.uid() and u.assigned_areas && p_doc_access_areas
  ) then
    return false;
  end if;

  if p_document_type = 'writingAnswer' then
    return public.has_role('evaluator')
      and public.has_area('writing')
      and exists (
        select 1
        from public.evaluation_roster er
        join public.writing_evaluation_plans p
          on p.year = er.year and p.round = er.round and p.status = 'finalized'
        join public.writing_plan_members m
          on m.year = p.year and m.round = p.round and m.evaluator_uid = auth.uid()
        join public.decision_results dr
          on dr.run_id = p.document_source_run_id
         and dr.applicant_id = er.applicant_id
         and dr.outcome = 'passed'
        where er.applicant_id = p_applicant_id
      );
  end if;

  return true;
end;
$$;

revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

drop policy if exists admission_documents_select_by_classification on public.admission_documents;
create policy admission_documents_select_by_classification
  on public.admission_documents for select
  using (public._can_access_document_v2(applicant_id, document_type, classification, access_areas));

drop policy if exists admission_documents_storage_select on storage.objects;
create policy admission_documents_storage_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'admission-documents'
    and exists (
      select 1 from public.admission_documents d
      where d.storage_path = storage.objects.name
        and d.active = true
        and public._can_access_document_v2(d.applicant_id, d.document_type, d.classification, d.access_areas)
    )
  );

create or replace function public.log_document_view(p_document_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  doc record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select * into doc
  from public.admission_documents
  where id = p_document_id and active = true;
  if not found then
    raise exception '문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if not public._can_access_document_v2(doc.applicant_id, doc.document_type, doc.classification, doc.access_areas) then
    raise exception '이 문서에 접근할 권한이 없습니다.' using errcode = '42501';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (doc.year, doc.round, 'user', caller::text, 'document.viewed', 'admission_documents',
     doc.id::text, doc.applicant_id::text,
     case when array_length(doc.access_areas, 1) = 1 then doc.access_areas[1] else null end);

  return json_build_object('storagePath', doc.storage_path, 'documentType', doc.document_type);
end;
$$;

revoke execute on function public.log_document_view(uuid) from anon;

-- ============================================================
-- 6. evaluator workspace / draft / submit
-- ============================================================

create or replace function public.get_m5d_writing_workspace(
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
  ) order by dr.rank, er.exam_no, er.display_name), '[]'::jsonb)
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
$$;

revoke all on function public.get_m5d_writing_workspace(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_workspace(int, admission_round) to authenticated;

create or replace function public.save_writing_score_draft(
  p_applicant_id uuid,
  p_responses jsonb,
  p_memo text,
  p_client_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_existing public.scores_writing%rowtype;
  v_computed jsonb;
  v_accepted boolean := true;
  v_current_total numeric;
  v_current_client_updated_at timestamptz;
begin
  if p_client_updated_at is null then
    raise exception 'p_client_updated_at은 필수입니다.' using errcode = '22023';
  end if;
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '글쓰기 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5d_require_writer(p_applicant_id);

  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';

  if not exists (
    select 1 from public.admission_rounds ar
    where ar.year = v_year and ar.round = v_round
      and ar.stage_status = 'open'
      and 'writing'::evaluation_area = any(ar.open_evaluation_areas)
  ) then
    raise exception '글쓰기 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:score:%s:%s', p_applicant_id::text, caller::text), 0));
  v_computed := public._m5d_validate_and_total(v_config_revision_id, p_responses, false);

  select * into v_existing
  from public.scores_writing
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 글쓰기 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  if v_existing.id is not null
     and v_existing.client_updated_at is not null
     and v_existing.client_updated_at >= p_client_updated_at then
    v_accepted := false;
    v_current_total := (v_existing.server_computed ->> 'total')::numeric;
    v_current_client_updated_at := v_existing.client_updated_at;
  else
    insert into public.scores_writing
      (applicant_id, evaluator_uid, year, round, config_revision_id,
       responses, memo, server_computed, submission_state, revision, client_updated_at)
    values
      (p_applicant_id, caller, v_year, v_round, v_config_revision_id,
       p_responses, p_memo, v_computed, 'draft', 1, p_client_updated_at)
    on conflict (applicant_id, evaluator_uid) do update set
      config_revision_id = excluded.config_revision_id,
      responses = excluded.responses,
      memo = excluded.memo,
      server_computed = excluded.server_computed,
      submission_state = 'draft',
      revision = public.scores_writing.revision + 1,
      client_updated_at = excluded.client_updated_at,
      submitted_at = null,
      updated_at = now();
    v_current_total := (v_computed ->> 'total')::numeric;
    v_current_client_updated_at := p_client_updated_at;
  end if;

  return jsonb_build_object(
    'accepted', v_accepted,
    'draftTotal', v_current_total,
    'serverClientUpdatedAt', v_current_client_updated_at,
    'submissionState', coalesce((
      select submission_state from public.scores_writing
      where applicant_id = p_applicant_id and evaluator_uid = caller
    ), 'draft'),
    'serverDraft', jsonb_build_object(
      'responses', coalesce((
        select responses from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ), '[]'::jsonb),
      'memo', (
        select memo from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ),
      'revision', coalesce((
        select revision from public.scores_writing
        where applicant_id = p_applicant_id and evaluator_uid = caller
      ), 0)
    )
  );
end;
$$;

revoke all on function public.save_writing_score_draft(uuid, jsonb, text, timestamptz) from public, anon;
grant execute on function public.save_writing_score_draft(uuid, jsonb, text, timestamptz) to authenticated;

create or replace function public.submit_writing_score(
  p_applicant_id uuid,
  p_responses jsonb,
  p_memo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_existing public.scores_writing%rowtype;
  v_computed jsonb;
  v_score_id uuid;
  v_revision int;
begin
  if p_memo is not null and length(p_memo) > 2000 then
    raise exception '글쓰기 메모는 2,000자를 초과할 수 없습니다.' using errcode = '23514';
  end if;

  caller := public._m5d_require_writer(p_applicant_id);

  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';

  if not exists (
    select 1 from public.admission_rounds ar
    where ar.year = v_year and ar.round = v_round
      and ar.stage_status = 'open'
      and 'writing'::evaluation_area = any(ar.open_evaluation_areas)
  ) then
    raise exception '글쓰기 평가가 현재 열려있지 않습니다.' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:score:%s:%s', p_applicant_id::text, caller::text), 0));

  select * into v_existing
  from public.scores_writing
  where applicant_id = p_applicant_id and evaluator_uid = caller
  for update;

  if v_existing.id is not null and v_existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 글쓰기 채점입니다. 수정하려면 superadmin에게 재개방을 요청하세요.' using errcode = '55000';
  end if;

  v_computed := public._m5d_validate_and_total(v_config_revision_id, p_responses, true);

  insert into public.scores_writing
    (applicant_id, evaluator_uid, year, round, config_revision_id,
     responses, memo, server_computed, submission_state, revision, client_updated_at, submitted_at)
  values
    (p_applicant_id, caller, v_year, v_round, v_config_revision_id,
     p_responses, p_memo, v_computed, 'submitted', coalesce(v_existing.revision, 0) + 1, now(), now())
  on conflict (applicant_id, evaluator_uid) do update set
    config_revision_id = excluded.config_revision_id,
    responses = excluded.responses,
    memo = excluded.memo,
    server_computed = excluded.server_computed,
    submission_state = 'submitted',
    revision = public.scores_writing.revision + 1,
    client_updated_at = now(),
    submitted_at = now(),
    updated_at = now()
  returning id, revision into v_score_id, v_revision;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.writing.submitted', 'scores_writing',
     v_score_id::text, p_applicant_id::text, 'writing', jsonb_build_object('revision', v_revision));

  return jsonb_build_object(
    'scoreId', v_score_id,
    'total', (v_computed ->> 'total')::numeric,
    'questionTotals', v_computed -> 'questionTotals',
    'submissionState', 'submitted',
    'revision', v_revision
  );
end;
$$;

revoke all on function public.submit_writing_score(uuid, jsonb, text) from public, anon;
grant execute on function public.submit_writing_score(uuid, jsonb, text) to authenticated;

-- ============================================================
-- 7. aggregate / trigger / alerts
-- ============================================================

create or replace function public._compute_writing_aggregate(
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_params jsonb;
  v_required int;
  v_submitted int;
  v_average numeric;
  v_gap numeric;
  v_score numeric;
  v_summary jsonb;
begin
  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';

  if v_config_revision_id is null then
    return jsonb_build_object(
      'complete', false, 'score', null, 'required', null, 'submitted', 0,
      'gap', null, 'sourceRevisionSummary', '[]'::jsonb,
      'functionVersion', 'm5d-writing-aggregate-v1'
    );
  end if;

  v_params := public._m5d_writing_params(v_config_revision_id);
  v_required := (v_params ->> 'requiredSubmissions')::int;

  select count(*)::int,
         avg((sw.server_computed ->> 'total')::numeric),
         max((sw.server_computed ->> 'total')::numeric) - min((sw.server_computed ->> 'total')::numeric),
         coalesce(jsonb_agg(jsonb_build_object(
           'scoreId', sw.id,
           'evaluatorUid', sw.evaluator_uid,
           'revision', sw.revision
         ) order by sw.evaluator_uid), '[]'::jsonb)
    into v_submitted, v_average, v_gap, v_summary
  from public.scores_writing sw
  join public.writing_plan_members m
    on m.year = v_year and m.round = v_round and m.evaluator_uid = sw.evaluator_uid
  where sw.applicant_id = p_applicant_id
    and sw.submission_state = 'submitted'
    and coalesce((sw.server_computed ->> 'valid')::boolean, false) = true
    and sw.config_revision_id = v_config_revision_id;

  if v_submitted < v_required then
    v_score := null;
  else
    v_score := least((v_params ->> 'max')::numeric, v_average);
  end if;

  return jsonb_build_object(
    'complete', v_submitted >= v_required,
    'score', v_score,
    'required', v_required,
    'submitted', v_submitted,
    'gap', case when v_submitted >= 2 then v_gap else null end,
    'sourceRevisionSummary', v_summary,
    'functionVersion', 'm5d-writing-aggregate-v1'
  );
end;
$$;

create or replace function public._refresh_writing_aggregate(
  p_applicant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
volatile
as $$
declare
  v_year int;
  v_round admission_round;
  v_config_revision_id uuid;
  v_agg jsonb;
  v_params jsonb;
  v_gap numeric;
  v_related uuid[];
begin
  select er.year, er.round into v_year, v_round
  from public.evaluation_roster er
  where er.applicant_id = p_applicant_id;
  if not found then
    delete from public.deep_writing_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  select p.config_revision_id into v_config_revision_id
  from public.writing_evaluation_plans p
  where p.year = v_year and p.round = v_round and p.status = 'finalized';
  if v_config_revision_id is null then
    delete from public.deep_writing_aggregates where applicant_id = p_applicant_id;
    return;
  end if;

  v_agg := public._compute_writing_aggregate(p_applicant_id);

  insert into public.deep_writing_aggregates
    (applicant_id, year, round, config_revision_id, complete, score, required, submitted, gap,
     source_revision_summary, function_version, computed_at)
  values
    (p_applicant_id, v_year, v_round, v_config_revision_id,
     (v_agg ->> 'complete')::boolean,
     nullif(v_agg ->> 'score', '')::numeric,
     (v_agg ->> 'required')::int,
     (v_agg ->> 'submitted')::int,
     nullif(v_agg ->> 'gap', '')::numeric,
     v_agg -> 'sourceRevisionSummary', v_agg ->> 'functionVersion', now())
  on conflict (applicant_id) do update set
    year = excluded.year,
    round = excluded.round,
    config_revision_id = excluded.config_revision_id,
    complete = excluded.complete,
    score = excluded.score,
    required = excluded.required,
    submitted = excluded.submitted,
    gap = excluded.gap,
    source_revision_summary = excluded.source_revision_summary,
    function_version = excluded.function_version,
    computed_at = excluded.computed_at;

  v_params := public._m5d_writing_params(v_config_revision_id);
  v_gap := nullif(v_agg ->> 'gap', '')::numeric;

  select coalesce(array_agg(distinct sw.evaluator_uid), '{}'::uuid[])
    into v_related
  from public.scores_writing sw
  join public.writing_plan_members m
    on m.year = v_year and m.round = v_round and m.evaluator_uid = sw.evaluator_uid
  where sw.applicant_id = p_applicant_id and sw.submission_state = 'submitted';

  if v_gap is not null and v_gap >= (v_params ->> 'alertGap')::numeric then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
    values
      (v_year, v_round, p_applicant_id, 'writing', 'scoreGap', 'warning',
       format('글쓰기 위원 간 총점 편차 %s점(기준 %s)', v_gap, v_params ->> 'alertGap'), v_related)
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      related_evaluator_uids = excluded.related_evaluator_uids,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5d'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'writing' and alert_type = 'scoreGap' and status <> 'resolved';
  end if;

  if (v_agg ->> 'submitted')::int < (v_agg ->> 'required')::int then
    insert into public.evaluation_alerts
      (year, round, applicant_id, area, alert_type, severity, summary)
    values
      (v_year, v_round, p_applicant_id, 'writing', 'missingSubmission', 'warning',
       format('글쓰기 제출 %s/%s', v_agg ->> 'submitted', v_agg ->> 'required'))
    on conflict (year, round, applicant_id, area, alert_type) do update set
      summary = excluded.summary,
      status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end,
      resolved_at = null,
      resolved_by = null;
  else
    update public.evaluation_alerts
    set status = 'resolved', resolved_at = now(), resolved_by = 'system:m5d'
    where year = v_year and round = v_round and applicant_id = p_applicant_id
      and area = 'writing' and alert_type = 'missingSubmission' and status <> 'resolved';
  end if;
end;
$$;

create or replace function public._trg_refresh_writing_aggregate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public._refresh_writing_aggregate(old.applicant_id);
    return old;
  else
    perform public._refresh_writing_aggregate(new.applicant_id);
    return new;
  end if;
end;
$$;

revoke all on function public._compute_writing_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._refresh_writing_aggregate(uuid) from public, anon, authenticated;
revoke all on function public._trg_refresh_writing_aggregate() from public, anon, authenticated;

drop trigger if exists trg_refresh_writing_aggregate on public.scores_writing;
create trigger trg_refresh_writing_aggregate
  after insert or update or delete on public.scores_writing
  for each row execute function public._trg_refresh_writing_aggregate();

-- ============================================================
-- 8. 관리자 진행현황 / 재개방 / 대체위원
-- ============================================================

create or replace function public.get_m5d_writing_progress(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','viewer']::app_role[]);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', er.exam_no,
        'displayName', er.display_name,
        'complete', coalesce(a.complete, false),
        'score', a.score,
        'required', a.required,
        'submitted', coalesce(a.submitted, 0),
        'gapAlert', exists (
          select 1 from public.evaluation_alerts ea
          where ea.applicant_id = er.applicant_id and ea.area = 'writing'
            and ea.alert_type = 'scoreGap' and ea.status <> 'resolved'
        ),
        'computedAt', a.computed_at
      ) order by dr.rank, er.exam_no, er.display_name)
      from public.writing_evaluation_plans p
      join public.decision_results dr
        on dr.run_id = p.document_source_run_id and dr.outcome = 'passed'
      join public.evaluation_roster er on er.applicant_id = dr.applicant_id
      left join public.deep_writing_aggregates a on a.applicant_id = er.applicant_id
      where p.year = p_year and p.round = p_round and p.status = 'finalized'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5d_writing_progress(int, admission_round) from public, anon;
grant execute on function public.get_m5d_writing_progress(int, admission_round) to authenticated;

create or replace function public.reopen_writing_score(
  p_score_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_score public.scores_writing%rowtype;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '재개방 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  select * into v_score
  from public.scores_writing
  where id = p_score_id
  for update;
  if not found then
    raise exception '글쓰기 채점 문서를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_score.submission_state <> 'submitted' then
    raise exception 'submitted 상태의 글쓰기 채점만 재개방할 수 있습니다.' using errcode = '55000';
  end if;

  update public.scores_writing
  set submission_state = 'reopened',
      revision = revision + 1,
      submitted_at = null,
      updated_at = now()
  where id = p_score_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_score.year, v_score.round, 'user', caller::text, 'score.writing.reopened', 'scores_writing',
     p_score_id::text, v_score.applicant_id::text, 'writing', '관리자 재개방',
     jsonb_build_object('reason', p_reason, 'evaluatorUid', v_score.evaluator_uid));

  return jsonb_build_object('scoreId', p_score_id, 'submissionState', 'reopened');
end;
$$;

revoke all on function public.reopen_writing_score(uuid, text) from public, anon;
grant execute on function public.reopen_writing_score(uuid, text) to authenticated;

create or replace function public.replace_m5d_writing_evaluator(
  p_old_evaluator_uid uuid,
  p_new_evaluator_uid uuid,
  p_year int,
  p_round admission_round,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_slot smallint;
  v_applicant_id uuid;
begin
  caller := public._require_superadmin();
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '대체위원 지정 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('m5d:plan:%s:%s', p_year, p_round::text), 0));

  if not exists (
    select 1 from public.writing_evaluation_plans p
    where p.year = p_year and p.round = p_round and p.status = 'finalized'
  ) then
    raise exception '최종확정된 글쓰기 평가계획이 없습니다.' using errcode = '55000';
  end if;

  select member_slot into v_slot
  from public.writing_plan_members
  where year = p_year and round = p_round and evaluator_uid = p_old_evaluator_uid
  for update;
  if not found then
    raise exception '기존 글쓰기 평가위원을 계획에서 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if p_old_evaluator_uid = p_new_evaluator_uid then
    raise exception '기존 위원과 대체 위원이 같습니다.' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.writing_plan_members
    where year = p_year and round = p_round and evaluator_uid = p_new_evaluator_uid
  ) then
    raise exception '대체 위원은 이미 해당 글쓰기 계획에 배정되어 있습니다.' using errcode = '23514';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_new_evaluator_uid
      and u.active = true
      and 'evaluator' = any(u.roles)
      and 'writing' = any(u.assigned_areas)
      and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
      and (coalesce(array_length(u.round_scopes, 1), 0) = 0 or p_round = any(u.round_scopes))
  ) then
    raise exception '대체 평가위원의 evaluator/writing/scope 권한이 유효하지 않습니다.' using errcode = '42501';
  end if;

  update public.writing_plan_members
  set evaluator_uid = p_new_evaluator_uid
  where year = p_year and round = p_round and member_slot = v_slot;

  for v_applicant_id in
    select dr.applicant_id
    from public.writing_evaluation_plans p
    join public.decision_results dr
      on dr.run_id = p.document_source_run_id and dr.outcome = 'passed'
    where p.year = p_year and p.round = p_round
  loop
    perform public._refresh_writing_aggregate(v_applicant_id);
  end loop;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, reason_code, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'writing_plan.member_replaced', 'writing_evaluation_plans',
     p_year::text || '_' || p_round::text, 'writing', '대체 평가위원 지정',
     jsonb_build_object('oldEvaluatorUid', p_old_evaluator_uid, 'newEvaluatorUid', p_new_evaluator_uid, 'slot', v_slot, 'reason', p_reason));

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'memberSlot', v_slot,
    'oldEvaluatorUid', p_old_evaluator_uid,
    'newEvaluatorUid', p_new_evaluator_uid
  );
end;
$$;

revoke all on function public.replace_m5d_writing_evaluator(uuid, uuid, int, admission_round, text) from public, anon;
grant execute on function public.replace_m5d_writing_evaluator(uuid, uuid, int, admission_round, text) to authenticated;

-- ============================================================
-- 9. migration self-verification
-- ============================================================

do $m5d_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regclass('public.writing_evaluation_plans') is null then missing_objects := array_append(missing_objects, 'table:writing_evaluation_plans'); end if;
  if to_regclass('public.writing_plan_members') is null then missing_objects := array_append(missing_objects, 'table:writing_plan_members'); end if;
  if to_regclass('public.scores_writing') is null then missing_objects := array_append(missing_objects, 'table:scores_writing'); end if;
  if to_regclass('public.deep_writing_aggregates') is null then missing_objects := array_append(missing_objects, 'table:deep_writing_aggregates'); end if;

  if to_regprocedure('public._m5d_writing_params(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_writing_params(uuid)'); end if;
  if to_regprocedure('public._m5d_validate_and_total(uuid,jsonb,boolean)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_validate_and_total(uuid,jsonb,boolean)'); end if;
  if to_regprocedure('public._m5d_validate_writing_plan(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'function:_m5d_validate_writing_plan'); end if;
  if to_regprocedure('public.get_m5d_writing_workspace(integer,admission_round)') is null then missing_objects := array_append(missing_objects, 'rpc:get_m5d_writing_workspace'); end if;
  if to_regprocedure('public.save_writing_score_draft(uuid,jsonb,text,timestamp with time zone)') is null then missing_objects := array_append(missing_objects, 'rpc:save_writing_score_draft'); end if;
  if to_regprocedure('public.submit_writing_score(uuid,jsonb,text)') is null then missing_objects := array_append(missing_objects, 'rpc:submit_writing_score'); end if;
  if to_regprocedure('public._compute_writing_aggregate(uuid)') is null then missing_objects := array_append(missing_objects, 'function:_compute_writing_aggregate'); end if;
  if to_regprocedure('public._trg_refresh_writing_aggregate()') is null then missing_objects := array_append(missing_objects, 'function:_trg_refresh_writing_aggregate'); end if;
  if to_regprocedure('public._can_access_document_v2(uuid,document_type,document_classification,evaluation_area[])') is null then missing_objects := array_append(missing_objects, 'function:_can_access_document_v2'); end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_writing'
      and t.tgname = 'trg_refresh_writing_aggregate'
      and not t.tgisinternal
  ) then
    missing_objects := array_append(missing_objects, 'trigger:trg_refresh_writing_aggregate');
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'admission_documents'
      and policyname = 'admission_documents_select_by_classification'
      and qual like '%_can_access_document_v2%'
  ) then
    missing_objects := array_append(missing_objects, 'policy:admission_documents_select_by_classification:v2');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5D_00013_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5d_verify$;

commit;

select
  'M5D_00013_APPLIED'::text as migration_status,
  to_regprocedure('public._m5d_writing_params(uuid)') is not null as helper_present,
  to_regclass('public.scores_writing') is not null as score_table_present,
  exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'scores_writing'
      and t.tgname = 'trg_refresh_writing_aggregate'
      and not t.tgisinternal
  ) as aggregate_trigger_present,
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'admission_documents'
      and policyname = 'admission_documents_select_by_classification'
      and qual like '%_can_access_document_v2%'
  ) as writing_document_rls_hardened;
