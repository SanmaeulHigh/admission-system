-- 새봄고 입학전형 시스템 — M8 사전작성 관리자 대시보드 + 접수대장 전환 (Task #36)
--
-- 배경: 00023 설계 당시부터 예정돼 있던 기능(00023 헤더 주석 6번:
-- "convertPreApplicationToApplicant는 단일 트랜잭션")인데 지금까지 이걸 호출할
-- 어떤 RPC도, 관리자가 사전작성 현황을 볼 화면도 없었다 — 실사용 피드백
-- ("사전작성 현황을 관리자 화면에서 전혀 볼 수가 없네 ㅠㅠ") 반영.
--
-- pre_applications 4테이블은 RLS 정책이 하나도 없다(00023) — 즉 클라이언트가
-- .from(...).select()로 직접 못 읽는다. 이 마이그레이션의 모든 RPC는
-- SECURITY DEFINER + _require_any_role(['superadmin','admin','reception'])로만
-- 접근을 허용한다(00003 register_applicant와 동일한 역할 조합 — 우편/방문
-- 서류를 실제로 받는 쪽이 reception이므로).
--
-- status 상태기계(00023에 이미 정의돼 있었지만 지금까지 'completed'→
-- 'bundleGenerated' 외에는 아무것도 전이시키지 않았음):
--   completed/bundleGenerated → (도착 확인) → arrived
--   arrived → (검수 시작) → reviewing
--   reviewing ⇄ supplementRequired (체크리스트 검수 중 보완 필요 시)
--   (converted·expired 전이는 이번 마이그레이션의 convert 함수/기존 만료
--    cron이 각각 담당 — 그 외 상태에서는 언제든 관리자가 직접 전환 가능:
--    실무상 절차를 엄격히 강제하면 오히려 방문접수 등 예외 케이스에서
--    직원을 막는 부작용이 크다고 판단해 "이미 전환됨/만료됨"만 막는다.)

-- ============================================================
-- 1. 감사 이벤트 기록 helper 재사용 헬퍼(파라미터 기본값만 다르게) —
--    이미 00025의 _record_pre_application_event를 그대로 쓴다. 새로 만들지 않음.
-- ============================================================

-- ============================================================
-- 2. admin_list_pre_applications — 사전작성 현황 목록
-- ============================================================

create or replace function public.admin_list_pre_applications(
  p_status_filter text[] default null
)
returns table (
  id uuid,
  pre_application_no text,
  year int,
  round admission_round,
  name text,
  applicant_phone text,
  guardian_phone text,
  status text,
  tracks text[],
  academic_status text,
  receipt_method text,
  school text,
  created_at timestamptz,
  expires_at timestamptz,
  shipping jsonb,
  arrival jsonb,
  document_review jsonb,
  conversion jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  return query
    select
      pa.id, pa.pre_application_no, pa.year, pa.round,
      pp.name, pp.applicant_phone, pp.guardian_phone,
      pa.status, pa.tracks, pa.academic_status, pa.receipt_method, pa.school,
      pa.created_at, pa.expires_at,
      pa.shipping, pa.arrival, pa.document_review, pa.conversion
    from public.pre_applications pa
    join public.pre_applications_private pp on pp.pre_application_id = pa.id
    where p_status_filter is null or pa.status = any(p_status_filter)
    order by pa.created_at desc;
end;
$$;

-- ============================================================
-- 3. admin_get_pre_application_detail — 관리자용 상세(개인정보 포함) + 최근 이벤트
-- ============================================================

create or replace function public.admin_get_pre_application_detail(
  p_pre_application_no text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  app_row record;
  priv_row record;
  events_json json;
begin
  perform public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select * into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  select coalesce(json_agg(e order by e.created_at desc), '[]'::json) into events_json
  from (
    select event_type, actor_type, created_at, metadata
    from public.pre_application_events
    where pre_application_id = app_row.id
    order by created_at desc
    limit 20
  ) e;

  return json_build_object(
    'preApplicationNo', app_row.pre_application_no,
    'year', app_row.year,
    'round', app_row.round,
    'status', app_row.status,
    'tracks', app_row.tracks,
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
    'postalCode', priv_row.postal_code,
    'guardianName', priv_row.guardian_name,
    'guardianRelation', priv_row.guardian_relation,
    'guardianPhone', priv_row.guardian_phone,
    'shipping', app_row.shipping,
    'arrival', app_row.arrival,
    'documentReview', app_row.document_review,
    'conversion', app_row.conversion,
    'createdAt', app_row.created_at,
    'expiresAt', app_row.expires_at,
    'events', events_json
  );
end;
$$;

-- ============================================================
-- 4. mark_pre_application_arrived — 서류 도착 확인
-- ============================================================

create or replace function public.mark_pre_application_arrived(
  p_pre_application_no text,
  p_method text default 'M'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('completed', 'bundleGenerated') then
    raise exception '이미 도착 확인되었거나(또는 전환/만료되어) 이 상태에서는 도착 확인을 할 수 없습니다(현재 상태: %).', app_row.status;
  end if;

  update public.pre_applications
  set status = 'arrived',
      arrival = jsonb_build_object('method', p_method, 'confirmedAt', now(), 'confirmedBy', caller::text)
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.arrived', 'admin', caller,
    jsonb_build_object('method', p_method));
end;
$$;

-- ============================================================
-- 5. mark_pre_application_reviewing — 서류 검수 시작
-- ============================================================

create or replace function public.mark_pre_application_reviewing(
  p_pre_application_no text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('arrived', 'supplementRequired') then
    raise exception '도착 확인 후에만 검수를 시작할 수 있습니다(현재 상태: %).', app_row.status;
  end if;

  update public.pre_applications
  set status = 'reviewing'
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.reviewing', 'admin', caller);
end;
$$;

-- ============================================================
-- 6. update_pre_application_document_review — 체크리스트/메모 갱신
--    (+ 보완 필요 여부에 따라 상태를 reviewing ⇄ supplementRequired로)
-- ============================================================

create or replace function public.update_pre_application_document_review(
  p_pre_application_no text,
  p_items jsonb default '[]'::jsonb,
  p_admin_memo text default null,
  p_supplement_required boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  new_status text;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  select id, status into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no
  for update;

  if app_row is null then
    raise exception '사전작성 건을 찾을 수 없습니다(%).', p_pre_application_no;
  end if;
  if app_row.status not in ('reviewing', 'supplementRequired') then
    raise exception '검수 중 상태에서만 체크리스트를 갱신할 수 있습니다(현재 상태: %).', app_row.status;
  end if;

  new_status := case when p_supplement_required then 'supplementRequired' else 'reviewing' end;

  update public.pre_applications
  set status = new_status,
      document_review = jsonb_build_object(
        'items', p_items,
        'adminMemo', p_admin_memo,
        'reviewedAt', now(),
        'reviewedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.admin.documentReviewUpdated', 'admin', caller,
    jsonb_build_object('supplementRequired', p_supplement_required));
end;
$$;

-- ============================================================
-- 7. convert_pre_application_to_applicant — 접수대장(applicants) 전환
--    00003 register_applicant와 동일한 4테이블 insert 패턴 + receipt_no 채번
--    재사용. source_pre_application_id로 FK 연결(00023에서 미리 걸어둔 목적).
-- ============================================================

create or replace function public.convert_pre_application_to_applicant(
  p_pre_application_no text,
  p_year int,
  p_round admission_round,
  p_receipt_method text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  priv_row record;
  effective_method text;
  new_receipt_no text;
  new_applicant_id uuid;
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
    raise exception '이미 접수대장으로 전환된 건입니다(%).', p_pre_application_no;
  end if;
  if app_row.status = 'expired' then
    raise exception '접수기간이 만료되어 전환할 수 없습니다(%).', p_pre_application_no;
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select * into priv_row
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  if priv_row is null then
    raise exception '사전작성 개인정보 행을 찾을 수 없습니다(데이터 정합성 이상, %).', p_pre_application_no;
  end if;

  effective_method := coalesce(p_receipt_method, app_row.receipt_method);
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, effective_method);

  insert into public.applicants
    (year, round, receipt_no, name, tracks, academic_status, school, grade_class_no,
     semester_choice, receipt_method, source_pre_application_id, created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, priv_row.name, app_row.tracks, app_row.academic_status,
     app_row.school, app_row.grade_class_no, app_row.semester_choice, effective_method,
     app_row.id, caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone)
  values
    (new_applicant_id, priv_row.gender, priv_row.birth_date, priv_row.applicant_phone,
     priv_row.email, priv_row.address, priv_row.guardian_name, priv_row.guardian_relation,
     priv_row.guardian_phone);

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, priv_row.name);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered.fromPreApplication', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  update public.pre_applications
  set status = 'converted',
      conversion = jsonb_build_object(
        'applicantId', new_applicant_id,
        'receiptNo', new_receipt_no,
        'convertedAt', now(),
        'convertedBy', caller::text
      )
  where id = app_row.id;

  perform public._record_pre_application_event(
    app_row.id, p_pre_application_no, 'preApplication.converted', 'admin', caller,
    jsonb_build_object('applicantId', new_applicant_id, 'receiptNo', new_receipt_no));

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

-- ============================================================
-- 8. 권한 하드닝 — 이번 세션에서 두 번 겪은 "revoke만으로는 anon execute가
--    안 막히는" 문제(00038/00040 참고) 재발을 막기 위해, 처음부터 기존
--    오버로드를 전부 drop한 뒤 명시적으로 public/anon/authenticated를 revoke하고
--    authenticated에만 다시 grant한다(내부 _require_any_role이 최종 게이트).
-- ============================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'admin_list_pre_applications',
      'admin_get_pre_application_detail',
      'mark_pre_application_arrived',
      'mark_pre_application_reviewing',
      'update_pre_application_document_review',
      'convert_pre_application_to_applicant'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_list_pre_applications(text[]) is
  '사전작성 현황 목록(관리자 대시보드). superadmin/admin/reception만 — 내부 _require_any_role로 검증. anon 완전 차단.';
comment on function public.admin_get_pre_application_detail(text) is
  '사전작성 건 상세(개인정보 포함) + 최근 이벤트 20건. superadmin/admin/reception만.';
comment on function public.convert_pre_application_to_applicant(text, int, admission_round, text) is
  '사전작성 건을 접수대장(applicants)으로 전환하는 단일 트랜잭션(00023 설계 의도).
   receipt_no는 00003의 _allocate_receipt_no를 그대로 재사용해 M1 수기접수와
   동일한 채번 규칙을 따른다. 전환 후 pre_applications.status=converted, 원본
   건과 신규 applicants 행이 source_pre_application_id로 연결된다.';
