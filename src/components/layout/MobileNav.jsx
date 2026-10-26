// UX1 명세서 24.1 — <900px에서는 top drawer navigation.
// 2026-10-12 UI 다듬기: 닫기 글자(✕)를 SVG로, Esc로 닫기, 현재 위치 표시(aria-current),
// 구역 제목을 데스크톱 사이드바와 같은 모양으로(한글엔 대문자·자간 벌리기가 의미 없음).
import { useCallback } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'
import { NAV_SECTIONS, findActiveNavPath, isNavItemVisible, isNavItemVisibleForMode, isNavSectionVisibleForMode } from '../../config/navigation'
import { useAdmissionMode } from '../../lib/admissionMode'
import useEscapeKey from '../../lib/useEscapeKey'
import Icon from '../ui/Icon'

export default function MobileNav({ open, onClose }) {
  const { hasAnyRole } = useAuth()
  const location = useLocation()
  const admissionMode = useAdmissionMode()
  const close = useCallback(() => onClose?.(), [onClose])
  useEscapeKey(open, close)

  if (!open) return null

  const visibleSections = NAV_SECTIONS.filter((section) => isNavSectionVisibleForMode(section, admissionMode))
    .map((section) => ({
      ...section,
      items: section.items.filter((item) => isNavItemVisible(item, hasAnyRole) && isNavItemVisibleForMode(item, admissionMode)),
    }))
    .filter((section) => section.items.length > 0)
  const activePath = findActiveNavPath(location.pathname, visibleSections.flatMap((s) => s.items))

  return (
    <div className="fixed inset-0 z-40 md:hidden" role="dialog" aria-modal="true" aria-label="메뉴">
      <div className="absolute inset-0 bg-black/30" onClick={onClose} aria-hidden="true" />
      <div className="absolute inset-x-0 top-0 max-h-[85vh] overflow-y-auto overscroll-contain rounded-b-2xl bg-surface-card p-4 shadow-lg">
        <div className="mb-3 flex items-center justify-between">
          <span className="text-sm font-semibold text-ink-primary">메뉴</span>
          <button
            type="button"
            onClick={onClose}
            aria-label="메뉴 닫기"
            className="inline-flex h-10 w-10 items-center justify-center rounded-lg text-ink-secondary hover:bg-surface-subtle"
          >
            <Icon name="close" size={20} />
          </button>
        </div>
        <nav aria-label="주 메뉴" className="space-y-4">
          {visibleSections.map((section, idx) => (
            <div key={section.label || `m-section-${idx}`}>
              {section.label && (
                <p className="mb-1 px-3 text-xs font-semibold text-ink-muted">{section.label}</p>
              )}
              <ul className="space-y-0.5">
                {section.items.map((item) => {
                  const active = item.path === activePath
                  return (
                    <li key={item.path}>
                      {item.newTab ? (
                        <a
                          href={item.path}
                          target="_blank"
                          rel="noopener noreferrer"
                          onClick={onClose}
                          className="flex items-center justify-between gap-2 rounded-lg px-3 py-3 text-[15px] text-ink-secondary"
                        >
                          <span>{item.label}</span>
                          <Icon name="externalLink" size={14} className="text-ink-muted" />
                          <span className="sr-only">(새 창)</span>
                        </a>
                      ) : (
                        <Link
                          to={item.path}
                          onClick={onClose}
                          aria-current={active ? 'page' : undefined}
                          className={`block rounded-lg px-3 py-3 text-[15px] ${
                            active
                              ? 'bg-brand-greenSoft font-semibold text-brand-deepGreenStrong shadow-[inset_3px_0_0_0_var(--brand-deep-green)]'
                              : 'text-ink-secondary'
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
      </div>
    </div>
  )
}
