-- 새봄고 입학전형 시스템 — 실시간 채점 현황(최고관리자) (2026-09-28)
--
-- 결정(2026-09-28, 담당 교사): 최고관리자가 채점 도중에도 위원별 채점 여부와 점수를
-- 이름까지 그대로 보고, 위원 간 편차를 확인할 수 있게 한다.
--
-- 원래 설계(00007)는 "관리자 화면은 진행률·경보만, 개별 점수는 사유를 남기고 열람"
-- 이었다. 이 결정으로 그 원칙을 최고관리자에 한해 완화한다. 대신
--   · 최고관리자(superadmin)만 볼 수 있다(일반 관리자 admin은 기존대로).
--   · 조회 기록을 audit_logs에 'scores.live_monitor_viewed'로 남긴다(같은 영역은 10분에 1번).
--   · 읽기 전용이다. 점수 수정은 기존 절차(재개방·대리 입력)로만 한다.
--
-- 영역: 서류평가 5개 + 모둠활동·학생면접·학부모면접·글쓰기.
-- 임시 저장(draft) 중인 채점은 "작성 중"으로만 보이고 점수는 보여주지 않는다.

create or replace function public.get_live_scoring_monitor(
  p_year int,
  p_round admission_round,
  p_area text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_rev uuid;
  v_params jsonb;
  v_scores jsonb;
  v_required int;
  v_gap numeric;
  v_is_document boolean;
  v_expected jsonb := '[]'::jsonb;
begin
  caller := public._require_superadmin();

  if p_area not in ('attendance','academic','community','essay','opinion',
                    'group','interview_student','interview_parent','writing') then
    raise exception '알 수 없는 영역입니다: %', p_area using errcode = '22023';
  end if;
  v_is_document := p_area in ('attendance','academic','community','essay','opinion');

  select config_revision_id into v_rev
  from public.admission_rounds where year = p_year and round = p_round;

  -- 필요 제출 건수·편차 경보 기준(설정에 있으면)
  begin
    if v_is_document then
      v_required := public._document_required_submissions(p_year, p_round, p_area);
      select (scoring_params -> p_area ->> 'alertGap')::numeric into v_gap
      from public.config_revisions where id = v_rev;
    elsif p_area = 'group' then
      v_params := public._m5b_group_params(v_rev);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    elsif p_area = 'writing' then
      v_params := public._m5d_writing_params(v_rev);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    else
      v_params := public._m5c_interview_params(v_rev, case when p_area = 'interview_student' then 'student' else 'parent' end);
      v_required := (v_params ->> 'requiredSubmissions')::int;
      v_gap := (v_params ->> 'alertGap')::numeric;
    end if;
  exception when others then
    -- 설정이 아직 없으면 기준 없이 보여준다.
    v_required := null;
    v_gap := null;
  end;

  -- 채점(제출·임시·재개방). 임시·재개방은 점수를 숨긴다.
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_scores from (
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs) as x
    from public.scores_attendance s
    where p_area = 'attendance' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs)
    from public.scores_academic s
    where p_area = 'academic' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'score')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.inputs)
    from public.scores_community s
    where p_area = 'community' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'total')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.items)
    from public.scores_essay s
    where p_area = 'essay' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state, 'score', (s.server_computed ->> 'total')::numeric,
      'submittedAt', s.submitted_at, 'inputs', s.items)
    from public.scores_opinion s
    where p_area = 'opinion' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state,
      'score', case when s.submission_state = 'submitted' then (s.server_computed ->> 'total')::numeric end,
      'submittedAt', s.submitted_at,
      'inputs', case when s.submission_state = 'submitted' then s.items end)
    from public.scores_group s
    where p_area = 'group' and s.year = p_year and s.round = p_round
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.student_submission_state,
      'score', case when s.student_submission_state = 'submitted' then (s.student_server_computed ->> 'total')::numeric end,
      'submittedAt', s.student_submitted_at,
      'inputs', case when s.student_submission_state = 'submitted' then s.student_items end)
    from public.scores_interview s
    where p_area = 'interview_student' and s.year = p_year and s.round = p_round
      and (s.student_revision > 0 or s.student_submission_state <> 'draft')
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.parent_submission_state,
      'score', case when s.parent_submission_state = 'submitted' then (s.parent_server_computed ->> 'total')::numeric end,
      'submittedAt', s.parent_submitted_at,
      'inputs', case when s.parent_submission_state = 'submitted' then s.parent_items end)
    from public.scores_interview s
    where p_area = 'interview_parent' and s.year = p_year and s.round = p_round
      and (s.parent_revision > 0 or s.parent_submission_state <> 'draft')
    union all
    select jsonb_build_object('applicantId', s.applicant_id, 'evaluatorUid', s.evaluator_uid,
      'state', s.submission_state,
      'score', case when s.submission_state = 'submitted' then (s.server_computed ->> 'total')::numeric end,
      'submittedAt', s.submitted_at,
      'inputs', case when s.submission_state = 'submitted' then s.responses end)
    from public.scores_writing s
    where p_area = 'writing' and s.year = p_year and s.round = p_round
  ) t;

  -- 서류평가는 영역을 배정받은 사람이 "채점해야 할 위원"이다(평가 준비 화면과 같은 기준).
  if v_is_document then
    select coalesce(jsonb_agg(u.id order by u.display_name), '[]'::jsonb) into v_expected
    from public.users u
    where u.active = true and p_area::evaluation_area = any(u.assigned_areas);
  end if;

  -- 자동 새로고침(30초)마다 기록이 쌓이지 않게, 같은 사람·같은 영역은 10분에 한 번만 남긴다.
  if not exists (
    select 1 from public.audit_logs l
    where l.action = 'scores.live_monitor_viewed' and l.actor_uid = caller::text
      and l.year = p_year and l.round = p_round and l.resource_id = p_area
      and l.created_at > now() - interval '10 minutes'
  ) then
    insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
    values (p_year, p_round, 'user', caller::text, 'scores.live_monitor_viewed', 'scores', p_area,
            jsonb_build_object('area', p_area));
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'requiredSubmissions', v_required,
    'alertGap', v_gap,
    'expectedEvaluatorUids', v_expected,
    'evaluators', coalesce((
      select jsonb_agg(jsonb_build_object('uid', u.id, 'name', u.display_name) order by u.display_name)
      from public.users u
      where u.id in (
        select (e ->> 'evaluatorUid')::uuid from jsonb_array_elements(v_scores) e
        union
        select (e #>> '{}')::uuid from jsonb_array_elements(v_expected) e
      )
    ), '[]'::jsonb),
    'roster', coalesce((
      select jsonb_agg(jsonb_build_object(
        'applicantId', a.id,
        'examNo', coalesce(er.exam_no, a.exam_no),
        'receiptNo', a.receipt_no,
        'name', a.name
      ) order by coalesce(er.exam_no, a.exam_no, a.receipt_no))
      from public.applicants a
      left join public.evaluation_roster er on er.applicant_id = a.id
      where a.year = p_year and a.round = p_round
        and (
          (v_is_document and er.evaluation_active = true)
          or (not v_is_document and er.evaluation_stage = 'documentPassed')
          or a.id in (select (e ->> 'applicantId')::uuid from jsonb_array_elements(v_scores) e)
        )
    ), '[]'::jsonb),
    'scores', v_scores,
    'fetchedAt', now()
  );
end;
$$;

revoke all on function public.get_live_scoring_monitor(int, admission_round, text) from public, anon;
grant execute on function public.get_live_scoring_monitor(int, admission_round, text) to authenticated;
