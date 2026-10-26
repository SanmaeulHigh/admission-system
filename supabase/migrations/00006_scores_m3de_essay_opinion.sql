-- 새봄고 입학전형 시스템 — M3d/e 자기소개서·학부모 소견서 채점 (Sprint 3 계속)
-- 근거: 2026학년도 새봄고 신입생 입학전형 서류평가 업무 진행 지침
-- (2025.11.3.) 4.(4)(5)항. 배점표는 이 문서를 그대로 반영했다.
--
-- 자기소개서: 10개 기준, 기준당 0~10점 정수, 5인 독립채점 합산(최대 500).
--   "형식적 서술이라도 관련성 있으면 최소 3점" — 사람 판단 영역이라
--   서버에서 강제하지 않고 채점 화면에 안내 문구로만 표시한다.
-- 학부모 소견서: 5개 기준, 기준당 0~5점 0.5단위, 4인 독립채점 합산(최대 100).
--   deductionFlags(모순 발견/건강·약물정보 누락)는 참고용 boolean 플래그로
--   기록하되, 실제 감점 반영은 위원이 최종 점수에 직접 반영한다(사람 판단).
--
-- 자소서는 "자동저장" 요구가 명시돼 있어(스펙 1251행) draft 상태를 둔다.
-- 소견서도 동일 패턴으로 일관되게 draft를 둔다.

-- ============================================================
-- 1. 테이블
-- ============================================================

create table public.scores_essay (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'draft' check (submission_state in ('draft', 'submitted', 'reopened')),
  items jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

create table public.scores_opinion (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  evaluator_uid uuid not null references public.users (id),
  year int not null,
  round admission_round not null,
  config_revision_id uuid not null references public.config_revisions (id),
  submission_state text not null default 'draft' check (submission_state in ('draft', 'submitted', 'reopened')),
  items jsonb not null default '{}'::jsonb,
  deduction_flags jsonb not null default '{}'::jsonb,
  server_computed jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (applicant_id, evaluator_uid)
);

comment on table public.scores_essay is
  'M3d. role=evaluator, area=essay. 기준 10개(각 0~10, 정수), 5인 합산 최대 500. items key는 config criteria 키셋과 정확히 일치해야 함.';
comment on table public.scores_opinion is
  'M3e. role=evaluator, area=opinion. 기준 5개(각 0~5, 0.5단위), 4인 합산 최대 100.';

-- ============================================================
-- 2. RLS (M3a~c와 동일 패턴: 본인 또는 관리자만 read, write는 RPC로만)
-- ============================================================

alter table public.scores_essay enable row level security;
alter table public.scores_opinion enable row level security;

create policy scores_essay_select_own_or_admin
  on public.scores_essay for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

create policy scores_opinion_select_own_or_admin
  on public.scores_opinion for select
  using (evaluator_uid = auth.uid() or public.has_role('superadmin') or public.has_role('admin'));

-- ============================================================
-- 3. 자기소개서 기준 키셋 (10개, 0~10점 정수)
-- ============================================================

create or replace function public._essay_criteria_keys()
returns text[]
language sql
immutable
as $$
  select array[
    'admissionWill', 'selfUnderstanding', 'schoolUnderstanding', 'schoolAdaptation',
    'learningWill', 'serviceWill', 'communityLife', 'careerConnection',
    'sincerity', 'feasibility'
  ];
$$;

-- ============================================================
-- 4. save_essay_draft — 자동저장 (제출확정 아님, 여러 번 호출 가능)
-- ============================================================

create or replace function public.save_essay_draft(
  p_applicant_id uuid,
  p_items jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  v numeric;
  existing record;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('essay')) then
    raise exception '자기소개서 평가 권한이 없습니다 (evaluator + essay 배정 필요).';
  end if;

  select * into existing from public.scores_essay
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출확정된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  -- 부분 저장 허용: 채워진 키만 0~10 정수인지 검증 (전체 키 필수는 제출 시점에)
  for k, v in select key, value::text::numeric from jsonb_each(p_items)
  loop
    if not (k = any(public._essay_criteria_keys())) then
      raise exception '알 수 없는 채점 기준: %', k;
    end if;
    if v < 0 or v > 10 or v != trunc(v) then
      raise exception '% 점수는 0~10 사이의 정수여야 합니다 (입력값: %)', k, v;
    end if;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_essay
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, submission_state)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items, 'draft')
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    submission_state = 'draft',
    updated_at = now();
end;
$$;

revoke execute on function public.save_essay_draft(uuid, jsonb) from anon;

-- ============================================================
-- 5. submit_essay_score — 제출확정 (10개 키 전부 필수, 서버가 합산)
-- ============================================================

create or replace function public.submit_essay_score(
  p_applicant_id uuid,
  p_items jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  total numeric := 0;
  existing record;
  required_keys text[] := public._essay_criteria_keys();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('essay')) then
    raise exception '자기소개서 평가 권한이 없습니다 (evaluator + essay 배정 필요).';
  end if;

  select * into existing from public.scores_essay
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  -- 10개 키 전부 존재해야 제출 가능 (draft는 부분 허용, 제출은 완전해야 함)
  foreach k in array required_keys loop
    if not (p_items ? k) then
      raise exception '% 기준 점수가 없습니다. 10개 기준을 모두 입력해야 제출할 수 있습니다.', k;
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(p_items)) <> array_length(required_keys, 1) then
    raise exception '허용되지 않은 추가 기준이 있습니다.';
  end if;

  for k in select jsonb_object_keys(p_items) loop
    declare v numeric := (p_items ->> k)::numeric;
    begin
      if v < 0 or v > 10 or v != trunc(v) then
        raise exception '% 점수는 0~10 사이의 정수여야 합니다 (입력값: %)', k, v;
      end if;
      total := total + v;
    end;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'essay') then
    raise exception '자기소개서 평가가 현재 열려있지 않습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_essay
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, server_computed,
     submission_state, submitted_at)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items,
     jsonb_build_object('total', total), 'submitted', now())
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.essay.submitted', 'scores_essay',
     p_applicant_id::text, p_applicant_id::text, 'essay');

  return jsonb_build_object('total', total)::json;
end;
$$;

revoke execute on function public.submit_essay_score(uuid, jsonb) from anon;

-- ============================================================
-- 6. 학부모 소견서 기준 키셋 (5개, 0~5점 0.5단위)
-- ============================================================

create or replace function public._opinion_criteria_keys()
returns text[]
language sql
immutable
as $$
  select array[
    'altEducationUnderstanding', 'schoolUnderstanding', 'childUnderstanding',
    'childCareerView', 'admissionWillParticipation'
  ];
$$;

-- ============================================================
-- 7. submit_opinion_score — 제출확정 (0.5단위 검증 포함)
-- ============================================================

create or replace function public.submit_opinion_score(
  p_applicant_id uuid,
  p_items jsonb,
  p_deduction_flags jsonb default '{}'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  app record;
  rev_id uuid;
  k text;
  total numeric := 0;
  existing record;
  required_keys text[] := public._opinion_criteria_keys();
begin
  if caller is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not (public.has_role('evaluator') and public.has_area('opinion')) then
    raise exception '학부모 소견서 평가 권한이 없습니다 (evaluator + opinion 배정 필요).';
  end if;

  select * into existing from public.scores_opinion
    where applicant_id = p_applicant_id and evaluator_uid = caller;
  if existing is not null and existing.submission_state = 'submitted' then
    raise exception '이미 제출된 채점입니다. 수정하려면 관리자에게 재개방을 요청하세요.';
  end if;

  foreach k in array required_keys loop
    if not (p_items ? k) then
      raise exception '% 기준 점수가 없습니다. 5개 기준을 모두 입력해야 제출할 수 있습니다.', k;
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(p_items)) <> array_length(required_keys, 1) then
    raise exception '허용되지 않은 추가 기준이 있습니다.';
  end if;

  for k in select jsonb_object_keys(p_items) loop
    declare v numeric := (p_items ->> k)::numeric;
    begin
      if v < 0 or v > 5 or mod(v * 10, 5) <> 0 then
        raise exception '% 점수는 0~5 사이의 0.5 단위여야 합니다 (입력값: %)', k, v;
      end if;
      total := total + v;
    end;
  end loop;

  select id, year, round into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if not public._is_evaluation_active(p_applicant_id) then
    raise exception '이 지원자는 현재 평가 활성 상태가 아닙니다.';
  end if;
  if not public._is_area_open(app.year, app.round, 'opinion') then
    raise exception '학부모 소견서 평가가 현재 열려있지 않습니다.';
  end if;
  rev_id := public._current_config_revision_id(app.year, app.round);

  insert into public.scores_opinion
    (applicant_id, evaluator_uid, year, round, config_revision_id, items, deduction_flags,
     server_computed, submission_state, submitted_at)
  values
    (p_applicant_id, caller, app.year, app.round, rev_id, p_items, p_deduction_flags,
     jsonb_build_object('total', total), 'submitted', now())
  on conflict (applicant_id, evaluator_uid) do update set
    items = excluded.items,
    deduction_flags = excluded.deduction_flags,
    server_computed = excluded.server_computed,
    config_revision_id = excluded.config_revision_id,
    submission_state = 'submitted',
    submitted_at = now(),
    updated_at = now();

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area)
  values
    (app.year, app.round, 'user', caller::text, 'score.opinion.submitted', 'scores_opinion',
     p_applicant_id::text, p_applicant_id::text, 'opinion');

  return jsonb_build_object('total', total)::json;
end;
$$;

revoke execute on function public.submit_opinion_score(uuid, jsonb, jsonb) from anon;

-- ============================================================
-- 8. reopen_score 확장 (기존 함수에 essay/opinion 테이블 추가)
-- ============================================================

create or replace function public.reopen_score(
  p_score_table text,
  p_score_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_score_table not in
     ('scores_attendance', 'scores_academic', 'scores_community', 'scores_essay', 'scores_opinion') then
    raise exception '알 수 없는 채점 테이블입니다: %', p_score_table;
  end if;

  if p_score_table = 'scores_attendance' then
    update public.scores_attendance set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_academic' then
    update public.scores_academic set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_community' then
    update public.scores_community set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  elsif p_score_table = 'scores_essay' then
    update public.scores_essay set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  else
    update public.scores_opinion set submission_state = 'reopened', updated_at = now() where id = p_score_id;
  end if;

  if not found then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, resource_id)
  values ('user', caller::text, 'score.reopened', p_score_table, p_score_id::text);
end;
$$;

revoke execute on function public.reopen_score(text, uuid) from anon;
