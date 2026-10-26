// UX1 명세서 2.4(로고 사용) + 4.1(Desktop layout) — 헤더 높이 60px,
// 로고+제품명, 연도·차수, 사용자 메뉴.
//
// 2026-07-14: 실제 새봄고 로고 이미지(원형 엠블럼)가 준비돼 자리표시자
// SVG를 실제 로고로 교체했다.
//
// 2026-10-12 UI 다듬기:
//  - 연도·차수를 고정값(2027학년도 본전형) 대신 실제 운영 중인 차수에서 가져온다
//    (테스트 차수 2099로 전환해도 헤더는 2027로 보이던 문제).
//  - 눌러도 아무 일도 없던 알림(🔔) 버튼을 없앴다.
//  - 글자 아이콘(☰ ▾)을 SVG로, 사용자 메뉴는 이름·역할을 한글로 보여주고
//    바깥 클릭·Esc로 닫히게 했다.

import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { ADMISSION_MODES, setAdmissionMode, useAdmissionMode } from '../../lib/admissionMode'
import { roundToText } from '../../lib/applicantLabels'
import { rolesToText } from '../../config/roles'
import useEscapeKey from '../../lib/useEscapeKey'
import Icon from '../ui/Icon'
import ChangePasswordForm from '../auth/ChangePasswordForm'
import schoolLogo from '../../assets/school-logo.png'
import { HeaderServerClock, HeaderToday } from './HeaderTimeInfo'
import { HeaderLookupInput } from '../lookup/ApplicantQuickLookup'
import { THEME_OPTIONS, setThemePref, useThemePref } from '../../lib/theme'

// 버전 표시(2026-10-26) — vite.config.js 에서 package.json 버전과 빌드 정보를 넣는다. 규칙: docs/버전_규칙.md
/* global __APP_VERSION__, __APP_BUILD__ */
const APP_VERSION = typeof __APP_VERSION__ === 'string' ? __APP_VERSION__ : '0.0.0'
const BUILD = typeof __APP_BUILD__ === 'object' && __APP_BUILD__ ? __APP_BUILD__ : {}
const BUILD_TITLE = `버전 ${APP_VERSION}${BUILD.commit ? ` · 커밋 ${BUILD.commit}` : ''}${BUILD.builtAt ? ` · 빌드 ${new Date(BUILD.builtAt).toLocaleString('ko-KR')}` : ''}`

function BrandMark({ size = 30 }) {
  return <img src={schoolLogo} alt="" width={size} height={size} />
}

const MODE_OPTIONS = [
  { value: ADMISSION_MODES.NEW, label: '신입학' },
  { value: ADMISSION_MODES.TRANSFER, label: '전편입학' },
]

export default function AppHeader({ onMenuClick }) {
  const { email, roles, userDoc, signOut } = useAuth()
  const { year, round } = useAdmissionCycle()
  const [menuOpen, setMenuOpen] = useState(false)
  const [pwOpen, setPwOpen] = useState(false)
  const [pwDone, setPwDone] = useState(false)
  const menuRef = useRef(null)
  const admissionMode = useAdmissionMode()
  const themePref = useThemePref()
  const navigate = useNavigate()

  // 2026-07-12 개선(Task #37, 사용자 피드백): 신입학/전편입학 전형을 선택하는
  // 스위처. 전환 시 사이드바 메뉴도 함께 바뀐다(navigation.js의 section.mode 참고).
  // 전환하면 지금 보던 화면이 새 모드 사이드바에 없을 수 있어 대시보드('/')로 이동한다.
  const handleModeChange = (nextMode) => {
    if (nextMode === admissionMode) return
    setAdmissionMode(nextMode)
    navigate('/')
  }

  const closeMenu = useCallback(() => setMenuOpen(false), [])
  useEscapeKey(menuOpen, closeMenu)

  // 메뉴 바깥을 누르면 닫는다
  useEffect(() => {
    if (!menuOpen) return undefined
    const onPointerDown = (event) => {
      if (menuRef.current && !menuRef.current.contains(event.target)) setMenuOpen(false)
    }
    document.addEventListener('pointerdown', onPointerDown)
    return () => document.removeEventListener('pointerdown', onPointerDown)
  }, [menuOpen])

  const displayName = userDoc?.display_name
  const cycleText = year && round ? `${year}학년도 ${roundToText(round)}` : '전형 정보 불러오는 중…'

  return (
    <header className="flex h-[60px] shrink-0 items-center justify-between gap-3 border-b border-border bg-surface-card px-4">
      <div className="flex min-w-0 items-center gap-2">
        {onMenuClick && (
          <button
            type="button"
            onClick={onMenuClick}
            aria-label="메뉴 열기"
            className="-ml-1 inline-flex h-10 w-10 items-center justify-center rounded-lg text-ink-primary hover:bg-surface-subtle md:hidden"
          >
            <Icon name="menu" size={20} />
          </button>
        )}
        <Link to="/" className="flex min-w-0 items-center gap-2 rounded-lg">
          <BrandMark />
          <span className="flex min-w-0 flex-col leading-tight">
            <span className="truncate text-base font-bold text-ink-primary">입학전형관리시스템</span>
            <span className="text-[10.5px] font-medium tabular-nums text-ink-muted" title={BUILD_TITLE}>v{APP_VERSION}</span>
          </span>
        </Link>
        {/* PC(1280px 이상)에서만: 오늘 날짜 + 다가오는 일정 D-day */}
        <div className="ml-6"><HeaderToday /></div>
      </div>

      <div className="hidden items-center gap-3 text-sm text-ink-secondary sm:flex">
        <div className="flex rounded-lg border border-border bg-surface-subtle p-0.5" role="group" aria-label="전형 전환">
          {MODE_OPTIONS.map((opt) => {
            const on = admissionMode === opt.value
            return (
              <button
                key={opt.value}
                type="button"
                aria-pressed={on}
                onClick={() => handleModeChange(opt.value)}
                className={`rounded-md px-3 py-1.5 text-xs font-semibold ${
                  on ? 'bg-brand-deepGreen text-white shadow-sm' : 'text-ink-secondary hover:bg-surface-card hover:text-ink-primary'
                }`}
              >
                {opt.label}
              </button>
            )
          })}
        </div>
        <span className="font-medium text-ink-primary">
          {admissionMode === ADMISSION_MODES.NEW ? cycleText : '전·편입생 선발 전형'}
        </span>
      </div>

      <div ref={menuRef} className="relative flex items-center gap-4">
        {/* PC(1280px 이상)에서만: 서버 시각 */}
        <HeaderLookupInput />
        <HeaderServerClock />
        <button
          type="button"
          onClick={() => setMenuOpen((v) => !v)}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          className="flex h-10 items-center gap-1.5 rounded-lg px-2.5 text-sm text-ink-primary hover:bg-surface-subtle"
        >
          <span className="max-w-[160px] truncate font-medium">
            {displayName ? `${displayName} 선생님` : email}
          </span>
          <Icon
            name="chevronDown"
            size={16}
            className={`text-ink-muted transition-transform duration-150 ${menuOpen ? 'rotate-180' : ''}`}
          />
        </button>
        {menuOpen && (
          <div
            role="menu"
            className="absolute right-0 top-full z-30 mt-1 w-64 origin-top-right rounded-xl border border-border bg-surface-card py-1 shadow-lg"
          >
            <div className="border-b border-border px-3 py-2.5">
              {displayName && <p className="text-sm font-semibold text-ink-primary">{displayName}</p>}
              <p className="truncate text-xs text-ink-muted">{email}</p>
              <p className="mt-1 text-xs text-ink-secondary">{rolesToText(roles)}</p>
            </div>
            <div className="border-b border-border px-3 py-2.5">
              <p className="mb-1.5 text-xs text-ink-secondary">화면 밝기</p>
              <div className="flex rounded-lg border border-border bg-surface-subtle p-0.5" role="group" aria-label="화면 밝기">
                {THEME_OPTIONS.map((o) => (
                  <button key={o.value} type="button" aria-pressed={themePref === o.value} onClick={() => setThemePref(o.value)}
                    className={`flex-1 rounded-md px-1.5 py-1 text-xs font-semibold ${themePref === o.value ? 'bg-brand-deepGreen text-white' : 'text-ink-secondary hover:text-ink-primary'}`}>
                    {o.value === 'system' ? '자동' : o.label}
                  </button>
                ))}
              </div>
            </div>
            <button
              type="button"
              role="menuitem"
              onClick={() => { setMenuOpen(false); setPwDone(false); setPwOpen(true) }}
              className="flex w-full items-center gap-2 px-3 py-2.5 text-left text-sm text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary"
            >
              <Icon name="lock" size={16} />
              비밀번호 변경
            </button>
            <button
              type="button"
              role="menuitem"
              onClick={signOut}
              className="flex w-full items-center gap-2 px-3 py-2.5 text-left text-sm text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary"
            >
              <Icon name="logOut" size={16} />
              로그아웃
            </button>
          </div>
        )}
      </div>
      {pwOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-labelledby="pw-title">
          <div className="w-full max-w-sm rounded-xl bg-surface-card p-6 shadow-xl">
            <h2 id="pw-title" className="mb-4 text-base font-bold text-ink-primary">비밀번호 변경</h2>
            {pwDone ? (
              <>
                <p className="mb-4 rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">비밀번호를 바꿨습니다. 다음 로그인부터 새 비밀번호를 쓰세요.</p>
                <button type="button" onClick={() => setPwOpen(false)} className="w-full rounded-lg border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">닫기</button>
              </>
            ) : (
              <ChangePasswordForm onDone={() => setPwDone(true)} onCancel={() => setPwOpen(false)} />
            )}
          </div>
        </div>
      )}
    </header>
  )
}
