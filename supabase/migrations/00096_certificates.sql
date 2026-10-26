-- 새봄고 입학전형 시스템 — 심층역량평가 대상 확인서 · 합격증서 발급 (2026-10-20)
--
-- 학교에서 인쇄해 전달한다(우편·직접). 발급할 때마다 발급대장에 남기고, 번호는 처음 발급할 때 매긴다.
--   심층역량평가 대상 확인서(deep_eligibility): 1차 사정이 '확정'된 뒤, 그 결과의 합격자만   — 번호 2027-심층-001
--   합격증서(final_pass)                     : 최종 사정이 '확정'된 뒤, 그 결과의 합격자만   — 번호 2027-A-PASS-001
--   두 경우 모두 지원 철회·제외(합격 취소·등록 포기 포함 처리)된 지원자는 뽑을 수 없다.
-- 번호는 학년도·종류별로 이어서 센다(추가모집 회차도 같은 순번을 이어 쓴다 — 번호가 겹치지 않게).
-- 처음 발급하는 사람들끼리는 수험번호 순으로 번호를 받는다. 다시 뽑으면 번호는 그대로, 인쇄 횟수만 는다.

create table if not exists public.certificate_issuances (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  kind text not null check (kind in ('deep_eligibility', 'final_pass')),
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  serial int not null check (serial > 0),
  cert_no text not null unique,
  first_issued_at timestamptz not null default now(),
  first_issued_by uuid references public.users (id),
  last_printed_at timestamptz not null default now(),
  last_printed_by uuid references public.users (id),
  print_count int not null default 1,
  unique (year, round, kind, applicant_id),
  unique (year, kind, serial)
);

comment on table public.certificate_issuances is
  '확인서·합격증서 발급대장. 번호(cert_no)는 첫 발급 때 정해지고 바뀌지 않는다. RPC로만 읽고 쓴다.';

alter table public.certificate_issuances enable row level security;
revoke all on table public.certificate_issuances from anon, authenticated;

-- 대상자(확정 결과의 합격자, 철회·제외 제외). 확정 전이면 오류.
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
  if p_kind = 'deep_eligibility' then
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
           'certNo', ci.cert_no,
           'printCount', coalesce(ci.print_count, 0),
           'firstIssuedAt', ci.first_issued_at,
           'lastPrintedAt', ci.last_printed_at
         ) order by a.exam_no nulls last, a.name), '[]'::jsonb)
  from public.applicants a
  left join public.applicants_private p on p.applicant_id = a.id
  left join public.certificate_issuances ci
    on ci.applicant_id = a.id and ci.year = p_year and ci.round = p_round and ci.kind = p_kind
  where a.id = any(p_ids);
$$;

revoke all on function public._certificate_items(int, admission_round, text, uuid[]) from public, anon, authenticated;

-- 1. 대상 목록(발급 여부·번호 포함). 확정 전이면 ready=false + 사유.
create or replace function public.list_certificate_targets(p_year int, p_round admission_round, p_kind text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  perform public._require_any_role(array['superadmin', 'admin']::app_role[]);
  begin
    select array_agg(t) into v_ids from public._certificate_target_ids(p_year, p_round, p_kind) t;
  exception when sqlstate '55000' then
    return jsonb_build_object('ready', false, 'reason', sqlerrm);
  end;
  return jsonb_build_object('ready', true, 'items', public._certificate_items(p_year, p_round, p_kind, coalesce(v_ids, '{}')));
end;
$$;

revoke all on function public.list_certificate_targets(int, admission_round, text) from public, anon;
grant execute on function public.list_certificate_targets(int, admission_round, text) to authenticated;

-- 2. 발급(인쇄 직전에 부른다): 처음이면 번호를 매기고, 이미 있으면 인쇄 횟수만 늘린다.
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

  -- 대상이 아닌 지원자가 섞였는지(확정 전이면 여기서 오류)
  select count(*) into v_bad
  from unnest(p_applicant_ids) x(id)
  where x.id not in (select t from public._certificate_target_ids(p_year, p_round, p_kind) t);
  if v_bad > 0 then
    raise exception '발급 대상이 아닌 지원자가 %명 섞여 있습니다(확정 결과의 합격자만, 철회·제외 제외).', v_bad using errcode = '42501';
  end if;

  -- 같은 종류 번호를 동시에 매기지 않게
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
       case when p_kind = 'deep_eligibility'
            then format('%s-심층-%s', p_year, lpad(v_next::text, 3, '0'))
            else format('%s-A-PASS-%s', p_year, lpad(v_next::text, 3, '0')) end,
       caller, caller);
    v_next := v_next + 1;
    v_new := v_new + 1;
  end loop;

  update public.certificate_issuances
  set print_count = print_count + 1, last_printed_at = now(), last_printed_by = caller
  where year = p_year and round = p_round and kind = p_kind
    and applicant_id = any(p_applicant_ids)
    and first_issued_at < now(); -- 이번에 새로 만든 행(now() 동일)은 1회 그대로

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
