-- 새봄고 입학전형 시스템 — 지원 전형을 고친 뒤 접수번호 다시 매기기 (2026-10-25)
--
-- 접수번호 가운데 글자는 전형코드(G 일반 / I 일반+인천학생추천 / U 일반+사회통합)다.
-- 접수 때 전형 체크를 빠뜨려 지원자 정보에서 전형을 고치면(update_applicant), 번호의 전형코드와 실제 전형이 어긋난다.
-- 이 RPC는 지금 전형에 맞는 코드로, 같은 접수일·그 전형의 다음 순번을 새로 매긴다.
--   · 예) 261023G001 (인천추천 체크 누락) → 전형 고침 → 261023I004
--   · 접수일은 그대로. 예전 번호는 빈 번호로 남고 다시 쓰지 않는다.
--   · 수험번호 부여 전만, 최고관리자·관리자만, 사유 필수, 감사 기록(applicant.receipt_no_renumbered).

create or replace function public.renumber_receipt_for_tracks(p_applicant_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_code text;
  v_new_no text;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);

  if char_length(v_reason) < 2 then
    raise exception '접수번호를 다시 매기는 사유를 적어 주세요.' using errcode = '22023';
  end if;

  select * into v_app from public.applicants where id = p_applicant_id for update;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_app.exam_no is not null then
    raise exception '수험번호가 이미 부여되어 접수번호를 바꿀 수 없습니다.' using errcode = '55000';
  end if;
  if v_app.receipt_no !~ '^\d{6}[GIUMV]\d{3}$' then
    raise exception '이 접수번호(%)는 다시 매길 수 없는 형식입니다.', v_app.receipt_no using errcode = '22023';
  end if;

  v_code := case
    when 'incheon' = any(v_app.tracks) then 'I'
    when 'social'  = any(v_app.tracks) then 'U'
    else 'G'
  end;
  if substr(v_app.receipt_no, 7, 1) = v_code then
    raise exception '접수번호가 이미 지금 전형(%)과 맞습니다. 먼저 지원자 정보에서 전형을 고치세요.', v_code using errcode = '22023';
  end if;

  -- 같은 접수일(한국 시간) 기준으로 새 전형의 다음 순번
  v_new_no := public._allocate_receipt_no(v_app.year, v_app.round, v_code, v_app.receipt_date);

  update public.applicants
  set receipt_no = v_new_no, updated_at = now(), updated_by = caller::text
  where id = p_applicant_id;

  update public.evaluation_roster
  set receipt_no = v_new_no, updated_at = now()
  where applicant_id = p_applicant_id;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, metadata)
  values
    (v_app.year, v_app.round, 'user', caller::text, 'applicant.receipt_no_renumbered', 'applicants',
     p_applicant_id::text, p_applicant_id::text,
     jsonb_build_object('oldReceiptNo', v_app.receipt_no, 'newReceiptNo', v_new_no,
                        'tracks', to_jsonb(v_app.tracks), 'reason', v_reason));

  return jsonb_build_object('receiptNo', v_new_no, 'oldReceiptNo', v_app.receipt_no);
end;
$$;

revoke all on function public.renumber_receipt_for_tracks(uuid, text) from public, anon;
grant execute on function public.renumber_receipt_for_tracks(uuid, text) to authenticated;
