// 수험번호 안내 SMS 발송 Edge Function (2026-09-28)
//
// 근거: 원서 접수 업무 진행 지침(2025.10.21.) 4-(2), 붙임 3 "수험번호 부여 SMS(예제)"
//   "원서 접수 마감 이후 3일 이내 개인별 연락처로 부여된 수험번호 안내"
//
// 문구는 붙임 3을 그대로 따른다. 줄바꿈이 있어 장문(LMS)으로 나간다
// (smsProvider가 길이를 보고 자동 판단한다).
//
// 생년월일/성별 줄(YYMMDD-X)은 붙임 3 양식에 있는 항목이다. 주민등록번호는
// 저장하지 않으므로 생년월일과 성별에서 뒷자리 첫 숫자를 계산한다.
//   내국인: 1900년대 남1·여2 / 2000년대 남3·여4
//   외국인: 1900년대 남5·여6 / 2000년대 남7·여8
// 생년월일이나 성별이 비어 있으면 그 줄은 빼고 보낸다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { sendSms } from "../_shared/smsProvider.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const ALLOWED_ROLES = ["superadmin", "admin"];

function formatReceiptDate(iso: string | null): string {
  if (!iso) return "-";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date(iso));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}. ${get("month")}. ${get("day")}.`;
}

function birthGenderLine(
  birthDate: string | null,
  gender: string | null,
  nationality: string | null,
): string | null {
  if (!birthDate || (gender !== "남" && gender !== "여")) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(birthDate);
  if (!m) return null;
  const year = Number(m[1]);
  const foreign = nationality && nationality !== "KOR";
  const male = gender === "남";
  let digit: number;
  if (year >= 2000) digit = foreign ? (male ? 7 : 8) : (male ? 3 : 4);
  else digit = foreign ? (male ? 5 : 6) : (male ? 1 : 2);
  return `${m[1].slice(2)}${m[2]}${m[3]}-${digit}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(supabaseUrl, serviceRoleKey);

  // 1) 호출자 인증 + 역할 확인
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return jsonResponse({ error: "로그인이 필요합니다." }, 401);

  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) return jsonResponse({ error: "로그인이 필요합니다." }, 401);

  const { data: profile } = await admin
    .from("users")
    .select("roles, active")
    .eq("id", userRes.user.id)
    .maybeSingle();
  const roles: string[] = profile?.roles ?? [];
  if (!profile?.active || !roles.some((r) => ALLOWED_ROLES.includes(r))) {
    return jsonResponse({ error: "권한이 없습니다." }, 403);
  }

  // 2) 요청 본문
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "요청 본문을 읽을 수 없습니다." }, 400);
  }
  const applicantId = typeof body.applicantId === "string" ? body.applicantId : null;
  const targets = Array.isArray(body.targets)
    ? body.targets.filter((t) => t === "applicant" || t === "guardian")
    : [];
  if (!applicantId || targets.length === 0) {
    return jsonResponse({ error: "applicantId, targets가 필요합니다." }, 400);
  }

  // 3) 지원자 정보 — 수험번호가 있어야만 보낸다
  const { data: applicant, error: appErr } = await admin
    .from("applicants")
    .select(
      "id, name, receipt_no, receipt_date, exam_no, nationality, application_status, " +
        "applicants_private(birth_date, gender, applicant_phone, guardian_phone)",
    )
    .eq("id", applicantId)
    .maybeSingle();
  if (appErr || !applicant) return jsonResponse({ error: "지원자를 찾을 수 없습니다." }, 404);
  if (!applicant.exam_no) {
    return jsonResponse({ error: "아직 수험번호가 부여되지 않은 지원자입니다." }, 400);
  }
  if (["withdrawn", "excluded"].includes(applicant.application_status)) {
    return jsonResponse({ error: "철회·제외된 지원자에게는 보낼 수 없습니다." }, 400);
  }

  const priv = Array.isArray(applicant.applicants_private)
    ? applicant.applicants_private[0]
    : applicant.applicants_private;

  // 4) 붙임 3 문구
  const bg = birthGenderLine(priv?.birth_date ?? null, priv?.gender ?? null, applicant.nationality);
  const lines = [
    "[새봄고등학교]",
    "접수해주신 입학원서에 대하여 수험번호가 부여되었음을 알려드립니다.",
    `접수번호 : ${applicant.receipt_no}`,
    `접수일자 : ${formatReceiptDate(applicant.receipt_date)}`,
    `성명 : ${applicant.name}`,
    ...(bg ? [`생년월일/성별 : ${bg}`] : []),
    `수험번호 : ${applicant.exam_no}`,
    "1단계 서류평가 진행 후 결과 발표에 대한 안내를 드리도록 하겠습니다. 감사합니다.",
  ];
  const message = lines.join("\n");

  // 기록 RPC는 auth.uid()로 호출자를 확인하므로 사용자 JWT를 실어 호출한다.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const results: Record<string, unknown> = {};
  for (const target of targets) {
    const phone = target === "applicant" ? priv?.applicant_phone : priv?.guardian_phone;
    const smsResult = await sendSms({ phone, message });
    results[target] = smsResult;

    const { error: recordErr } = await userClient.rpc("record_exam_no_sms_sent", {
      p_applicant_id: applicantId,
      p_target: target,
      p_sent: smsResult.sent,
      p_provider_code: smsResult.providerCode ?? null,
      p_provider_message: smsResult.providerMessage ?? smsResult.reason ?? null,
    });
    if (recordErr) results[target] = { ...smsResult, logError: recordErr.message };
  }

  return jsonResponse({ results });
});
