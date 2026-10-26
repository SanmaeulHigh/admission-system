-- 새봄고 입학전형 시스템 — M8c 원서 준비·접수 조회 (Sprint 1B #6)
-- 마스터 스펙 1389행 M8c, `M8_아키텍처_결정_2026-07-10.md` 3.1/9절 불변조건 5 대응.
--
-- get_pre_application_status: 회원가입 없이 임시접수번호+성명+6자리 조회코드로
-- 인증한 뒤, 마스터스펙 1393~1404행이 정한 "표시 가능 정보"만 반환한다.
-- 주소·전화번호·보호자 정보·등기번호 원문·관리자 메모·평가정보는 절대
-- 반환하지 않는다 — 이 함수 자체가 그 경계를 강제한다(pre_applications_private/
-- pre_application_secrets 컬럼은 여기서 단 하나도 select하지 않는다).

create or replace function public.get_pre_application_status(
  p_pre_application_no text,
  p_name text,
  p_raw_code text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  auth_ok boolean;
  app_row record;
  priv_name text;
  masked_name text;
  current_step text;
begin
  auth_ok := public.verify_pre_application_access(p_pre_application_no, p_name, p_raw_code);
  if not auth_ok then
    return null;
  end if;

  select *
  into app_row
  from public.pre_applications
  where pre_application_no = p_pre_application_no;

  if not found then
    return null;
  end if;

  -- 파기(30일 경과)로 private 행이 이미 삭제됐을 수 있다 — 그 경우 인증 시
  -- 입력한 성명으로 마스킹한다(어차피 verify가 이름 일치를 확인했으므로 안전).
  select name into priv_name
  from public.pre_applications_private
  where pre_application_id = app_row.id;

  masked_name := left(coalesce(priv_name, p_name), 1)
    || repeat('*', greatest(char_length(coalesce(priv_name, p_name)) - 1, 0));

  current_step := case app_row.status
    when 'completed' then '출력서류 생성 대기'
    when 'bundleGenerated' then '제출 준비/발송'
    when 'arrived' then '제출서류 검수 대기'
    when 'reviewing' then '제출서류 검수 중'
    when 'supplementRequired' then '보완 필요'
    when 'converted' then '원서접수 완료'
    when 'expired' then '접수기간 만료'
    else '확인 필요'
  end;

  return json_build_object(
    'maskedName', masked_name,
    'preApplicationNo', app_row.pre_application_no,
    'completedAt', app_row.created_at,
    'status', app_row.status,
    'receiptMethod', app_row.receipt_method,
    'bundleGeneratedAt', app_row.print_bundle ->> 'lastGeneratedAt',
    'bundleGenerationCount', coalesce((app_row.print_bundle ->> 'generationCount')::int, 0),
    'shippingRegistered', (app_row.shipping ? 'trackingNumber'),
    'arrivalConfirmed', (app_row.arrival ? 'confirmedAt'),
    'documentReviewStatus', app_row.document_review ->> 'publicStatus',
    'converted', (app_row.status = 'converted'),
    'finalApplicationNo', app_row.conversion ->> 'receiptNo',
    'currentStep', current_step
  );
end;
$$;

revoke execute on function public.get_pre_application_status(text, text, text)
  from public, anon, authenticated;

comment on function public.get_pre_application_status(text, text, text) is
  '반환 필드는 마스터스펙 1393~1404행 "표시 가능 정보" 목록을 그대로 따른다.
   주소·전화번호·보호자 정보·등기번호 원문·관리자 메모·평가정보는 절대 포함
   하지 않는다 — 이 함수를 감싸는 Edge Function도 이 목록을 넘어서는 필드를
   추가로 조회·반환하면 안 된다.';
