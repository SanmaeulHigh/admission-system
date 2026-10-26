begin;

-- 새봄고 입학전형 시스템 — M5e 심층역량평가 종이 백업/인쇄 패킷
-- 마스터 스펙 v1.2 섹션 1.3, M5e 대응.
--
-- 핵심 불변조건
--   1) 종이 백업 패킷은 superadmin/admin만 생성한다.
--   2) M4 final passed snapshot의 수험번호·성명만 사용하고 연락처/주소/사정점수/개별 평가점수는 포함하지 않는다.
--   3) 모둠·면접·글쓰기 계획의 finalized/source snapshot 상태를 서버가 ready로 판정한다.
--   4) 미확정 계획도 관리자 레이아웃 미리보기용 packet은 조회할 수 있으나, 운영용 print logging은 ready=true에서만 허용한다.
--   5) 평가 기준은 실제 채점 서버가 사용하는 config revision에서 읽어 종이표와 전자 채점 기준의 drift를 막는다.
--   6) packet 조회/운영용 인쇄 요청은 audit_logs에 원문 평가자료 없이 최소 메타데이터만 기록한다.

-- ============================================================
-- 1. 백업 준비상태 조회
-- ============================================================

create or replace function public.get_m5e_paper_backup_status(
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
  v_round public.admission_rounds%rowtype;
  v_group_plan public.deep_group_plans%rowtype;
  v_interview_plan public.interview_team_plans%rowtype;
  v_writing_plan public.writing_evaluation_plans%rowtype;
  v_group_validation jsonb;
  v_interview_validation jsonb;
  v_writing_validation jsonb;
  v_candidate_count int := 0;
  v_group_ready boolean := false;
  v_interview_ready boolean := false;
  v_writing_ready boolean := false;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_round.document_decision_run_id is not null then
    select count(*)::int into v_candidate_count
    from public.decision_results dr
    where dr.run_id = v_round.document_decision_run_id
      and dr.outcome = 'passed';
  end if;

  select * into v_group_plan
  from public.deep_group_plans
  where year = p_year and round = p_round;
  if found then
    v_group_validation := public.validate_m5a_group_plan(p_year, p_round);
    v_group_ready := v_group_plan.status = 'finalized'
      and v_group_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_group_validation ->> 'complete')::boolean, false);
  else
    v_group_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '모둠편성 계획이 없습니다.'))
    );
  end if;

  select * into v_interview_plan
  from public.interview_team_plans
  where year = p_year and round = p_round;
  if found then
    v_interview_validation := public.validate_m5c_interview_plan(p_year, p_round);
    v_interview_ready := v_interview_plan.status = 'finalized'
      and v_interview_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_interview_validation ->> 'complete')::boolean, false);
  else
    v_interview_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '면접조 계획이 없습니다.'))
    );
  end if;

  select * into v_writing_plan
  from public.writing_evaluation_plans
  where year = p_year and round = p_round;
  if found then
    v_writing_validation := public.validate_m5d_writing_plan(p_year, p_round);
    v_writing_ready := v_writing_plan.status = 'finalized'
      and v_writing_plan.document_source_run_id = v_round.document_decision_run_id
      and coalesce((v_writing_validation ->> 'complete')::boolean, false);
  else
    v_writing_validation := jsonb_build_object(
      'complete', false,
      'blockingIssues', jsonb_build_array(jsonb_build_object('code', 'PLAN_MISSING', 'message', '글쓰기 평가계획이 없습니다.'))
    );
  end if;

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', v_candidate_count,
    'group', jsonb_build_object(
      'ready', v_group_ready,
      'status', v_group_plan.status,
      'planRevision', v_group_plan.revision,
      'documentSourceRunId', v_group_plan.document_source_run_id,
      'sourceMatches', v_group_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_group_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'interview', jsonb_build_object(
      'ready', v_interview_ready,
      'status', v_interview_plan.status,
      'planRevision', v_interview_plan.revision,
      'documentSourceRunId', v_interview_plan.document_source_run_id,
      'configRevisionId', v_interview_plan.config_revision_id,
      'sourceMatches', v_interview_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_interview_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'writing', jsonb_build_object(
      'ready', v_writing_ready,
      'status', v_writing_plan.status,
      'planRevision', v_writing_plan.revision,
      'documentSourceRunId', v_writing_plan.document_source_run_id,
      'configRevisionId', v_writing_plan.config_revision_id,
      'sourceMatches', v_writing_plan.document_source_run_id = v_round.document_decision_run_id,
      'blockingIssues', coalesce(v_writing_validation -> 'blockingIssues', '[]'::jsonb)
    ),
    'allReady', v_group_ready and v_interview_ready and v_writing_ready,
    'checkedAt', now()
  );
end;
$$;

revoke all on function public.get_m5e_paper_backup_status(int, admission_round) from public, anon;
grant execute on function public.get_m5e_paper_backup_status(int, admission_round) to authenticated;

-- ============================================================
-- 2. 영역별 인쇄 패킷 조회
-- ============================================================

create or replace function public.get_m5e_paper_backup_packet(
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
  v_round public.admission_rounds%rowtype;
  v_status jsonb;
  v_area_status jsonb;
  v_payload jsonb;
  v_group_params jsonb;
  v_plan_config_revision_id uuid;
  v_candidate_count int := 0;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('group', 'interview', 'writing') then
    raise exception 'paper backup area는 group, interview, writing 중 하나여야 합니다: %', p_area using errcode = '22023';
  end if;

  select * into v_round
  from public.admission_rounds
  where year = p_year and round = p_round;
  if not found then
    raise exception 'admission_round를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  if v_round.document_decision_run_id is null then
    raise exception 'M4 final 1차 사정 run이 없습니다. 종이 백업 대상 명단을 확정할 수 없습니다.' using errcode = '55000';
  end if;

  v_status := public.get_m5e_paper_backup_status(p_year, p_round);
  v_area_status := v_status -> p_area;
  v_candidate_count := coalesce((v_status ->> 'candidateCount')::int, 0);

  if p_area = 'group' then
    v_group_params := public._m5b_group_params(v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_round.config_revision_id,
      'config', v_group_params,
      'evaluators', coalesce(jsonb_agg(evaluator_packet order by evaluator_packet ->> 'displayName', evaluator_packet ->> 'evaluatorUid'), '[]'::jsonb)
    ) into v_payload
    from (
      select jsonb_build_object(
        'evaluatorUid', u.id,
        'displayName', u.display_name,
        'email', u.email,
        'groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'groupId', g.id,
            'groupCode', g.group_code,
            'sortOrder', g.sort_order,
            'observerRole', case when exists (
              select 1 from public.deep_group_primary_observers po
              where po.group_id = g.id and po.evaluator_uid = u.id
            ) then 'primary' else 'roving' end,
            'plannedSegments', coalesce((
              select jsonb_agg(jsonb_build_object(
                'segmentId', s.id,
                'segmentCode', s.segment_code,
                'startsAt', s.starts_at,
                'endsAt', s.ends_at,
                'sortOrder', s.sort_order
              ) order by s.sort_order, s.starts_at)
              from public.deep_group_rotation_assignments ra
              join public.deep_group_rotation_segments s on s.id = ra.segment_id
              where ra.evaluator_uid = u.id
                and ra.target_group_id = g.id
                and ra.year = p_year and ra.round = p_round
            ), '[]'::jsonb),
            'members', coalesce((
              select jsonb_agg(jsonb_build_object(
                'applicantId', er.applicant_id,
                'examNo', er.exam_no,
                'displayName', er.display_name,
                'sortOrder', gm.sort_order
              ) order by gm.sort_order, er.exam_no, er.display_name)
              from public.deep_group_members gm
              join public.evaluation_roster er on er.applicant_id = gm.applicant_id
              where gm.group_id = g.id
            ), '[]'::jsonb)
          ) order by g.sort_order, g.group_code)
          from public.deep_groups g
          where g.year = p_year and g.round = p_round and g.active = true
            and (
              exists (
                select 1 from public.deep_group_primary_observers po
                where po.group_id = g.id and po.evaluator_uid = u.id
              )
              or exists (
                select 1 from public.deep_group_rotation_assignments ra
                where ra.year = p_year and ra.round = p_round
                  and ra.evaluator_uid = u.id and ra.target_group_id = g.id
              )
            )
        ), '[]'::jsonb)
      ) as evaluator_packet
      from public.users u
      where u.id in (
        select po.evaluator_uid
        from public.deep_group_primary_observers po
        where po.year = p_year and po.round = p_round
        union
        select ra.evaluator_uid
        from public.deep_group_rotation_assignments ra
        where ra.year = p_year and ra.round = p_round
      )
    ) packets;

  elsif p_area = 'interview' then
    select config_revision_id into v_plan_config_revision_id
    from public.interview_team_plans
    where year = p_year and round = p_round;
    v_plan_config_revision_id := coalesce(v_plan_config_revision_id, v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_plan_config_revision_id,
      'student', public._m5c_interview_params(v_plan_config_revision_id, 'student'::text),
      'parent', public._m5c_interview_params(v_plan_config_revision_id, 'parent'::text),
      'teams', coalesce(jsonb_agg(jsonb_build_object(
        'teamId', t.id,
        'teamCode', t.team_code,
        'location', t.location,
        'sortOrder', t.sort_order,
        'members', coalesce((
          select jsonb_agg(jsonb_build_object(
            'evaluatorUid', m.evaluator_uid,
            'displayName', u.display_name,
            'email', u.email,
            'memberSlot', m.member_slot
          ) order by m.member_slot)
          from public.interview_team_members m
          join public.users u on u.id = m.evaluator_uid
          where m.team_id = t.id
        ), '[]'::jsonb),
        'schedule', coalesce((
          select jsonb_agg(jsonb_build_object(
            'scheduleId', s.id,
            'applicantId', er.applicant_id,
            'examNo', er.exam_no,
            'displayName', er.display_name,
            'studentStartsAt', s.student_starts_at,
            'studentEndsAt', s.student_ends_at,
            'parentStartsAt', s.parent_starts_at,
            'parentEndsAt', s.parent_ends_at,
            'sortOrder', s.sort_order
          ) order by s.sort_order, s.student_starts_at, er.exam_no)
          from public.interview_schedules s
          join public.evaluation_roster er on er.applicant_id = s.applicant_id
          where s.team_id = t.id
        ), '[]'::jsonb)
      ) order by t.sort_order, t.team_code), '[]'::jsonb)
    ) into v_payload
    from public.interview_teams t
    where t.year = p_year and t.round = p_round and t.active = true;

  else
    select config_revision_id into v_plan_config_revision_id
    from public.writing_evaluation_plans
    where year = p_year and round = p_round;
    v_plan_config_revision_id := coalesce(v_plan_config_revision_id, v_round.config_revision_id);

    select jsonb_build_object(
      'configRevisionId', v_plan_config_revision_id,
      'config', public._m5d_writing_params(v_plan_config_revision_id),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'evaluatorUid', m.evaluator_uid,
          'displayName', u.display_name,
          'email', u.email,
          'memberSlot', m.member_slot
        ) order by m.member_slot)
        from public.writing_plan_members m
        join public.users u on u.id = m.evaluator_uid
        where m.year = p_year and m.round = p_round
      ), '[]'::jsonb),
      'candidates', coalesce((
        select jsonb_agg(jsonb_build_object(
          'applicantId', er.applicant_id,
          'examNo', er.exam_no,
          'displayName', er.display_name,
          'rank', dr.rank
        ) order by dr.rank, er.exam_no, er.display_name)
        from public.decision_results dr
        join public.evaluation_roster er on er.applicant_id = dr.applicant_id
        where dr.run_id = v_round.document_decision_run_id
          and dr.outcome = 'passed'
      ), '[]'::jsonb)
    ) into v_payload;
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'paper_backup.packet_viewed', 'paper_backup',
     p_year::text || '_' || p_round::text || '_' || p_area,
     p_area::evaluation_area,
     jsonb_build_object(
       'area', p_area,
       'ready', coalesce((v_area_status ->> 'ready')::boolean, false),
       'candidateCount', v_candidate_count,
       'planRevision', v_area_status -> 'planRevision',
       'documentDecisionRunId', v_round.document_decision_run_id
     ));

  return jsonb_build_object(
    'year', p_year,
    'round', p_round,
    'area', p_area,
    'generatedAt', now(),
    'documentDecisionRunId', v_round.document_decision_run_id,
    'candidateCount', v_candidate_count,
    'ready', coalesce((v_area_status ->> 'ready')::boolean, false),
    'planStatus', v_area_status ->> 'status',
    'planRevision', v_area_status -> 'planRevision',
    'blockingIssues', coalesce(v_area_status -> 'blockingIssues', '[]'::jsonb),
    'payload', coalesce(v_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.get_m5e_paper_backup_packet(int, admission_round, text) from public, anon;
grant execute on function public.get_m5e_paper_backup_packet(int, admission_round, text) to authenticated;

-- ============================================================
-- 3. 운영용 인쇄/PDF 저장 요청 감사로그
-- ============================================================

create or replace function public.log_m5e_paper_backup_print(
  p_year int,
  p_round admission_round,
  p_area text,
  p_page_count int,
  p_copy_count int default 1,
  p_mode text default 'print_dialog'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_status jsonb;
  v_area_status jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_area not in ('group', 'interview', 'writing') then
    raise exception 'paper backup area는 group, interview, writing 중 하나여야 합니다: %', p_area using errcode = '22023';
  end if;
  if coalesce(p_page_count, 0) <= 0 or coalesce(p_copy_count, 0) <= 0 then
    raise exception 'pageCount와 copyCount는 1 이상이어야 합니다.' using errcode = '22023';
  end if;
  if p_mode not in ('print_dialog', 'pdf_save') then
    raise exception 'mode는 print_dialog 또는 pdf_save여야 합니다.' using errcode = '22023';
  end if;

  v_status := public.get_m5e_paper_backup_status(p_year, p_round);
  v_area_status := v_status -> p_area;
  if not coalesce((v_area_status ->> 'ready')::boolean, false) then
    raise exception 'M5E_PAPER_BACKUP_NOT_READY: % 영역 계획이 최종확정·검증 완료 상태가 아닙니다: %',
      p_area, v_area_status -> 'blockingIssues' using errcode = '55000';
  end if;

  insert into public.audit_logs
    (year, round, actor_type, actor_uid, action, resource_type, resource_id, area, metadata)
  values
    (p_year, p_round, 'user', caller::text, 'paper_backup.print_requested', 'paper_backup',
     p_year::text || '_' || p_round::text || '_' || p_area,
     p_area::evaluation_area,
     jsonb_build_object(
       'area', p_area,
       'pageCount', p_page_count,
       'copyCount', p_copy_count,
       'mode', p_mode,
       'candidateCount', v_status -> 'candidateCount',
       'planRevision', v_area_status -> 'planRevision',
       'documentDecisionRunId', v_status -> 'documentDecisionRunId'
     ));

  return jsonb_build_object(
    'logged', true,
    'area', p_area,
    'pageCount', p_page_count,
    'copyCount', p_copy_count,
    'mode', p_mode,
    'loggedAt', now()
  );
end;
$$;

revoke all on function public.log_m5e_paper_backup_print(int, admission_round, text, int, int, text) from public, anon;
grant execute on function public.log_m5e_paper_backup_print(int, admission_round, text, int, int, text) to authenticated;

-- ============================================================
-- 4. migration self-verification
-- ============================================================

do $m5e_verify$
declare
  missing_objects text[] := '{}'::text[];
begin
  if to_regprocedure('public.get_m5e_paper_backup_status(integer,admission_round)') is null then
    missing_objects := array_append(missing_objects, 'rpc:get_m5e_paper_backup_status');
  end if;
  if to_regprocedure('public.get_m5e_paper_backup_packet(integer,admission_round,text)') is null then
    missing_objects := array_append(missing_objects, 'rpc:get_m5e_paper_backup_packet');
  end if;
  if to_regprocedure('public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)') is null then
    missing_objects := array_append(missing_objects, 'rpc:log_m5e_paper_backup_print');
  end if;

  if not has_function_privilege('authenticated', 'public.get_m5e_paper_backup_status(integer,admission_round)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:status:authenticated');
  end if;
  if not has_function_privilege('authenticated', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:packet:authenticated');
  end if;
  if not has_function_privilege('authenticated', 'public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:print:authenticated');
  end if;
  if has_function_privilege('anon', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') then
    missing_objects := array_append(missing_objects, 'grant:packet:anon_should_be_revoked');
  end if;

  if cardinality(missing_objects) > 0 then
    raise exception 'M5E_00014_VERIFY_FAILED: missing objects = %', array_to_string(missing_objects, ', ')
      using errcode = 'P0001';
  end if;
end
$m5e_verify$;

commit;

select
  'M5E_00014_APPLIED'::text as migration_status,
  to_regprocedure('public.get_m5e_paper_backup_status(integer,admission_round)') is not null as status_rpc_present,
  to_regprocedure('public.get_m5e_paper_backup_packet(integer,admission_round,text)') is not null as packet_rpc_present,
  to_regprocedure('public.log_m5e_paper_backup_print(integer,admission_round,text,integer,integer,text)') is not null as print_audit_rpc_present,
  not has_function_privilege('anon', 'public.get_m5e_paper_backup_packet(integer,admission_round,text)', 'EXECUTE') as anon_packet_revoked;
