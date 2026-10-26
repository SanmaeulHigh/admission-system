// UX1 명세서 7.1 — PageHeader.
// 제목에 M-code를 쓰지 않고, primary action은 최대 1개만 강조한다.
// 나머지 행동은 secondaryActions(텍스트 버튼) 또는 overflow menu로 뺀다.
//
// 이 컴포넌트는 UX1-A(공통 primitive) 산출물이다 — 기존 page들을 지금 당장
// 이걸로 바꾸지는 않는다(그건 UX1-C 이후 개별 페이지 리빌드 범위). 새로
// 만드는 화면과, 앞으로 리빌드하는 화면부터 사용한다.

import { Link } from 'react-router-dom'

export default function PageHeader({ breadcrumb, title, description, primaryAction, secondaryActions = [] }) {
  return (
    <div className="mb-6">
      {breadcrumb && breadcrumb.length > 0 && (
        <p className="mb-1 text-xs text-ink-muted">{breadcrumb.join(' / ')}</p>
      )}
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-ink-primary">{title}</h1>
          {description && <p className="mt-1 text-sm text-ink-secondary">{description}</p>}
        </div>
        {(primaryAction || secondaryActions.length > 0) && (
          <div className="flex flex-wrap items-center gap-2">
            {secondaryActions.map((action) =>
              action.to ? (
                <Link
                  key={action.label}
                  to={action.to}
                  className="rounded-lg border border-border px-3 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle"
                >
                  {action.label}
                </Link>
              ) : (
                <button
                  key={action.label}
                  type="button"
                  onClick={action.onClick}
                  disabled={action.disabled}
                  className="rounded-lg border border-border px-3 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                >
                  {action.label}
                </button>
              ),
            )}
            {primaryAction &&
              (primaryAction.to ? (
                <Link
                  to={primaryAction.to}
                  className="rounded-lg bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong"
                >
                  {primaryAction.label}
                </Link>
              ) : (
                <button
                  type="button"
                  onClick={primaryAction.onClick}
                  disabled={primaryAction.disabled}
                  className="rounded-lg bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
                >
                  {primaryAction.label}
                </button>
              ))}
          </div>
        )}
      </div>
    </div>
  )
}
