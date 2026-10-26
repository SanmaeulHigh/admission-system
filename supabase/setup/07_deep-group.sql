-- 2027 main M5b 모둠활동 배점 파라미터 반영.
-- 현재 admission_round에 연결된 locked revision을 복제해 deep.group만 추가한 새 revision을 생성한다.
-- stage/stage_status/open_evaluation_areas는 init_admission_round의 ON CONFLICT 특성상 유지된다.

do $$
declare
  admin_uid uuid;
  old_rev public.config_revisions%rowtype;
  new_rev_id uuid;
  new_scoring jsonb;
  existing_group jsonb;
begin
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

  if old_rev is null then
    raise exception '2027 main admission_round/config revision이 없습니다.';
  end if;

  existing_group := old_rev.scoring_params #> '{deep,group}';
  if existing_group is not null
     and existing_group -> 'criteria' = jsonb_build_array('contribution','communication','logicCreativity')
     and (existing_group ->> 'max')::numeric = 150
     and (existing_group ->> 'perEvaluatorMax')::numeric = 15
     and (existing_group ->> 'requiredPrimaryObservers')::int = 2
     and (existing_group ->> 'scaleFactor')::numeric = 10 then
    reset role;
    raise notice '2027 main deep.group 파라미터가 이미 반영되어 있습니다. 변경 없음.';
    return;
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'deep', coalesce(old_rev.scoring_params -> 'deep', '{}'::jsonb) || jsonb_build_object(
      'group', jsonb_build_object(
        'max', 150,
        'perEvaluatorMax', 15,
        'criteria', jsonb_build_array('contribution','communication','logicCreativity'),
        'criterionMax', 5,
        'scoreStep', 1,
        'combine', 'avg',
        'scaleFactor', 10,
        'requiredPrimaryObservers', 2,
        'rovingObserverPolicy', 'optionalConfirmedOnly'
      )
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  reset role;
  raise notice '=== 2027 main deep.group 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
end $$;
