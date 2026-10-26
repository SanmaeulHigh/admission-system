-- 2027학년도 주전형(main) — quota·가산점·동점기준 파라미터 반영
--
-- run_document_decision이 동작하려면 config에 quota가 있어야 한다.
-- 숫자는 공고 제2026-42호(모집 20명: 일반16/인천추천3/사회통합1, 배수 1.5) 및
-- 서류평가 지침(가산 20%, 1,000점 cap) 기준. 실제 요강과 다르면 이 파일만
-- 수정 후 재실행.

do $$
declare
  admin_uid uuid;
  old_rev record;
  new_rev_id uuid;
  new_scoring jsonb;
begin
  select id into admin_uid from public.users where 'superadmin' = any(roles) limit 1;
  if admin_uid is null then
    raise exception 'superadmin이 없습니다.';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', admin_uid::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select cr.* into old_rev
  from public.configs c
  join public.config_revisions cr on cr.id = c.active_revision_id
  where c.year = 2027;

  if old_rev is null then
    raise exception '2027 config가 없습니다. 이전 setup 스크립트들을 먼저 실행하세요.';
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'quota', jsonb_build_object(
      'general', 16, 'incheon', 3, 'social', 1, 'total', 20,
      'screeningMultiple', 1.5, 'unfilledTrackPolicy', 'pending'
    ),
    'bonus', jsonb_build_object(
      'rate', 0.2, 'cap', 1000, 'eligibilityTrack', 'incheon',
      'eligibleReasons', jsonb_build_array('농어민자녀', '강화군소재중학교졸업'),
      'applyLevel', 'total'
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  reset role;
  raise notice '=== 2027 main quota/가산점 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
  raise notice 'INFO: unfilledTrackPolicy는 pending으로 설정됨 — 최종(final) 사정 전 입학전형위원회 확정 필요 (섹션 5.8 E).';
end $$;
