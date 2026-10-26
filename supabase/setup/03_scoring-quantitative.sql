-- 2027학년도 주전형(main) — 출결·학업·공동체 배점 파라미터 반영 + 평가 오픈
--
-- config_revisions는 불변이라 Sprint 1의 첫 revision(schedule만 있고
-- scoring_params는 비어있었음)을 수정할 수 없다. 새 revision을 만들어
-- 배점 파라미터를 채우고 잠근 뒤, admission_rounds가 그 새 revision을
-- 쓰도록 재연결한다. 숫자는 마스터 스펙 섹션 3.2 config 예시(2026학년도
-- 실제 채점표 기준)를 그대로 사용 — 2027 요강 확정본과 다르면 이 스크립트
-- 숫자만 고쳐서 다시 실행하면 된다(새 revision이 또 생기는 방식으로).
--
-- SQL Editor에서 실행. superadmin 계정으로 시뮬레이션한다.

do $$
declare
  admin_uid uuid;
  old_rev record;
  new_rev_id uuid;
  new_schedule jsonb;
  new_scoring jsonb;
begin
  select id into admin_uid from public.users where 'superadmin' = any(roles) limit 1;
  if admin_uid is null then
    raise exception 'superadmin이 없습니다.';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', admin_uid::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 기존 revision의 schedule은 그대로 이어받는다 (일정 재입력 방지)
  select cr.* into old_rev
  from public.configs c
  join public.config_revisions cr on cr.id = c.active_revision_id
  where c.year = 2027;

  if old_rev is null then
    raise exception '2027 config가 없습니다. setup-2027-main.sql을 먼저 실행하세요.';
  end if;

  new_schedule := old_rev.schedule;

  new_scoring := jsonb_build_object(
    'attendance', jsonb_build_object(
      'max', 200,
      'perDayDeduction', 10,
      'attendanceEventPerAbsence', 3,
      'noRecordScore', 190,
      'requiredSubmissions', 1
    ),
    'academic', jsonb_build_object(
      'max', 100,
      'gradeMap', jsonb_build_object('A', 20, 'B', 16, 'C', 8, 'D', 4, 'E', 2),
      'gedBands', jsonb_build_array(
        jsonb_build_array(0, 60, 2),
        jsonb_build_array(61, 70, 4),
        jsonb_build_array(71, 80, 8),
        jsonb_build_array(81, 90, 16),
        jsonb_build_array(91, 100, 20)
      ),
      'noDocumentScore', 10,
      'requiredSubmissions', 1
    ),
    'community', jsonb_build_object(
      'max', 100,
      'grades', jsonb_build_object('1', 100, '2', 90, '3', 75, '4', 60, '5', 40),
      'requiredSubmissions', 2,
      'combine', 'avg'
    )
  );

  new_rev_id := public.create_config_draft(2027, new_schedule, new_scoring);
  perform public.lock_config_revision(new_rev_id);
  perform public.init_admission_round(2027, 'main', new_rev_id);

  -- 출결·학업·공동체 평가 오픈 (접수 단계 완전 종료 전이어도 개발/테스트
  -- 목적상 지금 연다 — 실제 전형에서는 서류평가 시작일에 맞춰 재조정할 것)
  perform public.set_round_stage(
    2027, 'main', 'document_review', 'open',
    array['attendance', 'academic', 'community']::evaluation_area[]
  );

  reset role;
  raise notice '=== 2027 main 배점 파라미터 반영 완료 (새 revision %) ===', new_rev_id;
  raise notice 'INFO: 출결/학업/공동체 평가가 open 상태로 전환되었습니다.';
end $$;
