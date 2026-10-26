// UX1-G(27장) — feedback/ErrorState.jsx.
// 화면 조회/로딩 실패를 status.danger 톤으로 통일해서 보여준다.
// 페이지마다 text-red-600 같은 raw Tailwind 색을 직접 쓰던 것을 대체한다.
// onRetry가 있으면 "다시 시도" 버튼을 보여준다(모호한 "확인/재시도" 대신
// 22.3 규칙에 맞춰 재시도라는 구체적 동사를 사용).

export default function ErrorState({ title = '불러오는 중 문제가 발생했습니다', description, onRetry }) {
  return (
    <div role="alert" className="rounded-md border border-status-danger bg-status-dangerSoft px-4 py-6 text-center">
      <p className="text-sm font-semibold text-status-danger">{title}</p>
      {description && <p className="mt-1 text-xs text-ink-secondary">{description}</p>}
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="mt-3 rounded-md border border-status-danger px-3 py-1.5 text-xs font-medium text-status-danger hover:bg-surface-card"
        >
          다시 시도
        </button>
      )}
    </div>
  )
}
