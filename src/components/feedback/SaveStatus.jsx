// UX1 명세서 8.2 — SaveStatus.
// 현장·평가 화면에서 저장 상태만 명확히 보여준다. 기술 상세(revision,
// client_updated_at 등)는 여기서 노출하지 않는다.
// 2026-10-12: 화면 낭독기도 저장 상태 변화를 읽도록 aria-live, ✓ 글자를 SVG로.

import Icon from '../ui/Icon'

const STATE_MAP = {
  saving: { label: '저장 중…', className: 'text-ink-muted' },
  saved: { label: '저장됨', className: 'text-brand-deepGreenStrong', icon: 'check' },
  offline: { label: '오프라인 · 기기에 임시 저장됨', className: 'text-brand-orangeStrong' },
  syncNeeded: { label: '동기화 필요', className: 'text-brand-orangeStrong' },
  error: { label: '저장 실패 · 다시 시도', className: 'text-status-danger' },
}

export default function SaveStatus({ state }) {
  const preset = STATE_MAP[state]
  if (!preset) return null
  return (
    <span role="status" aria-live="polite" className={`inline-flex items-center gap-1 text-xs font-medium ${preset.className}`}>
      {preset.icon && <Icon name={preset.icon} size={14} />}
      {preset.label}
    </span>
  )
}
