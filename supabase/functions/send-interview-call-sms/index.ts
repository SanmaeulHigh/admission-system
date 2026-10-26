// 면접 호출 SMS 발송 Edge Function (2026-07-31)
//
// 면접 당일 대기실(본관 2층)에 있는 지원자·보호자에게 호출 문자를 보낸다.
//
// 호출 단위는 (지원자, 면접구분)이다.
// 2026-10-14 변경: 당일 지원자 휴대전화를 수거하므로 학생면접·보호자면접 모두 보호자 번호로 보낸다.
//   - 학생면접: 보호자에게 "자녀 ○○○ 학생면접 차례" 알림(학생은 진행요원이 데려간다)
//   - 보호자면접: 보호자에게 "○○로 와 주세요"
//   - 보호자 번호가 없으면 지원자 번호로 보내고 로그에 fallback_reason 을 남긴다.
// (targets를 명시하면 그대로 따른다 — 예외 상황에서 지원자에게 직접 보내야 할 때)
//
// 호출 종류는 두 가지:
//   advance : 앞 순서 진행 중에 미리 예고 — "곧 순서입니다, 준비해 주세요"
//   now     : "지금 면접실로 오세요"
//
// 권한 검증은 DB 쪽 _require_interview_call_permission이 담당한다(그 지원자가
// 배정된 면접조의 위원 또는 superadmin/admin). 여기서는 로그인 여부와 최소
// 역할만 1차로 거르고, 실제 조 배정 확인은 사용자 JWT로 호출하는 RPC에
// 맡긴다 — 권한 판단 로직을 DB 한 곳에만 두기 위해서다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { sendSms, smsByteLength } from "../_shared/smsProvider.ts";

const SMS_MAX_BYTES = 90;

// 후보 문구를 긴 것부터 시도해 단문(90byte, EUC-KR) 안에 드는 첫 문구를 쓴다.
// 모두 넘으면(아주 긴 외국 이름 등) 마지막 후보를 장문으로 보낸다.
async function pickMessage(candidates: string[]): Promise<string> {
  for (const m of candidates) {
    if (await smsByteLength(m) <= SMS_MAX_BYTES) return m;
  }
  return candidates[candidates.length - 1];
}

function buildCandidates(
  section: "student" | "parent",
  callType: "advance" | "now",
  name: string,
  examNo: string,
  location: string | null,
): string[] {
  const p = "[새봄고]";
  const who = `${name}(${examNo})`;
  const place = location?.trim() || null;
  if (section === "student") {
    return callType === "now"
      ? [
        `${p} 자녀 ${who} 학생면접 차례입니다. 지원자는 진행요원이 안내합니다.`,
        `${p} 자녀 ${who} 학생면접 차례입니다. 진행요원이 안내합니다.`,
        `${p} ${examNo} 학생면접 차례입니다. 진행요원이 안내합니다.`,
      ]
      : [
        `${p} 곧 자녀 ${who} 학생면접입니다. 대기실에서 기다려 주세요.`,
        `${p} 곧 자녀 ${who} 학생면접입니다.`,
        `${p} 곧 ${examNo} 학생면접입니다.`,
      ];
  }
  return callType === "now"
    ? [
      ...(place ? [`${p} ${who} 보호자 면접 차례입니다. ${place}로 와 주세요.`] : []),
      `${p} ${who} 보호자 면접 차례입니다. 면접실로 와 주세요.`,
      `${p} ${examNo} 보호자 면접 차례입니다. 면접실로 와 주세요.`,
    ]
    : [
      ...(place ? [`${p} 곧 ${who} 보호자 면접입니다. ${place} 앞에서 준비해 주세요.`] : []),
      `${p} 곧 ${who} 보호자 면접입니다. 준비해 주세요.`,
      `${p} 곧 ${examNo} 보호자 면접입니다. 준비해 주세요.`,
    ];
}

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

// 면접위원(evaluator)도 본인 조 지원자를 직접 호출할 수 있어야 한다.
const ALLOWED_ROLES = ["superadmin", "admin", "evaluator"];

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

  // 1) 호출자 인증 확인
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) {
    return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  }
  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) {
    return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  }

  const { data: profile, error: profileErr } = await admin
    .from("users")
    .select("roles, active")
    .eq("id", userRes.user.id)
    .maybeSingle();
  if (profileErr || !profile || !profile.active) {
    return jsonResponse({ error: "권한이 없습니다." }, 403);
  }
  const roles: string[] = profile.roles ?? [];
  if (!roles.some((r) => ALLOWED_ROLES.includes(r))) {
    return jsonResponse({ error: "권한이 없습니다." }, 403);
  }

  // 2) 요청 본문
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "요청 본문을 읽을 수 없습니다." }, 400);
  }

  const year = typeof body.year === "number" ? body.year : null;
  const round = typeof body.round === "string" ? body.round : null;
  const applicantId = typeof body.applicantId === "string" ? body.applicantId : null;
  const section = body.section === "student" || body.section === "parent" ? body.section : null;
  const callType = body.callType === "advance" || body.callType === "now" ? body.callType : null;

  if (!year || !round || !applicantId || !section || !callType) {
    return jsonResponse(
      { error: "year, round, applicantId, section, callType이 필요합니다." },
      400,
    );
  }

  // 기본 대상은 면접구분과 상관없이 보호자(지원자 휴대전화 수거). 명시하면 그대로 따른다.
  const explicitTargets = Array.isArray(body.targets)
    ? body.targets.filter((t) => t === "applicant" || t === "guardian")
    : [];
  const targets: string[] = explicitTargets.length > 0 ? explicitTargets : ["guardian"];

  // 사용자 JWT를 그대로 실은 클라이언트 — RPC 안에서 auth.uid()로 조 배정을
  // 확인해야 하므로 service role이 아니라 이쪽으로 호출한다.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  // 3) 연락처 조회 (여기서 조 배정·최종확정 여부까지 서버가 다시 검증한다)
  const { data: recipient, error: recipientErr } = await userClient.rpc(
    "get_interview_call_sms_recipient",
    { p_year: year, p_round: round, p_applicant_id: applicantId },
  );
  if (recipientErr || !recipient) {
    return jsonResponse(
      { error: recipientErr?.message ?? "지원자 연락처를 확인할 수 없습니다." },
      403,
    );
  }

  // 받는 사람은 보호자다. 자녀 이름과 수험번호(프로젝터 화면과 같은 번호)를 함께 적는다.
  const message = await pickMessage(
    buildCandidates(section, callType, recipient.name, recipient.examNo, recipient.location ?? null),
  );

  const results: Record<string, unknown> = {};

  for (const requested of targets) {
    let target = requested;
    let fallbackReason: string | null = null;
    // 보호자 번호가 없으면 지원자 번호로 대신 보낸다(번호 형식만 대략 확인 — 최종 판정은 sendSms)
    if (target === "guardian" && !String(recipient.guardianPhone ?? "").replace(/[^0-9]/g, "")) {
      target = "applicant";
      fallbackReason = "보호자 번호 없음 → 지원자 번호로 발송";
    }
    const phone = target === "applicant"
      ? recipient.applicantPhone
      : recipient.guardianPhone;
    const smsResult = await sendSms({ phone, message });
    results[requested] = { ...smsResult, actualTarget: target, fallbackReason };

    const { error: recordErr } = await userClient.rpc("record_interview_call_sms_sent", {
      p_year: year,
      p_round: round,
      p_applicant_id: applicantId,
      p_section: section,
      p_call_type: callType,
      p_target: target,
      p_sent: smsResult.sent,
      p_provider_code: smsResult.providerCode ?? null,
      p_provider_message: smsResult.providerMessage ?? smsResult.reason ?? null,
      p_fallback_reason: fallbackReason,
    });
    if (recordErr) {
      results[requested] = { ...(results[requested] as object), logError: recordErr.message };
    }
  }

  return jsonResponse({ results });
});
