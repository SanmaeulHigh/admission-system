-- 새봄고 입학전형 시스템 — 교외 인증 관문 고침 (2026-10-13)
--
-- 증상: 교외에서 인증번호를 맞혀도 다시 로그인 화면으로 돌아감.
-- 원인: Caddy forward_auth 가 관문(GET /rest/v1/rpc/mfa_gate)을 부를 때 원래 요청의 주소 뒤
--       조건(?select=*&id=eq.…)이 그대로 따라붙어, PostgREST 가 이를 함수 인자로 보고
--       "그런 인자를 받는 mfa_gate 가 없다"(404)로 거부했다. 그래서 조건이 붙은 조회는 모두 막혔다.
-- 고침: Caddy 는 관문을 ?gate=1 로만 부르고(원래 조건 대신), 함수는 gate 인자를 받아 무시한다.

drop function if exists public.mfa_gate();

create or replace function public.mfa_gate(gate text default null)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_external_request() then
    return true;
  end if;
  if auth.uid() is not null and public._mfa_verified() then
    return true;
  end if;
  -- PT403: PostgREST 가 HTTP 403 으로 돌려준다
  raise exception '교외에서 접속하셨습니다. 휴대폰 인증을 마친 뒤 이용할 수 있습니다.' using errcode = 'PT403';
end;
$$;
grant execute on function public.mfa_gate(text) to anon, authenticated;
