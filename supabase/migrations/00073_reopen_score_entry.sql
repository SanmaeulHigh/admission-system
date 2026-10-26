-- 새봄고 입학전형 시스템 — 채점 재개방 한 곳으로 (2026-09-28)
--
-- 문제: 재개방 RPC는 영역별로 흩어져 있고(reopen_score / reopen_interview_score /
-- reopen_writing_score), 채점 문서 id를 알아야 해서 화면에서 부를 곳이 없었다
-- ("재개방 메뉴가 숨겨져 있다"). 화면에서는 "지원자 + 위원 + 영역"만 알면
-- 재개방할 수 있도록 하나로 묶는다.
--
-- · 서류평가 5개 영역·모둠활동: 기존 reopen_score 호출 + 사유를 감사 기록에 남김
--   (reopen_score는 사유 인자가 없고 연도·지원자도 기록하지 않아 여기서 보완한다).
-- · 학생/학부모 면접·글쓰기: 기존 reopen_interview_score / reopen_writing_score 호출
--   (원래대로 최고관리자만 가능, 사유 5자 이상).
-- · 제출확정 상태가 아니면 재개방하지 않는다.

create or replace function public.reopen_score_entry(
  p_area text,
  p_applicant_id uuid,
  p_evaluator_uid uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_id uuid;
  v_state text;
  v_year int;
  v_round admission_round;
  v_table text;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception '재개방 사유를 5자 이상 입력하세요.' using errcode = '23514';
  end if;

  if p_area in ('interview_student', 'interview_parent') then
    select id, year, round,
           case when p_area = 'interview_student' then student_submission_state else parent_submission_state end
      into v_id, v_year, v_round, v_state
    from public.scores_interview
    where applicant_id = p_applicant_id and evaluator_uid = p_evaluator_uid;
    if v_id is null then
      raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
    end if;
    if v_state <> 'submitted' then
      raise exception '제출확정된 채점만 재개방할 수 있습니다(현재: %).', v_state using errcode = '55000';
    end if;
    perform public.reopen_interview_score(
      v_id, case when p_area = 'interview_student' then 'student' else 'parent' end, btrim(p_reason));
    return jsonb_build_object('reopened', true, 'scoreId', v_id);
  end if;

  if p_area = 'writing' then
    select id, submission_state into v_id, v_state
    from public.scores_writing
    where applicant_id = p_applicant_id and evaluator_uid = p_evaluator_uid;
    if v_id is null then
      raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
    end if;
    perform public.reopen_writing_score(v_id, btrim(p_reason));
    return jsonb_build_object('reopened', true, 'scoreId', v_id);
  end if;

  v_table := case p_area
    when 'attendance' then 'scores_attendance'
    when 'academic' then 'scores_academic'
    when 'community' then 'scores_community'
    when 'essay' then 'scores_essay'
    when 'opinion' then 'scores_opinion'
    when 'group' then 'scores_group'
    else null end;
  if v_table is null then
    raise exception '알 수 없는 영역입니다: %', p_area using errcode = '22023';
  end if;

  execute format(
    'select id, submission_state, year, round from public.%I where applicant_id = $1 and evaluator_uid = $2',
    v_table)
  into v_id, v_state, v_year, v_round
  using p_applicant_id, p_evaluator_uid;

  if v_id is null then
    raise exception '해당 채점을 찾을 수 없습니다.' using errcode = 'P0002';
  end if;
  if v_state <> 'submitted' then
    raise exception '제출확정된 채점만 재개방할 수 있습니다(현재: %).', v_state using errcode = '55000';
  end if;

  perform public.reopen_score(v_table, v_id);

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    (v_year, v_round, 'user', caller::text, 'score.reopened_with_reason', v_table, v_id::text,
     p_applicant_id::text, p_area::evaluation_area, '재개방',
     jsonb_build_object('reason', btrim(p_reason), 'evaluatorUid', p_evaluator_uid));

  return jsonb_build_object('reopened', true, 'scoreId', v_id);
end;
$$;

revoke all on function public.reopen_score_entry(text, uuid, uuid, text) from public, anon;
grant execute on function public.reopen_score_entry(text, uuid, uuid, text) to authenticated;
