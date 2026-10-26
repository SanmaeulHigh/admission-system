-- 새봄고 입학전형 시스템 — 서류평가 중간 점검용 채점 품질 집계 (2026-10-16)
--
-- 채점기준표 Ⅴ 운영: "중간 점검(10. 23., 10. 30.) — 편차 경보가 잦은 기준과 모든 기준이 같은 점수인
-- 채점을 확인하고, 필요하면 위원 협의를 거침"
--   · 위원별: 제출 건수, 모든 기준을 같은 점수로 준 건수
--   · 기준별: 평균, 위원 간 점수 차가 큰 지원자 수(자기소개서 3점 이상, 소견서 1.5점 이상)
-- 지원자 이름·수험번호는 내보내지 않는다(기준 해석 협의용 집계만).

create or replace function public.get_document_scoring_quality(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb := '{}'::jsonb;
  v_area text;
  v_gap numeric;
  v_evaluators jsonb;
  v_criteria jsonb;
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);

  foreach v_area in array array['essay', 'opinion'] loop
    v_gap := case when v_area = 'essay' then 3 else 1.5 end;

    execute format($q$
      with s as (
        select applicant_id, evaluator_uid, items
        from public.%I
        where year = $1 and round = $2 and submission_state = 'submitted'
      ),
      per_eval as (
        select s.evaluator_uid,
               count(*) as submitted,
               count(*) filter (where (select count(distinct (v)::numeric) from jsonb_each_text(s.items) e(k, v)) = 1) as all_same
        from s group by s.evaluator_uid
      )
      select coalesce(jsonb_agg(jsonb_build_object(
               'evaluatorName', u.display_name, 'submitted', p.submitted, 'allSame', p.all_same)
             order by p.all_same desc, u.display_name), '[]'::jsonb)
      from per_eval p join public.users u on u.id = p.evaluator_uid
    $q$, 'scores_' || v_area)
    into v_evaluators using p_year, p_round;

    execute format($q$
      with s as (
        select applicant_id, evaluator_uid, items
        from public.%I
        where year = $1 and round = $2 and submission_state = 'submitted'
      ),
      cells as (
        select s.applicant_id, e.k as criterion, (e.v)::numeric as score
        from s cross join lateral jsonb_each_text(s.items) e(k, v)
      ),
      per_app as (
        select criterion, applicant_id, max(score) - min(score) as gap, count(*) as n
        from cells group by criterion, applicant_id
      )
      select coalesce(jsonb_agg(jsonb_build_object(
               'key', c.criterion,
               'avg', round(c.avg_score, 2),
               'wideGapCount', c.wide,
               'applicantCount', c.apps)
             order by c.wide desc, c.criterion), '[]'::jsonb)
      from (
        select a.criterion,
               (select avg(score) from cells x where x.criterion = a.criterion) as avg_score,
               count(*) filter (where a.n >= 2 and a.gap >= $3) as wide,
               count(*) filter (where a.n >= 2) as apps
        from per_app a group by a.criterion
      ) c
    $q$, 'scores_' || v_area)
    into v_criteria using p_year, p_round, v_gap;

    v_result := v_result || jsonb_build_object(v_area, jsonb_build_object(
      'gapThreshold', v_gap, 'evaluators', v_evaluators, 'criteria', v_criteria));
  end loop;

  return v_result;
end;
$$;

revoke all on function public.get_document_scoring_quality(int, admission_round) from public, anon;
grant execute on function public.get_document_scoring_quality(int, admission_round) to authenticated;
