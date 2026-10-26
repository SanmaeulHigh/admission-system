// UX1 명세서 14.6 — "준비를 완료할 수 없습니다" 패턴.
// 여러 경보를 압축된 리스트로 보여준다(각 항목 AlertBanner 전체가 아니라
// 아이콘+제목 한 줄). 확인 필요 항목이 있으면 확정 버튼 disabled는 호출부 책임.
// 아이콘은 이모지 대신 SVG(SeverityIcon)로 통일했다(2026-10-12).

import { SeverityIcon } from '../ui/Icon'

export default function BlockingPanel({ title = '준비를 완료할 수 없습니다', issues }) {
  if (!issues || issues.length === 0) return null

  return (
    <div role="alert" className="rounded-lg border border-status-danger bg-status-dangerSoft p-4">
      <p className="mb-2 text-sm font-semibold text-status-danger">{title}</p>
      <ul className="space-y-1.5">
        {issues.map((issue, i) => (
          <li key={i} className="flex items-start gap-2 text-sm text-ink-primary">
            <SeverityIcon severity={issue.severity || 'blocking'} className="mt-0.5" />
            <span>{issue.title}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
