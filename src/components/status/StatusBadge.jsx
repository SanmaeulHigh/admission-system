// UX1 명세서 8.1 / UX1-G(27장) — StatusBadge.
// raw enum(draft/submitted/finalized 등)을 사용자 문구로 번역해서 보여준다.
// 라벨·색상 매핑은 src/config/statusLabels.js 한 곳에서만 정의한다.
// 색상만으로 상태를 전달하지 않도록(접근성 원칙 25) 텍스트를 항상 함께 표시한다.

import { WORK_STATUS_LABEL, TONE_CLASS } from '../../config/statusLabels'

export default function StatusBadge({ status, label, tone }) {
  const preset = WORK_STATUS_LABEL[status]
  const text = label || preset?.label || status
  const className = TONE_CLASS[tone || preset?.tone] || TONE_CLASS.neutral

  return (
    <span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold ${className}`}>
      {text}
    </span>
  )
}
