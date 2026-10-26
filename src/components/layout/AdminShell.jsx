// UX1 명세서 4.1 — AdminShell.
// 관리자·평가위원의 데스크톱 업무 화면 전체를 감싼다. 기존 page 컴포넌트는
// 그대로 두고 이 Shell로 감싸기만 한다(UX1-A는 리빌드가 아니라 틀 구축).

import { useEffect, useState } from 'react'
import AppHeader from './AppHeader'
import Sidebar from './Sidebar'
import MobileNav from './MobileNav'
import WatermarkLogo from './WatermarkLogo'
import ApplicantQuickLookup from '../lookup/ApplicantQuickLookup'
import { useApplyTheme } from '../../lib/theme'
import PollBanner from '../poll/PollBanner'

// 사이드바 접힘 상태는 브라우저에 기억해 둔다(화면을 옮길 때마다 다시 펼쳐지지 않게).
const COLLAPSE_KEY = 'sanmaeul.sidebarCollapsed'

function readCollapsed() {
  try {
    return localStorage.getItem(COLLAPSE_KEY) === '1'
  } catch {
    return false
  }
}

export default function AdminShell({ children, fullBleed = false }) {
  useApplyTheme() // 다크 모드(사용자 메뉴에서 고름) — 업무 화면에서만
  // 업무 화면이 떠 있는 동안 브라우저 창(문서) 자체는 스크롤하지 않는다(2026-10-26).
  // 셸 밖 어딘가에 높이가 생기면 창이 한 번 더 내려가며 아래에 빈 공간이 보이던 문제를 원천 차단.
  useEffect(() => {
    document.documentElement.classList.add('shell-lock')
    window.scrollTo(0, 0)
    return () => document.documentElement.classList.remove('shell-lock')
  }, [])
  const [collapsed, setCollapsed] = useState(readCollapsed)
  useEffect(() => {
    try {
      localStorage.setItem(COLLAPSE_KEY, collapsed ? '1' : '0')
    } catch {
      // 저장 공간을 못 쓰는 환경이면 기억만 안 할 뿐 동작은 그대로
    }
  }, [collapsed])
  const [mobileNavOpen, setMobileNavOpen] = useState(false)

  // overflow-hidden(2026-10-26): 셸 밖으로 삐져나온 요소 때문에 문서 전체가 한 번 더 스크롤되며
  // 아래에 빈 공간이 생기던 문제 — 스크롤은 본문(main)과 메뉴 안에서만 한다
  return (
    <div className="app-shell-height flex flex-col overflow-hidden bg-surface-canvas">
      {/* 키보드 사용자가 메뉴를 건너뛰고 바로 본문으로 갈 수 있게 */}
      <a href="#main-content" className="skip-link">본문으로 건너뛰기</a>
      <AppHeader onMenuClick={() => setMobileNavOpen(true)} />
      {/* 교직원 투표(00104) — 열린 투표가 있을 때만 */}
      <PollBanner />
      <MobileNav open={mobileNavOpen} onClose={() => setMobileNavOpen(false)} />
      <div className="flex min-h-0 flex-1">
        <Sidebar collapsed={collapsed} onToggle={() => setCollapsed((v) => !v)} />
        <main id="main-content" tabIndex={-1} className="min-w-0 flex-1 overflow-y-auto focus:outline-none">
          {fullBleed ? children : <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6">{children}</div>}
        </main>
      </div>
      <WatermarkLogo />
      {/* 어느 화면에서든 QR(접수·수험번호)을 찍으면 지원자 카드 — 관리자·접수 담당만 */}
      <ApplicantQuickLookup />
    </div>
  )
}
