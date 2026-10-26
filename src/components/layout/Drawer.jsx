// UX1-G(27장) — "audit detail drawer visual standard" 항목.
// ReceptionPage의 지원자 상세 drawer가 이미 쓰고 있던 시각 패턴
// (전체화면 반투명 오버레이 + 우측 고정폭 slide panel)을 공통 컴포넌트로
// 뽑아내서, 감사 로그 상세 등 다른 화면의 drawer도 같은 표준을 쓰게 한다.
//
// 2026-10-12 UI 다듬기: Esc로 닫기, 대화상자 역할 표시, 안쪽 스크롤이 뒤 화면으로
// 번지지 않게(overscroll-contain), 닫기 버튼을 눌리기 쉬운 크기로.

import { useCallback, useId } from 'react'
import useEscapeKey from '../../lib/useEscapeKey'
import Icon from '../ui/Icon'

export default function Drawer({ open, onClose, title, subtitle, children, widthClassName = 'max-w-md' }) {
  const titleId = useId()
  const close = useCallback(() => onClose?.(), [onClose])
  useEscapeKey(open, close)

  if (!open) return null

  return (
    <div className="fixed inset-0 z-40 flex justify-end bg-black/30" onClick={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        className={`h-full w-full ${widthClassName} overflow-y-auto overscroll-contain bg-surface-card p-6 shadow-lg`}
        onClick={(e) => e.stopPropagation()}
      >
        {(title || subtitle) && (
          <div className="mb-4 flex items-start justify-between gap-3">
            <div className="min-w-0">
              {subtitle && <p className="text-xs tabular-nums text-ink-muted">{subtitle}</p>}
              {title && <h3 id={titleId} className="text-lg font-semibold text-ink-primary">{title}</h3>}
            </div>
            <button
              type="button"
              onClick={onClose}
              aria-label="닫기"
              className="-mr-2 -mt-1 inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-ink-secondary hover:bg-surface-subtle hover:text-ink-primary"
            >
              <Icon name="close" size={20} />
            </button>
          </div>
        )}
        {children}
      </div>
    </div>
  )
}
