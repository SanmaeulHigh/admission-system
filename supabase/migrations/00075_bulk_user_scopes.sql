-- 새봄고 입학전형 시스템 — 사용자 권한 적용 연도·차수 일괄 지정 (2026-09-29)
--
-- 사용자 권한 관리에서 여러 선생님을 골라 "몇 학년도 · 어느 차수(본전형/추가모집)"에
-- 권한이 적용되는지를 한 번에 바꾼다. 역할·영역별 세부 배정은 기존 화면
-- (역할 수정, 평가 준비)에서 따로 한다.
--
-- mode: 'replace' = 지정한 값으로 교체, 'add' = 기존 값에 추가(중복 제거)
-- 연도·차수를 비워 두면(빈 배열) 그 항목은 건드리지 않는다.

create or replace function public.set_user_scopes_bulk(
  p_user_ids uuid[],
  p_year_scopes int[],
  p_round_scopes admission_round[],
  p_mode text default 'replace'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_count int;
begin
  caller := public._require_superadmin();

  if p_user_ids is null or array_length(p_user_ids, 1) is null then
    raise exception '대상 사용자를 1명 이상 선택하세요.' using errcode = '22023';
  end if;
  if p_mode not in ('replace', 'add') then
    raise exception 'mode는 replace 또는 add여야 합니다.' using errcode = '22023';
  end if;
  if coalesce(array_length(p_year_scopes, 1), 0) = 0 and coalesce(array_length(p_round_scopes, 1), 0) = 0 then
    raise exception '연도나 차수 중 하나 이상을 지정하세요.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_year_scopes, '{}')) y where y < 2020 or y > 2200) then
    raise exception '연도 값이 올바르지 않습니다.' using errcode = '22023';
  end if;

  update public.users u set
    year_scopes = case
      when coalesce(array_length(p_year_scopes, 1), 0) = 0 then u.year_scopes
      when p_mode = 'replace' then (select array_agg(distinct y order by y) from unnest(p_year_scopes) y)
      else (select array_agg(distinct y order by y) from unnest(coalesce(u.year_scopes, '{}') || p_year_scopes) y)
    end,
    round_scopes = case
      when coalesce(array_length(p_round_scopes, 1), 0) = 0 then u.round_scopes
      when p_mode = 'replace' then (select array_agg(distinct r order by r) from unnest(p_round_scopes) r)
      else (select array_agg(distinct r order by r) from unnest(coalesce(u.round_scopes, '{}') || p_round_scopes) r)
    end,
    updated_at = now()
  where u.id = any(p_user_ids);
  get diagnostics v_count = row_count;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, metadata)
  values ('user', caller::text, 'user.scopes_bulk_updated', 'users',
          jsonb_build_object('userIds', to_jsonb(p_user_ids), 'yearScopes', to_jsonb(p_year_scopes),
                             'roundScopes', to_jsonb(p_round_scopes), 'mode', p_mode, 'updated', v_count));

  return jsonb_build_object('updated', v_count);
end;
$$;

revoke all on function public.set_user_scopes_bulk(uuid[], int[], admission_round[], text) from public, anon;
grant execute on function public.set_user_scopes_bulk(uuid[], int[], admission_round[], text) to authenticated;
