-- 2027학년도 주전형(main) — 자기소개서·학부모 소견서 배점 파라미터 반영 + 평가 오픈
--
-- setup-2027-scoring-params.sql(출결/학업/공동체) 다음에 실행. 기존 파라미터를
-- 이어받아 essay/opinion을 추가한 새 revision을 만든다(불변 원칙 — 계속 새
-- revision을 쌓아가는 방식).

do $$
declare
  admin_uid uuid;
  old_rev record;
  new_rev_id uuid;
  new_scoring jsonb;
  essay_criteria jsonb;
  opinion_criteria jsonb;
begin
  select id into admin_uid from public.users where 'superadmin' = any(roles) limit 1;
  if admin_uid is null then
    raise exception 'superadmin이 없습니다.';
  end if;

  -- _essay_criteria_keys()/_opinion_criteria_keys()는 authenticated에 execute가
  -- 없는 내부 전용 헬퍼다(hotfix-004에서 의도적으로 잠금 — 다른 SECURITY DEFINER
  -- 함수 내부 중첩호출로만 쓰이는 게 정상 경로). 이 스크립트는 role을
  -- authenticated로 낮춰서 실행하므로, 두 함수는 role 전환 전(superuser 권한)에
  -- 먼저 호출해 값을 변수에 담아둔다. (2026-07-09 수정 — 최초 작성 시점에는
  -- hotfix-004가 아직 없어 문제가 없었으나, 이후 재실행 시 permission denied로
  -- 막히는 것을 확인해 수정함)
  essay_criteria := to_jsonb(public._essay_criteria_keys());
  opinion_criteria := to_jsonb(public._opinion_criteria_keys());

  perform set_config('request.jwt.claims',
    json_build_object('sub', admin_uid::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select cr.* into old_rev
  from public.configs c
  join public.config_revisions cr on cr.id = c.active_revision_id
  where c.year = 2027;

  if old_rev is null then
    raise exception '2027 config가 없습니다. setup-2027-main.sql과 setup-2027-scoring-params.sql을 먼저 실행하세요.';
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'essay', jsonb_build_object(
      'max', 500,
      'perEvaluatorMax', 100,
      'requiredSubmissions', 5,
      'combine', 'sum',
      'alertGap', 3,
      'minIfRelevant', 3,
      'criteria', essay_criteria
    ),
    'opinion', jsonb_build_object(
      'max', 100,
      'perEvaluatorMax', 25,
      'requiredSubmissions', 4,
      'combine', 'sum',
      'scoreStep', 0.5,
      'alertGap', 1.5,
      'minIfRelevant', 0.5,
      'criteria', opinion_criteria
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  perform public.set_round_stage(
    2027, 'main', 'document_review', 'open',
    array['attendance', 'academic', 'community', 'essay', 'opinion']::evaluation_area[]
  );

  reset role;
  raise notice '=== 2027 main essay/opinion 배점 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
end $$;
