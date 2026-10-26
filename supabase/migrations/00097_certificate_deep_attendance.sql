-- 새봄고 입학전형 시스템 — 심층역량평가 응시 확인서 (2026-10-21)
--
-- 중학교 출석 인정 제출용. 요청한 학생만 개별 발급한다.
--   대상: 2차 당일 입실 기록(deep_checkins)이 있는 지원자. 응시한 사실은 그 뒤 철회·제외와 무관하므로 상태로 거르지 않는다.
--   번호: 2027-응시-001 (학년도·종류별 연번, 첫 발급 때 정해져 바뀌지 않음)
-- 00096의 발급대장·RPC에 종류(deep_attendance)를 하나 더한다.

alter table public.certificate_issuances drop constraint if exists certificate_issuances_kind_check;
alter table public.certificate_issuances
  add constraint certificate_issuances_kind_check check (kind in ('deep_eligibility', 'final_pass', 'deep_attendance'));

create or replace function public._certificate_target_ids(p_year int, p_round admission_round, p_kind text)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_run uuid;
begin
  if p_kind = 'deep_attendance' then
    if not exists (select 1 from public.deep_checkins where year = p_year and round = p_round) then
      raise exception '아직 심층역량평가 입실 기록이 없습니다. 당일 입실 확인(바코드)을 한 학생만 응시 확인서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
    return query
      select c.applicant_id from public.deep_checkins c
      where c.year = p_year and c.round = p_round;
    return;
  elsif p_kind = 'deep_eligibility' then
    select document_decision_run_id into v_run
    from public.admission_rounds where year = p_year and round = p_round;
    if v_run is null then
      raise exception '1차 사정이 아직 확정되지 않았습니다. 확정한 뒤에 심층역량평가 대상 확인서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  elsif p_kind = 'final_pass' then
    select id into v_run
    from public.decision_runs
    where year = p_year and round = p_round and decision_type = 'final' and status = 'finalized'
    order by finalized_at desc
    limit 1;
    if v_run is null then
      raise exception '최종 사정이 아직 확정되지 않았습니다. 확정한 뒤에 합격증서를 뽑을 수 있습니다.' using errcode = '55000';
    end if;
  else
    raise exception '알 수 없는 증서 종류입니다: %', p_kind using errcode = '22023';
  end if;

  return query
    select dr.applicant_id
    from public.decision_results dr
    join public.applicants a on a.id = dr.applicant_id
    where dr.run_id = v_run
      and dr.outcome = 'passed'
      and a.application_status not in ('withdrawn', 'excluded');
end;
$$;

revoke all on function public._certificate_target_ids(int, admission_round, text) from public, anon, authenticated;

-- 항목에 입실 시각(checkedInAt)을 더한다
create or replace function public._certificate_items(p_year int, p_round admission_round, p_kind text, p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'applicantId', a.id,
           'examNo', a.exam_no,
           'name', a.name,
           'nameEnglish', a.name_english,
           'nationality', a.nationality,
           'birthDate', p.birth_date,
           'tracks', a.tracks,
           'school', a.school,
           'academicStatus', a.academic_status,
           'checkedInAt', dc.checked_in_at,
           'certNo', ci.cert_no,
           'printCount', coalesce(ci.print_count, 0),
           'firstIssuedAt', ci.first_issued_at,
           'lastPrintedAt', ci.last_printed_at
         ) order by a.exam_no nulls last, a.name), '[]'::jsonb)
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.deep_checkins dc on dc.applicant_id = a.id and dc.year = p_year and dc.round = p_round
  left join public.certificate_issuances ci
    on ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind
  where a.id = any(p_ids);
$$;

revoke all on function public._certificate_items(int, admission_round, text, uuid[]) from public, anon, authenticated;

-- 발급: 번호 형식에 '응시'를 더한 것 말고는 00096과 같다
create or replace function public.issue_certificates(p_year int, p_round admission_round, p_kind text, p_applicant_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_bad int;
  v_next int;
  v_new int := 0;
  r record;
begin
  caller := public._require_any_role(array['superadmin', 'admin']::app_role[]);
  if p_applicant_ids is null or cardinality(p_applicant_ids) = 0 then
    raise exception '발급할 지원자를 고르세요.' using errcode = '22023';
  end if;

  select count(*) into v_bad
  from unnest(p_applicant_ids) x(id)
  where x.id not in (select t from public._certificate_target_ids(p_year, p_round, p_kind) t);
  if v_bad > 0 then
    raise exception '발급 대상이 아닌 지원자가 %명 섞여 있습니다.', v_bad using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(format('cert:%s:%s', p_year, p_kind), 0));

  select coalesce(max(serial), 0) + 1 into v_next
  from public.certificate_issuances where year = p_year and kind = p_kind;

  for r in
    select a.id
    from public.applicants a
    where a.id = any(p_applicant_ids)
      and not exists (
        select 1 from public.certificate_issuances ci
        where ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind)
    order by a.exam_no nulls last, a.name
  loop
    insert into public.certificate_issuances
      (year, round, kind, applicant_id, serial, cert_no, first_issued_by, last_printed_by)
    values
      (p_year, p_round, p_kind, r.id, v_next,
       format('%s-%s-%s', p_year,
              case p_kind when 'deep_eligibility' then '심층' when 'deep_attendance' then '응시' else 'A-PASS' end,
              lpad(v_next::text, 3, '0')),
       caller, caller);
    v_next := v_next + 1;
    v_new := v_new + 1;
  end loop;

  update public.certificate_issuances
  set print_count = print_count + 1, last_printed_at = now(), last_printed_by = caller
  where year = p_year and round = p_round and kind = p_kind
    and applicant_id = any(p_applicant_ids)
    and first_issued_at < now();

  insert into public.audit_logs (year, round, actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values (p_year, p_round, 'user', caller::text, 'certificate.issued.' || p_kind, 'certificate_issuances',
          p_year::text || '_' || p_round::text,
          jsonb_build_object('count', cardinality(p_applicant_ids), 'newlyNumbered', v_new));

  return jsonb_build_object(
    'issuedAt', now(),
    'items', public._certificate_items(p_year, p_round, p_kind, p_applicant_ids)
  );
end;
$$;

revoke all on function public.issue_certificates(int, admission_round, text, uuid[]) from public, anon;
grant execute on function public.issue_certificates(int, admission_round, text, uuid[]) to authenticated;
