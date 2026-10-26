-- 새봄고 입학전형 시스템 — 영역별 "배정 인원"을 "제출 필요 건수"와 분리 (2026-09-28)
--
-- 배경: 평가 준비 화면(00065)은 필요 인원을 scoring_params.<area>.requiredSubmissions
-- 에서 읽었다. 그런데 그 값은 이미 다른 뜻으로 쓰이고 있다.
--
--   · 평가 진행 현황(00007): 이 값만큼 "제출"돼야 완료로 본다.
--   · 1차 사정 완료 판정(00008): 설정을 읽지 않고 SQL에 박혀 있다
--     (공동체 2건·자기소개서 5건·학부모소견서 4건, 출결·학업은 1건이면 통과).
--
-- 그래서 출결·학업의 requiredSubmissions를 2로 올리면, 실제로는 한 사람이
-- 입력하므로 진행 현황이 영원히 미완료로 남고 대시보드의 "미완료 평가"가
-- 0이 되지 않는다. 반면 사정은 그대로 통과해 화면과 사정이 엇갈린다.
--
-- 실제로 필요한 것은 두 가지가 다르다는 사실을 인정하는 것이다.
--   · 배정 인원: 내부 규정상 몇 명이 그 영역을 맡아야 하는가 (출결·학업도 2명)
--   · 제출 필요 건수: 채점이 완료되려면 몇 건이 들어와야 하는가 (출결·학업은 1건)
--
-- 이 마이그레이션은 "배정 인원"만 담는 표를 따로 만든다. requiredSubmissions는
-- 손대지 않으므로 진행 현황·사정 동작은 그대로다.
--
-- config_revisions에 넣지 않은 이유: config revision은 잠기면 수정 불가라
-- 값 하나 바꾸려고 새 revision을 만들어 회차에 다시 연결해야 하는데, 그러면
-- 심층역량평가 계획이 CONFIG_SOURCE_STALE로 무효화된다. 배정 인원은 배점이
-- 아니라 운영 규정에 가까워 별도 표가 더 알맞다.

create table if not exists public.evaluation_area_staffing (
  year int not null,
  round admission_round not null,
  area evaluation_area not null,
  required_evaluators int not null check (required_evaluators >= 0),
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (year, round, area)
);

comment on table public.evaluation_area_staffing is
  '영역별로 배정해야 할 전형위원 수(내부 규정). 채점 완료 판정에 쓰이는 scoring_params.requiredSubmissions와는 다른 값이다.';

alter table public.evaluation_area_staffing enable row level security;
revoke all on public.evaluation_area_staffing from anon, authenticated;

-- 이미 만들어진 모든 회차에 기본값을 넣는다.
-- 출결·학업은 실제 입력은 1명이 하더라도 규정상 2명을 배정한다(2026-09-28 확인).
insert into public.evaluation_area_staffing (year, round, area, required_evaluators, updated_by)
select r.year, r.round, d.area, d.cnt, 'migration-00066'
from public.admission_rounds r
cross join (values
  ('attendance'::evaluation_area, 2),
  ('academic'::evaluation_area, 2),
  ('community'::evaluation_area, 2),
  ('essay'::evaluation_area, 5),
  ('opinion'::evaluation_area, 4)
) as d(area, cnt)
on conflict (year, round, area) do nothing;

-- ============================================================
-- 배정 인원 변경 (superadmin)
-- ============================================================

create or replace function public.set_evaluation_area_staffing(
  p_year int,
  p_round admission_round,
  p_area evaluation_area,
  p_required_evaluators int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_superadmin();

  if p_required_evaluators is null or p_required_evaluators < 0 or p_required_evaluators > 50 then
    raise exception '배정 인원은 0~50 사이여야 합니다.' using errcode = '23514';
  end if;

  insert into public.evaluation_area_staffing
    (year, round, area, required_evaluators, updated_by)
  values
    (p_year, p_round, p_area, p_required_evaluators, caller::text)
  on conflict (year, round, area) do update set
    required_evaluators = excluded.required_evaluators,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'staffing.required_evaluators_changed',
     'evaluation_area_staffing', p_area::text, p_area,
     jsonb_build_object('requiredEvaluators', p_required_evaluators));
end;
$$;

revoke all on function public.set_evaluation_area_staffing(int, admission_round, evaluation_area, int) from public, anon;
grant execute on function public.set_evaluation_area_staffing(int, admission_round, evaluation_area, int) to authenticated;

-- ============================================================
-- 조회 함수 갱신 — 배정 인원은 새 표에서, 없으면 기존 동작(설정값)으로 대체
-- ============================================================

create or replace function public.get_evaluation_staffing(
  p_year int,
  p_round admission_round,
  p_stage text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_areas evaluation_area[];
  v_rev_id uuid;
  v_params jsonb;
  v_result jsonb;
  v_available jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_stage = 'document' then
    v_areas := array['attendance','academic','community','essay','opinion']::evaluation_area[];
  elsif p_stage = 'deep' then
    v_areas := array['group','interview','writing']::evaluation_area[];
  else
    raise exception '알 수 없는 평가 단계입니다: % (document 또는 deep)', p_stage
      using errcode = '22023';
  end if;

  select config_revision_id into v_rev_id
  from public.admission_rounds where year = p_year and round = p_round;
  if v_rev_id is not null then
    select scoring_params into v_params from public.config_revisions where id = v_rev_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'area', a.area,
    -- 배정해야 할 인원(운영 규정). 표에 값이 없으면 예전처럼 설정값을 쓴다.
    'requiredCount', coalesce(
      (select s.required_evaluators from public.evaluation_area_staffing s
        where s.year = p_year and s.round = p_round and s.area = a.area),
      (v_params -> a.area::text ->> 'requiredSubmissions')::int
    ),
    -- 채점 완료로 보기 위해 실제로 들어와야 하는 제출 건수(참고 표시용).
    -- 배정 인원과 다를 수 있다(예: 출결은 2명 배정, 1건 제출이면 완료).
    'requiredSubmissions', (v_params -> a.area::text ->> 'requiredSubmissions')::int,
    'requiredRole', public._score_area_required_role(a.area)::text,
    'assigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id, 'displayName', u.display_name, 'email', u.email,
        'roles', u.roles
      ) order by u.display_name)
      from public.users u
      where u.active = true and a.area = any(u.assigned_areas)
    ), '[]'::jsonb)
  ) order by ord), '[]'::jsonb)
  into v_result
  from unnest(v_areas) with ordinality as a(area, ord);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email,
    'roles', roles, 'assignedAreas', assigned_areas
  ) order by display_name), '[]'::jsonb)
  into v_available
  from public.users
  where active = true
    and roles && array['evaluator','quant']::app_role[];

  return jsonb_build_object(
    'stage', p_stage,
    'year', p_year,
    'round', p_round,
    'areas', v_result,
    'availableUsers', v_available
  );
end;
$$;

revoke all on function public.get_evaluation_staffing(int, admission_round, text) from public, anon;
grant execute on function public.get_evaluation_staffing(int, admission_round, text) to authenticated;
