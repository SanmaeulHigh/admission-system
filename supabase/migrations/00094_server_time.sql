-- 새봄고 입학전형 시스템 — 서버 시각 조회 (2026-10-19)
-- 머리글에 서버 시각을 보여 주기 위한 아주 작은 RPC. 기기 시계가 틀려도 접수 마감(17:00) 등을
-- 서버 기준으로 볼 수 있게 한다. 화면은 응답 왕복 시간의 절반을 보정해 기기 시계와의 차이를 계산한다.

create or replace function public.get_server_time()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

revoke all on function public.get_server_time() from public, anon;
grant execute on function public.get_server_time() to authenticated;
