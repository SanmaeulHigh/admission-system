-- 2026-07-13: 로컬 서버 전환 이원화(A안) — 사전작성(M8)은 클라우드에 남기고,
-- 정식 접수 이후 데이터만 로컬로 이전한다(docs/로컬서버_전환_검토_2026-07.md 9절).
--
-- 지금까지의 convert_pre_application_to_applicant(00042)는 같은 DB 안에서
-- pre_applications -> applicants로 "한 트랜잭션"에 옮겼다. 이원화 이후에는
-- 두 DB가 물리적으로 분리되므로(클라우드=사전작성, 로컬=접수대장) 한
-- 트랜잭션으로 묶을 수 없다 — 대신 2단계로 나눈다:
--   1) (이 마이그레이션, 클라우드 DB에 적용) admin_export_pre_application_for_bridge
--      로 개인정보 포함 전체 데이터를 jsonb로 꺼낸다. 아직 상태를 바꾸지 않는다
--      — 로컬 쪽 insert가 실패할 수도 있으므로, 실제로 로컬에 저장된 뒤에만
--      완료 처리해야 한다(2번 함수).
--   2) 로컬 시스템에서 00048의 admin_import_applicant_from_pre_application_bridge로
--      실제 applicants 행을 만든 뒤, 성공하면 다시 이 클라우드 DB로 돌아와
--      admin_mark_pre_application_bridged를 호출해 완료 처리한다.
--
-- 인증/전송 방식: 관리자가 클라우드 대시보드 계정으로 이 함수를 호출한다
-- (기존 사전작성 대시보드와 동일한 로그인). 별도 공유 비밀키·Edge Function
-- 없이, 관리자가 로컬 시스템의 "사전작성 이관" 화면에서 클라우드 계정으로
-- 한 번 더 로그인해 이 RPC를 직접 호출하는 방식을 전제로 설계했다 — 새
-- Edge Function을 로컬에 추가하지 않아도 되고(설치절차서의 "Edge Function
-- 이전 불필요" 결론을 그대로 유지), 이 RPC를 호출한 실제 사람이 caller로
-- 남아 감사 추적이 더 명확하다.
--
-- 이 함수가 반환하는 jsonb는 00048의 admin_import_applicant_from_pre_application_bridge
-- 파라미터 p_payload와 1:1로 맞춰서 설계했다 — 필드명을 바꾸면 양쪽을 같이
-- 고쳐야 한다.

create or replace function public.admin_export_pre_application_for_bridge(
  p_pre_application_no text
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
  payload jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 접수대장으로 전환/이관된 건입니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'expired' then
    raise exception '접수기간이 만료되어 이관할 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'cancelled' then
    raise exception '취소된 건입니다(%).', p_pre_application_no;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  if priv_row is null then
    raise exception '사전작성 개인정보 행을 찾을 수 없습니다(데이터 정합성 이상, %).', p_pre_application_no;
  end if;

  payload := jsonb_build_object(
    'preApplicationNo', app_row.pre_application_no,
    'tracks', to_jsonb(app_row.tracks),
    'academicStatus', app_row.academic_status,
    'school', app_row.school,
    'gradeClassNo', app_row.grade_class_no,
    'semesterChoice', app_row.semester_choice,
    'receiptMethod', app_row.receipt_method,
    'name', priv_row.name,
    'gender', priv_row.gender,
    'birthDate', priv_row.birth_date,
    'applicantPhone', priv_row.applicant_phone,
    'email', priv_row.email,
    'address', priv_row.address,
    'guardianName', priv_row.guardian_name,
    'guardianRelation', priv_row.guardian_relation,
    'guardianPhone', priv_row.guardian_phone,
    'exportedAt', now(),
    'exportedBy', caller::text
  );

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.exportedForBridge', 'admin', caller,
    jsonb_build_object('exportedAt', now()));

  return payload;
end;
$$;

-- 로컬 쪽 insert가 성공적으로 끝난 뒤에만 호출한다. 실패했는데도 이 함수를
-- 호출하면 로컬에는 데이터가 없는데 클라우드만 "전환됨"으로 표시되는
-- 불일치가 생긴다 — 반드시 로컬 insert 성공을 확인한 뒤 호출할 것.
create or replace function public.admin_mark_pre_application_bridged(
  p_pre_application_no text,
  p_local_receipt_no text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'converted' then
    raise exception '이미 완료 처리된 건입니다(%).', p_pre_application_no;
  end if;

  update public.pre_applications
  set status = 'converted',
      conversion = jsonb_build_object(
        'bridgedToLocal', true,
        'localReceiptNo', p_local_receipt_no,
        'bridgedAt', now(),
        'bridgedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.bridgedToLocal', 'admin', caller,
    jsonb_build_object('localReceiptNo', p_local_receipt_no));

  return json_build_object('preApplicationNo', p_pre_application_no, 'localReceiptNo', p_local_receipt_no);
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'admin_export_pre_application_for_bridge',
      'admin_mark_pre_application_bridged'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_export_pre_application_for_bridge(text) is
  '이원화(A안) 브릿지 1단계 — 사전작성 데이터를 jsonb로 내보낸다(클라우드 DB용).
   상태는 아직 바꾸지 않는다. 로컬 시스템(00048)에서 실제 접수대장 insert가
   성공한 뒤 admin_mark_pre_application_bridged를 호출해 완료 처리한다.';
comment on function public.admin_mark_pre_application_bridged(text, text) is
  '이원화(A안) 브릿지 2단계 — 로컬 접수대장 insert 성공 확인 후 호출. status를
   converted로 바꾸고 conversion에 로컬 접수번호를 기록한다(applicantId는 다른
   DB에 있어 여기 저장하지 않는다).';
