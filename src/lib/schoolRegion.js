// 학교 이름 → 소재지(시도 시군구) (2026-10-25)
//
// 지원자 목록에서 출신 중학교에 커서를 올리면 소재지를 보여 주려고 쓴다.
// 접수 때 학교 주소를 따로 저장하지 않으므로, 접수 화면과 같은 NEIS 학교 검색(search-school)을
// 학교 이름으로 불러 주소 앞부분만 쓴다. 한 번 찾은 이름은 이 창이 열려 있는 동안 기억한다.
// 이름이 같은 학교가 여러 곳이면 모두 보여 준다(예: '중앙중학교').

import { supabase, getEdgeFunctionErrorMessage } from './supabase'

const cache = new Map() // name → Promise<{ regions: string[] } | { error: string }>

// '경기도 수원시 장안구 …' → '경기도 수원시 장안구', '인천광역시 미추홀구 …' → '인천광역시 미추홀구'
export function addressToRegion(address, fallback = '') {
  const t = String(address || '').trim().split(/\s+/)
  if (!t[0]) return fallback
  if (t[0].startsWith('세종')) return t[0]
  const parts = [t[0]]
  if (t[1]) parts.push(t[1])
  if (t[1]?.endsWith('시') && t[2]?.endsWith('구')) parts.push(t[2]) // 일반구가 있는 시
  return parts.join(' ')
}

export function lookupSchoolRegion(name) {
  const key = String(name || '').trim()
  if (key.length < 2) return Promise.resolve({ regions: [] })
  if (!cache.has(key)) {
    const p = supabase.functions
      .invoke('search-school', { body: { query: key } })
      .then(async ({ data, error }) => {
        if (error) {
          // 실제 사유(권한·서버 응답 코드)를 보여 주려고 꺼낸다(2026-10-26)
          const status = error.context?.status
          const msg = await getEdgeFunctionErrorMessage(error, error.message)
          throw new Error(status ? `${msg} (응답 ${status})` : msg)
        }
        const exact = (data?.schools || []).filter((s) => s.name === key)
        const list = exact.length ? exact : []
        const regions = [...new Set(list.map((s) => addressToRegion(s.address, s.region)).filter(Boolean))]
        return { regions, reason: data?.reason || null }
      })
      .catch((err) => {
        cache.delete(key) // 실패는 기억하지 않는다(다음에 다시 시도)
        return { error: err?.message || '조회 실패' }
      })
    cache.set(key, p)
  }
  return cache.get(key)
}
