-- 2027학년도 주전형(main) — quota.unfilledTrackPolicy 확정 반영.
--
-- 담당 교사 결정(2026-07-08): 인천학생추천전형·사회통합전형 미충원 인원은
-- 일반전형으로 이월한다(carryToGeneral). 요강 승인본에는 이 정책이 명시되어
-- 있지 않아(제5.8절 E 확인 항목) 입학전형위원회 결정 사항으로 반영한다.
--
-- setup-2027-quota-bonus-params.sql이 처음 반영한 'pending' 값을 대체한다.
-- quota.general/incheon/social/total/screeningMultiple 등 나머지 값은 그대로 둔다.

do $$
declare
  admin_uid uuid;
  old_rev public.config_revisions%rowtype;
  new_rev_id uuid;
  new_scoring jsonb;
  current_policy text;
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

  if old_rev.scoring_params -> 'quota' is null then
    raise exception '2027 main config에 quota 파라미터가 없습니다. setup-2027-quota-bonus-params.sql을 먼저 실행하세요.';
  end if;

  current_policy := old_rev.scoring_params #>> '{quota,unfilledTrackPolicy}';
  if current_policy = 'carryToGeneral' then
    reset role;
    raise notice '2027 main quota.unfilledTrackPolicy가 이미 carryToGeneral입니다. 변경 없음.';
    return;
  end if;

  new_scoring := jsonb_set(
    old_rev.scoring_params,
    '{quota,unfilledTrackPolicy}',
    to_jsonb('carryToGeneral'::text)
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  reset role;
  raise notice '=== 2027 main quota.unfilledTrackPolicy: % -> carryToGeneral 반영 완료 (새 revision %) ===', current_policy, new_rev_id;
end $$;
