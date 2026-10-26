-- 새봄고 입학전형 시스템 — 공동체 생활 적합성 '상호 검토' 단계 (2026-10-16)
--
-- 채점기준표: "등급을 판정하고 근거를 시스템에 메모(10자 이상)로 남기며, 상호 간 근거와 등급이 맞는지 검토함"
-- 독립 채점 원칙 때문에 평소에는 다른 위원의 등급·메모를 볼 수 없다. 관리자가 '상호 검토'를 연 동안에만,
-- 그 지원자를 이미 제출한 공동체 위원이 같은 지원자의 다른 위원 등급·근거 메모를 볼 수 있다.
-- 등급을 바꿔야 하면 기존 재개방(reopen) 절차로 다시 제출한다(이 단계는 열람만 연다).

create table if not exists public.document_review_settings (
  year int not null,
  round admission_round not null,
  community_peer_review_open boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (year, round)
);

comment on table public.document_review_settings is
  '서류평가 운영 설정. community_peer_review_open=true 인 동안만 공동체 위원 간 등급·근거 메모 열람.';

alter table public.document_review_settings enable row level security;
revoke all on table public.document_review_settings from anon, authenticated;

create or replace function public._community_peer_review_open(p_year int, p_round admission_round)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select community_peer_review_open from public.document_review_settings
                   where year = p_year and round = p_round), false);
$$;

revoke all on function public._community_peer_review_open(int, admission_round) from public, anon, authenticated;

-- 1. 관리자: 상호 검토 열기/닫기
create or replace function public.set_community_peer_review(p_year int, p_round admission_round, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  insert into public.document_review_settings (year, round, community_peer_review_open, updated_at, updated_by)
  values (p_year, p_round, p_open, now(), caller::text)
  on conflict (year, round) do update
    set community_peer_review_open = excluded.community_peer_review_open,
        updated_at = now(), updated_by = excluded.updated_by;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text,
          case when p_open then 'community.peer_review.opened' else 'community.peer_review.closed' end,
          'document_review_settings', p_year::text || '_' || p_round::text, '{}'::jsonb);

  return jsonb_build_object('open', p_open);
end;
$$;

revoke all on function public.set_community_peer_review(int, admission_round, boolean) from public, anon;
grant execute on function public.set_community_peer_review(int, admission_round, boolean) to authenticated;

-- 2. 위원: 한 지원자에 대한 다른 위원 등급·메모 (상호 검토가 열려 있고, 본인이 이미 제출한 경우만)
create or replace function public.get_community_peer_review(p_applicant_id uuid)
returns jsonb
language plpgsql
volatile -- 열람 기록(audit_logs)을 남기므로 stable 이 아님
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  v_app record;
  v_is_admin boolean;
  v_items jsonb;
begin
  if caller is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;

  select year, round into v_app from public.applicants where id = p_applicant_id;
  if v_app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select exists (select 1 from public.users where id = caller and active and roles && array['superadmin','admin']::app_role[])
    into v_is_admin;

  if not v_is_admin and not exists (
    select 1 from public.users u
    where u.id = caller and u.active and 'evaluator' = any(u.roles) and 'community' = any(u.assigned_areas)
  ) then
    raise exception '공동체 생활 적합성 위원만 볼 수 있습니다.' using errcode = '42501';
  end if;

  if not public._community_peer_review_open(v_app.year, v_app.round) then
    return jsonb_build_object('open', false);
  end if;

  if not v_is_admin and not exists (
    select 1 from public.scores_community s
    where s.applicant_id = p_applicant_id and s.evaluator_uid = caller and s.submission_state = 'submitted'
  ) then
    return jsonb_build_object('open', true, 'eligible', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'evaluatorName', u.display_name,
           'mine', s.evaluator_uid = caller,
           'grade', (s.inputs ->> 'grade')::int,
           'score', s.server_computed -> 'score',
           'memo', s.inputs ->> 'evidenceMemo',
           'submittedAt', s.submitted_at
         ) order by s.submitted_at), '[]'::jsonb)
    into v_items
  from public.scores_community s
  join public.users u on u.id = s.evaluator_uid
  where s.applicant_id = p_applicant_id and s.submission_state = 'submitted';

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values (v_app.year, v_app.round, 'user', caller::text, 'community.peer_review.viewed',
          'scores_community', p_applicant_id::text, p_applicant_id::text, '{}'::jsonb);

  return jsonb_build_object('open', true, 'eligible', true, 'items', v_items);
end;
$$;

revoke all on function public.get_community_peer_review(uuid) from public, anon;
grant execute on function public.get_community_peer_review(uuid) to authenticated;

-- 3. 관리자: 상호 검토 현황판(등급이 갈린 지원자 먼저)
create or replace function public.get_community_review_board(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);

  select coalesce(jsonb_agg(x.item order by x.mismatch desc, x.exam_no nulls last, x.display_name), '[]'::jsonb)
    into v_items
  from (
    select r.exam_no, r.display_name,
           count(distinct (s.inputs ->> 'grade')) > 1 as mismatch,
           jsonb_build_object(
             'applicantId', r.applicant_id,
             'examNo', r.exam_no,
             'displayName', r.display_name,
             'mismatch', count(distinct (s.inputs ->> 'grade')) > 1,
             'gradeGap', max((s.inputs ->> 'grade')::int) - min((s.inputs ->> 'grade')::int),
             'submissions', jsonb_agg(jsonb_build_object(
               'evaluatorName', u.display_name,
               'grade', (s.inputs ->> 'grade')::int,
               'memo', s.inputs ->> 'evidenceMemo'
             ) order by s.submitted_at)
           ) as item
    from public.scores_community s
    join public.evaluation_roster r on r.applicant_id = s.applicant_id
    join public.users u on u.id = s.evaluator_uid
    where s.year = p_year and s.round = p_round and s.submission_state = 'submitted'
    group by r.applicant_id, r.exam_no, r.display_name
  ) x;

  return jsonb_build_object(
    'open', public._community_peer_review_open(p_year, p_round),
    'items', v_items
  );
end;
$$;

revoke all on function public.get_community_review_board(int, admission_round) from public, anon;
grant execute on function public.get_community_review_board(int, admission_round) to authenticated;
