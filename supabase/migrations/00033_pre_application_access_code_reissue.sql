-- 새봄고 입학전형 시스템 — M8d(일부) 관리자 조회코드 재발급 + SMS 재발송
-- 담당 교사 요청: "6자리 조회코드를 관리자 화면에서 조회할 수 있으면 좋겠다.
-- 학부모 전화 문의가 많을 것 같다" — 조회코드는 원문 미저장(해시만 저장,
-- 00024)이라 "조회"는 불가능하다. 대신 관리자가 새 코드를 발급하고(기존
-- 코드는 즉시 무효화) 바로 문자로 재발송하는 기능으로 대체한다. 관리자도
-- 새 코드를 화면으로 보지 않는다 — 시스템이 만들어서 바로 발송만 한다.
--
-- 접수 완료 시점 자동발송(같은 요청의 다른 절반)은 Edge Function 쪽
-- (create-pre-application/index.ts + _shared/smsProvider.ts)에서 처리한다 —
-- 그쪽은 이미 원문 코드를 들고 있는 시점이라 별도 RPC가 필요 없다.
--
-- ⚠️ 실행 전/후 액션 아이템:
--   1) 00032에서 이미 등록했다면 pre_application_edge_functions_base_url은
--      재등록할 필요 없다(그대로 재사용).
--   2) 이 마이그레이션 실행 후, SQL Editor에서 새 비밀 1개를 Vault에 등록:
--
--        select vault.create_secret(
--          '<32바이트 이상의 무작위 문자열>',
--          'pre_application_sms_secret',
--          'M8 send-pre-application-sms Edge Function 호출 인증용 공유 비밀'
--        );
--
--      무작위 값은 select encode(gen_random_bytes(32), 'base64'); 로 만든다.
--      (00032의 pre_application_cron_secret과 다른 값을 쓴다 — 기능별로
--      비밀을 분리해서, 하나가 새어도 다른 하나까지 뚫리지 않게 한다.)
--   3) 같은 값을 Edge Function 환경변수로도 설정:
--        supabase secrets set PRE_APPLICATION_SMS_SECRET=<위와 동일한 값>
--   4) send-pre-application-sms Edge Function을 배포한다.
--   5) 실제 문자 발송 자체는 SMS_PROVIDER_ENDPOINT/SMS_PROVIDER_API_KEY/
--      SMS_SENDER_NUMBER가 설정되기 전까지는 "발송 스킵"으로 조용히
--      끝난다(_shared/smsProvider.ts 참고) — 문자 API 계정이 준비되면
--      그 3개 시크릿만 추가로 설정하면 된다.

create or replace function public.reissue_pre_application_access_code(
  p_pre_application_no text,
  p_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  app_row record;
  new_code text;
  base_url text;
  sms_secret text;
  masked_phone text;
  phone_len int;
begin
  -- 접수(reception)·관리자(admin)·최고관리자(superadmin)만 — 평가위원 등은 불가.
  caller := public._require_any_role(array['superadmin', 'admin', 'reception']::app_role[]);

  select pa.id, pa.pre_application_no, pa.status, pp.name,
         coalesce(pp.applicant_phone, pp.guardian_phone) as phone
  into app_row
  from public.pre_applications pa
  left join public.pre_applications_private pp on pp.pre_application_id = pa.id
  where pa.pre_application_no = p_pre_application_no
  for update of pa;

  if app_row is null then
    raise exception '사전작성 데이터를 찾을 수 없습니다.';
  end if;

  if app_row.status in ('converted', 'expired') then
    raise exception '이미 전환되었거나 만료된 사전작성은 조회코드를 재발급할 수 없습니다.';
  end if;

  if app_row.phone is null or length(trim(app_row.phone)) = 0 then
    raise exception '등록된 연락처(본인 또는 보호자)가 없어 문자로 재발송할 수 없습니다.';
  end if;

  -- 새 코드 발급 — set_pre_application_access_code가 기존 코드를 즉시
  -- 무효화하고(verifier_version 증가) 실패횟수/잠금도 초기화한다(00024).
  new_code := public._generate_pre_application_access_code();
  perform public.set_pre_application_access_code(app_row.id, new_code);

  perform public._record_pre_application_event(
    app_row.id, app_row.pre_application_no, 'preApplication.accessCode.reissued', 'admin',
    caller, jsonb_build_object('reason', p_reason)
  );
  -- 원문 코드/전화번호는 이벤트 metadata에도 절대 남기지 않는다.

  select decrypted_secret into base_url
  from vault.decrypted_secrets where name = 'pre_application_edge_functions_base_url';
  select decrypted_secret into sms_secret
  from vault.decrypted_secrets where name = 'pre_application_sms_secret';

  if base_url is null or sms_secret is null then
    raise exception 'Vault에 pre_application_edge_functions_base_url/pre_application_sms_secret이 없습니다. SQL Editor에서 vault.create_secret(...)으로 먼저 등록하세요 (마이그레이션 파일 상단 주석 참고).'
      using errcode = 'config_file_error';
  end if;

  -- 비동기(fire-and-forget) 호출 — 새 코드는 이 요청 본문에만 실려서
  -- send-pre-application-sms Edge Function으로 전달되고, 이 함수는 이후
  -- 어디에도 원문을 남기지 않는다.
  perform net.http_post(
    url => base_url || '/send-pre-application-sms',
    body => jsonb_build_object(
      'phone', app_row.phone,
      'name', app_row.name,
      'preApplicationNo', app_row.pre_application_no,
      'code', new_code
    ),
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', sms_secret
    ),
    timeout_milliseconds => 10000
  );

  -- 관리자 화면에는 마스킹된 연락처만 돌려준다(원문 코드/전체 전화번호 노출 금지).
  phone_len := char_length(app_row.phone);
  masked_phone := left(app_row.phone, 3)
    || repeat('*', greatest(phone_len - 7, 0))
    || right(app_row.phone, least(4, greatest(phone_len - 3, 0)));

  return json_build_object(
    'reissuedAt', now(),
    'maskedPhone', masked_phone
  );
end;
$$;

revoke all on function public.reissue_pre_application_access_code(text, text) from public, anon;
grant execute on function public.reissue_pre_application_access_code(text, text) to authenticated;

comment on function public.reissue_pre_application_access_code(text, text) is
  '관리자가 6자리 조회코드를 "조회"할 수는 없다(원문 미저장, 00024) — 대신 이
   함수가 새 코드를 발급하고 즉시 SMS로 재발송한다. 반환값에는 마스킹된
   전화번호만 담기고, 원문 코드/전체 전화번호는 호출자(관리자)에게도 절대
   노출하지 않는다. 실제 발송은 send-pre-application-sms Edge Function이
   담당(pg_net으로 비동기 호출).';
