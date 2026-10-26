-- 새봄고 입학전형 시스템 — 입실 시각 고치기 · 수기 입실 등록 (2026-10-21)
--
-- 당일 행정 사유(접수처 대기, 바코드 불량, 수험표 미지참 등)로 스캔이 늦거나 못 찍은 경우를 위해.
--   · 고치기: 이미 있는 입실 기록의 시각만 바꾼다. 같은 날 안에서만. 처음 스캔 시각은 original_checked_in_at에 남긴다.
--   · 수기 등록: 미입실 대상자를 시각을 넣어 입실 처리한다(method = 'manual').
--   · 둘 다 사유 필수(2자 이상), 미래 시각 금지, 감사 기록(checkin.corrected / checkin.manual)에 이전·이후 시각과 사유를 남긴다.
--   · 응시 확인서를 이미 뽑았으면 certificateIssued = true를 돌려준다(화면에서 다시 인쇄 안내).

alter table public.deep_checkins add column if not exists original_checked_in_at timestamptz;
alter table public.deep_checkins add column if not exists corrected_at timestamptz;
alter table public.deep_checkins add column if not exists corrected_by uuid references public.users (id);
alter table public.deep_checkins add column if not exists correction_reason text;

alter table public.deep_checkins drop constraint if exists deep_checkins_method_check;
alter table public.deep_checkins
  add constraint deep_checkins_method_check check (method in ('exam_no', 'receipt_no', 'manual'));

comment on column public.deep_checkins.original_checked_in_at is '시각을 처음 고치기 전의 원래 스캔 시각(고친 적 없으면 null)';
comment on column public.deep_checkins.correction_reason is '마지막으로 고치거나 수기 등록한 사유';

-- 1. 입실 시각 고치기
create or replace function public.set_checkin_time(p_applicant_id uuid, p_checked_in_at timestamptz, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_row record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_issued boolean;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '고치는 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_checked_in_at is null or p_checked_in_at > now() + interval '1 minute' then
    raise exception '아직 오지 않은 시각으로는 고칠 수 없습니다.' using errcode = '22023';
  end if;

  select * into v_row from public.deep_checkins where applicant_id = p_applicant_id for update;
  if v_row.applicant_id is null then
    raise exception '입실 기록이 없습니다. 수기 입실 등록을 쓰세요.' using errcode = 'P0002';
  end if;

  if (p_checked_in_at at time zone 'Asia/Seoul')::date
     <> (coalesce(v_row.original_checked_in_at, v_row.checked_in_at) at time zone 'Asia/Seoul')::date then
    raise exception '입실 날짜는 바꿀 수 없습니다(같은 날 안에서 시각만 고칠 수 있습니다).' using errcode = '22023';
  end if;

  update public.deep_checkins
  set original_checked_in_at = coalesce(original_checked_in_at, checked_in_at),
      checked_in_at = p_checked_in_at,
      corrected_at = now(),
      corrected_by = caller,
      correction_reason = v_reason
  where applicant_id = p_applicant_id;

  select exists (
    select 1 from public.certificate_issuances
    where applicant_id = p_applicant_id and kind = 'deep_attendance'
  ) into v_issued;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_row.year, v_row.round, 'user', caller::text, 'checkin.corrected', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('from', v_row.checked_in_at, 'to', p_checked_in_at,
                        'original', coalesce(v_row.original_checked_in_at, v_row.checked_in_at),
                        'reason', v_reason, 'certificateIssued', v_issued));

  return jsonb_build_object('checkedInAt', p_checked_in_at, 'certificateIssued', v_issued);
end;
$$;

revoke all on function public.set_checkin_time(uuid, timestamptz, text) from public, anon;
grant execute on function public.set_checkin_time(uuid, timestamptz, text) to authenticated;

-- 2. 수기 입실 등록(대상자만)
create or replace function public.manual_checkin(p_applicant_id uuid, p_checked_in_at timestamptz, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '수기 등록 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_checked_in_at is null or p_checked_in_at > now() + interval '1 minute' then
    raise exception '아직 오지 않은 시각으로는 등록할 수 없습니다.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if not (v_app.evaluation_stage in ('documentPassed', 'deep') and v_app.application_status not in ('withdrawn', 'excluded')) then
    raise exception '2차 심층역량평가 대상이 아닙니다.' using errcode = '42501';
  end if;
  if exists (select 1 from public.deep_checkins where applicant_id = p_applicant_id) then
    raise exception '이미 입실 기록이 있습니다. 시각 고치기를 쓰세요.' using errcode = '23505';
  end if;

  insert into public.deep_checkins
    (applicant_id, year, round, checked_in_at, checked_in_by, method, corrected_at, corrected_by, correction_reason)
  values
    (p_applicant_id, v_app.year, v_app.round, p_checked_in_at, caller, 'manual', now(), caller, v_reason);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'checkin.manual', 'deep_checkins',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('checkedInAt', p_checked_in_at, 'reason', v_reason));

  return jsonb_build_object('checkedInAt', p_checked_in_at, 'certificateIssued', false);
end;
$$;

revoke all on function public.manual_checkin(uuid, timestamptz, text) from public, anon;
grant execute on function public.manual_checkin(uuid, timestamptz, text) to authenticated;

-- 3. 입실 현황에 고친 내역을 더한다
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
        'checkedInAt', c.checked_in_at,
        'method', c.method,
        'originalCheckedInAt', c.original_checked_in_at,
        'correctedAt', c.corrected_at,
        'correctionReason', c.correction_reason
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
