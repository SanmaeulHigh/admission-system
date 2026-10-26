-- 새봄고 입학전형 시스템 — 전형위원 서류 열람 권한을 서류 종류별로 수동 설정 (2026-10-01)
--
-- 기존 규칙(00013): 평가위원·정량평가 위원은 "본인 담당영역 ∩ 서류의 access_areas"가
-- 겹칠 때만 열람했다. 입학원서·자격 증빙·동의서(reception 분류)는 아예 못 봤고,
-- 글쓰기 답안은 서류평가 통과자 것을 글쓰기 배정 위원만 볼 수 있었다.
--
-- 바꾸는 이유(2026-10-01 운영 판단): 종이 전형 때처럼 지원자가 제출한 서류 일체를
-- 전형위원 모두가 열람할 수 있어야 한다. 대신 슈퍼관리자가 위원별로 특정 서류
-- 종류를 수동으로 막을 수 있게 한다.
--
-- 새 규칙:
--   · superadmin / admin: 지금처럼 전부.
--   · adminOnly 분류: 관리자만(변경 없음).
--   · reception 역할: reception 분류 서류는 지금처럼 열람.
--   · evaluator / quant: 분류(reception·evaluation)와 담당영역에 관계없이,
--     users.viewable_document_types에 그 서류 종류가 있으면 열람.
--     viewable_document_types가 NULL이면 "전체" — 나중에 서류 종류가 추가돼도 자동 포함.
--
-- 보완책: 모든 열람은 여전히 log_document_view로 전건 감사 기록된다.
-- 업로드 시 정하는 access_areas는 이제 열람 판정에 쓰이지 않는다(데이터는 그대로 둔다).

alter table public.users
  add column if not exists viewable_document_types document_type[];

comment on column public.users.viewable_document_types is
  '평가위원·정량평가 위원이 열람할 수 있는 서류 종류. NULL = 전체.';

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
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

-- 슈퍼관리자가 위원별 열람 서류 종류를 지정한다.
-- p_types = NULL → 전체 열람(기본값으로 되돌림), 빈 배열 → 아무 서류도 열람 불가.
create or replace function public.set_user_document_access(
  p_user_ids uuid[],
  p_types document_type[]
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

  update public.users u set
    viewable_document_types = case
      when p_types is null then null
      else (select coalesce(array_agg(distinct t order by t), '{}') from unnest(p_types) t)
    end,
    updated_at = now(),
    updated_by = caller::text
  where u.id = any(p_user_ids);
  get diagnostics v_count = row_count;

  insert into public.audit_logs (actor_type, actor_uid, action, resource_type, metadata)
  values ('user', caller::text, 'user.document_access_updated', 'users',
          jsonb_build_object('userIds', to_jsonb(p_user_ids), 'types', to_jsonb(p_types),
                             'updated', v_count));

  return jsonb_build_object('updated', v_count);
end;
$$;

revoke all on function public.set_user_document_access(uuid[], document_type[]) from public, anon;
grant execute on function public.set_user_document_access(uuid[], document_type[]) to authenticated;
