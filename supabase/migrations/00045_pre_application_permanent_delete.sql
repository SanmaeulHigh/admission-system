-- 새봄고 입학전형 시스템 — 사전작성 건 완전삭제(하드 delete) (Task #53)
--
-- 배경: 00043의 admin_cancel_pre_application은 의도적으로 소프트 삭제만
-- 지원했다("완전삭제 대신 취소 상태 유지" — 당시 사용자 확인). 이번에는
-- 사용자가 명시적으로 "개별 지원자 정보도 완전삭제하는 기능"을 요청함
-- (2026-07-12). 소프트 삭제(취소) 기능은 그대로 두고, 진짜 하드 delete를
-- 별도 함수로 추가한다 — 기존 취소 기능을 대체하지 않는다.
--
-- 권한: mark_*/admin_cancel_pre_application 등은 reception까지 허용하지만,
-- 이 함수는 PII를 영구히 파기하는 작업이라 superadmin/admin만 허용한다
-- (delete_applicant(00022)와 동일한 권한 수준 — reception 제외).
--
-- 접수대장 전환(converted) 건은 이 함수로 지울 수 없다(2026-07-12 사용자 확인:
-- "전환된 건은 삭제 금지하되, 정식 접수대장에서 지울 수 있으면 됨") — 이미
-- applicants 테이블에 실제 지원자 기록이 생성돼 있으므로, 그 기록을 지우고
-- 싶으면 00022의 delete_applicant를 정식 접수대장 화면에서 사용해야 한다
-- (delete_applicant는 pre_applications를 건드리지 않으므로 두 함수가 서로
-- 안전하게 독립적으로 동작한다).
--
-- 삭제 순서: pre_applications_private/pre_application_secrets는 00023에서
-- on delete cascade로 걸려있어 자동 삭제된다. pre_application_events는
-- on delete set null이라 삭제 후에도 pre_application_no 텍스트로 감사 이력이
-- 남는다 — 그래서 실제 delete 직전에 이벤트를 1건 기록해둔다(삭제 자체를
-- 추적할 마지막 흔적).

create or replace function public.admin_permanently_delete_pre_application(
  p_pre_application_no text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  priv_row record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;

  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환된 건은 완전삭제할 수 없습니다. 실제 지원자 기록을 지우려면 정식 접수대장(지원자 삭제) 기능을 사용하세요(%).', p_pre_application_no
      using errcode = '55000';
  end if;

  select name into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  -- delete 직전에 이벤트를 남긴다 — pre_application_events.pre_application_id는
  -- on delete set null이라 삭제 후에도 pre_application_no 텍스트로 이력이 남는다.
  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.permanentlyDeleted', 'admin', caller,
    jsonb_build_object('reason', p_reason));

  delete from public.pre_applications where id = app_row.id;
  -- pre_applications_private / pre_application_secrets는 on delete cascade로 함께 삭제.

  return jsonb_build_object(
    'deleted', true,
    'preApplicationNo', p_pre_application_no,
    'name', priv_row.name
  );
end;
$$;

revoke all on function public.admin_permanently_delete_pre_application(text, text) from public, anon, authenticated;
grant execute on function public.admin_permanently_delete_pre_application(text, text) to authenticated;

comment on function public.admin_permanently_delete_pre_application(text, text) is
  '사전작성 건 완전삭제(하드 delete) — 이름/연락처/주소 등 원문 개인정보까지
   pre_applications_private/pre_application_secrets가 cascade로 함께 삭제된다.
   superadmin/admin만(reception 제외 — PII 영구삭제이므로 소프트
   삭제(admin_cancel_pre_application, reception 포함 허용)보다 권한을 좁힌다).
   이미 접수대장으로 전환된 건은 삭제 금지 — 정식 접수대장에서는 기존
   delete_applicant로 처리한다(2026-07-12 사용자 확인).';
