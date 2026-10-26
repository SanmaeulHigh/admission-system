// UX1 명세서 4.1 "사이드바 규칙" — 폭 232px, 접을 수 있음, 권한 없는 메뉴는
// disabled가 아니라 아예 미노출, 현재 위치는 좌측 오렌지 라인 + 하위 항목은
// 진녹색 텍스트로 강조.

import { Link, useLocation } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'
import { NAV_SECTIONS, findActiveNavPath, isNavItemVisible, isNavItemVisibleForMode, isNavSectionVisibleForMode } from '../../config/navigation'
import { useAdmissionMode } from '../../lib/admissionMode'
import Icon from '../ui/Icon'

export default function Sidebar({ collapsed, onToggle }) {
  const { hasAnyRole } = useAuth()
  const location = useLocation()
  const admissionMode = useAdmissionMode()

  const visibleSections = NAV_SECTIONS.filter((section) => isNavSectionVisibleForMode(section, admissionMode))
    .map((section) => ({
      ...section,
      items: section.items.filter((item) => isNavItemVisible(item, hasAnyRole) && isNavItemVisibleForMode(item, admissionMode)),
    }))
    .filter((section) => section.items.length > 0)
  const activePath = findActiveNavPath(location.pathname, visibleSections.flatMap((s) => s.items))

  if (collapsed) {
    return (
      <aside className="hidden w-14 shrink-0 border-r border-border bg-surface-card py-4 md:flex md:flex-col md:items-center">
        <button
          type="button"
          onClick={onToggle}
          aria-label="메뉴 펼치기"
          title="메뉴 펼치기"
          className="inline-flex h-10 w-10 items-center justify-center rounded-lg text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary"
        >
          <Icon name="chevronRight" size={18} />
        </button>
      </aside>
    )
  }

  return (
    // 폭을 232 → 260으로 넓혔다. 기존 폭에서는 "사용자(선생님) 권한 관리",
    // "년도·전형(회차) 설정" 같은 긴 항목이 두 줄로 접혀 목록이 지저분했다.
    <aside className="hidden w-[216px] shrink-0 flex-col border-r border-border bg-surface-card py-3 md:flex">
      <div className="mb-1 flex items-center justify-between px-4">
        <button
          type="button"
          onClick={onToggle}
          className="inline-flex h-8 items-center gap-1 rounded-lg px-2 text-xs font-medium text-ink-muted hover:bg-surface-subtle hover:text-ink-primary"
        >
          <Icon name="chevronLeft" size={16} />
          메뉴 접기
        </button>
      </div>
      <nav aria-label="주 메뉴" className="flex-1 overflow-y-auto overscroll-contain px-2 pb-4">
        {visibleSections.map((section, idx) => (
          <div key={section.label || `section-${idx}`} className={idx > 0 ? 'mt-1 pt-4' : ''}>
            {/* 구역 제목: 한글에는 uppercase가 의미가 없고 자간만 벌어져 읽기
                나빠진다. 대신 위에 구분선을 두어 구역이 나뉜 걸 보이게 했다. */}
            {section.label && (
              <p className="mb-1.5 border-t border-border/70 px-3 pt-3 text-xs font-semibold text-ink-muted">
                {section.label}
              </p>
            )}
            <ul className="space-y-0.5">
              {section.items.map((item) => {
                const active = item.path === activePath
                return (
                  <li key={item.path}>
                    {/* newTab 항목(예: 대기실 프로젝터 송출 화면)은 관리 화면을
                        벗어나지 않도록 새 창으로 연다. */}
                    {item.newTab ? (
                      <a
                        href={item.path}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="flex items-center justify-between gap-2 rounded-lg px-3 py-2.5 text-[15px] leading-snug text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary"
                      >
                        <span>{item.label}</span>
                        <Icon name="externalLink" size={14} className="text-ink-muted" />
                        <span className="sr-only">(새 창)</span>
                      </a>
                    ) : (
                      <Link
                        to={item.path}
                        aria-current={active ? 'page' : undefined}
                        // 선택 상태를 한 가지 방식으로 통일했다. 예전에는 최상위
                        // 항목은 주황 라인, 하위 항목은 초록 배경으로 서로 달라
                        // "지금 어디" 신호가 일관되지 않았다.
                        className={`block rounded-lg px-3 py-2.5 text-[15px] leading-snug ${
                          active
                            ? 'bg-brand-greenSoft font-semibold text-brand-deepGreenStrong shadow-[inset_3px_0_0_0_var(--brand-deep-green)]'
                            : 'text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary'
                        }`}
                      >
                        {item.label}
                      </Link>
                    )}
                  </li>
                )
              })}
            </ul>
          </div>
        ))}
      </nav>
    </aside>
  )
}
