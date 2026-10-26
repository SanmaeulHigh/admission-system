// 접수증 안내 문자(SMS/LMS) 발송 Edge Function
//
// 접수증 화면(ReceiptPrint.jsx)에서 담당자가 "문자로 전송" 버튼을 눌러
// 수동으로 호출한다(자동 발송 아님). 지원자/보호자 연락처 중 선택한
// 대상에게 접수 완료 안내 문자를 보낸다.
//
// 그림문자(MMS) 전송은 지원하지 않는다 — 2026-07-14 확인 결과 문자나라
// 웹연동서비스(기본형)는 이미지 첨부 파라미터가 없고 "그림문자 지원X"로
// 명시돼 있다. 접수증 이미지는 PNG 저장 버튼으로 담당자가 직접 저장해서
// 별도 채널로 전달해야 한다.
//
// 인증: Supabase 플랫폼이 기본적으로 verify_jwt=true로 배포하므로, 이
// 함수가 호출되는 시점에는 이미 유효한 로그인 세션(Authorization 헤더)이
// 보장된다. 다만 "로그인만 하면 문자 발송 가능"은 과한 권한이므로,
// public.users에서 superadmin/admin/reception 역할을 가진 사용자인지
// 한 번 더 확인한다(접수 업무 담당자만 발송 가능).

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

const ALLOWED_ROLES = ["superadmin", "admin", "reception"];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
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

  // 2) 담당자 역할 확인 (superadmin/admin/reception만 발송 가능)
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

  const applicantId = typeof body.applicantId === "string" ? body.applicantId : null;
  const targets = Array.isArray(body.targets)
    ? body.targets.filter((t) => t === "applicant" || t === "guardian")
    : [];

  if (!applicantId || targets.length === 0) {
    return jsonResponse({ error: "applicantId, targets가 필요합니다." }, 400);
  }

  // 4) 지원자 정보 조회
  const { data: applicant, error: applicantErr } = await admin
    .from("applicants")
    .select(
      "id, year, name, receipt_no, applicants_private(applicant_phone, guardian_name, guardian_phone)",
    )
    .eq("id", applicantId)
    .maybeSingle();

  if (applicantErr || !applicant) {
    return jsonResponse({ error: "지원자를 찾을 수 없습니다." }, 404);
  }

  const private_ = Array.isArray(applicant.applicants_private)
    ? applicant.applicants_private[0]
    : applicant.applicants_private;

  const message =
    `[새봄고] ${applicant.name} 님(${applicant.year}학년도 신입생 입학전형) ` +
    `접수번호 ${applicant.receipt_no}로 접수가 완료되었습니다. ` +
    `서류평가 결과는 안내된 일정에 따라 개별 통지됩니다.`;

  // 지원자·보호자를 동시에 보낸다(차례로 보내면 응답이 늦을 때 시간 제한에 걸리기 쉽다)
  const results: Record<string, unknown> = {};
  const jobs: Promise<void>[] = [];
  if (targets.includes("applicant")) {
    jobs.push(sendSms({ phone: private_?.applicant_phone, message }).then((r) => { results.applicant = r; }));
  }
  if (targets.includes("guardian")) {
    jobs.push(sendSms({ phone: private_?.guardian_phone, message }).then((r) => { results.guardian = r; }));
  }
  await Promise.all(jobs);

  return jsonResponse({ results });
});
