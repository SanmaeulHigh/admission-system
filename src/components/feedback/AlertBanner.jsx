// UX1 명세서 23장 — feedback/AlertBanner.jsx.
// translateAlert()로 번역된 경보 하나를 아이콘+제목+설명+행동버튼으로 보여준다.
// 아이콘은 이모지(🔴🟠ℹ️) 대신 SVG(SeverityIcon)로 통일했다(2026-10-12).

import { SeverityIcon } from '../ui/Icon'

const SEVERITY_CLASS = {
  blocking: 'border-status-danger bg-status-dangerSoft',
  warning: 'border-brand-orangeStrong bg-brand-orangeSoft',
  info: 'border-brand-blue bg-brand-blueSoft',
}
const SEVERITY_TEXT = {
  blocking: 'text-status-danger',
  warning: 'text-brand-orangeStrong',
  info: 'text-brand-blue',
}

export default function AlertBanner({ severity = 'blocking', title, description, actionLabel, onAction }) {
  return (
    <div
      role={severity === 'blocking' ? 'alert' : 'status'}
      className={`flex items-start justify-between gap-3 rounded-lg border px-4 py-3 ${SEVERITY_CLASS[severity]}`}
    >
      <div className="flex min-w-0 items-start gap-2">
        <SeverityIcon severity={severity} size={18} className="mt-px" />
        <div>
          <p className={`text-sm font-semibold ${SEVERITY_TEXT[severity]}`}>{title}</p>
          {description && <p className="mt-0.5 text-sm text-ink-secondary">{description}</p>}
        </div>
      </div>
      {actionLabel && onAction && (
        <button
          type="button"
          onClick={onAction}
          className={`shrink-0 whitespace-nowrap text-xs font-semibold underline ${SEVERITY_TEXT[severity]}`}
        >
          {actionLabel}
        </button>
      )}
    </div>
  )
}
