-- 새봄고 입학전형 시스템 — 지원자 삭제 (접수 실수·테스트 데이터 정리용)
-- 담당 교사 리허설 중 요청: "접수 대장에서 이미 접수된 지원자의 정보를 모두
-- 지울 수 있는 기능이 있어야 함".
--
-- applicants를 참조하는 모든 테이블(applicants_private/applicants_admin/
-- admission_documents/scores_*/evaluation_roster/deep_*_aggregates/
-- decision_results)이 이미 on delete cascade로 걸려있어 applicants 행 하나만
-- 지우면 관련 데이터가 전부 정리된다 — 새 cascade 설정 불필요.
--
-- audit_logs.applicant_id는 uuid FK가 아니라 text 컬럼이라(00001) cascade
-- 대상이 아니다 — 삭제 기록 자체는 지원자가 사라진 뒤에도 안전하게 남는다.
--
-- 최종 사정이 끝난(finalPassed/finalFailed) 지원자는 삭제를 막는다 — 이미
-- 공식 결과가 나온 사람은 삭제가 아니라 입학전형위원회 결정을 거친 정정
-- 절차로 처리해야 한다.

create or replace function public.delete_applicant(
  p_applicant_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception '삭제 사유를 5자 이상 입력해야 합니다.' using errcode = '55000';
  end if;

  select id, year, round, receipt_no, name, application_status, evaluation_stage
  into app
  from public.applicants where id = p_applicant_id;

  if app is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = '55000';
  end if;

  if app.evaluation_stage in ('finalPassed', 'finalFailed') then
    raise exception '최종 사정이 끝난 지원자는 삭제할 수 없습니다. 정정이 필요하면 입학전형위원회 결정을 거쳐 처리하세요.'
      using errcode = '55000';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, reason_code, metadata)
  values
    (app.year, app.round, 'user', caller::text, 'applicant.deleted', 'applicants', app.id::text, app.id::text,
     p_reason,
     jsonb_build_object('receiptNo', app.receipt_no, 'name', app.name,
       'applicationStatus', app.application_status, 'evaluationStage', app.evaluation_stage));

  delete from public.applicants where id = p_applicant_id;

  return jsonb_build_object('deleted', true, 'receiptNo', app.receipt_no, 'name', app.name);
end;
$$;

revoke all on function public.delete_applicant(uuid, text) from public, anon;
grant execute on function public.delete_applicant(uuid, text) to authenticated;
