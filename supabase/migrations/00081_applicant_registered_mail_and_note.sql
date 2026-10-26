-- 새봄고 입학전형 시스템 — 우편 접수 등기번호·접수 비고 (2026-10-12)
--
-- 예전 엑셀 접수대장에서는 우편 접수 건의 등기번호를 비고 칸에 적어 두었다.
-- 분실·도착 시점 문의에 대비해 시스템에도 남긴다.
--   registered_mail_no : 우편(등기) 접수 시 등기번호
--   reception_note     : 접수대장 비고(자유 기재)
--
-- register_applicant / update_applicant는 인자가 22개라 손대지 않고, 두 값만
-- 고치는 RPC를 따로 둔다(접수·수정 양식이 저장 직후 이어서 호출).

alter table public.applicants
  add column if not exists registered_mail_no text,
  add column if not exists reception_note text;

create or replace function public.set_applicant_reception_extra(
  p_applicant_id uuid,
  p_registered_mail_no text default null,
  p_reception_note text default null
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

  update public.applicants
  set registered_mail_no = nullif(trim(coalesce(p_registered_mail_no, '')), ''),
      reception_note = nullif(trim(coalesce(p_reception_note, '')), ''),
      updated_at = now(),
      updated_by = caller::text
  where id = p_applicant_id
    and (registered_mail_no is distinct from nullif(trim(coalesce(p_registered_mail_no, '')), '')
      or reception_note is distinct from nullif(trim(coalesce(p_reception_note, '')), ''));

  -- 바뀐 게 있을 때만 기록
  if found then
    insert into public.audit_logs
      (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
    values
      ('user', caller::text, 'applicant.reception_extra_updated', 'applicants',
       p_applicant_id::text, p_applicant_id::text);
  elsif not exists (select 1 from public.applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
end;
$$;

revoke execute on function public.set_applicant_reception_extra(uuid, text, text) from anon;
