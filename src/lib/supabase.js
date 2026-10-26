// Supabase 클라이언트 초기화
// 마스터 스펙 v1.2 섹션 0.2의 Firebase 요구는 Supabase로 대체되었다
// (2026-07-06 결정, docs/검토메모 참조). 리전: ap-northeast-2 (서울).
//
// 접근 통제의 최종 경계는 Postgres Row Level Security(RLS)다 — 클라이언트
// 코드의 어떤 분기도 보안 장치가 아니다 (스펙 섹션 6.1 원칙 동일 적용).
//
// anon key는 공개되어도 안전하도록 설계된 키다(RLS가 지키는 전제).
// 단, service_role key는 절대 프론트엔드/리포에 넣지 않는다.

import { createClient } from '@supabase/supabase-js'

// 2026-10-13: 화면과 Supabase는 언제나 같은 주소로 받는다(Caddy). https 로 열렸으면 화면의
// 주소를 그대로 쓴다 — ipsi.example.org(터널), local.example.org(교내 비상 주소) 어느 쪽으로
// 들어와도 API가 같은 길로 간다. 개발 서버 등 http 로 열면 .env 의 주소를 쓴다.
const envSupabaseUrl = import.meta.env.VITE_SUPABASE_URL
export const supabaseUrl =
  typeof window !== 'undefined' && window.location.protocol === 'https:'
    ? window.location.origin
    : envSupabaseUrl
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY 환경변수가 없습니다. .env.local을 확인하세요.'
  )
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    // OAuth 리다이렉트 후 세션을 URL에서 회수
    detectSessionInUrl: true,
    persistSession: true,
    autoRefreshToken: true,
  },
})

// supabase.functions.invoke()가 non-2xx를 받으면 error(FunctionsHttpError)를
// 던지는데, error.context는 파싱되지 않은 원본 fetch Response 객체다
// (error.context.body는 이미 읽은 JSON이 아니라 스트림이라 항상 undefined).
// error.context.json()을 직접 호출해야 Edge Function이 보낸
// { error: "..." } 메시지를 꺼낼 수 있다 — 이 헬퍼로 공용화한다.
export async function getEdgeFunctionErrorMessage(fnError, fallback) {
  try {
    if (fnError?.context?.json) {
      const body = await fnError.context.json()
      if (body?.error) return body.error
    }
  } catch {
    // JSON 파싱 실패 시 아래 fallback으로.
  }
  return fnError?.message || fallback
}
