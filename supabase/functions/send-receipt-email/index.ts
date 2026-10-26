// 접수증 PDF 이메일 발송 Edge Function (2026-10-25)
//
// 접수증 화면(ReceiptPrint.jsx)에서 담당자가 [이메일로 보내기]를 눌러 수동으로 호출한다(자동 발송 아님).
//  · PDF는 브라우저가 만들어 보낸다(연락처를 뺀 메일용 판). 받는 주소는 화면이 보낸 값이 아니라
//    DB(applicants_private.email)에서 다시 읽는다 — 다른 주소로 새어 나가지 않게.
//  · 메일 서버는 일반 SMTP. 학교 입학전형 메일 계정(구글·네이버웍스 등)의 SMTP를 쓴다.
//  · 담당자(superadmin/admin/reception)만. 보낼 때마다 감사 기록(receipt.emailed).
//
// 필요한 비밀값(서버의 functions .env 또는 docker-compose 환경변수):
//   SMTP_HOST       예) smtp.gmail.com
//   SMTP_PORT       예) 465 (SSL) 또는 587 (STARTTLS)
//   SMTP_USER       보내는 계정 주소
//   SMTP_PASS       앱 비밀번호(구글은 2단계 인증 후 '앱 비밀번호' 발급)
//   SMTP_FROM_NAME  (선택) 보내는 사람 이름, 기본 '새봄고등학교 입학전형'
// 하나라도 없으면 보내지 않고 not_configured로 알려 준다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import nodemailer from "npm:nodemailer@6.9.14";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const ALLOWED_ROLES = ["superadmin", "admin", "reception"];
const MAX_PDF_BYTES = 8 * 1024 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function maskEmail(email: string) {
  const [local, domain] = email.split("@");
  const head = local.slice(0, 2);
  return `${head}${"*".repeat(Math.max(1, local.length - 2))}@${domain}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(supabaseUrl, serviceRoleKey);

  // 1) 호출자 확인
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  const { data: profile } = await admin.from("users").select("roles, active").eq("id", userRes.user.id).maybeSingle();
  if (!profile?.active || !(profile.roles ?? []).some((r: string) => ALLOWED_ROLES.includes(r))) {
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
  const pdfBase64 = typeof body.pdfBase64 === "string" ? body.pdfBase64 : null;
  if (!applicantId || !pdfBase64) return jsonResponse({ error: "applicantId, pdfBase64가 필요합니다." }, 400);

  let pdfBytes: Uint8Array;
  try {
    pdfBytes = Uint8Array.from(atob(pdfBase64), (c) => c.charCodeAt(0));
  } catch {
    return jsonResponse({ error: "PDF 데이터가 올바르지 않습니다." }, 400);
  }
  if (pdfBytes.length > MAX_PDF_BYTES) return jsonResponse({ error: "PDF가 너무 큽니다." }, 400);
  if (!(pdfBytes[0] === 0x25 && pdfBytes[1] === 0x50 && pdfBytes[2] === 0x44 && pdfBytes[3] === 0x46)) {
    return jsonResponse({ error: "PDF 파일이 아닙니다." }, 400);
  }

  // 3) 지원자·받는 주소(DB에서)
  const { data: applicant } = await admin
    .from("applicants")
    .select("id, year, round, name, receipt_no, applicants_private(email)")
    .eq("id", applicantId)
    .maybeSingle();
  if (!applicant) return jsonResponse({ error: "지원자를 찾을 수 없습니다." }, 404);
  const priv = Array.isArray(applicant.applicants_private) ? applicant.applicants_private[0] : applicant.applicants_private;
  const to = String(priv?.email ?? "").trim();
  if (!EMAIL_RE.test(to)) return jsonResponse({ result: { sent: false, reason: "invalid_email" } });

  // 4) SMTP 설정
  const host = Deno.env.get("SMTP_HOST");
  const port = Number(Deno.env.get("SMTP_PORT") ?? "465");
  const user = Deno.env.get("SMTP_USER");
  const pass = Deno.env.get("SMTP_PASS");
  const fromName = Deno.env.get("SMTP_FROM_NAME") || "새봄고등학교 입학전형";
  if (!host || !user || !pass) {
    return jsonResponse({ result: { sent: false, reason: "not_configured" } });
  }

  const transporter = nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: { user, pass },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000,
  });

  const subject = `[새봄고] ${applicant.year}학년도 신입생 입학전형 접수증 (${applicant.receipt_no})`;
  const text =
    `${applicant.name} 님, 새봄고등학교 ${applicant.year}학년도 신입생 입학전형 원서가 접수되었습니다.\n\n` +
    `접수번호: ${applicant.receipt_no}\n` +
    `접수증을 첨부합니다. 수험번호는 원서 접수 마감 후 개별 안내됩니다.\n\n` +
    `이 메일은 발신 전용입니다. 문의는 학교 교무실로 해 주세요.\n` +
    `새봄고등학교`;

  let result: Record<string, unknown>;
  try {
    await transporter.sendMail({
      from: { name: fromName, address: user },
      to,
      subject,
      text,
      attachments: [{ filename: `접수증_${applicant.receipt_no}.pdf`, content: pdfBytes, contentType: "application/pdf" }],
    });
    result = { sent: true, to: maskEmail(to) };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("접수증 메일 발송 실패", msg);
    result = { sent: false, reason: "smtp_error", message: msg.slice(0, 300) };
  }

  await admin.from("audit_logs").insert({
    year: applicant.year,
    round: applicant.round,
    actor_type: "user",
    actor_uid: userRes.user.id,
    action: result.sent ? "receipt.emailed" : "receipt.email_failed",
    resource_type: "applicants",
    resource_id: applicant.id,
    applicant_id: applicant.id,
    metadata: { to: maskEmail(to), bytes: pdfBytes.length, ...(result.sent ? {} : { reason: result.reason }) },
  });

  return jsonResponse({ result });
});
