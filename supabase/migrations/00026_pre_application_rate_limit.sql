-- 새봄고 입학전형 시스템 — M8 Edge Function IP 레이트리밋 (Sprint 1B #3 일부)
-- `M8_아키텍처_결정_2026-07-10.md` 3.3 대응: "Edge Function 자체의 IP/
-- preApplicationId 기준 레이트리밋은 별도 pre_application_rate_limits
-- 테이블(윈도우 카운트 방식)로 구현".
--
-- Redis 없이 고정 윈도우 카운터로 구현 (기존 receipt_counters/
-- pre_application_counters와 동일한 단순 카운터 패턴). 완벽한 슬라이딩
--윈도우는 아니지만 봇 방지 목적엔 충분하고, 별도 인프라가 필요 없다.

create table public.pre_application_rate_limits (
  bucket_key text primary key,   -- 예: 'create:203.0.113.1' (동작종류:IP)
  window_start timestamptz not null,
  request_count int not null default 0
);

alter table public.pre_application_rate_limits enable row level security;
-- 정책 없음 = 클라이언트 전면 차단. RPC 내부에서만 접근.

create or replace function public._check_pre_application_rate_limit(
  p_bucket_key text,
  p_max_requests int,
  p_window_seconds int
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  row_rec record;
begin
  select * into row_rec
  from public.pre_application_rate_limits
  where bucket_key = p_bucket_key
  for update;

  if row_rec is null then
    insert into public.pre_application_rate_limits (bucket_key, window_start, request_count)
    values (p_bucket_key, now(), 1);
    return true;
  end if;

  if row_rec.window_start + make_interval(secs => p_window_seconds) <= now() then
    -- 윈도우 만료 → 새 윈도우로 리셋
    update public.pre_application_rate_limits
    set window_start = now(), request_count = 1
    where bucket_key = p_bucket_key;
    return true;
  end if;

  if row_rec.request_count >= p_max_requests then
    return false;
  end if;

  update public.pre_application_rate_limits
  set request_count = request_count + 1
  where bucket_key = p_bucket_key;
  return true;
end;
$$;

revoke execute on function public._check_pre_application_rate_limit(text, int, int)
  from public, anon, authenticated;

comment on function public._check_pre_application_rate_limit(text, int, int) is
  '고정 윈도우 카운터. true면 허용(카운트 증가됨), false면 이번 요청은 거부(카운트
   증가 없음). Edge Function이 IP별로 호출 — 예: 5분당 5회.';
