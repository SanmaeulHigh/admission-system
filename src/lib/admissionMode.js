// 신입학/전편입학 전형 스위처 (Task #37)
//
// 사용자 피드백: 상단에 "2027학년도 본전형"만 고정 표시돼 있어서 전편입학
// 전형(공고 2026-40호) 업무를 보는 직원은 자기가 지금 어느 전형 화면을 보고
// 있는지 헷갈리고, 사이드바에는 "전·편입생 접수대장"이 신입학 지원자 메뉴
// 밑에 섞여 있었다.
//
// AppHeader·Sidebar·MobileNav 세 컴포넌트가 같은 "현재 모드"를 공유해야
// 하는데, 이걸 위해 App 트리 최상단에 새 Context Provider를 추가하는 대신
// (기존 AdminShell/Sidebar/AppHeader 구조를 그대로 두기 위해) 아주 작은
// pub-sub + localStorage 저장소를 둔다 — AuthContext처럼 무거운 상태가
// 아니라 "화면 전환용 UI 토글" 하나뿐이라 이 정도로 충분하다.
//
// localStorage에 저장해 새로고침/재방문해도 마지막으로 보던 전형 화면이
// 유지되게 한다(민감정보 아님 — 그냥 UI 상태).

import { useSyncExternalStore } from 'react'

export const ADMISSION_MODES = {
  NEW: 'new', // 신입학(M0~M8 본 파이프라인)
  TRANSFER: 'transfer', // 전·편입생 선발 전형(공고 2026-40호, 별도 테이블/화면)
}

const STORAGE_KEY = 'sanmaeul_admission_mode'
const listeners = new Set()

function readStored() {
  if (typeof window === 'undefined') return ADMISSION_MODES.NEW
  const v = window.localStorage.getItem(STORAGE_KEY)
  return v === ADMISSION_MODES.TRANSFER ? ADMISSION_MODES.TRANSFER : ADMISSION_MODES.NEW
}

let currentMode = readStored()

// 2026-10-20: 화면 전체 색을 모드에 맞춘다(전편입학 = 파란 계열, src/index.css).
function applyThemeAttribute(mode) {
  if (typeof document === 'undefined') return
  document.documentElement.dataset.admissionMode = mode
}
applyThemeAttribute(currentMode)

export function getAdmissionMode() {
  return currentMode
}

export function setAdmissionMode(mode) {
  if (mode !== ADMISSION_MODES.NEW && mode !== ADMISSION_MODES.TRANSFER) return
  if (mode === currentMode) return
  currentMode = mode
  applyThemeAttribute(mode)
  if (typeof window !== 'undefined') {
    window.localStorage.setItem(STORAGE_KEY, mode)
  }
  listeners.forEach((listener) => listener())
}

function subscribe(callback) {
  listeners.add(callback)
  return () => listeners.delete(callback)
}

/** 컴포넌트에서 현재 모드를 구독한다(다른 탭/컴포넌트의 변경도 즉시 반영). */
export function useAdmissionMode() {
  return useSyncExternalStore(subscribe, getAdmissionMode, () => ADMISSION_MODES.NEW)
}
