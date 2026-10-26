// 수험표·접수증 하단 안내 블록(전형 일정표·목록형 안내·문의처). 인쇄용으로 글자를 작게 쓴다.

export function ScheduleTable({ rows, title = '전형 일정' }) {
  if (!rows?.length) return null
  return (
    <div>
      <p className="mb-1 text-[11px] font-bold text-ink-primary">{title}</p>
      <table className="w-full border-collapse text-[10.5px]">
        <thead>
          <tr className="bg-surface-subtle text-ink-secondary">
            <th className="border border-border px-2 py-1 text-left font-semibold">구분</th>
            <th className="border border-border px-2 py-1 text-left font-semibold">일시</th>
            <th className="border border-border px-2 py-1 text-left font-semibold">비고</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([label, when, note]) => (
            <tr key={label}>
              <td className="border border-border px-2 py-1 font-semibold text-ink-primary">{label}</td>
              <td className="border border-border px-2 py-1 text-ink-primary">{when}</td>
              <td className="border border-border px-2 py-1 text-ink-secondary">{note}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function NoteList({ title, items }) {
  if (!items?.length) return null
  return (
    <div>
      <p className="mb-1 text-[11px] font-bold text-ink-primary">{title}</p>
      {/* 글머리표를 직접 그린다 — PDF 저장(html2canvas)이 기본 목록 점을 위로 뜨게 그린다. */}
      <ul className="space-y-0.5 text-[10.5px] leading-snug text-ink-secondary">
        {items.map((t) => (
          <li key={t} className="flex gap-1.5">
            <span className="shrink-0">•</span>
            <span>{t}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

export function Contacts({ items }) {
  if (!items?.length) return null
  return (
    // 항목 중간에서 줄이 끊기거나 '·'가 줄 첫머리에 오지 않도록 항목 단위로 줄바꿈한다.
    <div className="flex gap-2 rounded-md bg-surface-subtle px-3 py-2 text-[10px] leading-snug text-ink-secondary">
      <span className="shrink-0 font-bold text-ink-primary">문의</span>
      <div className="flex flex-wrap gap-x-3 gap-y-0.5">
        {items.map((t) => <span key={t} className="whitespace-nowrap">{t}</span>)}
      </div>
    </div>
  )
}
