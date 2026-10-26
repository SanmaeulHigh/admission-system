-- 사용자(선생님) 권한 관리 화면 지원 — 로그인은 했지만 아직 public.users에
-- 없는(= 승인 대기) 계정 목록 조회 RPC.
--
-- 배경: 00001에서 upsert_user_access/set_user_active_status RPC는 이미
-- 만들어뒀지만 이걸 쓰는 화면이 없었다(2026-07-11 사용자 지적). public.users는
-- users_select_superadmin 정책으로 superadmin이 이미 전체 조회 가능하지만,
-- "구글 로그인은 했는데 아직 승인 안 된" 계정은 auth.users에만 있고
-- public.users에는 행이 없어 PostgREST로 직접 조회가 안 된다(auth 스키마는
-- 노출되지 않음). 이 RPC가 그 간극을 메운다 — auth.users를 SECURITY DEFINER로
-- 조회하되 이메일/가입시각 등 최소 정보만 반환한다(비밀번호 해시 등 민감
-- 컬럼은 절대 select하지 않음).

create or replace function public.list_pending_signins()
returns table (id uuid, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_superadmin();

  return query
    select au.id, au.email::text, au.created_at
    from auth.users au
    left join public.users u on u.id = au.id
    where u.id is null
    order by au.created_at desc;
end;
$$;

revoke execute on function public.list_pending_signins() from anon, authenticated;
comment on function public.list_pending_signins() is
  '구글 로그인은 완료했으나 아직 upsert_user_access로 승인되지 않은 계정 목록(superadmin 전용). auth.users에서 id/email/created_at만 최소 반환.';
