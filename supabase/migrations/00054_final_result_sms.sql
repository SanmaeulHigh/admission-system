-- 새봄고 입학전형 시스템 — 최종 합격자 개별 통보 SMS 발송 (2026-07-14)
--
-- 배경: 최종 사정 확정(run_final_decision, mode='final') 이후, 지금까지는
-- FinalAnnouncePage에서 CSV만 뽑아 "학교 문자발송 도구에서 수동 진행"하는
-- 방식이었다(00017_m6c_pass_list.sql). 접수증 안내 문자에 이미 문자나라
-- 연동(_shared/smsProvider.ts)이 있으므로, 같은 연동을 재사용해 합격자에게
-- 시스템에서 바로 SMS를 보낼 수 있게 확장한다. 대상은 "합격자"로 한정한다
-- (get_final_pass_list의 purpose='sms'는 합격/불합격 전원을 내려주지만, 이
-- 기능은 불합격 통보까지 시스템이 대신하는 것은 범위 밖 — 요청대로 합격자만).
--
-- 안전장치:
--   * 반드시 finalized 상태인 최종(decision_type='final') run만 사용 —
--     시뮬레이션 결과로는 절대 발송 대상을 만들 수 없다(get_final_pass_list와
--     동일 원칙).
--   * 중복발송 방지: (run_id, applicant_id, target)별 발송 이력을 로그
--     테이블에 남기고, 이미 성공 발송된 대상은 화면에서 "발송완료"로 표시해
--     실수로 여러 번 누르다 중복 발송하는 걸 막는다(그래도 재발송 자체는
--     막지 않는다 — 학교 쪽에서 필요하면 다시 보낼 수 있어야 하므로).
--   * audit_logs.metadata에는 연락처 원문을 절대 넣지 않는다(00001 코멘트
--     원칙 그대로) — 로그 테이블에도 전화번호를 저장하지 않고 target/발송
--     결과만 남긴다(전화번호 자체는 이미 applicants_private에 있다).

-- ============================================================
-- 1. 발송 이력 테이블
-- ============================================================

create table public.final_result_sms_log (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.decision_runs(id),
  applicant_id uuid not null references public.applicants(id),
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid not null references public.users(id),
  created_at timestamptz not null default now()
);

create index final_result_sms_log_run_applicant_idx
  on public.final_result_sms_log (run_id, applicant_id);

comment on table public.final_result_sms_log is
  '최종 합격자 개별 통보 SMS 발송 이력. 전화번호 원문은 저장하지 않는다(applicants_private 참조). 직접 SELECT는 막고 get_final_result_sms_recipients RPC로만 조회.';

alter table public.final_result_sms_log enable row level security;
revoke all on public.final_result_sms_log from public, anon, authenticated;
-- RLS 정책을 만들지 않는다 = 클라이언트 직접 접근 전면 거부, SECURITY DEFINER
-- RPC를 통해서만 읽고 쓴다(scores_* 테이블과 동일한 원칙).

-- ============================================================
-- 2. 발송 대상 조회 — 합격자만, 발송 이력 포함
-- ============================================================

create or replace function public.get_final_result_sms_recipients(
  p_year int,
  p_round admission_round
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_run_id uuid;
  v_finalized_at timestamptz;
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select id, finalized_at into v_run_id, v_finalized_at
  from public.decision_runs
  where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 최종 사정 결과(final, finalized)가 없습니다.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.final_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome = 'passed';

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$$;

revoke all on function public.get_final_result_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_final_result_sms_recipients(int, admission_round) to authenticated;

-- ============================================================
-- 3. 발송 결과 기록 — Edge Function(send-final-result-sms)이 문자나라
--    호출 후 이 RPC로 결과를 남긴다(전화번호 자체는 남기지 않음)
-- ============================================================

create or replace function public.record_final_result_sms_sent(
  p_run_id uuid,
  p_applicant_id uuid,
  p_target text,
  p_sent boolean,
  p_provider_code text default null,
  p_provider_message text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_target not in ('applicant', 'guardian') then
    raise exception 'target은 applicant 또는 guardian이어야 합니다.' using errcode = '22023';
  end if;

  if not exists (select 1 from public.decision_runs where id = p_run_id and decision_type = 'final' and status = 'finalized') then
    raise exception '확정된 최종 사정(run)만 기록할 수 있습니다.' using errcode = '55000';
  end if;

  insert into public.final_result_sms_log
    (run_id, applicant_id, target, sent, provider_code, provider_message, sent_by)
  values
    (p_run_id, p_applicant_id, p_target, p_sent, p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    ('user', caller::text, 'decision.final.result_sms_sent', 'final_result_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('runId', p_run_id, 'target', p_target, 'sent', p_sent, 'providerCode', p_provider_code));
end;
$$;

revoke all on function public.record_final_result_sms_sent(uuid, uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_final_result_sms_sent(uuid, uuid, text, boolean, text, text) to authenticated;
