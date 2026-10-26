-- 새봄고 입학전형 시스템 — 관리자 화면에서 현재 년도/전형(회차) 전환
--
-- 배경: 지금까지 YEAR=2027 / ROUND='main'이 20개 가까운 화면 파일에 각각
-- 하드코딩되어 있었다. admission_round enum이 애초에 'main','extra1',
-- 'extra2' 세 값을 갖도록 설계돼 있었던 것도(00001) 추가모집 등 회차 전환을
-- 염두에 둔 것이었는데, 실제로 전환할 수 있는 화면이 없었다. 이 마이그레이션은
-- admission_rounds에 "현재 활성 회차" 플래그를 추가하고, superadmin/admin이
-- 관리자 화면에서 이를 전환할 수 있는 RPC를 제공한다.
--
-- 설계: 여러 (year, round) 조합이 admission_rounds에 미리 init_admission_round로
-- 만들어져 있을 수 있으나, 그중 정확히 하나만 "현재"로 표시되어 전체
-- 화면(접수/평가/사정/발표 등)이 기본으로 바라보는 대상이 된다. 새 (year, round)
-- 자체를 만드는 것은 기존과 동일하게 init_admission_round + config revision
-- 절차를 그대로 쓰고, 이 마이그레이션은 "이미 있는 것 중 어느 걸 지금 볼지"만
-- 다룬다.

alter table public.admission_rounds
  add column is_current boolean not null default false;

-- 한 번에 하나의 (year, round)만 현재로 표시되도록 부분 유니크 인덱스로 강제.
create unique index admission_rounds_one_current_idx
  on public.admission_rounds (is_current)
  where is_current;

-- ============================================================
-- 1. 목록 조회 — 설정 화면에서 고를 수 있는 후보 목록
-- ============================================================

create or replace function public.list_admission_rounds()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_result jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(jsonb_agg(jsonb_build_object(
    'year', year, 'round', round, 'stage', stage, 'stageStatus', stage_status,
    'isCurrent', is_current, 'updatedAt', updated_at
  ) order by year desc, round), '[]'::jsonb)
  into v_result
  from public.admission_rounds;

  return v_result;
end;
$$;

revoke all on function public.list_admission_rounds() from public, anon;
grant execute on function public.list_admission_rounds() to authenticated;

-- ============================================================
-- 2. 현재 활성 회차 조회 — 로그인한 모든 사용자가 앱 로드시 호출
--    (특정 데이터 노출 없이 year/round만 반환하므로 role 제한 불필요,
--    단 활성 계정만 — is_active_user()로 최소한의 게이트만 건다)
-- ============================================================

create or replace function public.get_current_admission_cycle()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
begin
  if not public.is_active_user() then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select year, round into v_row
  from public.admission_rounds
  where is_current = true
  limit 1;

  if v_row is null then
    -- 아직 아무도 현재 회차를 지정하지 않았다면, 가장 최근에 만들어진
    -- admission_round를 잠정 기본값으로 돌려준다(관리자가 곧 지정하도록 유도).
    select year, round into v_row
    from public.admission_rounds
    order by created_at desc
    limit 1;
  end if;

  if v_row is null then
    return jsonb_build_object('year', null, 'round', null);
  end if;

  return jsonb_build_object('year', v_row.year, 'round', v_row.round);
end;
$$;

revoke all on function public.get_current_admission_cycle() from public, anon;
grant execute on function public.get_current_admission_cycle() to authenticated;

-- ============================================================
-- 3. 현재 활성 회차 전환 — superadmin/admin
-- ============================================================

create or replace function public.set_current_admission_cycle(
  p_year int,
  p_round admission_round
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

  if not exists (select 1 from public.admission_rounds where year = p_year and round = p_round) then
    raise exception 'admission_round(%, %)가 초기화되어 있지 않습니다. 먼저 해당 회차 설정을 만들어주세요.', p_year, p_round
      using errcode = 'P0002';
  end if;

  update public.admission_rounds set is_current = false where is_current = true;
  update public.admission_rounds set is_current = true where year = p_year and round = p_round;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id)
  values (p_year, p_round, 'user', caller::text, 'admission_round.set_current', 'admission_rounds',
          p_year::text || '_' || p_round::text);
end;
$$;

revoke all on function public.set_current_admission_cycle(int, admission_round) from public, anon;
grant execute on function public.set_current_admission_cycle(int, admission_round) to authenticated;

-- ============================================================
-- 4. 기존 2027/main을 현재로 지정(마이그레이션 적용 직후 화면이 비지 않도록)
-- ============================================================

update public.admission_rounds
set is_current = true
where year = 2027 and round = 'main'
  and exists (select 1 from public.admission_rounds where year = 2027 and round = 'main');
