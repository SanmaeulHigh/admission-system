-- 2026-07-13: 이원화(A안) 브릿지 2단계 — 로컬(교내) 서버 DB에 적용할 마이그레이션.
-- 00047(클라우드)의 admin_export_pre_application_for_bridge가 반환한 jsonb를
-- 그대로 받아 접수대장(applicants) 4테이블에 insert한다. 00042의
-- convert_pre_application_to_applicant와 같은 패턴이지만, 원본
-- pre_applications 행이 이 DB에는 없으므로(다른 DB에 있음) FK로 연결할 수
-- 없다 — source_pre_application_id(uuid FK) 대신 source_pre_application_no
-- (text, FK 없음)를 새로 둔다.
--
-- 이 마이그레이션은 클라우드 DB에도 똑같이 적용될 수 있다(같은 migrations
-- 폴더를 두 프로젝트에 그대로 적용하는 현재 운영 방식과 일치) — 클라우드
-- 쪽에서는 이 컬럼/함수가 그냥 쓰이지 않을 뿐, 문제는 없다.

alter table public.applicants
  add column if not exists source_pre_application_no text;

comment on column public.applicants.source_pre_application_no is
  '이원화(A안) 브릿지로 가져온 경우의 원본 사전작성 번호(다른 DB에 있어 FK
   불가 — 자연키만 보관). 같은 DB 안에서 전환된 경우(00042 경로)는 대신
   source_pre_application_id(uuid FK)를 쓴다. 두 값이 동시에 채워지는 경우는
   없다.';

-- 아래 함수 안의 exists 체크만으로는 동시 요청(관리자 두 명이 동시에 같은
-- 건을 이관 시도하는 등) 경쟁 조건을 완전히 막지 못한다 — DB 유니크
-- 인덱스로 최종 방어선을 둔다.
create unique index if not exists applicants_source_pre_application_no_uidx
  on public.applicants (source_pre_application_no)
  where source_pre_application_no is not null;

create or replace function public.admin_import_applicant_from_pre_application_bridge(
  p_payload jsonb,
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
  effective_method text;
  new_receipt_no text;
  new_applicant_id uuid;
  v_pre_application_no text;
  v_tracks text[];
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  v_pre_application_no := p_payload->>'preApplicationNo';
  if v_pre_application_no is null or length(trim(v_pre_application_no)) = 0 then
    raise exception 'payload에 preApplicationNo가 없습니다.';
  end if;

  if exists (
    select 1 from public.applicants where source_pre_application_no = v_pre_application_no
  ) then
    raise exception '이미 이 사전작성 번호(%)로 가져온 접수 건이 있습니다. 중복 이관을 막기 위해 중단합니다.', v_pre_application_no;
  end if;

  if not exists (
    select 1 from public.admission_rounds where year = p_year and round = p_round
  ) then
    raise exception '전형 차수(%, %)가 초기화되어 있지 않습니다.', p_year, p_round;
  end if;

  select array(select jsonb_array_elements_text(p_payload->'tracks')) into v_tracks;

  effective_method := coalesce(p_receipt_method, p_payload->>'receiptMethod');
  new_receipt_no := public._allocate_receipt_no(p_year, p_round, effective_method);

  insert into public.applicants
    (year, round, receipt_no, name, tracks, academic_status, school, grade_class_no,
     semester_choice, receipt_method, source_pre_application_no, created_by, updated_by)
  values
    (p_year, p_round, new_receipt_no, p_payload->>'name', v_tracks, p_payload->>'academicStatus',
     p_payload->>'school', p_payload->>'gradeClassNo', p_payload->>'semesterChoice', effective_method,
     v_pre_application_no, caller::text, caller::text)
  returning id into new_applicant_id;

  insert into public.applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone)
  values
    (new_applicant_id, p_payload->>'gender',
     nullif(p_payload->>'birthDate', '')::date,
     p_payload->>'applicantPhone', p_payload->>'email', p_payload->>'address',
     p_payload->>'guardianName', p_payload->>'guardianRelation', p_payload->>'guardianPhone');

  insert into public.applicants_admin (applicant_id) values (new_applicant_id);

  insert into public.evaluation_roster
    (applicant_id, year, round, receipt_no, display_name)
  values
    (new_applicant_id, p_year, p_round, new_receipt_no, p_payload->>'name');

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    (p_year, p_round, 'user', caller::text, 'applicant.registered.fromPreApplicationBridge', 'applicants',
     new_applicant_id::text, new_applicant_id::text);

  return json_build_object(
    'applicantId', new_applicant_id,
    'receiptNo', new_receipt_no,
    'preApplicationNo', v_pre_application_no
  );
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
      'admin_import_applicant_from_pre_application_bridge'
    )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

comment on function public.admin_import_applicant_from_pre_application_bridge(jsonb, int, admission_round, text) is
  '이원화(A안) 브릿지 2단계(로컬 DB) — 00047 admin_export_pre_application_for_bridge가
   반환한 jsonb를 받아 접수대장에 insert한다. 호출 성공 후 반드시 클라우드
   DB의 admin_mark_pre_application_bridged를 호출해 원본을 완료 처리할 것
   (안 하면 클라우드 목록에 "미이관"으로 계속 남아 있을 뿐 — 중복 이관은
   source_pre_application_no unique 체크로 이미 막혀 있어 데이터 오류는
   발생하지 않는다).';
