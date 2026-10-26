-- 새봄고 입학전형 시스템 — 출결·학업성실도·공동체를 최고관리자 1인 채점으로 (2026-09-28)
--
-- 결정(2026-09-28, 담당 교사): 출결·학업성실도·공동체생활적합성은 최고관리자 혼자 채점한다.
-- 00066에서 내부 규정상 2명으로 늘렸던 배정 인원을 1명으로 되돌리고, 공동체의
-- "2인 제출·평균" 규칙도 1건 제출이면 확정되도록 바꾼다.
--
-- 제출 건수 기준은 config_revisions.scoring_params.requiredSubmissions에 있었지만,
-- 확정(lock)된 설정은 고칠 수 없고 고치면 기존 계획이 무효화된다(CONFIG_SOURCE_STALE).
-- 그래서 운영 설정 표 evaluation_area_staffing에 required_submissions(제출 건수
-- 재정의) 칸을 두고, 아래 한 함수가 모든 곳의 기준이 되게 한다.
--   _document_required_submissions(연도, 차수, 영역)
--     = 운영 설정 재정의 → 설정(config) 값 → 기본값(출결1·학업1·공동체2·자소서5·소견서4)
--
-- 이 함수를 쓰도록 바꾸는 곳:
--   · _compute_document_aggregate (00008) — 1차 사정 점수 계산. 공동체/자소서/소견서 건수 비교
--   · get_evaluation_progress / recompute_evaluation_alerts (00007) — 진행 현황·미제출 경고
--   · get_evaluation_staffing (00066) — 평가 준비 화면의 "필요 제출" 표시
-- 자소서 5건·소견서 4건은 그대로다(값이 같으므로 동작 변화 없음).

alter table public.evaluation_area_staffing
  add column if not exists required_submissions int check (required_submissions is null or required_submissions >= 1);

comment on column public.evaluation_area_staffing.required_submissions is
  '채점 완료로 보는 제출 건수 재정의(null이면 config의 requiredSubmissions 사용). 2026-09-28 공동체 1건.';

-- 배정 인원 1명, 공동체 제출 1건 — 모든 차수
update public.evaluation_area_staffing
   set required_evaluators = 1, updated_at = now(), updated_by = 'migration-00069'
 where area in ('attendance','academic','community');

update public.evaluation_area_staffing
   set required_submissions = 1, updated_at = now(), updated_by = 'migration-00069'
 where area = 'community';

-- 앞으로 새 차수를 만들 때도 같은 기본값이 들어가게 한다.
create or replace function public._trg_seed_evaluation_area_staffing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.evaluation_area_staffing (year, round, area, required_evaluators, required_submissions, updated_by)
  select new.year, new.round, d.area, d.cnt, d.sub, 'default'
  from (values
    ('attendance'::evaluation_area, 1, null::int),
    ('academic'::evaluation_area, 1, null::int),
    ('community'::evaluation_area, 1, 1),
    ('essay'::evaluation_area, 5, null::int),
    ('opinion'::evaluation_area, 4, null::int)
  ) as d(area, cnt, sub)
  on conflict (year, round, area) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_seed_evaluation_area_staffing on public.admission_rounds;
create trigger trg_seed_evaluation_area_staffing
  after insert on public.admission_rounds
  for each row execute function public._trg_seed_evaluation_area_staffing();

-- ============================================================
-- 제출 건수 기준 함수
-- ============================================================

create or replace function public._document_required_submissions(
  p_year int,
  p_round admission_round,
  p_area text
)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_override int;
  v_config int;
begin
  select s.required_submissions into v_override
  from public.evaluation_area_staffing s
  where s.year = p_year and s.round = p_round and s.area::text = p_area;
  if v_override is not null then
    return v_override;
  end if;

  select (c.scoring_params -> p_area ->> 'requiredSubmissions')::int into v_config
  from public.admission_rounds r
  join public.config_revisions c on c.id = r.config_revision_id
  where r.year = p_year and r.round = p_round;
  if v_config is not null then
    return v_config;
  end if;

  return case p_area
    when 'attendance' then 1
    when 'academic' then 1
    when 'community' then 2
    when 'essay' then 5
    when 'opinion' then 4
    else null
  end;
end;
$$;

revoke all on function public._document_required_submissions(int, admission_round, text) from public, anon, authenticated;

-- ============================================================
-- 1차 사정 점수 계산 (00008 원문에서 건수 비교만 바꿈)
-- ============================================================

create or replace function public._compute_document_aggregate(p_applicant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  app record;
  rev_id uuid;
  params jsonb;
  attendance_score numeric;
  academic_score numeric;
  community_score numeric;
  community_count int;
  essay_score numeric;
  essay_count int;
  opinion_score numeric;
  opinion_count int;
  raw_total numeric;
  final_total numeric;
  is_complete boolean;
  bonus_applied boolean := false;
  bonus_amount numeric := 0;
begin
  select id, year, round, tracks, bonus_eligible, bonus_reason
    into app from public.applicants where id = p_applicant_id;
  if app is null then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;

  rev_id := public._current_config_revision_id(app.year, app.round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- 출결 (5.2.1): 필수 1건, 없으면 null/미확정
  select (server_computed ->> 'score')::numeric into attendance_score
    from public.scores_attendance
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 학업성실도 (5.2.2)
  select (server_computed ->> 'score')::numeric into academic_score
    from public.scores_academic
    where applicant_id = p_applicant_id and submission_state = 'submitted'
    limit 1;

  -- 공동체 (5.2.3): 필요 제출 건수(기본 2, 2026-09-28부터 1)를 정확히 채워야 확정. 여러 명이면 평균.
  select count(*), avg((server_computed ->> 'score')::numeric)
    into community_count, community_score
    from public.scores_community
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if community_count <> public._document_required_submissions(app.year, app.round, 'community') then
    community_score := null;
  end if;

  -- 자소서 (5.2.4): 필요 제출 건수(기본 5)를 정확히 채워야 확정
  select count(*), sum((server_computed ->> 'total')::numeric)
    into essay_count, essay_score
    from public.scores_essay
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if essay_count <> public._document_required_submissions(app.year, app.round, 'essay') then
    essay_score := null;
  end if;

  -- 소견서 (5.2.5): 필요 제출 건수(기본 4)를 정확히 채워야 확정
  select count(*), sum((server_computed ->> 'total')::numeric)
    into opinion_count, opinion_score
    from public.scores_opinion
    where applicant_id = p_applicant_id and submission_state = 'submitted';
  if opinion_count <> public._document_required_submissions(app.year, app.round, 'opinion') then
    opinion_score := null;
  end if;

  -- 서류평가 원점수 (5.2.6): 5개 영역 전부 확정일 때만
  is_complete := attendance_score is not null and academic_score is not null
    and community_score is not null and essay_score is not null and opinion_score is not null;

  if is_complete then
    raw_total := attendance_score + academic_score + community_score + essay_score + opinion_score;

    -- 가산점 (5.2.7, applyLevel='total' 기본값 — 섹션 5.8 D 확인 전까지 이 값 사용)
    -- config에 bonus 파라미터가 아직 없으면(설정 전 단계) 안전하게 가산점 미적용으로 처리.
    if params -> 'bonus' is not null
       and 'incheon' = any(app.tracks)
       and app.bonus_eligible = true
       and app.bonus_reason = any(
         array(select jsonb_array_elements_text(coalesce(params -> 'bonus' -> 'eligibleReasons', '[]'::jsonb)))
       )
    then
      bonus_applied := true;
      final_total := least(
        coalesce((params -> 'bonus' ->> 'cap')::numeric, raw_total),
        raw_total * (1 + coalesce((params -> 'bonus' ->> 'rate')::numeric, 0))
      );
      bonus_amount := final_total - raw_total;
    else
      final_total := raw_total;
    end if;
  end if;

  return jsonb_build_object(
    'attendance', attendance_score,
    'academic', academic_score,
    'community', community_score,
    'essay', essay_score,
    'opinion', opinion_score,
    'complete', is_complete,
    'rawTotal', raw_total,
    'bonusApplied', bonus_applied,
    'bonusAmount', bonus_amount,
    'finalTotal', final_total
  );
end;
$$;

revoke execute on function public._compute_document_aggregate(uuid) from anon, authenticated;

-- ============================================================
-- 진행 현황·미제출 경고 (00007 원문에서 필요 건수만 바꿈)
-- ============================================================

create or replace function public.recompute_evaluation_alerts(
  target_year int,
  target_round admission_round
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
  created_count int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  if rev_id is null then
    raise exception '이 라운드에 연결된 config revision이 없습니다.';
  end if;
  select scoring_params into params from public.config_revisions where id = rev_id;

  -- ── scoreGap: essay ──────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_essay
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'essay' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'essay', 'scoreGap', 'warning',
         format('자소서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'essay' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'essay' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── scoreGap: opinion ────────────────────────────────────
  for r in
    select applicant_id,
           max((server_computed ->> 'total')::numeric) - min((server_computed ->> 'total')::numeric) as gap,
           array_agg(evaluator_uid) as evaluators
    from public.scores_opinion
    where year = target_year and round = target_round and submission_state = 'submitted'
    group by applicant_id
    having count(*) >= 2
  loop
    if r.gap >= coalesce((params -> 'opinion' ->> 'alertGap')::numeric, 999999) then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary, related_evaluator_uids)
      values
        (target_year, target_round, r.applicant_id, 'opinion', 'scoreGap', 'warning',
         format('소견서 위원 간 총점 편차 %s점 (기준 %s점 이상)', r.gap, params -> 'opinion' ->> 'alertGap'),
         r.evaluators)
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary, related_evaluator_uids = excluded.related_evaluator_uids,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = 'opinion' and alert_type = 'scoreGap' and status != 'resolved';
    end if;
  end loop;

  -- ── missingSubmission: 5개 영역 전부, 평가활성 지원자 기준 ──
  for r in
    select er.applicant_id, area_key.area,
           public._document_required_submissions(target_year, target_round, area_key.area) as required,
           coalesce(cnt.submitted, 0) as submitted
    from public.evaluation_roster er
    cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
    left join lateral (
      select count(*) as submitted from (
        select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
        union all
        select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
        union all
        select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
        union all
        select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
        union all
        select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
      ) x
    ) cnt on true
    where er.year = target_year and er.round = target_round and er.evaluation_active = true
  loop
    if r.required is not null and r.submitted < r.required then
      insert into public.evaluation_alerts
        (year, round, applicant_id, area, alert_type, severity, summary)
      values
        (target_year, target_round, r.applicant_id, r.area::evaluation_area, 'missingSubmission', 'warning',
         format('%s 영역 제출 %s/%s건', r.area, r.submitted, r.required))
      on conflict (year, round, applicant_id, area, alert_type) do update set
        summary = excluded.summary,
        status = case when public.evaluation_alerts.status = 'resolved' then 'open' else public.evaluation_alerts.status end;
      created_count := created_count + 1;
    else
      update public.evaluation_alerts set status = 'resolved', resolved_at = now(), resolved_by = caller::text
        where year = target_year and round = target_round and applicant_id = r.applicant_id
          and area = r.area::evaluation_area and alert_type = 'missingSubmission' and status != 'resolved';
    end if;
  end loop;

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type)
  values (target_year, target_round, 'user', caller::text, 'evaluation_alerts.recomputed', 'evaluation_alerts');

  return jsonb_build_object('processed', created_count)::json;
end;
$$;

revoke execute on function public.recompute_evaluation_alerts(int, admission_round) from anon;

create or replace function public.get_evaluation_progress(
  target_year int,
  target_round admission_round
)
returns table (
  applicant_id uuid,
  receipt_no text,
  display_name text,
  area text,
  required int,
  submitted int,
  complete boolean,
  open_alerts int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  rev_id uuid;
  params jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  rev_id := public._current_config_revision_id(target_year, target_round);
  select scoring_params into params from public.config_revisions where id = rev_id;

  return query
  select
    er.applicant_id,
    er.receipt_no,
    er.display_name,
    area_key.area,
    public._document_required_submissions(target_year, target_round, area_key.area) as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= public._document_required_submissions(target_year, target_round, area_key.area) as complete,
    (select count(*)::int from public.evaluation_alerts ea
      where ea.applicant_id = er.applicant_id and ea.area::text = area_key.area and ea.status = 'open') as open_alerts
  from public.evaluation_roster er
  cross join (values ('attendance'),('academic'),('community'),('essay'),('opinion')) as area_key(area)
  left join lateral (
    select count(*) as submitted from (
      select sa.applicant_id from public.scores_attendance sa where sa.applicant_id = er.applicant_id and sa.submission_state='submitted' and area_key.area='attendance'
      union all
      select sc.applicant_id from public.scores_academic sc where sc.applicant_id = er.applicant_id and sc.submission_state='submitted' and area_key.area='academic'
      union all
      select scm.applicant_id from public.scores_community scm where scm.applicant_id = er.applicant_id and scm.submission_state='submitted' and area_key.area='community'
      union all
      select se.applicant_id from public.scores_essay se where se.applicant_id = er.applicant_id and se.submission_state='submitted' and area_key.area='essay'
      union all
      select so.applicant_id from public.scores_opinion so where so.applicant_id = er.applicant_id and so.submission_state='submitted' and area_key.area='opinion'
    ) x
  ) cnt on true
  where er.year = target_year and er.round = target_round and er.evaluation_active = true
  order by er.receipt_no, area_key.area;
end;
$$;

revoke execute on function public.get_evaluation_progress(int, admission_round) from anon;

-- ============================================================
-- 평가 준비 화면 (00066 원문에서 필요 제출 표시만 바꿈)
-- ============================================================

create or replace function public.get_evaluation_staffing(
  p_year int,
  p_round admission_round,
  p_stage text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_areas evaluation_area[];
  v_rev_id uuid;
  v_params jsonb;
  v_result jsonb;
  v_available jsonb;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_stage = 'document' then
    v_areas := array['attendance','academic','community','essay','opinion']::evaluation_area[];
  elsif p_stage = 'deep' then
    v_areas := array['group','interview','writing']::evaluation_area[];
  else
    raise exception '알 수 없는 평가 단계입니다: % (document 또는 deep)', p_stage
      using errcode = '22023';
  end if;

  select config_revision_id into v_rev_id
  from public.admission_rounds where year = p_year and round = p_round;
  if v_rev_id is not null then
    select scoring_params into v_params from public.config_revisions where id = v_rev_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'area', a.area,
    -- 배정해야 할 인원(운영 규정). 표에 값이 없으면 예전처럼 설정값을 쓴다.
    'requiredCount', coalesce(
      (select s.required_evaluators from public.evaluation_area_staffing s
        where s.year = p_year and s.round = p_round and s.area = a.area),
      (v_params -> a.area::text ->> 'requiredSubmissions')::int
    ),
    -- 채점 완료로 보기 위해 실제로 들어와야 하는 제출 건수(참고 표시용).
    -- 배정 인원과 다를 수 있다(예: 출결은 2명 배정, 1건 제출이면 완료).
    'requiredSubmissions', case when a.area in ('attendance','academic','community','essay','opinion')
      then public._document_required_submissions(p_year, p_round, a.area::text)
      else (v_params -> a.area::text ->> 'requiredSubmissions')::int end,
    'requiredRole', public._score_area_required_role(a.area)::text,
    'assigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uid', u.id, 'displayName', u.display_name, 'email', u.email,
        'roles', u.roles
      ) order by u.display_name)
      from public.users u
      where u.active = true and a.area = any(u.assigned_areas)
    ), '[]'::jsonb)
  ) order by ord), '[]'::jsonb)
  into v_result
  from unnest(v_areas) with ordinality as a(area, ord);

  select coalesce(jsonb_agg(jsonb_build_object(
    'uid', id, 'displayName', display_name, 'email', email,
    'roles', roles, 'assignedAreas', assigned_areas
  ) order by display_name), '[]'::jsonb)
  into v_available
  from public.users
  where active = true
    and roles && array['evaluator','quant']::app_role[];

  return jsonb_build_object(
    'stage', p_stage,
    'year', p_year,
    'round', p_round,
    'areas', v_result,
    'availableUsers', v_available
  );
end;
$$;

revoke all on function public.get_evaluation_staffing(int, admission_round, text) from public, anon;
grant execute on function public.get_evaluation_staffing(int, admission_round, text) to authenticated;
