// 최고관리자 전용 계정 관리 Edge Function (2026-10-13)
//
// 자체 회원가입을 막은 뒤(GoTrue DISABLE_SIGNUP=true) 계정은 최고관리자만 만든다.
//   action = "create"         : 아이디(이메일)·임시 비밀번호로 계정 생성 + 역할·범위 부여(upsert_user_access)
//                               + 휴대폰 번호(set_user_mobile_phone, 선택)
//   action = "reset_password" : 임시 비밀번호로 재설정
// 두 경우 모두 user_metadata.must_change_password = true 로 두어, 첫 로그인 때 본인이 새 비밀번호로
// 바꾸게 한다(화면: ChangePasswordGate). 임시 비밀번호는 저장·기록하지 않는다.
// 역할 부여·휴대폰 RPC는 요청자의 JWT로 호출해 기존 권한 검사(_require_superadmin)를 그대로 거친다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return jsonResponse({ error: "로그인이 필요합니다." }, 401);

  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) return jsonResponse({ error: "로그인이 필요합니다." }, 401);
  const callerId = userRes.user.id;
  const { data: caller } = await admin.from("users").select("roles, active").eq("id", callerId).maybeSingle();
  if (!caller?.active || !(caller.roles ?? []).includes("superadmin")) {
    return jsonResponse({ error: "최고관리자만 할 수 있습니다." }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "요청 본문을 읽을 수 없습니다." }, 400);
  }
  const action = body.action;
  const password = typeof body.password === "string" ? body.password : "";
  if (password.length < 8) return jsonResponse({ error: "임시 비밀번호는 8자 이상이어야 합니다." }, 400);

  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });

  if (action === "reset_password") {
    const userId = typeof body.userId === "string" ? body.userId : "";
    if (!userId) return jsonResponse({ error: "userId가 필요합니다." }, 400);
    const { error } = await admin.auth.admin.updateUserById(userId, {
      password,
      user_metadata: { must_change_password: true },
    });
    if (error) return jsonResponse({ error: `비밀번호를 바꾸지 못했습니다: ${error.message}` }, 400);
    await admin.from("audit_logs").insert({
      actor_type: "user", actor_uid: callerId, action: "user.password_reset_by_admin",
      resource_type: "users", resource_id: userId, metadata: {},
    });
    return jsonResponse({ ok: true });
  }

  if (action === "create") {
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";
    const roles = Array.isArray(body.roles) ? body.roles : [];
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return jsonResponse({ error: "아이디(이메일) 형식이 아닙니다." }, 400);
    if (!displayName) return jsonResponse({ error: "이름을 입력하세요." }, 400);
    if (roles.length === 0) return jsonResponse({ error: "역할을 1개 이상 고르세요." }, 400);

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { must_change_password: true },
    });
    if (createErr || !created?.user) {
      const msg = createErr?.message ?? "";
      return jsonResponse({
        error: /already|registered|exists/i.test(msg) ? "이미 있는 아이디입니다." : `계정을 만들지 못했습니다: ${msg}`,
      }, 400);
    }
    const newId = created.user.id;

    const { error: accessErr } = await userClient.rpc("upsert_user_access", {
      target_email: email,
      new_display_name: displayName,
      new_roles: roles,
      new_assigned_areas: Array.isArray(body.areas) ? body.areas : [],
      new_year_scopes: Array.isArray(body.yearScopes) ? body.yearScopes : [2027],
      new_round_scopes: Array.isArray(body.roundScopes) ? body.roundScopes : ["main"],
    });
    if (accessErr) {
      // 역할을 못 주면 반쯤 만든 계정이 남지 않게 지운다
      await admin.auth.admin.deleteUser(newId);
      return jsonResponse({ error: `역할을 부여하지 못해 계정 생성을 취소했습니다: ${accessErr.message}` }, 400);
    }

    let phoneWarning: string | null = null;
    const phone = typeof body.mobilePhone === "string" ? body.mobilePhone.trim() : "";
    if (phone) {
      const { error: phoneErr } = await userClient.rpc("set_user_mobile_phone", { p_user_id: newId, p_phone: phone });
      if (phoneErr) phoneWarning = `휴대폰 번호는 저장하지 못했습니다: ${phoneErr.message}`;
    }

    await admin.from("audit_logs").insert({
      actor_type: "user", actor_uid: callerId, action: "user.created_by_admin",
      resource_type: "users", resource_id: newId, metadata: { roles },
    });
    return jsonResponse({ ok: true, userId: newId, phoneWarning });
  }

  return jsonResponse({ error: "알 수 없는 요청입니다." }, 400);
});
