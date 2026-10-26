-- 새봄고 입학전형 시스템 — 비활성화된 선생님(사용자) 계정 삭제
-- 2026-07-14 요청: "선생님들 중 비활성화된 계정에 대해 삭제하는 기능도 만들어달라"
--
-- 지금까지는 set_user_active_status(00001/00046)로 활성/비활성 전환만
-- 가능했고, 계정 자체를 지우는 수단이 없었다. 이 RPC는 "이미 비활성화된"
-- 계정만 완전히 삭제한다(활성 계정은 먼저 비활성화부터 해야 함 — 실수로
-- 로그인 중인 계정을 바로 지우는 사고 방지).
--
-- 삭제 범위: auth.users 행까지 지운다(로그인 자체를 막기 위함). public.users는
-- auth.users(id) on delete cascade라 자동으로 같이 삭제된다(00001).
--
-- 평가 기록 보호: scores_*/interview_team_members/writing_plan_members/
-- deep_group_primary_observers/deep_group_rotation_assignments의
-- evaluator_uid는 public.users(id)를 참조하되 on delete cascade가 아니다
-- (RESTRICT가 기본값, 00005/00006/00009/00010/00012/00013 참고) — 즉 평가
-- 기록이 남아있는 계정을 지우려 하면 FK 위반으로 막힌다. DB 에러 메시지 대신
-- 이 RPC가 먼저 확인해서 친절한 한국어 메시지로 안내한다.

create or replace function public.delete_deactivated_user(
  p_target_uid uuid,
  p_reason text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  target record;
  ref_count int;
begin
  caller := public._require_superadmin();

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  if p_target_uid = caller then
    raise exception '자기 자신의 계정은 이 기능으로 삭제할 수 없습니다.' using errcode = '55000';
  end if;

  select id, email, display_name, active into target
  from public.users where id = p_target_uid;

  if target is null then
    raise exception '사용자를 찾을 수 없습니다.' using errcode = '55000';
  end if;

  if target.active then
    raise exception '활성 상태인 계정입니다. 먼저 비활성화한 뒤 삭제할 수 있습니다.' using errcode = '55000';
  end if;

  select
    (select count(*) from public.scores_attendance where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_academic where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_essay where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_opinion where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_group where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_interview where evaluator_uid = p_target_uid) +
    (select count(*) from public.scores_writing where evaluator_uid = p_target_uid) +
    (select count(*) from public.deep_group_primary_observers where evaluator_uid = p_target_uid) +
    (select count(*) from public.deep_group_rotation_assignments where evaluator_uid = p_target_uid) +
    (select count(*) from public.interview_team_members where evaluator_uid = p_target_uid) +
    (select count(*) from public.writing_plan_members where evaluator_uid = p_target_uid)
  into ref_count;

  if ref_count > 0 then
    raise exception '이 계정은 평가 기록(%건)이 남아있어 삭제할 수 없습니다. 기록 보존이 필요하면 비활성화 상태로 유지하세요.', ref_count
      using errcode = '55000';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, reason_code, metadata)
  values
    ('user', caller::text, 'user.access.deleted', 'users', p_target_uid::text, p_reason,
     jsonb_build_object('email', target.email, 'displayName', target.display_name));

  delete from auth.users where id = p_target_uid; -- public.users는 cascade로 함께 삭제됨

  return json_build_object('deleted', true, 'email', target.email, 'displayName', target.display_name);
end;
$$;

revoke all on function public.delete_deactivated_user(uuid, text) from public, anon;
grant execute on function public.delete_deactivated_user(uuid, text) to authenticated;
