-- 새봄고 입학전형 시스템 — QR·번호로 지원자 빠른 조회 (2026-10-21)
--
-- 어느 화면에서든 접수증·수험표·화일 표지의 QR(접수번호/수험번호)을 찍으면 지원자 카드를 띄운다.
--   · 조회 전용: 입실 처리 등 아무 기록도 바꾸지 않는다(입실은 입실 확인 화면에서만).
--   · 최고관리자·관리자·접수 담당만. 평가위원(블라인드 평가)에게는 열지 않는다.
--   · 접수 담당에게는 접수 정보·서류 현황만, 평가 진행 상황(1차·최종 결과, 입실)은 관리자에게만.
--   · 생년월일·성별·연락처는 돌려주지 않는다(필요하면 지원자 정보 창에서).
--   · 조회할 때마다 감사 기록(applicant.lookup)을 남긴다.

create or replace function public.lookup_applicant_by_code(p_year int, p_round admission_round, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_app record;
  v_method text;
  v_admin boolean;
  v_docs jsonb;
  v_checked timestamptz;
begin
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  v_admin := exists (
    select 1 from public.users u
    where u.id = caller and u.roles && array['superadmin', 'admin']::app_role[]
  );

  if v_code = '' then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  -- 지금 차수 먼저, 없으면 같은 학년도 다른 차수
  select a.* into v_app from public.applicants a
  where a.year = p_year and (upper(a.exam_no) = v_code or upper(a.receipt_no) = v_code)
  order by (a.round = p_round) desc
  limit 1;

  if v_app.id is null then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, metadata)
    values (p_year, p_round, 'user', caller::text, 'applicant.lookup.not_found', 'applicants',
            jsonb_build_object('code', v_code));
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  v_method := case when upper(v_app.exam_no) = v_code then 'exam_no' else 'receipt_no' end;

  select coalesce(jsonb_agg(distinct d.document_type), '[]'::jsonb) into v_docs
  from public.admission_documents d
  where d.applicant_id = v_app.id and d.active = true;

  if v_admin then
    select checked_in_at into v_checked from public.deep_checkins where applicant_id = v_app.id;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.lookup', 'applicants',
     v_app.id::text, v_app.id::text, jsonb_build_object('method', v_method));

  return jsonb_build_object(
    'found', true,
    'code', v_code,
    'method', v_method,
    'scope', case when v_admin then 'admin' else 'reception' end,
    'applicant', jsonb_build_object(
      'applicantId', v_app.id,
      'year', v_app.year,
      'round', v_app.round,
      'receiptNo', v_app.receipt_no,
      'examNo', v_app.exam_no,
      'name', v_app.name,
      'tracks', to_jsonb(v_app.tracks),
      'school', v_app.school,
      'academicStatus', v_app.academic_status,
      'receiptDate', v_app.receipt_date,
      'receiptMethod', v_app.receipt_method,
      'applicationStatus', v_app.application_status,
      'documents', v_docs,
      'applicationFormDocId', (
        select d.id from public.admission_documents d
        where d.applicant_id = v_app.id and d.document_type = 'applicationForm' and d.active = true
        order by d.uploaded_at desc limit 1),
      -- 아래는 관리자에게만
      'evaluationStage', case when v_admin then v_app.evaluation_stage end,
      'checkedInAt', v_checked
    )
  );
end;
$$;

revoke all on function public.lookup_applicant_by_code(int, admission_round, text) from public, anon;
grant execute on function public.lookup_applicant_by_code(int, admission_round, text) to authenticated;
