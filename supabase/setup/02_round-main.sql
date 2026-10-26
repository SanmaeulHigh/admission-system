-- 2027학년도 주전형(main) 초기화 (SQL Editor에서 1회 실행)
--
-- register_applicant는 admission_rounds 행이 있어야 동작하므로, 접수 기능을
-- 쓰기 전에 이 스크립트를 한 번 실행한다. RPC들이 superadmin 검증을
-- 하므로, SQL Editor(postgres)에서 실행할 때는 아래처럼 superadmin의
-- JWT를 시뮬레이션해서 호출한다.
--
-- 일정(schedule)은 공고 제2026-42호 기준 임시값 — 정확한 값은 요강 확정
-- 내용으로 나중에 새 revision을 만들어 갱신한다 (기존 revision은 불변).

do $$
declare
  admin_uid uuid;
  rev_id uuid;
begin
  select id into admin_uid from public.users where 'superadmin' = any(roles) limit 1;
  if admin_uid is null then
    raise exception 'superadmin 계정이 없습니다. bootstrap-superadmin.sql을 먼저 실행하세요.';
  end if;

  -- superadmin JWT 시뮬레이션
  perform set_config('request.jwt.claims',
    json_build_object('sub', admin_uid::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 이미 초기화되어 있으면 건너뜀 (재실행 안전)
  if exists (select 1 from public.admission_rounds where year = 2027 and round = 'main') then
    reset role;
    raise notice '2027 main은 이미 초기화되어 있습니다. 아무것도 변경하지 않았습니다.';
    return;
  end if;

  rev_id := public.create_config_draft(
    2027,
    jsonb_build_object(
      'receiptStart', '2026-10-19',
      'receiptEnd', '2026-10-23',
      'documentReviewStart', '2026-11-03',
      'documentReviewEnd', '2026-11-05',
      'deepEvaluationDate', '2026-11-14',
      'resultAnnounceDate', '2026-11-18',
      'preApplicationStart', '2026-09-01'
    ),
    jsonb_build_object(
      'note', '배점·가산점 파라미터는 Sprint 2(채점)에서 채운다'
    )
  );

  perform public.lock_config_revision(rev_id);
  perform public.init_admission_round(2027, 'main', rev_id);

  reset role;
  raise notice '2027 main 초기화 완료 (revision %)', rev_id;
end $$;
