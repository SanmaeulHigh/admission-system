// 로그인 화면 서버 상태 표시 (2026-07-14 요청)
// 배경: 서버 PC(자체 호스팅 Supabase + 프론트 서빙을 겸함)를 슈퍼관리자
// 퇴근길에 꺼버리면 선생님들이 접속 자체가 안 되는데, 브라우저의 일반
// "연결할 수 없음" 오류만 보고는 "내 PC/네트워크 문제인지 학교 서버가
// 꺼진 건지" 구분이 안 된다. PWA(vite-plugin-pwa)가 로그인 화면 정적
// 파일을 캐싱해두므로, 서버가 꺼져 있어도 (이전에 한 번이라도 접속한
// 적 있는 PC라면) 이 화면 자체는 뜨고, 여기서 GoTrue 헬스 엔드포인트로
// 서버 도달 가능 여부만 확인해 알려준다.
//
// "온라인" 판정 기준: fetch가 예외 없이 응답을 받으면(설령 401/403이라도)
// 서버 자체는 살아있는 것으로 본다 — 여기서 확인하려는 건 인증 성공 여부가
// 아니라 "이 주소로 서버가 응답하는가"이기 때문이다. 네트워크 자체가
// 끊기거나(연결 거부), 타임아웃(4초)이 나면 "오프라인"으로 표시한다.

import { useCallback, useEffect, useState } from 'react'
import { supabaseUrl } from '../../lib/supabase'

// Supabase 클라이언트와 같은 주소를 쓴다(https 로 열면 화면 주소 = 터널·비상 주소 어느 쪽이든)
const HEALTH_URL = `${supabaseUrl}/auth/v1/health`
const CHECK_INTERVAL_MS = 20000
const TIMEOUT_MS = 4000

export default function ServerStatusBadge() {
  const [status, setStatus] = useState('checking') // 'checking' | 'online' | 'offline'

  const check = useCallback(async () => {
    setStatus('checking')
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
    try {
      await fetch(HEALTH_URL, {
        signal: controller.signal,
        cache: 'no-store',
        headers: { apikey: import.meta.env.VITE_SUPABASE_ANON_KEY },
      })
      // 401/403 등 어떤 HTTP 응답이라도 왔다면 서버는 살아있는 것.
      setStatus('online')
    } catch {
      setStatus('offline')
    } finally {
      clearTimeout(timer)
    }
  }, [])

  useEffect(() => {
    check()
    const id = setInterval(check, CHECK_INTERVAL_MS)
    return () => clearInterval(id)
  }, [check])

  const PRESET = {
    checking: { dot: 'bg-ink-muted', text: 'text-ink-muted', label: '서버 상태 확인 중…' },
    online: { dot: 'bg-brand-deepGreen', text: 'text-brand-deepGreenStrong', label: '서버 정상 작동 중' },
    offline: {
      dot: 'bg-status-danger',
      text: 'text-status-danger',
      label: '서버에 연결할 수 없습니다 (관리자에게 문의하세요)',
    },
  }[status]

  return (
    <div className="mb-5 flex items-center justify-between gap-2 rounded-md bg-surface-subtle px-3 py-2 text-xs">
      <span className={`flex items-center gap-1.5 font-medium ${PRESET.text}`}>
        <span className={`h-2 w-2 shrink-0 rounded-full ${PRESET.dot}`} aria-hidden="true" />
        {PRESET.label}
      </span>
      <button
        type="button"
        onClick={check}
        className="shrink-0 text-ink-muted underline hover:text-ink-secondary"
      >
        새로고침
      </button>
    </div>
  )
}
