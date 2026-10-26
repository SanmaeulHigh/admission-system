// 1단계(서류평가) 결과 개별 통보 SMS 발송 Edge Function (2026-10-13)
//
// 1단계 사정 화면(DocumentDecisionPage)의 "1단계 결과 SMS 발송"에서 호출한다.
// send-final-result-sms 와 같은 구조다:
//   * 확정(finalized)된 1차(decision_type='document') 사정 결과만 사용
//   * 합격·불합격 문구는 여기서 확정 결과(outcome)를 직접 읽어 고른다
//   * 발송 결과는 record_document_result_sms_sent RPC로 기록(사용자 JWT로 호출)
// 2단계 심층역량평가 날짜는 화면이 요강 일정에서 읽어 넘긴다(deepDate, 예: "11. 14.(토)").
// 날짜가 없거나 형식이 이상하면 날짜 문장을 빼고 "추후 안내"로 보낸다.

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

  // 2) 담당자 역할 확인 (superadmin/admin만 — 1단계 사정 화면과 동일한 권한)
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

  // 3) 요청 본문
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "요청 본문을 읽을 수 없습니다." }, 400);
  }

  const runId = typeof body.runId === "string" ? body.runId : null;
  const applicantId = typeof body.applicantId === "string" ? body.applicantId : null;
  const targets = Array.isArray(body.targets)
    ? body.targets.filter((t) => t === "applicant" || t === "guardian")
    : [];

  // 2단계 날짜: "11. 14.(토)" 같은 짧은 글자만 받는다
  const rawDeepDate = typeof body.deepDate === "string" ? body.deepDate.trim() : "";
  const deepDate = /^[0-9 .()월화수목금토일]{4,20}$/.test(rawDeepDate) ? rawDeepDate : "";

  if (!runId || !applicantId || targets.length === 0) {
    return jsonResponse({ error: "runId, applicantId, targets가 필요합니다." }, 400);
  }

  // 4) 확정된 1단계 사정 + 판정 검증 — 이 두 조건이 아니면 절대 발송하지 않는다.
  const { data: run, error: runErr } = await admin
    .from("decision_runs")
    .select("id, decision_type, status")
    .eq("id", runId)
    .maybeSingle();
  if (runErr || !run || run.decision_type !== "document" || run.status !== "finalized") {
    return jsonResponse({ error: "확정된 1단계 사정(run) 결과가 아닙니다." }, 400);
  }

  const { data: decisionResult, error: drErr } = await admin
    .from("decision_results")
    .select("outcome")
    .eq("run_id", runId)
    .eq("applicant_id", applicantId)
    .maybeSingle();
  const outcome = decisionResult?.outcome;
  if (drErr || !decisionResult || (outcome !== "passed" && outcome !== "failed")) {
    return jsonResponse({ error: "확정된 1단계 사정에서 합격 또는 불합격으로 판정된 지원자에게만 통보할 수 있습니다." }, 400);
  }

  // 5) 지원자 연락처 조회
  const { data: applicant, error: applicantErr } = await admin
    .from("applicants")
    .select(
      "id, name, year, receipt_no, exam_no, applicants_private(applicant_phone, guardian_name, guardian_phone)",
    )
    .eq("id", applicantId)
    .maybeSingle();
  if (applicantErr || !applicant) {
    return jsonResponse({ error: "지원자를 찾을 수 없습니다." }, 404);
  }

  const private_ = Array.isArray(applicant.applicants_private)
    ? applicant.applicants_private[0]
    : applicant.applicants_private;

  const name = applicant.name;
  const year = applicant.year;
  const numbers = applicant.exam_no
    ? `(접수번호 ${applicant.receipt_no} · 수험번호 ${applicant.exam_no})`
    : `(접수번호 ${applicant.receipt_no})`;
  const deepLine = deepDate
    ? `2단계 심층역량평가는 ${deepDate}에 실시하며, 입실 시간은 추후 안내드립니다.`
    : `2단계 심층역량평가 일정과 입실 시간은 추후 안내드립니다.`;
  const messages: Record<string, string> = outcome === "passed"
    ? {
      applicant:
        `[새봄고등학교] ${name} 님, ${year}학년도 새봄고등학교 신입생 입학전형 1단계 서류평가에 합격하셨습니다. 축하드립니다! ` +
        `${deepLine} 당일 수험표와 신분증을 꼭 지참해 주세요. ` +
        `자세한 내용은 학교 홈페이지 공지사항을 확인해 주세요. ${numbers}`,
      guardian:
        `[새봄고등학교] ${name} 학생이 ${year}학년도 새봄고등학교 신입생 입학전형 1단계 서류평가에 합격하였습니다. ` +
        `${deepLine} 당일 수험표와 신분증을 꼭 챙겨 주세요. ` +
        `자세한 내용은 학교 홈페이지 공지사항을 확인해 주시기 바랍니다. ${numbers}`,
    }
    : {
      applicant:
        `[새봄고등학교] ${name} 님, ${year}학년도 신입생 입학전형에 보여주신 관심과 정성에 깊이 감사드립니다. ` +
        `아쉽게도 1단계 서류평가에서 함께하지 못하게 되었음을 알려드립니다. ` +
        `지원서에 담아 준 고민과 노력은 앞으로의 길에서도 소중한 힘이 될 것입니다. ` +
        `${name} 님의 내일을 진심으로 응원합니다. ${numbers}`,
      guardian:
        `[새봄고등학교] ${year}학년도 신입생 입학전형에 ${name} 학생과 함께 정성껏 지원해 주셔서 깊이 감사드립니다. ` +
        `아쉽게도 1단계 서류평가에서 함께하지 못하게 되었음을 알려드립니다. ` +
        `너그러이 헤아려 주시기를 바라며, 학생의 앞날을 진심으로 응원하겠습니다. ${numbers}`,
    };

  // record_document_result_sms_sent RPC는 auth.uid()로 호출자를 확인하므로,
  // service role이 아니라 사용자 JWT를 그대로 실어 보낸 클라이언트로 호출한다.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const results: Record<string, unknown> = {};

  for (const target of targets) {
    const phone = target === "applicant" ? private_?.applicant_phone : private_?.guardian_phone;
    const smsResult = await sendSms({ phone, message: messages[target] });
    results[target] = smsResult;

    const { error: recordErr } = await userClient.rpc("record_document_result_sms_sent", {
      p_run_id: runId,
      p_applicant_id: applicantId,
      p_target: target,
      p_sent: smsResult.sent,
      p_provider_code: smsResult.providerCode ?? null,
      p_provider_message: smsResult.providerMessage ?? smsResult.reason ?? null,
    });
    if (recordErr) {
      results[target] = { ...smsResult, logError: recordErr.message };
    }
  }

  return jsonResponse({ outcome, results });
});
