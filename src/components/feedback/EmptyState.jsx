// UX1-G(27장) — feedback/EmptyState.jsx.
// "목록/결과 없음"을 페이지마다 제각각 회색조/문구로 표현하던 것을
// (예: bg-gray-50 text-gray-500, text-gray-400 등 raw Tailwind 색)
// 하나의 시각 표준으로 통일한다. surface-subtle 배경 + ink 톤 텍스트만 쓴다.

export default function EmptyState({ title = '표시할 내용이 없습니다', description, action }) {
  return (
    <div className="rounded-md border border-dashed border-border bg-surface-subtle px-4 py-8 text-center">
      <p className="text-sm font-medium text-ink-secondary">{title}</p>
      {description && <p className="mt-1 text-xs text-ink-muted">{description}</p>}
      {action && <div className="mt-3">{action}</div>}
    </div>
  )
}
