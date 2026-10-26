// 교외 접속 휴대폰 인증번호 발송 Edge Function (2026-10-13)
//
// 교외(학교 공인 IP가 아닌 곳)에서 로그인한 사용자에게 등록된 휴대폰으로 6자리 인증번호를 보낸다.
// 인증번호 원문은 저장하지 않고 sha256(코드:사용자ID:세션ID) 해시만 login_otp_challenges에 남긴다.
// 확인은 DB 함수 verify_login_otp 가 같은 방식으로 해시를 비교한다(00085).
//
// 교외 판단: Cloudflare가 붙이는 Cf-Connecting-Ip 헤더를 trusted_networks(학교 공인 IP)와 비교.
// 헤더가 없거나 학교 IP면 교내 → 인증번호를 보내지 않는다.
// 남용 방지: 60초에 1번, 1시간에 5번까지.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { sendSms } from "../_shared/smsProvider.ts";

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

// "203.0.113.10" 이 "203.0.113.0/24" 안에 있는지(IPv4). IPv6는 정확히 같을 때만.
function ipInCidr(ip: string, cidr: string): boolean {
  const [base, bitsText] = cidr.split("/");
  if (ip.includes(":") || base.includes(":")) return ip === base;
  const toNum = (s: string) => s.split(".").reduce((n, p) => (n * 256) + Number(p), 0);
  const bits = bitsText === undefined ? 32 : Number(bitsText);
  if (bits === 0) return true;
  const mask = bits >= 32 ? 0xffffffff : (0xffffffff << (32 - bits)) >>> 0;
  return ((toNum(ip) & mask) >>> 0) === ((toNum(base) & mask) >>> 0);
}

function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  try {
    const part = jwt.split(".")[1];
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
  } catch {
    return null;
  }
}

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 1) 로그인 확인
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  const userId = userRes.user.id;
  const sessionId = String(decodeJwtPayload(jwt)?.session_id ?? "");
  if (!sessionId) return jsonResponse({ error: "로그인 세션을 확인할 수 없습니다. 다시 로그인하세요." }, 400);

  // 2) 교외인지 확인
  const clientIp = (req.headers.get("cf-connecting-ip") ?? "").trim();
  if (!clientIp) return jsonResponse({ error: "교내 접속에서는 인증번호가 필요 없습니다." }, 400);
  const { data: nets } = await admin.from("trusted_networks").select("cidr");
  if ((nets ?? []).some((n: { cidr: string }) => ipInCidr(clientIp, n.cidr))) {
    return jsonResponse({ error: "교내 접속에서는 인증번호가 필요 없습니다." }, 400);
  }

  // 3) 사용자·휴대폰
  const { data: profile } = await admin
    .from("users")
    .select("active, mobile_phone")
    .eq("id", userId)
    .maybeSingle();
  if (!profile?.active) return jsonResponse({ error: "권한이 없습니다." }, 403);
  if (!profile.mobile_phone) {
    return jsonResponse({ error: "등록된 휴대폰 번호가 없습니다. 입학전형 담당자에게 등록을 요청하세요." }, 400);
  }

  // 4) 남용 방지
  const now = Date.now();
  const { data: recent } = await admin
    .from("login_otp_challenges")
    .select("created_at")
    .eq("user_id", userId)
    .gte("created_at", new Date(now - 60 * 60 * 1000).toISOString())
    .order("created_at", { ascending: false });
  if ((recent ?? []).length >= 5) {
    return jsonResponse({ error: "1시간에 5번까지만 받을 수 있습니다. 잠시 뒤 다시 시도하세요." }, 429);
  }
  if (recent?.[0] && now - new Date(recent[0].created_at).getTime() < 60 * 1000) {
    return jsonResponse({ error: "1분 뒤에 다시 받을 수 있습니다." }, 429);
  }

  // 5) 인증번호 만들기·저장(해시만)
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1000000;
  const code = String(n).padStart(6, "0");
  const codeHash = await sha256Hex(`${code}:${userId}:${sessionId}`);
  const { data: challenge, error: insErr } = await admin
    .from("login_otp_challenges")
    .insert({
      user_id: userId,
      session_id: sessionId,
      code_hash: codeHash,
      client_ip: clientIp,
      expires_at: new Date(now + 5 * 60 * 1000).toISOString(),
    })
    .select("id")
    .single();
  if (insErr || !challenge) return jsonResponse({ error: "인증번호를 만들지 못했습니다." }, 500);

  // 6) 문자 발송
  const result = await sendSms({
    phone: profile.mobile_phone,
    message: `[새봄고] 입학전형 시스템 인증번호 [${code}] 5분 안에 입력하세요.`,
  });

  await admin.from("audit_logs").insert({
    actor_type: "user",
    actor_uid: userId,
    action: result.sent ? "auth.mfa.code_sent" : "auth.mfa.code_send_failed",
    resource_type: "users",
    resource_id: userId,
    metadata: { ip: clientIp, providerCode: result.providerCode ?? null },
  });

  if (!result.sent) {
    await admin.from("login_otp_challenges").delete().eq("id", challenge.id);
    return jsonResponse({ error: `문자를 보내지 못했습니다(${result.providerMessage ?? result.reason ?? "알 수 없음"}).` }, 502);
  }
  return jsonResponse({ sent: true, expiresInSeconds: 300 });
});
