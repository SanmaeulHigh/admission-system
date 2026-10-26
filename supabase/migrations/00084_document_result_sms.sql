-- 새봄고 입학전형 시스템 — 1차(서류평가) 결과 개별 통보 SMS (2026-10-13)
--
-- 요강: "1차 결과 및 2차 대상자 발표 — 개별 통보(SMS)·홈페이지".
-- 최종 결과 문자(00054·00079)와 같은 방식으로, 확정된 1차 사정 결과대로
-- 합격·불합격 안내 문자를 시스템에서 보낸다.
--
-- 안전장치(최종 결과 문자와 동일):
--   * 확정(finalized)된 1차(decision_type='document') 사정 결과만 대상
--   * 합격·불합격 문구는 Edge Function(send-document-result-sms)이 확정 결과를
--     직접 다시 읽어 고른다 — 화면이 판정을 잘못 넘겨도 문구가 뒤바뀌지 않는다
--   * (run, 지원자, 대상)별 발송 이력을 남겨 화면에 "발송완료" 표시, 중복 발송 방지
--   * 이력·감사 로그에 전화번호 원문을 남기지 않는다

create table if not exists public.document_result_sms_log (
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

create index if not exists document_result_sms_log_run_applicant_idx
  on public.document_result_sms_log (run_id, applicant_id);

comment on table public.document_result_sms_log is
  '1차(서류평가) 결과 개별 통보 SMS 발송 이력. 전화번호 원문은 저장하지 않는다. 직접 SELECT는 막고 RPC로만 조회.';

alter table public.document_result_sms_log enable row level security;
revoke all on public.document_result_sms_log from public, anon, authenticated;

-- 발송 대상: 확정된 1차 사정의 합격·불합격자(합격자 먼저, 수험번호 순)
create or replace function public.get_document_result_sms_recipients(
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
  where year = p_year and round = p_round and decision_type = 'document' and status = 'finalized'
  order by finalized_at desc
  limit 1;

  if v_run_id is null then
    raise exception '확정된 1차 사정 결과가 없습니다. 1차 사정을 먼저 확정하세요.' using errcode = '55000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'receiptNo', a.receipt_no,
    'examNo', a.exam_no,
    'name', a.name,
    'outcome', dr.outcome,
    'applicantPhone', ap.applicant_phone,
    'guardianName', ap.guardian_name,
    'guardianPhone', ap.guardian_phone,
    'applicantSent', exists (
      select 1 from public.document_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'applicant' and l.sent = true
    ),
    'guardianSent', exists (
      select 1 from public.document_result_sms_log l
      where l.run_id = v_run_id and l.applicant_id = a.id and l.target = 'guardian' and l.sent = true
    )
  ) order by (dr.outcome <> 'passed'), a.exam_no, a.receipt_no), '[]'::jsonb)
  into v_items
  from public.decision_results dr
  join public.applicants a on a.id = dr.applicant_id
  left join public.applicants_private ap on ap.applicant_id = a.id
  where dr.run_id = v_run_id and dr.outcome in ('passed', 'failed');

  return jsonb_build_object('runId', v_run_id, 'finalizedAt', v_finalized_at, 'items', v_items);
end;
$$;

revoke all on function public.get_document_result_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_document_result_sms_recipients(int, admission_round) to authenticated;

-- 발송 결과 기록(Edge Function이 사용자 JWT로 호출)
create or replace function public.record_document_result_sms_sent(
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

  if not exists (
    select 1 from public.decision_runs
    where id = p_run_id and decision_type = 'document' and status = 'finalized'
  ) then
    raise exception '확정된 1차 사정(run)만 기록할 수 있습니다.' using errcode = '55000';
  end if;

  insert into public.document_result_sms_log
    (run_id, applicant_id, target, sent, provider_code, provider_message, sent_by)
  values
    (p_run_id, p_applicant_id, p_target, p_sent, p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    ('user', caller::text, 'decision.document.result_sms_sent', 'document_result_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('runId', p_run_id, 'target', p_target, 'sent', p_sent, 'providerCode', p_provider_code));
end;
$$;

revoke all on function public.record_document_result_sms_sent(uuid, uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_document_result_sms_sent(uuid, uuid, text, boolean, text, text) to authenticated;
