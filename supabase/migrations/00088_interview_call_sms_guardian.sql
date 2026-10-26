-- 새봄고 입학전형 시스템 — 면접 호출 문자를 보호자 번호로 (2026-10-14)
--
-- 배경: 2027 심층평가 당일 지원자 휴대전화는 사전교육 때 수거한다. 그래서 학생면접 호출(예고·호출)도
--       보호자 번호로 보낸다(Edge Function send-interview-call-sms 가 대상 결정). 보호자 번호가 없으면
--       지원자 번호로 보내고, 그 사실을 로그(fallback_reason)에 남긴다.
-- 바꾸는 것:
--   1) 연락처 조회에 면접 장소·조 이름을 더한다(보호자 문구 "○○로 와 주세요").
--   2) interview_call_sms_log.fallback_reason 열 추가.
--   3) record_interview_call_sms_sent 에 p_fallback_reason 인자(기본 null) 추가 — 예전 형태는 지우고 다시 만든다.

-- 1. 연락처 + 면접 장소
create or replace function public.get_interview_call_sms_recipient(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
  v_team record;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  select a.name,
         a.receipt_no,
         r.exam_no,
         p.applicant_phone,
         p.guardian_name,
         p.guardian_phone
  into v_row
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.evaluation_roster r on r.applicant_id = a.id
  where a.id = p_applicant_id;

  if v_row is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  select t.team_code, t.location
  into v_team
  from public.interview_schedules s
  join public.interview_teams t on t.id = s.team_id
  where s.year = p_year and s.round = p_round and s.applicant_id = p_applicant_id
  limit 1;

  return jsonb_build_object(
    'applicantId', p_applicant_id,
    'name', v_row.name,
    'receiptNo', v_row.receipt_no,
    'examNo', coalesce(v_row.exam_no, v_row.receipt_no),
    'applicantPhone', v_row.applicant_phone,
    'guardianName', v_row.guardian_name,
    'guardianPhone', v_row.guardian_phone,
    'teamCode', v_team.team_code,
    'location', v_team.location
  );
end;
$$;

revoke all on function public.get_interview_call_sms_recipient(int, admission_round, uuid) from public, anon;
grant execute on function public.get_interview_call_sms_recipient(int, admission_round, uuid) to authenticated;

-- 2. 로그 열
alter table public.interview_call_sms_log
  add column if not exists fallback_reason text;

comment on column public.interview_call_sms_log.fallback_reason is
  '원래 대상(보호자) 대신 다른 번호로 보낸 이유. 예: 보호자 번호 없음 → 지원자 번호로 발송.';

-- 3. 기록 함수(인자 하나 추가)
drop function if exists public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text);

create or replace function public.record_interview_call_sms_sent(
  p_year int,
  p_round admission_round,
  p_applicant_id uuid,
  p_section text,
  p_call_type text,
  p_target text,
  p_sent boolean,
  p_provider_code text default null,
  p_provider_message text default null,
  p_fallback_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_interview_call_permission(p_year, p_round, p_applicant_id);

  insert into public.interview_call_sms_log
    (year, round, applicant_id, section, call_type, target, sent,
     provider_code, provider_message, sent_by, fallback_reason)
  values
    (p_year, p_round, p_applicant_id, p_section, p_call_type, p_target, p_sent,
     p_provider_code, p_provider_message, caller, p_fallback_reason);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'interview.call.sms_sent',
     'interview_call_sms_log', p_applicant_id::text,
     jsonb_build_object('section', p_section, 'callType', p_call_type,
                        'target', p_target, 'sent', p_sent,
                        'fallbackReason', p_fallback_reason));
end;
$$;

revoke all on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text, text)
  from public, anon;
grant execute on function public.record_interview_call_sms_sent(int, admission_round, uuid, text, text, text, boolean, text, text, text)
  to authenticated;
