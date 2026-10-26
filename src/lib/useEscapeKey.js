// 열린 창(대화상자·서랍·메뉴)을 Esc 키로 닫는다 (2026-10-12, UI 다듬기)
// 처리 중(submitting)일 때는 닫히지 않게 enabled=false로 넘긴다.

import { useEffect } from 'react'

export default function useEscapeKey(enabled, onEscape) {
  useEffect(() => {
    if (!enabled || !onEscape) return undefined
    const handler = (event) => {
      if (event.key === 'Escape') onEscape(event)
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [enabled, onEscape])
}
