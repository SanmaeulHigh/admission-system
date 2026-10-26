-- 새봄고 입학전형 시스템 — 서류평가 정성 영역 채점기준표 저장소 (2026-10-16)
--
-- 채점기준표는 대외비다. 화면 코드(자바스크립트)는 로그인 없이도 내려받을 수 있으므로 기준표 문구를
-- 코드에 넣지 않고 이 표에만 둔다. 원문은 저장소에 커밋하지 않는 SQL 파일(supabase/private/)로 넣는다.
--
-- area: 'common'(공통 원칙) / 'essay' / 'opinion' / 'community'
-- 읽기: 관리자, 또는 해당 영역을 배정받은 평가위원·정량위원(학년도 범위 포함).
--       'common'은 essay·opinion·community 중 하나라도 배정된 위원이 읽는다.

create table if not exists public.evaluation_rubrics (
  year int not null,
  area text not null check (area in ('common', 'essay', 'opinion', 'community')),
  content jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'sql',
  primary key (year, area)
);

comment on table public.evaluation_rubrics is
  '서류평가 정성 영역 채점기준표(대외비). get_evaluation_rubric RPC로만 읽는다.';

alter table public.evaluation_rubrics enable row level security;
revoke all on table public.evaluation_rubrics from anon, authenticated;

create or replace function public.get_evaluation_rubric(p_year int, p_area text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_content jsonb;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = caller and u.active
      and (
        u.roles && array['superadmin', 'admin']::app_role[]
        or (
          u.roles && array['evaluator', 'quant']::app_role[]
          and (coalesce(array_length(u.year_scopes, 1), 0) = 0 or p_year = any(u.year_scopes))
          and (
            (p_area = 'common' and u.assigned_areas && array['essay', 'opinion', 'community']::evaluation_area[])
            or (p_area in ('essay', 'opinion', 'community') and p_area::evaluation_area = any(u.assigned_areas))
          )
        )
      )
  ) then
    raise exception '이 채점기준표를 볼 권한이 없습니다.' using errcode = '42501';
  end if;

  select content into v_content from public.evaluation_rubrics where year = p_year and area = p_area;
  return v_content; -- 아직 넣지 않았으면 null(화면은 '기준표 미등록'으로 표시)
end;
$$;

revoke all on function public.get_evaluation_rubric(int, text) from public, anon;
grant execute on function public.get_evaluation_rubric(int, text) to authenticated;
