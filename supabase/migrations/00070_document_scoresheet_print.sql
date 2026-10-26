-- 새봄고 입학전형 시스템 — 서류평가 채점표 출력(결재용) (2026-09-28)
--
-- 목적: 서류평가 영역별 채점표를 인쇄해 서명을 받고, 스캔해서 K-에듀파인으로
-- 결재받는다. 출결·학업성실도·공동체는 최고관리자 1명이 시스템에서 채점하지만
-- (00069), 내부 규정상 채점위원은 2명이어야 하므로 채점표 서명란에 이름을 한 명
-- 더 올릴 수 있게 한다(2026-09-28 결정).
--
-- · scoresheet_cosigners: 영역별로 서명란에 추가할 이름(시스템 계정이 아니어도 됨).
--   시스템 채점 기록에는 영향이 없고, 인쇄물 서명란에만 쓰인다.
-- · get_document_scoresheet: 영역별 채점표 데이터(평가 대상 명단 + 제출된 채점 + 추가 서명자).
--   1차 사정 확정 전에도 볼 수 있다(결재는 확정 전후 모두 필요할 수 있음).

create table if not exists public.scoresheet_cosigners (
  year int not null,
  round admission_round not null,
  area evaluation_area not null,
  names text[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (year, round, area)
);

comment on table public.scoresheet_cosigners is
  '채점표 인쇄 시 서명란에 추가로 올릴 이름(내부 규정상 채점위원 수 충족용). 채점 기록과 무관.';

alter table public.scoresheet_cosigners enable row level security;
revoke all on public.scoresheet_cosigners from anon, authenticated;

-- ============================================================
-- 1. 추가 서명자 저장
-- ============================================================

create or replace function public.set_scoresheet_cosigners(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_names text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_names text[];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(array_agg(n order by ord), '{}')
    into v_names
  from (
    select btrim(x) as n, ord
    from unnest(coalesce(p_names, '{}'::text[])) with ordinality as t(x, ord)
    where btrim(coalesce(x, '')) <> ''
  ) s;

  if array_length(v_names, 1) > 5 then
    raise exception '추가 서명자는 최대 5명까지입니다.' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(v_names) n where length(n) > 30) then
    raise exception '이름은 30자 이내로 입력하세요.' using errcode = '23514';
  end if;

  insert into public.scoresheet_cosigners (year, round, area, names, updated_by)
  values (p_year, p_round, p_area, v_names, caller::text)
  on conflict (year, round, area) do update set
    names = excluded.names, updated_at = now(), updated_by = caller::text;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'scoresheet.cosigners_changed',
     'scoresheet_cosigners', p_area::text, p_area, jsonb_build_object('names', to_jsonb(v_names)));

  return jsonb_build_object('names', to_jsonb(v_names));
end;
$$;

revoke all on function public.set_scoresheet_cosigners(int, admission_round, evaluation_area, text[]) from public, anon;
grant execute on function public.set_scoresheet_cosigners(int, admission_round, evaluation_area, text[]) to authenticated;

-- ============================================================
-- 2. 채점표 데이터
-- ============================================================

create or replace function public.get_document_scoresheet(
  p_year int,
  p_round admission_round,
  p_area evaluation_area
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_scores jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('attendance','academic','community','essay','opinion') then
    raise exception '서류평가 영역이 아닙니다: %', p_area using errcode = '22023';
  end if;

  if p_area = 'attendance' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_attendance s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'academic' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_academic s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'community' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.inputs, 'score', (s.server_computed ->> 'score')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_community s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  elsif p_area = 'essay' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.items, 'score', (s.server_computed ->> 'total')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_essay s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid, 'evaluatorName', u.display_name,
      'inputs', s.items, 'score', (s.server_computed ->> 'total')::numeric, 'submittedAt', s.submitted_at
    )), '[]'::jsonb) into v_scores
    from public.scores_opinion s join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted';
  end if;

  -- 개별 점수가 이름과 함께 나가는 조회이므로 열람 기록을 남긴다.
  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, area)
  values (p_year, p_round, 'user', caller::text, 'scoresheet.viewed', 'scores', p_area::text, p_area);

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', er.applicant_id,
        'examNo', coalesce(er.exam_no, a.exam_no),
        'receiptNo', a.receipt_no,
        'name', a.name
      ) order by coalesce(er.exam_no, a.exam_no, a.receipt_no))
      from public.evaluation_roster er
      join public.applicants a on a.id = er.applicant_id
      where er.year = p_year and er.round = p_round and er.evaluation_active = true
    ), '[]'::jsonb),
    'scores', v_scores,
    'cosigners', coalesce((
      select to_jsonb(c.names) from public.scoresheet_cosigners c
      where c.year = p_year and c.round = p_round and c.area = p_area
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_document_scoresheet(int, admission_round, evaluation_area) from public, anon;
grant execute on function public.get_document_scoresheet(int, admission_round, evaluation_area) to authenticated;
