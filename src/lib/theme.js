// 화면 밝기(다크 모드) 설정 (2026-10-26)
//
// 'system'(컴퓨터 설정 따름) / 'light' / 'dark'. 고른 값은 이 브라우저에 기억한다.
// 실제 적용(<html data-theme="dark">)은 업무 화면 틀(AdminShell)이 켜져 있는 동안만 한다 —
// 접수증·수험표·합격증서 같은 인쇄 서식 화면은 셸 밖이라 늘 밝게 보이고, 인쇄도 늘 밝게 나간다(index.css).

import { useEffect, useState } from 'react'

const KEY = 'sanmaeul.theme'
const EVENT = 'sanmaeul:theme'
export const THEME_OPTIONS = [
  { value: 'system', label: '자동(컴퓨터 설정)' },
  { value: 'light', label: '밝게' },
  { value: 'dark', label: '어둡게' },
]

export function getThemePref() {
  try {
    const v = localStorage.getItem(KEY)
    return v === 'light' || v === 'dark' ? v : 'system'
  } catch {
    return 'system'
  }
}

export function setThemePref(value) {
  try { localStorage.setItem(KEY, value) } catch { /* 기억만 못 함 */ }
  window.dispatchEvent(new CustomEvent(EVENT, { detail: value }))
}

export function useThemePref() {
  const [pref, setPref] = useState(getThemePref)
  useEffect(() => {
    const on = (e) => setPref(e.detail)
    window.addEventListener(EVENT, on)
    return () => window.removeEventListener(EVENT, on)
  }, [])
  return pref
}

// AdminShell에서 부른다: 켜져 있는 동안 <html data-theme>를 맞추고, 나가면 지운다.
export function useApplyTheme() {
  const pref = useThemePref()
  useEffect(() => {
    const root = document.documentElement
    const mq = window.matchMedia?.('(prefers-color-scheme: dark)')
    const apply = () => {
      const dark = pref === 'dark' || (pref === 'system' && mq?.matches)
      if (dark) root.setAttribute('data-theme', 'dark')
      else root.removeAttribute('data-theme')
      document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#1A1F1C' : '#FFFFFF')
    }
    apply()
    mq?.addEventListener?.('change', apply)
    return () => {
      mq?.removeEventListener?.('change', apply)
      root.removeAttribute('data-theme')
      document.querySelector('meta[name="theme-color"]')?.setAttribute('content', '#FFFFFF')
    }
  }, [pref])
}
