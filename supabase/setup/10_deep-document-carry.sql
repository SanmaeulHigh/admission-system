-- 2027학년도 주전형(main) — M6a deep.documentCarry(2차 400점 환산) 파라미터 반영.
--
-- 근거: 새봄고 공고 제2026-42호(2026.7.6 승인) "(2) 2차 심층역량평가
-- ① 1차 서류평가 획득 점수(400점 만점): 1차 서류평가 획득 점수(1,000점 만점)의
-- 4/10를 반영함". 요강이 1차 합불 판정에도 그대로 쓰는 "1차 서류평가 점수"는
-- 가산점 포함·1,000점 cap 적용 후 값이므로, documentCarry도 그 값(=decision_results
-- .total_score)을 그대로 0.4배 환산해 사용한다. 가산 전 원점수 별도 이월 아님
-- (담당 교사 확인, 2026-07-08).
--
-- multiplier(0.4) × 1,000(cap) = 400 이므로 max(400) cap은 이 config 값 조합에서는
-- 이론상 항상 정확히 경계에서만 맞물리고 절대 초과하지 않는다. 그래도 산식 자체의
-- 방어적 안전장치로 max를 명시하고 _compute_final_aggregate에서 least()로 강제한다.

do $$
declare
  admin_uid uuid;
  old_rev public.config_revisions%rowtype;
  new_rev_id uuid;
  new_scoring jsonb;
  existing_carry jsonb;
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

  existing_carry := old_rev.scoring_params #> '{deep,documentCarry}';
  if existing_carry is not null
     and (existing_carry ->> 'multiplier')::numeric = 0.4
     and (existing_carry ->> 'max')::numeric = 400 then
    reset role;
    raise notice '2027 main deep.documentCarry 파라미터가 이미 반영되어 있습니다. 변경 없음.';
    return;
  end if;

  new_scoring := old_rev.scoring_params || jsonb_build_object(
    'deep', coalesce(old_rev.scoring_params -> 'deep', '{}'::jsonb) || jsonb_build_object(
      'documentCarry', jsonb_build_object(
        'multiplier', 0.4,
        'max', 400
      )
    )
  );

  new_rev_id := public.create_config_draft(2027, old_rev.schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  reset role;
  raise notice '=== 2027 main deep.documentCarry 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
end $$;
