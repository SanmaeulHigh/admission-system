-- 새봄고 입학전형 시스템 — '학교장' 권한 (2026-10-12)
--
-- 교장선생님은 평가 점수는 보지 않되, 지원자 서류는 보고 싶어 하신다.
-- 기존 권한으로는 맞는 게 없다:
--   viewer(열람 전용) → 서류는 못 보고 사정 결과·최종 집계 점수가 보임
--   evaluator         → 채점자로 잡힘, admin → 전부 보임
-- 그래서 principal(학교장) 권한을 새로 둔다.
--   * 지원자 기본 정보(applicants: 이름·전형·출신교·번호) 조회 가능
--   * 연락처·주소(applicants_private)는 조회 불가 — 정책을 주지 않는다
--   * 서류: 관리자 전용(adminOnly)을 뺀 모든 서류 열람(열람 기록은 기존처럼 남는다)
--     위원과 마찬가지로 users.viewable_document_types로 종류를 좁힐 수 있다
--   * 점수·사정 테이블에는 아무 정책도 주지 않으므로 볼 수 없다
--
-- 주의: enum 값 추가는 그 값을 쓰는 문장과 같은 트랜잭션에 있으면 안 된다.
-- psql로 이 파일을 그대로 흘려 넣으면(문장마다 자동 커밋) 문제없다.
-- psql -1 / --single-transaction 으로 돌리지 말 것.

alter type public.app_role add value if not exists 'principal';

-- 지원자 기본 정보 조회
drop policy if exists applicants_select_principal on public.applicants;
create policy applicants_select_principal
  on public.applicants for select
  using (public.is_active_user() and public.has_role('principal'));

-- 서류 열람 규칙(00076)에 학교장 추가
create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator') or public.has_role('principal')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;
