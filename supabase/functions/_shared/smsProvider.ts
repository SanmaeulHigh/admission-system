// 문자나라(munjanara.co.kr) 연동 공용 헬퍼 — 텍스트(SMS/LMS) 전용
//
// 문자나라는 REST API/SDK가 아니라 GET 요청 하나(https://munjanara.co.kr/
// send.sys?userid=...&passwd=...&sender=...&receiver=...&message=...)로 끝나는
// 단순 구조다. 응답은 파이프(|)로 구분된 문자열이고 첫 필드가 결과코드다
// (9=성공, 그 외는 실패 — 아래 RESULT_CODE_MESSAGES 참고).
//
// 2026-07-14 확인: message를 UTF-8 그대로 보내면 수신 문자가 깨진다(구형
// 게이트웨이라 EUC-KR을 기대함 — 원래 PHP 샘플에도 iconv("UTF-8","EUC-KR")
// 단계가 있었다). 그래서 message만 EUC-KR로 인코딩한 바이트를 직접
// percent-encode해서 붙인다(URLSearchParams는 항상 UTF-8로 인코딩하므로
// message 필드에는 쓸 수 없음).
//
// 2026-07-14 확인: 이 상품(웹연동서비스 기본형)은 그림문자(MMS/포토문자)를
// 지원하지 않는다("그림문자 지원X") — 텍스트(단문 90byte/장문 2000byte)만
// 가능하다. 접수증 이미지를 함께 보내는 기능은 없다.
//
// 환경변수가 설정돼 있지 않으면 조용히 "미설정"으로 처리하고 절대 예외를
// 던지지 않는다 — SMS가 안 되더라도 호출부(접수증 화면)의 나머지 동작이
// 실패하면 안 되기 때문이다.
//
// 필요한 환경변수(Supabase 대시보드 → Edge Functions → Secrets):
//   MUNJANARA_USERID  — 문자나라 로그인 아이디
//   MUNJANARA_PASSWD  — 문자나라 "2차 비밀번호"(로그인 비밀번호와 다름 —
//                       문자나라 홈페이지 '개인정보수정'에서 API 발송용으로
//                       별도 설정)
//   SMS_SENDER_NUMBER — 문자나라에 사전 등록된 발신번호(숫자만)
// 셋 중 하나라도 없으면 발송을 스킵한다(부분 설정 상태로 어설프게 시도하지 않음).

export interface SmsSendResult {
  sent: boolean;
  reason?: "not_configured" | "provider_error" | "invalid_phone";
  providerCode?: string;
  providerMessage?: string;
}

// 문자나라 응답 결과코드 (가이드 표 그대로)
const RESULT_CODE_MESSAGES: Record<string, string> = {
  "9": "성공",
  "1": "필수값 누락",
  "2": "존재하지 않는 아이디",
  "3": "비밀번호 오류(2차 비밀번호 확인 필요)",
  "4": "잔액 부족",
  "6": "발신번호가 숫자로 이루어지지 않음",
  "7": "등록되지 않은 아이디",
  "11": "중복 발송(짧은 시간 내 동일 내용/번호 반복)",
  "12": "발신번호가 전화번호 규칙 또는 자릿수가 틀림",
  "13": "발신번호가 사전 등록되어 있지 않음",
  "14": "수신번호가 유효하지 않거나 등록되어 있지 않음",
  "15": "동일 내용 반복 발송 제한",
  "16": "예약시간이 유효하지 않음",
};

const PROVIDER_TIMEOUT_MS = 10_000;

function normalizePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const digits = raw.replace(/[^0-9]/g, "");
  // 한국 휴대전화 형식만 허용(010 등 + 8~9자리, 총 10~11자리) — 그 외는 스킵.
  if (!/^01[0-9]{8,9}$/.test(digits)) return null;
  return digits;
}

// EUC-KR로 인코딩한 바이트를 %XX 형태로 percent-encode한다(대문자 hex,
// RFC 3986 표준 percent-encoding과 동일한 표기).
function percentEncodeBytes(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) {
    out += "%" + b.toString(16).padStart(2, "0").toUpperCase();
  }
  return out;
}

async function callMunjanaraApi(
  userid: string,
  passwd: string,
  senderNumber: string,
  toPhone: string,
  message: string,
): Promise<{ ok: boolean; code: string; raw: string }> {
  const { default: iconv } = await import("npm:iconv-lite@0.6.3");
  const eucKrBytes: Uint8Array = iconv.encode(message, "euc-kr");

  // 장문(90byte 초과) 발송 여부 — 실제 전송 바이트(EUC-KR) 기준으로 판단해야
  // 한글 90byte 제한(45자)과 실제 일치한다(UTF-8 기준으로 재면 한 글자당
  // 3byte라 과대평가됨).
  const allowMms = eucKrBytes.length > 90 ? "1" : "0";

  const otherParams = new URLSearchParams({
    userid,
    passwd,
    sender: senderNumber,
    receiver: toPhone,
    encode: "1", // message를 URL 인코딩해서 보낸다는 표시
    end_alert: "0", // 자동화 호출이므로 문자나라 쪽 완료 팝업 알림은 끈다
    allow_mms: allowMms, // 장문허용(이름 그대로 사진과는 무관)
  });

  const url =
    `https://munjanara.co.kr/send.sys?${otherParams.toString()}` +
    `&message=${percentEncodeBytes(eucKrBytes)}`;

  // 2026-10-25: 문자나라 응답이 늦으면 Edge Function 전체가 시간 제한(wall clock)에 걸려
  // 강제 종료되고 화면에는 'non-2xx'만 떴다. 10초 안에 답이 없으면 끊고 '응답 없음'으로 돌려준다.
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), PROVIDER_TIMEOUT_MS);
  let ok = false;
  let raw = "";
  try {
    const res = await fetch(url, { method: "GET", signal: ctrl.signal });
    ok = res.ok;
    raw = (await res.text()).trim();
  } finally {
    clearTimeout(timer);
  }
  // 성공 응답 형식: "결과코드|잔여잔액|발송건수|예약유무|고객전달값" — 실패 시에는
  // 결과코드만 오는 경우도 있어 첫 필드만 신뢰한다.
  const code = raw.split("|")[0]?.trim() ?? "";
  return { ok: ok && code === "9", code, raw };
}

/** 단문 한도(90byte) 판단용 — 실제 전송과 같은 EUC-KR 기준 바이트 수 */
export async function smsByteLength(message: string): Promise<number> {
  const { default: iconv } = await import("npm:iconv-lite@0.6.3");
  return iconv.encode(message, "euc-kr").length;
}

/**
 * 임의의 텍스트 메시지를 SMS/LMS로 보낸다. 절대 예외를 던지지 않는다 —
 * 실패해도 { sent: false, reason } 로만 알려주고, 호출부가 나머지 흐름을
 * 정상적으로 이어가게 한다.
 */
export async function sendSms(params: {
  phone: string | null | undefined;
  message: string;
}): Promise<SmsSendResult> {
  const userid = Deno.env.get("MUNJANARA_USERID");
  const passwd = Deno.env.get("MUNJANARA_PASSWD");
  const senderNumber = Deno.env.get("SMS_SENDER_NUMBER");

  if (!userid || !passwd || !senderNumber) {
    console.log(
      "SMS 발송 스킵(미설정) — MUNJANARA_USERID/MUNJANARA_PASSWD/SMS_SENDER_NUMBER 중 하나 이상 없음.",
    );
    return { sent: false, reason: "not_configured" };
  }

  const toPhone = normalizePhone(params.phone);
  if (!toPhone) {
    return { sent: false, reason: "invalid_phone" };
  }

  try {
    const result = await callMunjanaraApi(userid, passwd, senderNumber, toPhone, params.message);
    if (!result.ok) {
      const providerMessage = RESULT_CODE_MESSAGES[result.code] ?? `알 수 없는 응답: ${result.raw}`;
      console.error(`SMS 발송 실패(결과코드=${result.code}: ${providerMessage})`);
      return {
        sent: false,
        reason: "provider_error",
        providerCode: result.code,
        providerMessage,
      };
    }
    return { sent: true };
  } catch (err) {
    const timedOut = err instanceof DOMException && err.name === "AbortError";
    console.error(timedOut ? "SMS 발송 시간 초과(문자나라 응답 없음)" : "SMS 발송 중 예외", err);
    return {
      sent: false,
      reason: "provider_error",
      providerMessage: timedOut
        ? "문자나라 서버가 10초 안에 응답하지 않았습니다(서버 PC의 인터넷 연결을 확인하세요)."
        : `문자나라 연결 오류: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
}
