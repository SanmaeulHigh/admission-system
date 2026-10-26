-- 새봄고 입학전형 시스템 — 접수일 바꾸기(우편 도착일 소급) + 접수번호 다시 매기기 (2026-10-25)
--
-- 접수번호 = YYMMDD + 전형코드 + 순번(접수일·전형별). 접수일을 바꾸면 번호도 그 날짜 기준으로 다시 매긴다.
--   · 쓰는 경우: 등기가 전날 도착했는데 다음 날 입력한 경우 등 — 도착일로 소급.
--   · 새 번호는 바꾼 날짜·같은 전형의 '다음 순번'(그날 마지막 번호 뒤). 예전 번호는 비어 있는 번호로 남고 다시 쓰지 않는다.
--   · 접수 시각(시:분)은 그대로 두고 날짜만 바꾼다.
--   · 수험번호가 부여되기 전에만. 미래 날짜·같은 날짜는 막는다. 사유 필수.
--   · 최고관리자·관리자만. 감사 기록(applicant.receipt_date_changed)에 이전·새 번호/날짜와 사유를 남긴다.
--   · 00050에서 접수일·접수번호를 '불변'으로 두었던 것을 이 RPC 한 곳으로만 바꿀 수 있게 연다.
-- 바꾼 뒤에는 접수증·화일 표지를 다시 출력해야 한다(번호가 바뀜).

create or replace function public.change_receipt_date(p_applicant_id uuid, p_date date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old_date date;
  v_new_at timestamptz;
  v_track_code text;
  v_new_no text;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '접수일을 바꾸는 사유를 적어 주세요.' using errcode = '22023';
  end if;
  if p_date is null then
    raise exception '바꿀 날짜를 고르세요.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id for update;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_app.exam_no is not null then
    raise exception '수험번호가 이미 부여되어 접수일을 바꿀 수 없습니다.' using errcode = '55000';
  end if;
  if v_app.receipt_no like 'T%' then
    raise exception '전·편입 지원자는 이 기능을 쓰지 않습니다.' using errcode = '22023';
  end if;

  v_old_date := (v_app.receipt_date at time zone 'Asia/Seoul')::date;
  if p_date = v_old_date then
    raise exception '지금 접수일과 같은 날짜입니다.' using errcode = '22023';
  end if;
  if p_date > (now() at time zone 'Asia/Seoul')::date then
    raise exception '앞으로 올 날짜로는 바꿀 수 없습니다.' using errcode = '22023';
  end if;

  -- 시:분은 그대로, 날짜만 바꾼다(한국 시간 기준)
  v_new_at := (p_date + (v_app.receipt_date at time zone 'Asia/Seoul')::time) at time zone 'Asia/Seoul';

  v_track_code := case
    when 'incheon' = any(v_app.tracks) then 'I'
    when 'social'  = any(v_app.tracks) then 'U'
    else 'G'
  end;
  v_new_no := public._allocate_receipt_no(v_app.year, v_app.round, v_track_code, v_new_at);

  update public.applicants
  set receipt_no = v_new_no, receipt_date = v_new_at, updated_at = now(), updated_by = caller::text
  where id = p_applicant_id;

  update public.evaluation_roster
  set receipt_no = v_new_no, updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.receipt_date_changed', 'applicants',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('oldReceiptNo', v_app.receipt_no, 'newReceiptNo', v_new_no,
                        'oldReceiptDate', v_app.receipt_date, 'newReceiptDate', v_new_at,
                        'reason', v_reason));

  return jsonb_build_object('receiptNo', v_new_no, 'receiptDate', v_new_at, 'oldReceiptNo', v_app.receipt_no);
end;
$$;

revoke all on function public.change_receipt_date(uuid, date, text) from public, anon;
grant execute on function public.change_receipt_date(uuid, date, text) to authenticated;
