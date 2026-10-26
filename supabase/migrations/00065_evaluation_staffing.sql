-- 새봄고 입학전형 시스템 — 평가 준비(전형위원 배정 현황) (2026-09-28)
--
-- 배경: 담당 영역 배정은 예전부터 "사용자(선생님) 권한 관리"에서 할 수 있었다.
-- 다만 그 화면은 사람 단위라 "자기소개서 평가위원이 지금 몇 명인가"를 볼 수 없다.
--
-- 이게 실제 사고로 이어진다. 서류평가는 영역마다 제출해야 할 평가위원 수가
-- 설정(scoring_params.<area>.requiredSubmissions)으로 정해져 있고,
-- _compute_document_aggregate가 그 인원수를 정확히 채운 지원자만 "완료"로 본다.
-- 인원이 모자라면 1차 사정 확정이 아예 되지 않는데, 지금 구조로는 그 사실을
-- 사정 단계에 가서야 알게 된다. 준비 단계에서 미리 보이게 하는 것이 목적이다.
--
-- 데이터는 새로 만들지 않는다. users.assigned_areas 하나를 사람 중심(권한 관리)과
-- 영역 중심(이 화면)으로 다르게 보여줄 뿐이라, 두 화면이 서로 어긋날 수 없다.
--
-- 심층역량평가(모둠·면접·글쓰기)는 성격이 다르다. 여기서는 "이 영역에 참여할
-- 위원"만 정하고, 실제 몇 명이 필요한지는 조 편성(전형 준비)에서 결정된다.
-- 그래서 필요 인원을 숫자로 못 박지 않고 배정된 인원만 보여준다.

-- ============================================================
-- 1. 영역별 배정 현황 조회
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
    -- 필요 인원은 서류평가에만 의미가 있다(위 주석 참고). 심층역량평가는 null.
    'requiredCount', case
      when p_stage = 'document'
        then (v_params -> a.area::text ->> 'requiredSubmissions')::int
      else null
    end,
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

  -- 배정 후보: 활성 계정 중 평가 역할을 가진 사람 전원.
  -- (영역마다 필요한 역할이 달라 화면에서 다시 거른다)
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

-- ============================================================
-- 2. 영역 배정 / 해제
--    권한은 기존 담당영역 변경 경로(upsert_user_access)와 동일하게
--    superadmin으로 맞춘다 — 누가 어떤 지원자를 채점하는지가 바뀌는 일이라
--    admin까지 열지 않는다. 화면에서는 admin에게 조회만 허용한다.
-- ============================================================

create or replace function public.set_user_area_assignment(
  p_target_uid uuid,
  p_area evaluation_area,
  p_assigned boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_user record;
  v_required app_role;
  v_next evaluation_area[];
begin
  caller := public._require_superadmin();

  select * into v_user from public.users where id = p_target_uid;
  if v_user is null then
    raise exception '대상 사용자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not v_user.active then
    raise exception '비활성 계정에는 영역을 배정할 수 없습니다.' using errcode = '55000';
  end if;

  v_required := public._score_area_required_role(p_area);

  if p_assigned then
    -- 역할이 없으면 배정해도 실제 채점을 할 수 없다. 조용히 넘어가면
    -- "배정은 했는데 화면이 안 보인다"는 문제가 되므로 여기서 막는다.
    if not (v_required = any(v_user.roles)) then
      raise exception '% 영역은 % 역할이 필요합니다. 사용자 권한 관리에서 역할을 먼저 부여하세요.',
        p_area, v_required using errcode = '42501';
    end if;
    if p_area = any(v_user.assigned_areas) then
      return jsonb_build_object('changed', false, 'assignedAreas', v_user.assigned_areas);
    end if;
    v_next := array_append(v_user.assigned_areas, p_area);
  else
    if not (p_area = any(v_user.assigned_areas)) then
      return jsonb_build_object('changed', false, 'assignedAreas', v_user.assigned_areas);
    end if;
    v_next := array_remove(v_user.assigned_areas, p_area);
  end if;

  update public.users
  set assigned_areas = v_next,
      updated_at = now(),
      updated_by = caller::text
  where id = p_target_uid;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    ('user', caller::text,
     case when p_assigned then 'user.area.assigned' else 'user.area.unassigned' end,
     'users', p_target_uid::text, p_area,
     jsonb_build_object('assignedAreas', v_next));

  return jsonb_build_object('changed', true, 'assignedAreas', v_next);
end;
$$;

revoke all on function public.set_user_area_assignment(uuid, evaluation_area, boolean) from public, anon;
grant execute on function public.set_user_area_assignment(uuid, evaluation_area, boolean) to authenticated;
