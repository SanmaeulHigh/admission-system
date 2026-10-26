-- 새봄고 입학전형 시스템 — M3f 관리자 모니터 (Sprint 3 마무리)
-- 마스터 스펙 v1.2 섹션 3.18(evaluationAlerts), 6.10(개별점수 상세조회) 대응.
--
-- 이번 마이그레이션에서 바로잡는 것: Sprint 3 앞부분(00005/00006)에서
-- scoresXxx 테이블에 superadmin/admin의 SELECT를 그냥 열어뒀는데, 스펙은
-- "관리자 기본 UI는 aggregate/alert만 사용, 개별점수는 사유기록+감사로그
-- 후 별도 Function으로만" (2463행, 2592행)이라고 명시한다. 여기서
-- 정책을 교체해 admin의 직접 테이블 조회를 막고, 사유 기반 Function으로만
-- 개별점수를 볼 수 있게 한다.

-- ============================================================
-- 1. evaluation_alerts (섹션 3.18)
-- ============================================================

create type alert_type as enum
  ('scoreGap', 'missingSubmission', 'primaryObserverMissing', 'invalidScore', 'aggregationBlocked');
create type alert_severity as enum ('info', 'warning', 'blocking');
create type alert_status as enum ('open', 'acknowledged', 'resolved');

create table public.evaluation_alerts (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  area evaluation_area not null,
  alert_type alert_type not null,
  severity alert_severity not null default 'warning',
  summary text not null,
  related_evaluator_uids uuid[] not null default '{}',
  status alert_status not null default 'open',
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolved_by text,
  unique (year, round, applicant_id, area, alert_type)
);

comment on table public.evaluation_alerts is
  '평가위원은 절대 읽을 수 없다 (섹션 3.18). 관리자 대시보드는 개별점수보다 이 경보·제출상태를 우선 표시한다.';

alter table public.evaluation_alerts enable row level security;

create policy evaluation_alerts_select_admins
  on public.evaluation_alerts for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write는 정책 없음 = 아래 recompute RPC로만

-- ============================================================
-- 2. scoresXxx 관리자 blanket SELECT 제거 — 개별점수 비노출 원칙 강화
--    (Sprint 3 앞부분에서 admin에게 그냥 열어뒀던 것을 여기서 좁힌다)
-- ============================================================

drop policy if exists scores_attendance_select_own_or_admin on public.scores_attendance;
drop policy if exists scores_academic_select_own_or_admin on public.scores_academic;
drop policy if exists scores_community_select_own_or_admin on public.scores_community;
drop policy if exists scores_essay_select_own_or_admin on public.scores_essay;
drop policy if exists scores_opinion_select_own_or_admin on public.scores_opinion;

create policy scores_attendance_select_own on public.scores_attendance for select using (evaluator_uid = auth.uid());
create policy scores_academic_select_own on public.scores_academic for select using (evaluator_uid = auth.uid());
create policy scores_community_select_own on public.scores_community for select using (evaluator_uid = auth.uid());
create policy scores_essay_select_own on public.scores_essay for select using (evaluator_uid = auth.uid());
create policy scores_opinion_select_own on public.scores_opinion for select using (evaluator_uid = auth.uid());

-- 이제 admin/superadmin이 개별점수를 보려면 반드시 아래
-- get_evaluation_score_detail (사유기록 + 감사로그)을 거쳐야 한다.
-- reopen_score 등 기존 RPC는 SECURITY DEFINER라 이 RLS 강화와 무관하게 계속 동작한다.

-- ============================================================
-- 3. get_evaluation_score_detail — 사유 기반 개별점수 상세조회 (섹션 6.10)
-- ============================================================

create or replace function public.get_evaluation_score_detail(
  p_applicant_id uuid,
  p_area evaluation_area,
  p_target_evaluator_uid uuid,
  p_reason_code text,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  caller_doc record;
  score_row record;
  result jsonb;
  valid_reasons text[] := array['편차 경보 확인', '입력 오류 확인', '입학전형위원회 협의', '이의·감사 대응', '기타'];
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if not (p_reason_code = any(valid_reasons)) then
    raise exception '알 수 없는 사유코드입니다: %', p_reason_code;
  end if;
  if p_reason_code = '기타' and (p_reason_text is null or length(trim(p_reason_text)) = 0) then
    raise exception '사유가 "기타"인 경우 reason_text를 반드시 입력해야 합니다.';
  end if;

  select * into caller_doc from public.users where id = caller;

  -- 관리자 자신이 동일영역 evaluator이고 본인 미제출이면 타 위원 점수 열람 거부.
  -- 반드시 요청한 p_area 하나만 확인한다 (다른 영역 제출 여부로 착각하면 안 됨).
  if p_area = any(caller_doc.assigned_areas) and (caller_doc.roles && array['evaluator','quant']::app_role[]) then
    declare
      already_submitted boolean := false;
    begin
      if p_area = 'attendance' then
        select exists(select 1 from public.scores_attendance
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'academic' then
        select exists(select 1 from public.scores_academic
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'community' then
        select exists(select 1 from public.scores_community
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'essay' then
        select exists(select 1 from public.scores_essay
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      elsif p_area = 'opinion' then
        select exists(select 1 from public.scores_opinion
          where applicant_id = p_applicant_id and evaluator_uid = caller and submission_state = 'submitted')
          into already_submitted;
      end if;

      if not already_submitted then
        raise exception '본인 평가를 제출하기 전에는 같은 영역의 다른 위원 점수를 열람할 수 없습니다.';
      end if;
    end;
  end if;

  if p_area = 'attendance' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_attendance
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'academic' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_academic
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'community' then
    select applicant_id, evaluator_uid, inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_community
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'essay' then
    select applicant_id, evaluator_uid, items as inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_essay
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  elsif p_area = 'opinion' then
    select applicant_id, evaluator_uid, items as inputs, server_computed, submission_state, submitted_at
      into score_row from public.scores_opinion
      where applicant_id = p_applicant_id and evaluator_uid = p_target_evaluator_uid;
  else
    raise exception '개별점수 상세조회를 지원하지 않는 영역입니다: %', p_area;
  end if;

  if score_row is null then
    raise exception '해당 채점 문서를 찾을 수 없습니다.';
  end if;

  result := jsonb_build_object(
    'applicantId', score_row.applicant_id,
    'evaluatorUid', score_row.evaluator_uid,
    'inputs', score_row.inputs,
    'serverComputed', score_row.server_computed,
    'submissionState', score_row.submission_state,
    'submittedAt', score_row.submitted_at
  );

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id, area, reason_code, metadata)
  values
    ('user', caller::text, 'score.detail_viewed', 'scores_' || p_area::text, p_target_evaluator_uid::text,
     p_applicant_id::text, p_area, p_reason_code,
     jsonb_build_object('reasonText', p_reason_text));

  return result::json;
end;
$$;

revoke execute on function public.get_evaluation_score_detail(uuid, evaluation_area, uuid, text, text) from anon;

-- ============================================================
-- 4. recompute_evaluation_alerts — 경보 재계산 (superadmin/admin 트리거)
--    scoreGap(essay/opinion), missingSubmission(전 영역) 감지.
--    이미 open인 동일 경보는 유지, 더 이상 유효하지 않으면 자동 resolved.
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
           (params -> area_key.area ->> 'requiredSubmissions')::int as required,
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

-- ============================================================
-- 5. get_evaluation_progress — 위원별 진행률 (개별점수 노출 없이 카운트만)
-- ============================================================

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
    (params -> area_key.area ->> 'requiredSubmissions')::int as required,
    coalesce(cnt.submitted, 0)::int as submitted,
    coalesce(cnt.submitted, 0) >= coalesce((params -> area_key.area ->> 'requiredSubmissions')::int, 0) as complete,
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
