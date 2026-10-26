-- 새봄고 입학전형 시스템 — M7a 감사 로그 조회 (Sprint 7 시작)
-- 마스터 스펙 v1.2 M7 "감사 로그 조회... 평가 잠금 해제·재제출·위원 대체배정 이력"
-- 대응.
--
-- audit_logs 테이블과 그 기록 자체는 이미 존재한다(00001에서 테이블 생성,
-- M4~M6 전체 RPC가 이미 40여 종의 action으로 기록 중). 이 마이그레이션은
-- 신규 로깅을 추가하지 않는다 — 이미 쌓인 데이터를 관리자가 필터링해서
-- 조회할 수 있는 RPC 하나만 추가한다.

create or replace function public.get_audit_logs(
  p_year int default null,
  p_round admission_round default null,
  p_action_like text default null,
  p_actor_uid uuid default null,
  p_resource_type text default null,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select count(*) into v_total
  from public.audit_logs al
  where (p_year is null or al.year = p_year)
    and (p_round is null or al.round = p_round)
    and (p_action_like is null or al.action like p_action_like)
    and (p_actor_uid is null or al.actor_uid = p_actor_uid::text)
    and (p_resource_type is null or al.resource_type = p_resource_type)
    and (p_date_from is null or al.created_at >= p_date_from)
    and (p_date_to is null or al.created_at <= p_date_to);

  return jsonb_build_object(
    'totalCount', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', al.id,
        'createdAt', al.created_at,
        'year', al.year,
        'round', al.round,
        'actorType', al.actor_type,
        'actorUid', al.actor_uid,
        'actorName', u.display_name,
        'action', al.action,
        'resourceType', al.resource_type,
        'resourceId', al.resource_id,
        'applicantId', al.applicant_id,
        'area', al.area,
        'reasonCode', al.reason_code,
        'metadata', al.metadata
      ) order by al.created_at desc)
      from (
        select *
        from public.audit_logs al
        where (p_year is null or al.year = p_year)
          and (p_round is null or al.round = p_round)
          and (p_action_like is null or al.action like p_action_like)
          and (p_actor_uid is null or al.actor_uid = p_actor_uid::text)
          and (p_resource_type is null or al.resource_type = p_resource_type)
          and (p_date_from is null or al.created_at >= p_date_from)
          and (p_date_to is null or al.created_at <= p_date_to)
        order by al.created_at desc
        limit v_limit offset v_offset
      ) al
      left join public.users u on u.id::text = al.actor_uid
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_audit_logs(int, admission_round, text, uuid, text, timestamptz, timestamptz, int, int) from public, anon;
grant execute on function public.get_audit_logs(int, admission_round, text, uuid, text, timestamptz, timestamptz, int, int) to authenticated;

-- ============================================================
-- 조회 성능을 위한 인덱스 (audit_logs는 00001부터 계속 쌓여왔고 인덱스가 없었다)
-- ============================================================

create index if not exists idx_audit_logs_year_round_created
  on public.audit_logs (year, round, created_at desc);

create index if not exists idx_audit_logs_action
  on public.audit_logs (action);

create index if not exists idx_audit_logs_actor_uid
  on public.audit_logs (actor_uid);
