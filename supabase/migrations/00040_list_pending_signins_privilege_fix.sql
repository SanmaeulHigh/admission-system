-- list_pending_signins(00039) 권한 하드닝 핫픽스
--
-- 회귀 테스트([0])에서 anon execute가 여전히 열려 있는 것이 확인됐다 —
-- 00036/00037에서 이미 한 번 겪은 것과 동일한 원인이다(00038 참고):
-- `revoke ... from anon, authenticated`만으로는 이 프로젝트의 PUBLIC 기본
-- 부여분(또는 반복된 배포 과정에서 남았을 수 있는 동일 이름의 과거
-- 오버로드)이 제거되지 않는다. 이번엔 authenticated 쪽도 완전히 막아야
-- 하는 함수라 `from public, anon, authenticated`로 명시한다 — 이 RPC는
-- superadmin만 호출해야 하고 내부에서 _require_superadmin()으로도
-- 재검증하지만, PostgREST 레벨에서도 완전히 막아 이중 방어한다.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'list_pending_signins'
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end;
$$;

create function public.list_pending_signins()
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

revoke execute on function public.list_pending_signins() from public, anon, authenticated;
-- 주의: authenticated에게도 execute를 주지 않는다 — PostgREST RPC 호출
-- 자체는 "로그인된 계정이면 누구나 함수 존재는 호출 시도 가능"하지만,
-- 실제 데이터 접근은 함수 내부 _require_superadmin()이 막는다(기존
-- upsert_user_access/set_user_active_status와 동일한 이중 방어 패턴).
-- 다만 이 프로젝트의 다른 superadmin 전용 RPC(upsert_user_access 등)는
-- "revoke ... from anon"만 하고 authenticated에는 execute를 남겨
-- _require_superadmin() 내부 검증에만 의존한다 — list_pending_signins도
-- 그 패턴을 따르려면 authenticated는 남겨야 정상 동작한다(관리 화면이
-- superadmin 계정으로 이 RPC를 호출하는 것 자체가 authenticated 롤로
-- 이루어지기 때문). 따라서 아래에서 authenticated에게는 다시 execute를
-- 부여한다 — 최종 방어선은 함수 내부 _require_superadmin()이다.
grant execute on function public.list_pending_signins() to authenticated;

comment on function public.list_pending_signins() is
  '구글 로그인은 완료했으나 아직 upsert_user_access로 승인되지 않은 계정 목록(superadmin 전용, 내부 _require_superadmin()으로 검증). auth.users에서 id/email/created_at만 최소 반환. anon은 완전 차단.';
