-- 2027 main M5d 글쓰기 배점 파라미터 반영.
-- 승인 요강은 글쓰기 200점(3문항 중 2택)을 명시하고, 마스터 스펙은 문항별 4영역을 요구한다.
-- 다만 승인 요강에는 4개 세부 criterion의 공식 명칭·단계표가 없다.
-- 아래 4영역/0~25점 5점 간격 단계는 구현 기본값이며, 심층역량평가 운영계획 확정 시
-- 기존 revision을 수정하지 않고 이 setup을 수정해 새 immutable revision을 생성한다.

do $$
declare
  admin_uid uuid;
  old_rev public.config_revisions%rowtype;
  new_rev_id uuid;
  new_scoring jsonb;
  writing_params jsonb;
  common_criteria jsonb;
begin
  if to_regprocedure('public._m5d_writing_params(uuid)') is null then
    raise exception 'M5D_HELPER_MISSING: public._m5d_writing_params(uuid)가 없습니다. 검증된 00013 적용 상태를 확인하세요.' using errcode = '42883';
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

  common_criteria := jsonb_build_array(
    jsonb_build_object(
      'key', 'understanding',
      'label', '내용 이해·문제 파악',
      'max', 25,
      'scoreValues', jsonb_build_array(0, 5, 10, 15, 20, 25)
    ),
    jsonb_build_object(
      'key', 'reasoning',
      'label', '사고·논리 전개',
      'max', 25,
      'scoreValues', jsonb_build_array(0, 5, 10, 15, 20, 25)
    ),
    jsonb_build_object(
      'key', 'specificity',
      'label', '구체성·근거',
      'max', 25,
      'scoreValues', jsonb_build_array(0, 5, 10, 15, 20, 25)
    ),
    jsonb_build_object(
      'key', 'organizationExpression',
      'label', '구성·표현',
      'max', 25,
      'scoreValues', jsonb_build_array(0, 5, 10, 15, 20, 25)
    )
  );

  writing_params := jsonb_build_object(
    'max', 200,
    'perEvaluatorMax', 200,
    'requiredSubmissions', 2,
    'combine', 'avg',
    'alertGap', 40,
    'questionRule', jsonb_build_object(
      'pick', 2,
      'of', 3,
      'each', 100,
      'criteriaPerQuestion', 4
    ),
    'questions', jsonb_build_array(
      jsonb_build_object('id', 'Q1', 'label', '문항 1', 'criteria', common_criteria),
      jsonb_build_object('id', 'Q2', 'label', '문항 2', 'criteria', common_criteria),
      jsonb_build_object('id', 'Q3', 'label', '문항 3', 'criteria', common_criteria)
    )
  );

  if old_rev.scoring_params #> '{deep,writing}' = writing_params then
    reset role;
    raise notice '2027 main deep.writing 파라미터가 이미 반영되어 있습니다. 변경 없음.';
    return;
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'deep', coalesce(old_rev.scoring_params -> 'deep', '{}'::jsonb) || jsonb_build_object(
      'writing', writing_params
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  reset role;
  perform public._m5d_writing_params(new_rev_id::uuid);

  raise notice '=== 2027 main M5d 글쓰기 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
end $$;
