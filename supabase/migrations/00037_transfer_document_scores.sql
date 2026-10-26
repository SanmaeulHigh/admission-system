-- 새봄고 전·편입생 선발 전형(공고 2026-40호) — 1차 서류전형 채점(1000점)
--
-- 요강 4번 전형방법 그대로:
--   ① 학교생활기록부(300점) = 출결(200) + 학업성실도(100)
--   ② 자기소개서(자필, 500) + 보호자소견서(200) = 700점
-- 총 1000점. 2차 면접(별도 전형)은 이번 마이그레이션 범위 밖 — 원서 접수
-- (7/13~16) 이후 서류전형(7/20~22)에 맞춰 나중에 추가한다.
--
-- 신입생 M3a/b(scores_attendance/scores_academic)와 달리 이 전형은
-- 평가위원별 제출·평균 집계 구조가 아니라 학교(전편입학위원회)가 서류를
-- 검토해 확정 점수 하나를 입력하는 방식이라 지원자 1인당 1행이면 충분하다
-- (unique(applicant_id), evaluator_uid 없음). 출결·학업성실도는 요강의
-- 점수표를 그대로 서버에서 계산하고(클라이언트가 계산한 값은 신뢰하지
-- 않음 — 마스터스펙 5.1 원칙과 동일), 자기소개서·보호자소견서는 서면
-- 평가라 점수를 직접 입력받되 배점 상한만 서버가 검증한다.
--
-- config_revisions.scoring_params 체계는 신입생 다회차·연도별 재사용을
-- 위한 것이라 이번 단발성 전편입 전형에는 과한 설계라 판단해 채택하지
-- 않았다 — 요강 점수표를 RPC에 직접 반영한다(향후 매년 반복되는 정례
-- 전형이 되면 그때 config화 검토).

create table public.transfer_document_scores (
  applicant_id uuid primary key references public.transfer_applicants (id) on delete cascade,

  -- 출결(200점). record_type: schoolRecord(일반 계산) | ged(검정고시 출신, 180점 고정)
  -- | noRecord(중학교 학생부 미제출, 0점).
  attendance_record_type text check (attendance_record_type in ('schoolRecord', 'ged', 'noRecord')),
  attendance_inputs jsonb,
  attendance_score numeric check (attendance_score is null or (attendance_score >= 0 and attendance_score <= 200)),

  -- 학업성실도(100점). record_type: schoolRecord(성취도 A~E) | ged(원점수 구간환산)
  -- | equivalentNoRecord(동등학력 인정자 중 학생부 미제출, 70점 고정).
  academic_record_type text check (academic_record_type in ('schoolRecord', 'ged', 'equivalentNoRecord')),
  academic_inputs jsonb,
  academic_score numeric check (academic_score is null or (academic_score >= 0 and academic_score <= 100)),

  -- 자기소개서(자필)·보호자소견서 — 서면 평가, 직접 입력(상한만 서버 검증)
  self_intro_score numeric check (self_intro_score is null or (self_intro_score >= 0 and self_intro_score <= 500)),
  guardian_opinion_score numeric check (guardian_opinion_score is null or (guardian_opinion_score >= 0 and guardian_opinion_score <= 200)),

  updated_at timestamptz not null default now(),
  updated_by text
);

comment on table public.transfer_document_scores is
  '전편입학 1차 서류전형(1000점 만점) 채점 결과. 총점 = attendance_score + academic_score + self_intro_score + guardian_opinion_score(널 항목은 미채점으로 취급, 화면에서 0으로 합산하지 않는다).';

alter table public.transfer_document_scores enable row level security;

create policy transfer_document_scores_select_staff
  on public.transfer_document_scores for select
  using (
    public.has_role('superadmin') or public.has_role('admin') or public.has_role('reception')
  );

-- write는 전부 아래 RPC 전용(정책 없음)

-- ============================================================
-- 1. submit_transfer_attendance_score — 출결 200점
-- ============================================================

create or replace function public.submit_transfer_attendance_score(
  p_applicant_id uuid,
  p_record_type text,
  p_unexcused_absences int default null,
  p_other_event_count int default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  effective_days int;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'noRecord') then
    raise exception '알 수 없는 출결 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'ged' then
    computed_score := 180; -- 요강: 중학교 졸업학력 검정고시 출신자는 180점
    effective_days := null;
  elsif p_record_type = 'noRecord' then
    computed_score := 0;   -- 요강: 중학교 학교생활기록부 미제출자는 0점
    effective_days := null;
  else
    if p_unexcused_absences is null or p_unexcused_absences < 0
       or p_other_event_count is null or p_other_event_count < 0 then
      raise exception '미인정 결석 일수·조퇴/지각/결과 횟수는 0 이상의 정수여야 합니다.';
    end if;
    -- 요강: 미인정 조퇴·지각·결과 3회 = 미인정 결석 1일로 환산
    effective_days := p_unexcused_absences + floor(p_other_event_count::numeric / 3);
    -- 요강 점수표: 결석 0일=200점, 1일당 -10점, 20일 이상=0점
    -- (200 - 10*일수를 0 이상으로 clamp하면 표의 모든 행과 정확히 일치함)
    computed_score := greatest(0, 200 - 10 * effective_days);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, attendance_record_type, attendance_inputs, attendance_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object(
       'unexcusedAbsences', p_unexcused_absences,
       'otherEventCount', p_other_event_count,
       'effectiveAbsenceDays', effective_days
     ),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    attendance_record_type = excluded.attendance_record_type,
    attendance_inputs = excluded.attendance_inputs,
    attendance_score = excluded.attendance_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.attendance.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score, 'effectiveAbsenceDays', effective_days);
end;
$$;

revoke execute on function public.submit_transfer_attendance_score(uuid, text, int, int) from anon;

-- ============================================================
-- 2. submit_transfer_academic_score — 학업성실도 100점
--    p_subjects: [{"subject":"국어","achievement":"A"}] (schoolRecord) 또는
--                [{"subject":"국어","rawScore":85}] (ged) — 서버가 상위 5개 선정·합산
-- ============================================================

create or replace function public.submit_transfer_academic_score(
  p_applicant_id uuid,
  p_record_type text,
  p_subjects jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  subj jsonb;
  points numeric;
  points_list numeric[] := '{}';
  top5_sum numeric;
  computed_score numeric;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_record_type not in ('schoolRecord', 'ged', 'equivalentNoRecord') then
    raise exception '알 수 없는 학업성실도 기록 유형입니다: %', p_record_type;
  end if;

  if p_record_type = 'equivalentNoRecord' then
    -- 요강: 고1 중 중학교 졸업자와 동등 학력 인정자 중 학교생활기록부 미제출자 = 70점
    computed_score := 70;
  else
    if jsonb_array_length(p_subjects) = 0 then
      raise exception '과목 데이터가 없습니다.';
    end if;

    for subj in select * from jsonb_array_elements(p_subjects)
    loop
      if p_record_type = 'schoolRecord' then
        -- 요강 표: A=20, B=16, C=8, D=4, E=2
        points := case subj ->> 'achievement'
          when 'A' then 20 when 'B' then 16 when 'C' then 8
          when 'D' then 4 when 'E' then 2
          else null
        end;
        if points is null then
          raise exception '알 수 없는 성취도 값: %', subj ->> 'achievement';
        end if;
      else
        declare
          raw numeric := (subj ->> 'rawScore')::numeric;
        begin
          if raw is null or raw < 0 or raw > 100 then
            raise exception '검정고시 원점수는 0~100 사이여야 합니다: %', subj ->> 'rawScore';
          end if;
          -- 요강 표: ~60=2, 61~70=4, 71~80=8, 81~90=16, 91~100=20
          points := case
            when raw <= 60 then 2
            when raw <= 70 then 4
            when raw <= 80 then 8
            when raw <= 90 then 16
            else 20
          end;
        end;
      end if;
      points_list := array_append(points_list, points);
    end loop;

    -- 상위 5과목 선정·합산은 서버만 수행(클라이언트가 미리 고르지 않음 — M3b와 동일 원칙)
    select coalesce(sum(v), 0) into top5_sum
    from (select v from unnest(points_list) as v order by v desc limit 5) t;

    computed_score := least(top5_sum, 100);
  end if;

  insert into public.transfer_document_scores
    (applicant_id, academic_record_type, academic_inputs, academic_score, updated_at, updated_by)
  values
    (p_applicant_id, p_record_type,
     jsonb_build_object('subjects', p_subjects),
     computed_score, now(), caller::text)
  on conflict (applicant_id) do update set
    academic_record_type = excluded.academic_record_type,
    academic_inputs = excluded.academic_inputs,
    academic_score = excluded.academic_score,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.academic.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object('score', computed_score);
end;
$$;

revoke execute on function public.submit_transfer_academic_score(uuid, text, jsonb) from anon;

-- ============================================================
-- 3. submit_transfer_essay_scores — 자기소개서(500)·보호자소견서(200)
--    서면 평가 결과를 직접 입력(전편입학위원회가 합의한 점수). 서버는
--    배점 상한만 검증한다.
-- ============================================================

create or replace function public.submit_transfer_essay_scores(
  p_applicant_id uuid,
  p_self_intro_score numeric default null,
  p_guardian_opinion_score numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
begin
  caller := public._require_any_role(array['superadmin','admin','reception']::app_role[]);

  if not exists (select 1 from public.transfer_applicants where id = p_applicant_id) then
    raise exception '지원자를 찾을 수 없습니다.';
  end if;
  if p_self_intro_score is not null and (p_self_intro_score < 0 or p_self_intro_score > 500) then
    raise exception '자기소개서 점수는 0~500 사이여야 합니다.';
  end if;
  if p_guardian_opinion_score is not null and (p_guardian_opinion_score < 0 or p_guardian_opinion_score > 200) then
    raise exception '보호자소견서 점수는 0~200 사이여야 합니다.';
  end if;

  insert into public.transfer_document_scores
    (applicant_id, self_intro_score, guardian_opinion_score, updated_at, updated_by)
  values
    (p_applicant_id, p_self_intro_score, p_guardian_opinion_score, now(), caller::text)
  on conflict (applicant_id) do update set
    self_intro_score = coalesce(excluded.self_intro_score, public.transfer_document_scores.self_intro_score),
    guardian_opinion_score = coalesce(excluded.guardian_opinion_score, public.transfer_document_scores.guardian_opinion_score),
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, applicant_id)
  values
    ('user', caller::text, 'transferScore.essays.submitted', 'transfer_document_scores',
     p_applicant_id::text, p_applicant_id::text);

  return json_build_object(
    'selfIntroScore', p_self_intro_score,
    'guardianOpinionScore', p_guardian_opinion_score
  );
end;
$$;

revoke execute on function public.submit_transfer_essay_scores(uuid, numeric, numeric) from anon;
