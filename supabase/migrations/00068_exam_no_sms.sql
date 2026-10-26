-- 새봄고 입학전형 시스템 — 수험번호 안내 문자 (2026-09-28)
--
-- 근거: 원서 접수 업무 진행 지침(2025.10.21.) 4-(2)
--   "원서 접수 마감 이후 3일 이내 개인별 연락처로 부여된 수험번호 안내(SMS 등)"
--   문구는 붙임 3(수험번호 부여 SMS 예제)을 따른다(Edge Function send-exam-no-sms).
--
-- 구조는 합격자 통보 문자(00054)와 같다.
--   · 발송 대상 조회 RPC → 화면에서 대상 확인
--   · Edge Function이 실제 발송 → 결과를 이 로그에 기록
--   · 로그에는 연락처를 저장하지 않는다(누구에게·언제·성공 여부만).
--   · 재발송은 막지 않는다(수신 실패·번호 변경 대응). 화면에서 "발송완료"로만 표시.

create table if not exists public.exam_no_sms_log (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  exam_no text not null,
  target text not null check (target in ('applicant', 'guardian')),
  sent boolean not null,
  provider_code text,
  provider_message text,
  sent_by uuid references public.users (id),
  created_at timestamptz not null default now()
);

create index if not exists exam_no_sms_log_applicant_idx
  on public.exam_no_sms_log (year, round, applicant_id);

alter table public.exam_no_sms_log enable row level security;
revoke all on public.exam_no_sms_log from anon, authenticated;

-- ============================================================
-- 1. 발송 대상 — 수험번호가 부여된 지원자(철회·제외 제외)
-- ============================================================

create or replace function public.get_exam_no_sms_recipients(
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
  v_items jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select coalesce(jsonb_agg(jsonb_build_object(
    'applicantId', a.id,
    'examNo', a.exam_no,
    'receiptNo', a.receipt_no,
    'name', a.name,
    'applicantPhone', p.applicant_phone,
    'guardianPhone', p.guardian_phone,
    'applicantSent', exists (
      select 1 from public.exam_no_sms_log l
      where l.applicant_id = a.id and l.target = 'applicant' and l.sent
        and l.exam_no = a.exam_no),
    'guardianSent', exists (
      select 1 from public.exam_no_sms_log l
      where l.applicant_id = a.id and l.target = 'guardian' and l.sent
        and l.exam_no = a.exam_no)
  ) order by a.exam_no), '[]'::jsonb)
  into v_items
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  where a.year = p_year and a.round = p_round
    and a.exam_no is not null
    and a.application_status not in ('withdrawn', 'excluded');

  -- "발송완료"는 지금 번호 기준으로만 본다(exam_no 일치 조건). 재부여로 번호가
  -- 바뀌면 옛 번호로 보낸 문자는 완료로 치지 않아 다시 보내도록 유도한다.
  return jsonb_build_object('items', v_items);
end;
$$;

revoke all on function public.get_exam_no_sms_recipients(int, admission_round) from public, anon;
grant execute on function public.get_exam_no_sms_recipients(int, admission_round) to authenticated;

-- ============================================================
-- 2. 발송 결과 기록 (Edge Function이 사용자 JWT로 호출)
-- ============================================================

create or replace function public.record_exam_no_sms_sent(
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
  v_app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_target not in ('applicant', 'guardian') then
    raise exception '대상은 applicant 또는 guardian이어야 합니다.' using errcode = '22023';
  end if;

  select id, year, round, exam_no into v_app from public.applicants where id = p_applicant_id;
  if v_app is null or v_app.exam_no is null then
    raise exception '수험번호가 부여된 지원자가 아닙니다.' using errcode = 'P0002';
  end if;

  insert into public.exam_no_sms_log
    (year, round, applicant_id, exam_no, target, sent, provider_code, provider_message, sent_by)
  values
    (v_app.year, v_app.round, p_applicant_id, v_app.exam_no, p_target, p_sent,
     p_provider_code, p_provider_message, caller);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'exam_no.sms_sent', 'exam_no_sms_log',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('target', p_target, 'sent', p_sent, 'examNo', v_app.exam_no));
end;
$$;

revoke all on function public.record_exam_no_sms_sent(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.record_exam_no_sms_sent(uuid, text, boolean, text, text) to authenticated;
