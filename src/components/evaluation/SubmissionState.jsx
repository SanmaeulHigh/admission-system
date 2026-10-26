// UX1 명세서 23장 — evaluation/SubmissionState.jsx.
// "8/12 완료" 같은 제출 진행률을 막대+텍스트로 함께 보여준다(색상만으로
// 상태를 전달하지 않는다 — 접근성 원칙 25).

export default function SubmissionState({ submitted, total, size = 'md' }) {
  const pct = total > 0 ? Math.round((submitted / total) * 100) : 0
  const complete = total > 0 && submitted >= total
  const barHeight = size === 'sm' ? 'h-1' : 'h-1.5'

  return (
    <div className="min-w-[88px]">
      <div className="flex items-center justify-between text-xs">
        <span className={complete ? 'font-semibold text-brand-deepGreenStrong' : 'text-ink-secondary'}>
          {submitted} / {total} 완료
        </span>
      </div>
      <div className={`mt-1 w-full overflow-hidden rounded-full bg-surface-subtle ${barHeight}`}>
        <div
          className={`h-full rounded-full ${complete ? 'bg-brand-green' : 'bg-brand-orange'}`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  )
}
