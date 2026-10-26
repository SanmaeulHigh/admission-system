-- 새봄고 입학전형 시스템 — M7b 내보내기 이력·체크섬 (Sprint 7 계속)
-- 마스터 스펙 v1.2 섹션 3.23 "내보내기 이력"(exports/{exportId}) 대응.
--
-- 스펙 원안은 Firestore + Storage 기준으로 generatedFilePath(서버 저장 경로)를
-- 포함하지만, 이 프로젝트는 서버 함수 없이 클라이언트가 직접 XLSX/CSV를
-- 생성해 즉시 다운로드하는 구조다(검토메모에서 이미 확정된 제약). 그래서
-- 파일을 서버에 남기지 않고, "무엇을 언제 누가 어떤 소스 데이터 기준으로
-- 내보냈는지 + 체크섬"만 기록한다 — 나중에 "그때 그 파일이 이 데이터와
-- 일치하는가"를 사후 검증할 수 있는 최소한의 증거로 충분하다.
--
-- checksum은 클라이언트에서 생성된 파일 바이트를 SHA-256으로 해시해 전달한다
-- (브라우저 Web Crypto API, 서버 재계산 없음 — 파일 자체가 서버에 없으므로
-- 서버가 재계산할 방법이 없다. 클라이언트 신뢰가 전제이며, 이는 감사로그
-- 전반의 "actor가 주장하는 사실을 기록"이라는 기존 원칙과 동일하다).

create type export_type as enum
  ('receiptLedger', 'documentResult', 'finalResultSms', 'finalResultWebsite',
   'committeePacket', 'scoreWorkbook', 'educationOffice');

create table public.exports (
  id uuid primary key default gen_random_uuid(),
  year int not null,
  round admission_round not null,
  export_type export_type not null,
  file_format text not null,
  checksum_sha256 text not null,
  decision_run_id uuid references public.decision_runs (id),
  config_revision_id uuid references public.config_revisions (id),
  row_count int,
  metadata jsonb not null default '{}'::jsonb,
  generated_by text not null,
  generated_at timestamptz not null default now()
);

comment on table public.exports is
  '내보내기(다운로드) 이력. 파일 자체는 서버에 저장하지 않는다(클라이언트 직접
   생성·다운로드 구조) — 무엇을 언제 누가 어떤 decisionRun/configRevision
   기준으로 내보냈는지와 체크섬만 남겨 사후 검증 근거로 삼는다.';

alter table public.exports enable row level security;

create policy exports_select_admins
  on public.exports for select
  using (public.has_role('superadmin') or public.has_role('admin'));

-- write 정책 없음: RPC 전용.

-- ============================================================
-- log_export — 클라이언트가 파일 생성·다운로드 직후 호출
-- ============================================================

create or replace function public.log_export(
  p_year int,
  p_round admission_round,
  p_export_type export_type,
  p_file_format text,
  p_checksum_sha256 text,
  p_decision_run_id uuid default null,
  p_config_revision_id uuid default null,
  p_row_count int default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  v_id uuid;
begin
  caller := public._require_any_role(array['superadmin','admin']::app_role[]);

  if p_checksum_sha256 is null or length(trim(p_checksum_sha256)) <> 64 then
    raise exception 'checksum_sha256은 64자 hex 문자열이어야 합니다.' using errcode = '55000';
  end if;

  insert into public.exports
    (year, round, export_type, file_format, checksum_sha256, decision_run_id,
     config_revision_id, row_count, metadata, generated_by)
  values
    (p_year, p_round, p_export_type, p_file_format, lower(trim(p_checksum_sha256)),
     p_decision_run_id, p_config_revision_id, p_row_count, p_metadata, caller::text)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.log_export(int, admission_round, export_type, text, text, uuid, uuid, int, jsonb) from public, anon;
grant execute on function public.log_export(int, admission_round, export_type, text, text, uuid, uuid, int, jsonb) to authenticated;

-- ============================================================
-- get_export_history — 조회
-- ============================================================

create or replace function public.get_export_history(
  p_year int default null,
  p_round admission_round default null,
  p_export_type export_type default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total int;
begin
  perform public._require_any_role(array['superadmin','admin']::app_role[]);

  select count(*) into v_total
  from public.exports e
  where (p_year is null or e.year = p_year)
    and (p_round is null or e.round = p_round)
    and (p_export_type is null or e.export_type = p_export_type);

  return jsonb_build_object(
    'totalCount', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'year', e.year,
        'round', e.round,
        'exportType', e.export_type,
        'fileFormat', e.file_format,
        'checksumSha256', e.checksum_sha256,
        'decisionRunId', e.decision_run_id,
        'decisionRunStatus', dr.status,
        'decisionRunMode', dr.mode,
        'configRevisionId', e.config_revision_id,
        'rowCount', e.row_count,
        'metadata', e.metadata,
        'generatedByName', u.display_name,
        'generatedAt', e.generated_at
      ) order by e.generated_at desc)
      from (
        select * from public.exports e
        where (p_year is null or e.year = p_year)
          and (p_round is null or e.round = p_round)
          and (p_export_type is null or e.export_type = p_export_type)
        order by e.generated_at desc
        limit v_limit offset v_offset
      ) e
      left join public.users u on u.id::text = e.generated_by
      left join public.decision_runs dr on dr.id = e.decision_run_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_export_history(int, admission_round, export_type, int, int) from public, anon;
grant execute on function public.get_export_history(int, admission_round, export_type, int, int) to authenticated;
