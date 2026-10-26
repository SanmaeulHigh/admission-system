-- 2027 main M5c 학생·학부모면접 배점 파라미터 반영.
-- 승인 요강의 면접 평가 주제 및 2026 채점표 구조(학생 5영역×30점)를 바탕으로
-- deep.interviewStudent / deep.interviewParent를 새 immutable config revision에 추가한다.
-- 운영계획에서 세부 단계표가 달라지면 이 setup을 수정해 새 revision으로 교체한다.

do $$
declare
  admin_uid uuid;
  old_rev public.config_revisions%rowtype;
  new_rev_id uuid;
  new_scoring jsonb;
  student_params jsonb;
  parent_params jsonb;
begin
  -- M5c migration helper가 실제 DB 카탈로그에 존재하는지 config 변경 전에 확인한다.
  if to_regprocedure('public._m5c_interview_params(uuid,text)') is null then
    raise exception 'M5C_HELPER_MISSING: public._m5c_interview_params(uuid,text)가 없습니다. 수정된 00012 적용 상태를 확인하세요.' using errcode = '42883';
  end if;

  select id into admin_uid
  from public.users
  where active = true and 'superadmin' = any(roles)
  order by id
  limit 1;
  if admin_uid is null then
    raise exception '활성 superadmin이 없습니다.';
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_uid::text, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;

  select cr.* into old_rev
  from public.admission_rounds ar
  join public.config_revisions cr on cr.id = ar.config_revision_id
  where ar.year = 2027 and ar.round = 'main';

  if not found then
    raise exception '2027 main admission_round/config revision이 없습니다.';
  end if;

  student_params := jsonb_build_object(
    'max', 150,
    'perEvaluatorMax', 150,
    'requiredSubmissions', 2,
    'combine', 'avg',
    'alertGap', 30,
    'durationMinutes', 25,
    'criteria', jsonb_build_array(
      jsonb_build_object(
        'key', 'schoolUnderstanding',
        'label', '학교·교육과정 이해',
        'max', 30,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25, 30)
      ),
      jsonb_build_object(
        'key', 'learningAttitude',
        'label', '배움의 자세',
        'max', 30,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25, 30)
      ),
      jsonb_build_object(
        'key', 'communityReadiness',
        'label', '공동체 생활 준비도',
        'max', 30,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25, 30)
      ),
      jsonb_build_object(
        'key', 'selfUnderstanding',
        'label', '자기이해·표현',
        'max', 30,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25, 30)
      ),
      jsonb_build_object(
        'key', 'admissionMotivation',
        'label', '입학의지·성장 가능성',
        'max', 30,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25, 30)
      )
    )
  );

  parent_params := jsonb_build_object(
    'max', 100,
    'perEvaluatorMax', 100,
    'requiredSubmissions', 2,
    'combine', 'avg',
    'alertGap', 20,
    'durationMinutes', 20,
    'criteria', jsonb_build_array(
      jsonb_build_object(
        'key', 'childUnderstanding',
        'label', '자녀 이해',
        'max', 25,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25)
      ),
      jsonb_build_object(
        'key', 'alternativeEducationUnderstanding',
        'label', '대안교육·교육철학 이해',
        'max', 25,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25)
      ),
      jsonb_build_object(
        'key', 'communicationCooperation',
        'label', '가정-학교 소통·협력 의지',
        'max', 25,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25)
      ),
      jsonb_build_object(
        'key', 'careerView',
        'label', '자녀의 진로관',
        'max', 25,
        'scoreValues', jsonb_build_array(5, 10, 15, 20, 25)
      )
    )
  );

  if old_rev.scoring_params #> '{deep,interviewStudent}' = student_params
     and old_rev.scoring_params #> '{deep,interviewParent}' = parent_params then
    reset role;
    raise notice '2027 main deep.interviewStudent / deep.interviewParent 파라미터가 이미 반영되어 있습니다. 변경 없음.';
    return;
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'deep', coalesce(old_rev.scoring_params -> 'deep', '{}'::jsonb) || jsonb_build_object(
      'interviewStudent', student_params,
      'interviewParent', parent_params
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  -- private validator 직접 호출은 DB 관리자 역할로 복귀한 뒤 수행한다.
  reset role;
  perform public._m5c_interview_params(new_rev_id::uuid, 'student'::text);
  perform public._m5c_interview_params(new_rev_id::uuid, 'parent'::text);

  raise notice '=== 2027 main M5c 면접 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
end $$;
