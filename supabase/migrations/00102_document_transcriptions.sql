-- 새봄고 입학전형 시스템 — 자기소개서·학부모 소견서 입력본(문항별 받아 적기) (2026-10-25)
--
-- 손글씨 자기소개서(서식 2, 9문항)·학부모 소견서(서식 3, 7문항)를 접수 담당·관리자가 문항별로 받아 적어 두면,
-- 서류 열람·채점 화면에서 위원이 원본 옆에 '입력본'으로 볼 수 있다.
--   · 입력: 최고관리자·관리자·접수 담당. 저장하면 바로 위원에게 보인다(검수 단계 없음, 2026-10-25 결정).
--   · 접수 담당은 받아 적기 위해 자기소개서·소견서 원본도 열람한다(_can_access_document_v2 보완).
--   · 열람: 위 세 역할 + 그 서류 종류를 열람할 수 있는 위원(평가위원·정량평가·학교장 — 00076/00082 규칙 그대로).
--   · 원문 그대로 옮긴다(맞춤법을 고치지 않음, 읽을 수 없는 글자는 [판독불가]). 원본과 다르면 원본이 우선.
--   · 저장할 때마다 이력(document_transcription_history)을 남긴다. 1차 사정이 확정된 뒤에는 관리자만 고칠 수 있다.
--   · 위원이 입력본을 열면 서류 열람과 같이 감사 기록(transcription.viewed)을 남긴다.

-- 0. 접수 담당도 자기소개서·학부모 소견서 원본을 열람(받아 적기용). 나머지 규칙은 00082 그대로.
create or replace function public._can_access_document_v2(
  p_applicant_id uuid,
  p_document_type document_type,
  p_doc_classification document_classification,
  p_doc_access_areas evaluation_area[]
)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_active_user() then
    return false;
  end if;
  if public.has_role('superadmin') or public.has_role('admin') then
    return true;
  end if;
  if p_doc_classification = 'adminOnly' then
    return false;
  end if;
  if p_doc_classification = 'reception' and public.has_role('reception') then
    return true;
  end if;
  -- 2026-10-25(00102): 접수 담당이 자기소개서·학부모 소견서를 받아 적으려면 원본을 봐야 한다
  if p_document_type in ('essay', 'opinion') and public.has_role('reception') then
    return true;
  end if;
  if not (public.has_role('quant') or public.has_role('evaluator') or public.has_role('principal')) then
    return false;
  end if;

  return exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and (u.viewable_document_types is null
           or p_document_type = any(u.viewable_document_types))
  );
end;
$$;
revoke execute on function public._can_access_document_v2(uuid, document_type, document_classification, evaluation_area[]) from anon;

create table if not exists public.document_transcriptions (
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  document_type text not null check (document_type in ('essay', 'opinion')),
  answers jsonb not null default '{}'::jsonb,   -- {"1": "…", "2": "…"}
  completed boolean not null default false,     -- 입력 담당이 '입력 끝'으로 표시
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users (id),
  primary key (applicant_id, document_type)
);

create table if not exists public.document_transcription_history (
  id bigserial primary key,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  document_type text not null,
  answers jsonb not null,
  completed boolean not null,
  saved_at timestamptz not null default now(),
  saved_by uuid references public.users (id)
);
create index if not exists document_transcription_history_idx
  on public.document_transcription_history (applicant_id, document_type, saved_at desc);

alter table public.document_transcriptions enable row level security;
alter table public.document_transcription_history enable row level security;
revoke all on public.document_transcriptions from anon, authenticated;
revoke all on public.document_transcription_history from anon, authenticated;

-- 1. 읽기
create or replace function public.get_document_transcription(p_applicant_id uuid, p_document_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff boolean;
  v_row record;
  v_app record;
begin
  if not public.is_active_user() then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  if p_document_type not in ('essay', 'opinion') then
    raise exception '입력본이 없는 서류 종류입니다.' using errcode = '22023';
  end if;

  v_staff := public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception');
  if not v_staff and not public._can_access_document_v2(
       p_applicant_id, p_document_type::document_type, 'evaluation'::document_classification, '{}'::evaluation_area[]) then
    raise exception '이 서류를 열람할 권한이 없습니다.' using errcode = '42501';
  end if;

  select * into v_row from public.document_transcriptions
  where applicant_id = p_applicant_id and document_type = p_document_type;

  if not v_staff and v_row.applicant_id is not null then
    select year, round into v_app from public.applicants where id = p_applicant_id;
    insert into public.audit_logs
      (year, round, actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
    values
      (v_app.year, v_app.round, 'user', auth.uid()::text, 'transcription.viewed', 'document_transcriptions',
       p_applicant_id::text || ':' || p_document_type, p_applicant_id::text);
  end if;

  if v_row.applicant_id is null then
    return jsonb_build_object('exists', false);
  end if;
  return jsonb_build_object(
    'exists', true,
    'answers', v_row.answers,
    'completed', v_row.completed,
    'updatedAt', v_row.updated_at
  );
end;
$$;

revoke all on function public.get_document_transcription(uuid, text) from public, anon;
grant execute on function public.get_document_transcription(uuid, text) to authenticated;

-- 2. 저장(통째로 덮어쓰기 + 이력)
create or replace function public.save_document_transcription(
  p_applicant_id uuid, p_document_type text, p_answers jsonb, p_completed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_app record;
  v_clean jsonb := '{}'::jsonb;
  k text;
  v text;
  v_max int;
begin
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  if p_document_type not in ('essay', 'opinion') then
    raise exception '입력본이 없는 서류 종류입니다.' using errcode = '22023';
  end if;
  v_max := case p_document_type when 'essay' then 9 else 7 end;

  select a.id, a.year, a.round into v_app from public.applicants a where a.id = p_applicant_id;
  if v_app.id is null then
    raise exception '지원자를 찾을 수 없습니다.' using errcode = 'P0002';
  end if;

  -- 1차 사정이 확정된 뒤에는 관리자만
  if exists (select 1 from public.admission_rounds r
             where r.year = v_app.year and r.round = v_app.round and r.document_decision_run_id is not null)
     and not (public.has_role('superadmin') or public.has_role('admin')) then
    raise exception '1차 사정이 확정되어 입력본은 관리자만 고칠 수 있습니다.' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_answers, '{}'::jsonb)) <> 'object' then
    raise exception '입력 형식이 올바르지 않습니다.' using errcode = '22023';
  end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_answers, '{}'::jsonb)) loop
    if k !~ '^[0-9]+$' or k::int < 1 or k::int > v_max then
      raise exception '없는 문항 번호입니다: %', k using errcode = '22023';
    end if;
    if char_length(v) > 20000 then
      raise exception '%번 문항이 너무 깁니다.', k using errcode = '22023';
    end if;
    if btrim(v) <> '' then
      v_clean := v_clean || jsonb_build_object(k, v);
    end if;
  end loop;

  insert into public.document_transcriptions (applicant_id, document_type, answers, completed, updated_at, updated_by)
  values (p_applicant_id, p_document_type, v_clean, coalesce(p_completed, false), now(), caller)
  on conflict (applicant_id, document_type) do update
    set answers = excluded.answers, completed = excluded.completed, updated_at = now(), updated_by = caller;

  insert into public.document_transcription_history (applicant_id, document_type, answers, completed, saved_by)
  values (p_applicant_id, p_document_type, v_clean, coalesce(p_completed, false), caller);

  return jsonb_build_object('savedAt', now(), 'filled', (select count(*) from jsonb_object_keys(v_clean)));
end;
$$;

revoke all on function public.save_document_transcription(uuid, text, jsonb, boolean) from public, anon;
grant execute on function public.save_document_transcription(uuid, text, jsonb, boolean) to authenticated;

-- 3. 입력 현황(접수 담당 이상)
create or replace function public.list_transcription_status(p_year int, p_round admission_round)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'applicantId', a.id,
      'receiptNo', a.receipt_no,
      'examNo', a.exam_no,
      'name', a.name,
      'hasEssay', exists (select 1 from public.admission_documents d where d.applicant_id = a.id and d.document_type = 'essay' and d.active),
      'hasOpinion', exists (select 1 from public.admission_documents d where d.applicant_id = a.id and d.document_type = 'opinion' and d.active),
      'essay', (select jsonb_build_object('filled', (select count(*) from jsonb_object_keys(t.answers)), 'completed', t.completed, 'updatedAt', t.updated_at)
                from public.document_transcriptions t where t.applicant_id = a.id and t.document_type = 'essay'),
      'opinion', (select jsonb_build_object('filled', (select count(*) from jsonb_object_keys(t.answers)), 'completed', t.completed, 'updatedAt', t.updated_at)
                  from public.document_transcriptions t where t.applicant_id = a.id and t.document_type = 'opinion')
    ) order by coalesce(a.exam_no, a.receipt_no))
    from public.applicants a
    where a.year = p_year and a.round = p_round and a.application_status not in ('withdrawn', 'excluded')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_transcription_status(int, admission_round) from public, anon;
grant execute on function public.list_transcription_status(int, admission_round) to authenticated;
