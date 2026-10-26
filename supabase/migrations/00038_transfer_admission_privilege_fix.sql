-- 전·편입생 선발 전형(00036/00037) 권한 하드닝 핫픽스
--
-- 회귀 테스트([0])에서 register_transfer_applicant에 anon execute가 여전히
-- 열려 있는 것이 실제로 확인됐다. 원인: 00036/00037이 `revoke ... from anon`
-- 만 실행했는데, 이 프로젝트의 public 스키마 기본 권한 하에서는 PUBLIC
-- 자체에 대한 EXECUTE 권한(또는 이번 배포 과정에서 반복된 db push/migration
-- repair 과정에서 남았을 수 있는 동일 이름의 과거 오버로드)이 별도로 남아
-- anon 롤에도 그대로 승계되고 있었다. `revoke ... from anon`만으로는 PUBLIC
-- 부여분 자체를 제거하지 못한다(Postgres GRANT 의미상 PUBLIC 부여는 개별
-- 롤에 대한 REVOKE로 지워지지 않음).
--
-- 조치:
--   1) 혹시 남아있을 수 있는 동일 함수명의 다른 시그니처(과거 배포 잔재)를
--      전부 동적으로 찾아 삭제한다 — 어떤 오버로드가 원인이든 깨끗하게 정리.
--   2) 7개 함수를 동일한 본문으로 재생성하면서 `revoke ... from public, anon`
--      을 명시하고, 실제 호출 주체(직원, authenticated)에게는
--      `grant ... to authenticated`를 명시적으로 다시 부여해 애매함을 없앤다.
--   3) _allocate_transfer_receipt_no(내부 전용)는 public/anon/authenticated
--      모두에서 회수한다(원래 의도와 동일, 명시적으로 재확인).

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'register_transfer_applicant',
        'update_transfer_application_status',
        'update_transfer_document_checklist',
        '_allocate_transfer_receipt_no',
        'submit_transfer_attendance_score',
        'submit_transfer_academic_score',
        'submit_transfer_essay_scores'
      )
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end;
$$;

-- ============================================================
-- 1. _allocate_transfer_receipt_no (내부 전용 — public/anon/authenticated 전면 차단)
-- ============================================================

create function public._allocate_transfer_receipt_no(
  p_round_label text,
  at_time timestamptz default now()
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dk text := to_char(at_time at time zone 'Asia/Seoul', 'YYMMDD');
  seq int;
begin
  insert into public.transfer_receipt_counters (round_label, date_key, last_seq)
  values (p_round_label, dk, 0)
  on conflict (round_label, date_key) do nothing;

  update public.transfer_receipt_counters
  set last_seq = last_seq + 1
  where round_label = p_round_label and date_key = dk
  returning last_seq into seq;

  if seq > 999 then
    raise exception '일일 전편입학 접수번호 한도(999)를 초과했습니다.';
  end if;

  return 'T' || dk || lpad(seq::text, 3, '0');
end;
$$;

revoke execute on function public._allocate_transfer_receipt_no(text, timestamptz) from public, anon, authenticated;

-- ============================================================
-- 2. register_transfer_applicant
-- ============================================================

create function public.register_transfer_applicant(
  p_name text,
  p_eligibility_category text,
  p_receipt_date date,
  p_round_label text default '2026-07',
  p_current_school text default null,
  p_current_grade text default null,
  p_tracking_no text default null,
  p_document_checklist jsonb default '{}'::jsonb,
  p_staff_memo text default null,
  p_gender text default null,
  p_birth_date date default null,
  p_applicant_phone text default null,
  p_email text default null,
  p_address text default null,
  p_guardian_name text default null,
  p_guardian_relation text default null,
  p_guardian_phone text default null,
  p_withdrawal_date date default null,
  p_alt_school_name text default null,
  p_staff_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  new_receipt_no text;
  new_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '성명은 필수입니다.';
  end if;
  if p_eligibility_category not in ('enrolled', 'withdrawn', 'altSchool') then
    raise exception '지원자격 구분이 올바르지 않습니다: %', p_eligibility_category;
  end if;
  if p_receipt_date is null then
    raise exception '접수일(등기 도착일)은 필수입니다.';
  end if;

  new_receipt_no := public._allocate_transfer_receipt_no(p_round_label);

  insert into public.transfer_applicants
    (round_label, receipt_no, name, eligibility_category, current_school, current_grade,
     receipt_date, tracking_no, document_checklist, staff_memo, created_by, updated_by)
  values
    (p_round_label, new_receipt_no, trim(p_name), p_eligibility_category, p_current_school,
     p_current_grade, p_receipt_date, p_tracking_no, coalesce(p_document_checklist, '{}'::jsonb),
     p_staff_memo, caller::text, caller::text)
  returning id into new_id;

  insert into public.transfer_applicants_private
    (applicant_id, gender, birth_date, applicant_phone, email, address,
     guardian_name, guardian_relation, guardian_phone, withdrawal_date, alt_school_name, staff_note)
  values
    (new_id, p_gender, p_birth_date, p_applicant_phone, p_email, p_address,
     p_guardian_name, p_guardian_relation, p_guardian_phone, p_withdrawal_date,
     p_alt_school_name, p_staff_note);

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.registered', 'transfer_applicants',
     new_id::text, new_id::text);

  return json_build_object(
    'applicantId', new_id,
    'receiptNo', new_receipt_no
  );
end;
$$;

revoke execute on function public.register_transfer_applicant(
  text, text, date, text, text, text, text, jsonb, text, text, date, text, text, text,
  text, text, text, date, text, text
) from public, anon;
grant execute on function public.register_transfer_applicant(
  text, text, date, text, text, text, text, jsonb, text, text, date, text, text, text,
  text, text, text, date, text, text
) to authenticated;

-- ============================================================
-- 3. update_transfer_application_status
-- ============================================================

create function public.update_transfer_application_status(
  p_applicant_id uuid,
  p_new_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_new_status not in ('received', 'incomplete', 'complete', 'withdrawn', 'excluded') then
    raise exception '알 수 없는 접수 상태입니다: %', p_new_status;
  end if;

  update public.transfer_applicants
  set application_status = p_new_status,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code)
  values
    ('user', caller::text, 'transferApplicant.status_changed:' || p_new_status, 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text, p_reason);
end;
$$;

revoke execute on function public.update_transfer_application_status(uuid, text, text) from public, anon;
grant execute on function public.update_transfer_application_status(uuid, text, text) to authenticated;

-- ============================================================
-- 4. update_transfer_document_checklist
-- ============================================================

create function public.update_transfer_document_checklist(
  p_applicant_id uuid,
  p_checklist jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if p_checklist is null or jsonb_typeof(p_checklist) <> 'object' then
    raise exception '체크리스트는 JSON 객체여야 합니다.';
  end if;

  update public.transfer_applicants
  set document_checklist = document_checklist || p_checklist,
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id;

  if not found then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferApplicant.checklist_updated', 'transfer_applicants',
     p_applicant_id::text, p_applicant_id::text);
end;
$$;

revoke execute on function public.update_transfer_document_checklist(uuid, jsonb) from public, anon;
grant execute on function public.update_transfer_document_checklist(uuid, jsonb) to authenticated;

-- ============================================================
-- 5. submit_transfer_attendance_score
-- ============================================================

create function public.submit_transfer_attendance_score(
  p_applicant_id uuid,
  p_record_type text,
  p_unexcused_absences int default null,
  p_other_event_count int default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  effective_days int;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'noRecord') then
    raise exception '알 수 없는 출결 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'ged' then
    computed_score := 180;
    effective_days := null;
  elsif p_record_type = 'noRecord' then
    computed_score := 0;
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_other_event_count is null or p_other_event_count < 0 then
      raise exception '미인정 결석 일수·조퇴/지각/결과 횟수는 0 이상의 정수여야 합니다.';
    end if;
    effective_days := p_unexcused_absences + floor(p_other_event_count::numeric / 3);
    computed_score := greatest(0, 200 - 10 * effective_days);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, attendance_record_type, attendance_inputs, attendance_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'otherEventCount', p_other_event_count,
       'effectiveAbsenceDays', effective_days
     ),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    attendance_record_type = excluded.attendance_record_type,
    attendance_inputs = excluded.attendance_inputs,
    attendance_score = excluded.attendance_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.attendance.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days);
end;
$$;

revoke execute on function public.submit_transfer_attendance_score(uuid, text, int, int) from public, anon;
grant execute on function public.submit_transfer_attendance_score(uuid, text, int, int) to authenticated;

-- ============================================================
-- 6. submit_transfer_academic_score
-- ============================================================

create function public.submit_transfer_academic_score(
  p_applicant_id uuid,
  p_record_type text,
  p_subjects jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'equivalentNoRecord') then
    raise exception '알 수 없는 학업성실도 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'equivalentNoRecord' then
    computed_score := 70;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_record_type = 'schoolRecord' then
        points := case subj ->> 'achievement'
          when 'A' then 20 when 'B' then 16 when 'C' then 8
          when 'D' then 4 when 'E' then 2
          else null
        end;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception '검정고시 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          points := case
            when raw <= 60 then 2
            when raw <= 70 then 4
            when raw <= 80 then 8
            when raw <= 90 then 16
            else 20
          end;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, 100);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, academic_record_type, academic_inputs, academic_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object('subjects', p_subjects),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    academic_record_type = excluded.academic_record_type,
    academic_inputs = excluded.academic_inputs,
    academic_score = excluded.academic_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.academic.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score);
end;
$$;

revoke execute on function public.submit_transfer_academic_score(uuid, text, jsonb) from public, anon;
grant execute on function public.submit_transfer_academic_score(uuid, text, jsonb) to authenticated;

-- ============================================================
-- 7. submit_transfer_essay_scores
-- ============================================================

create function public.submit_transfer_essay_scores(
  p_applicant_id uuid,
  p_self_intro_score numeric default null,
  p_guardian_opinion_score numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_self_intro_score is not null and (p_self_intro_score < 0 or p_self_intro_score > 500) then
    raise exception '자기소개서 점수는 0~500 사이여야 합니다.';
  end if;
  if p_guardian_opinion_score is not null and (p_guardian_opinion_score < 0 or p_guardian_opinion_score > 200) then
    raise exception '보호자소견서 점수는 0~200 사이여야 합니다.';
  end if;

  insert into public.transfer_document_scores
    (applicant_id, self_intro_score, guardian_opinion_score, updated_at, updated_by)
  values
    (p_applicant_id, p_self_intro_score, p_guardian_opinion_score, now(), caller::text)
  on conflict (applicant_id) do update set
    self_intro_score = coalesce(excluded.self_intro_score, public.transfer_document_scores.self_intro_score),
    guardian_opinion_score = coalesce(excluded.guardian_opinion_score, public.transfer_document_scores.guardian_opinion_score),
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.essays.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object(
    'selfIntroScore', p_self_intro_score,
    'guardianOpinionScore', p_guardian_opinion_score
  );
end;
$$;

revoke execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) from public, anon;
grant execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) to authenticated;
