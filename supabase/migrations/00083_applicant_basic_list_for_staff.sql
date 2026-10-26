-- 새봄고 입학전형 시스템 — 지원자 기본 목록 열람(평가위원·정량평가·학교장) (2026-10-13)
--
-- 평가위원·정량평가 위원도 학교장처럼 지원자 목록 정도는 볼 수 있게 한다.
-- 다만 applicants 표를 통째로 열면(RLS는 행 단위라 열을 가릴 수 없음) 가산점·등기번호·
-- 접수 비고 같은 칸까지 보이므로, 필요한 열만 돌려주는 함수로 연다.
--   돌려주는 열: id, 수험번호, 접수번호, 성명, 지원 전형, 학적, 출신 중학교, 접수 상태
--   연락처·주소·보호자(applicants_private)는 여전히 볼 수 없다.
-- 00082에서 학교장에게 준 applicants 표 직접 조회 정책은 이 함수로 대체하고 지운다.

drop policy if exists applicants_select_principal on public.applicants;

create or replace function public.list_applicants_basic(p_year int, p_round admission_round)
returns table (
  id uuid,
  exam_no text,
  receipt_no text,
  name text,
  tracks text[],
  academic_status text,
  school text,
  application_status text
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  perform public._require_any_role(
    array['superadmin','admin','reception','evaluator','quant','principal']::app_role[]
  );
  return query
    select a.id, a.exam_no, a.receipt_no, a.name, a.tracks, a.academic_status, a.school,
           a.application_status::text
    from public.applicants a
    where a.year = p_year and a.round = p_round
      and a.application_status not in ('withdrawn', 'excluded')
    order by a.exam_no nulls last, a.receipt_no;
end;
$$;

revoke execute on function public.list_applicants_basic(int, admission_round) from anon;
grant execute on function public.list_applicants_basic(int, admission_round) to authenticated;
