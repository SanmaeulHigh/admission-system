// UX1 명세서 14.2/15.1/16.1 — 준비 workspace 상단 단계 표시.
// steps: [{label}], currentIndex: 0-based.

export default function Stepper({ steps, currentIndex, onStepClick }) {
  return (
    <div className="mb-6 flex items-center">
      {steps.map((step, i) => {
        const state = i < currentIndex ? 'done' : i === currentIndex ? 'current' : 'pending'
        const clickable = onStepClick && i <= currentIndex
        return (
          <div key={step} className="flex flex-1 items-center last:flex-none">
            <button
              type="button"
              disabled={!clickable}
              onClick={() => clickable && onStepClick(i)}
              className={`flex items-center gap-2 rounded-full px-3 py-1.5 text-sm ${
                state === 'current'
                  ? 'bg-brand-deepGreen font-semibold text-white'
                  : state === 'done'
                    ? 'text-brand-deepGreenStrong hover:bg-brand-greenSoft'
                    : 'text-ink-muted'
              } ${clickable ? 'cursor-pointer' : 'cursor-default'}`}
            >
              <span
                className={`flex h-5 w-5 items-center justify-center rounded-full text-xs ${
                  state === 'current'
                    ? 'bg-white text-brand-deepGreenStrong'
                    : state === 'done'
                      ? 'bg-brand-green text-white'
                      : 'bg-border-strong text-white'
                }`}
              >
                {state === 'done' ? '✓' : i + 1}
              </span>
              {step}
            </button>
            {i < steps.length - 1 && (
              <div className={`mx-1 h-0.5 flex-1 ${i < currentIndex ? 'bg-brand-green' : 'bg-border-strong'}`} />
            )}
          </div>
        )
      })}
    </div>
  )
}
