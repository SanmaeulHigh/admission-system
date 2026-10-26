// 출신 중학교 검색 (2026-10-12 재도입)
//
// 예전 사전작성 포털(M8, 2b78f2f에서 제거)에 있던 NEIS 학교 검색을
// 원서 접수 화면용으로 다시 들였다. 그때와 달리 교직원 전용이다.
//   - 로그인한 접수 담당(superadmin·admin·reception)만 호출할 수 있다.
//   - 포털용 IP 레이트리밋 RPC는 포털과 함께 지워져 쓰지 않는다.
//
// 나이스(NEIS) 교육정보 개방포털 학교기본정보 API는 브라우저 CORS를 막고,
// 인증키를 프런트에 노출하면 안 되므로 서버에서만 호출한다.
//
// 필요한 환경변수: NEIS_API_KEY (open.neis.go.kr 에서 발급)
// 키가 없거나 NEIS가 응답하지 않으면 빈 목록을 돌려준다 — 화면에서는
// "검색 결과 없음"으로 보이고, 학교명은 언제든 직접 입력할 수 있다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

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
const NEIS_ENDPOINT = "https://open.neis.go.kr/hub/schoolInfo";

interface NeisSchoolRow {
  SCHUL_NM: string;
  LCTN_SC_NM: string;
  ORG_RDNMA?: string;
  ATPT_OFCDC_SC_CODE: string;
  SD_SCHUL_CODE: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "허용되지 않는 메서드입니다." }, 405);
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 1) 호출자 인증 + 역할 확인
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
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

  // 2) 검색어 — 두 글자 이상만(한 글자는 결과가 너무 많다)
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "요청 본문을 읽을 수 없습니다." }, 400);
  }
  const query = typeof body.query === "string" ? body.query.trim() : "";
  if (query.length < 2) return jsonResponse({ schools: [] });

  const apiKey = Deno.env.get("NEIS_API_KEY");
  if (!apiKey) {
    console.error("NEIS_API_KEY가 설정되지 않았습니다 — 빈 결과를 돌려줍니다.");
    return jsonResponse({ schools: [], reason: "서버에 NEIS_API_KEY가 설정되지 않았습니다" });
  }

  const url = new URL(NEIS_ENDPOINT);
  url.searchParams.set("KEY", apiKey);
  url.searchParams.set("Type", "json");
  url.searchParams.set("pIndex", "1");
  url.searchParams.set("pSize", "30");
  url.searchParams.set("SCHUL_NM", query);
  // 지원자는 중학교 졸업(예정)자이므로 중학교만
  url.searchParams.set("SCHUL_KND_SC_NM", "중학교");

  // 실패 이유를 화면에 알려 준다(키 값 자체는 절대 내보내지 않는다).
  let rows: NeisSchoolRow[] = [];
  let reason: string | null = null;
  try {
    const res = await fetch(url.toString(), { signal: AbortSignal.timeout(8000) });
    if (res.ok) {
      const data = await res.json();
      // 정상: { schoolInfo: [ {head: [...]}, {row: [...]} ] }
      // 오류·결과 없음: { RESULT: { CODE: "INFO-200" | "ERROR-290" ..., MESSAGE } }
      const schoolInfo = data?.schoolInfo;
      const rowEntry = Array.isArray(schoolInfo)
        ? schoolInfo.find((e: unknown) => (e as { row?: unknown })?.row)
        : null;
      rows = (rowEntry?.row as NeisSchoolRow[]) ?? [];
      const code: string | undefined = data?.RESULT?.CODE;
      if (!rows.length && code && code !== "INFO-200") {
        reason = `NEIS 응답 ${code}: ${data?.RESULT?.MESSAGE ?? ""}`;
        console.error("NEIS 오류", code, data?.RESULT?.MESSAGE);
      }
    } else {
      reason = `NEIS 서버 응답 ${res.status}`;
      console.error("NEIS API 호출 실패", res.status);
    }
  } catch (err) {
    reason = `NEIS 서버에 연결하지 못했습니다 (${err instanceof Error ? err.name : "오류"})`;
    console.error("NEIS API 호출 오류", err);
  }

  const schools = rows.map((r) => ({
    name: r.SCHUL_NM,
    region: r.LCTN_SC_NM,
    address: r.ORG_RDNMA ?? "",
    code: `${r.ATPT_OFCDC_SC_CODE}-${r.SD_SCHUL_CODE}`,
  }));

  return jsonResponse({ schools, reason });
});
