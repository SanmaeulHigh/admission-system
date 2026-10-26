-- 새봄고 입학전형 시스템 — 2차 심층역량평가 입실 확인(바코드) (2026-09-28)
--
-- 현장 PC에 연결한 USB 바코드 리더로 수험표(수험번호) 또는 접수증(접수번호)을
-- 찍으면 사진·수험번호·성명·접수번호·생년월일·성별·출신중학교를 띄워 본인 확인을
-- 하고, 입실 시각을 기록한다. 장소는 본관(노트북 Tailscale 접속, 2026-09-28 결정).
--
-- · 대상: 1차 합격(evaluation_stage = documentPassed/deep), 철회·제외 아님.
--   대상이 아니면 정보는 보여주되 입실 기록은 하지 않는다(현장에서 바로 알아보도록).
--   단, 1차 사정 전 리허설을 위해 p_allow_ineligible = true면 대상이 아니어도 기록한다.
-- · 생년월일·성별이 나가므로 최고관리자·관리자만 쓸 수 있고, 찍을 때마다 감사 기록을 남긴다.
-- · 잘못 찍었을 때를 위해 입실 취소가 있다.

create table if not exists public.deep_checkins (
  applicant_id uuid primary key references public.applicants (id) on delete cascade,
  year int not null,
  round admission_round not null,
  checked_in_at timestamptz not null default now(),
  checked_in_by uuid references public.users (id),
  scanned_code text,
  method text not null check (method in ('exam_no', 'receipt_no'))
);

create index if not exists deep_checkins_round_idx on public.deep_checkins (year, round);

alter table public.deep_checkins enable row level security;
revoke all on public.deep_checkins from anon, authenticated;

-- ============================================================
-- 1. 바코드 스캔 → 조회 + 입실 기록
-- ============================================================

create or replace function public.checkin_scan(
  p_year int,
  p_round admission_round,
  p_code text,
  p_allow_ineligible boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_app record;
  v_priv record;
  v_method text;
  v_eligible boolean;
  v_existing record;
  v_recorded boolean := false;
  v_checked_at timestamptz;
  v_photo_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if v_code = '' then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select a.* into v_app from public.applicants a
  where a.year = p_year and a.round = p_round and upper(a.exam_no) = v_code
  limit 1;
  if found then
    v_method := 'exam_no';
  else
    select a.* into v_app from public.applicants a
    where a.year = p_year and a.round = p_round and upper(a.receipt_no) = v_code
    limit 1;
    if found then
      v_method := 'receipt_no';
    end if;
  end if;

  if v_method is null then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, metadata)
    values (p_year, p_round, 'user', caller::text, 'checkin.not_found', 'deep_checkins',
            jsonb_build_object('code', v_code));
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select gender, birth_date into v_priv from public.applicants_private where applicant_id = v_app.id;

  select id into v_photo_id from public.admission_documents
  where applicant_id = v_app.id and document_type = 'photo' and active = true
  order by uploaded_at desc limit 1;

  v_eligible := v_app.evaluation_stage in ('documentPassed', 'deep')
    and v_app.application_status not in ('withdrawn', 'excluded');

  select * into v_existing from public.deep_checkins where applicant_id = v_app.id;

  if v_existing.applicant_id is null and (v_eligible or p_allow_ineligible) then
    insert into public.deep_checkins (applicant_id, year, round, checked_in_by, scanned_code, method)
    values (v_app.id, v_app.year, v_app.round, caller, v_code, v_method)
    returning checked_in_at into v_checked_at;
    v_recorded := true;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (p_year, p_round, 'user', caller::text,
     case when v_recorded then 'checkin.recorded' else 'checkin.scanned' end,
     'deep_checkins', v_app.id::text, v_app.id::text,
     jsonb_build_object('method', v_method, 'eligible', v_eligible,
                        'alreadyCheckedIn', v_existing.applicant_id is not null));

  return jsonb_build_object(
    'found', true,
    'code', v_code,
    'method', v_method,
    'applicant', jsonb_build_object(
      'applicantId', v_app.id,
      'examNo', v_app.exam_no,
      'receiptNo', v_app.receipt_no,
      'name', v_app.name,
      'birthDate', v_priv.birth_date,
      'gender', v_priv.gender,
      'school', v_app.school,
      'academicStatus', v_app.academic_status,
      'tracks', to_jsonb(v_app.tracks),
      'applicationStatus', v_app.application_status,
      'evaluationStage', v_app.evaluation_stage,
      'hasPhoto', v_photo_id is not null
    ),
    'eligible', v_eligible,
    'recorded', v_recorded,
    'checkedInAt', coalesce(v_checked_at, v_existing.checked_in_at),
    'alreadyCheckedIn', v_existing.applicant_id is not null
  );
end;
$$;

revoke all on function public.checkin_scan(int, admission_round, text, boolean) from public, anon;
grant execute on function public.checkin_scan(int, admission_round, text, boolean) to authenticated;

-- ============================================================
-- 2. 입실 현황(대상자 전원 + 입실 시각)
-- ============================================================

create or replace function public.get_checkin_status(
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
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id,
        'examNo', a.exam_no,
        'receiptNo', a.receipt_no,
        'name', a.name,
        'eligible', a.evaluation_stage in ('documentPassed', 'deep')
          and a.application_status not in ('withdrawn', 'excluded'),
        'checkedInAt', c.checked_in_at
      ) order by coalesce(a.exam_no, a.receipt_no))
      from public.applicants a
      left join public.deep_checkins c on c.applicant_id = a.id
      where a.year = p_year and a.round = p_round
        and (
          (a.evaluation_stage in ('documentPassed', 'deep') and a.application_status not in ('withdrawn', 'excluded'))
          or c.applicant_id is not null
        )
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_checkin_status(int, admission_round) from public, anon;
grant execute on function public.get_checkin_status(int, admission_round) to authenticated;

-- ============================================================
-- 3. 입실 취소(잘못 찍었을 때)
-- ============================================================

create or replace function public.cancel_checkin(p_applicant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  delete from public.deep_checkins where applicant_id = p_applicant_id returning * into v_row;
  if v_row.applicant_id is null then
    raise exception '입실 기록이 없습니다.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_row.year, v_row.round, 'user', caller::text, 'checkin.cancelled', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('checkedInAt', v_row.checked_in_at));
end;
$$;

revoke all on function public.cancel_checkin(uuid) from public, anon;
grant execute on function public.cancel_checkin(uuid) to authenticated;
