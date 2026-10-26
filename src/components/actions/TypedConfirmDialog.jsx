// UX1 명세서 21.1 Level 3(전형 결과에 중대한 영향) 위험 작업 공통 dialog.
// readiness checklist는 호출부에서 이미 통과시킨 뒤에만 이 dialog를 띄운다
// (이 컴포넌트 자체는 지정 문구 입력 검증만 담당한다).
//
// 색상 규칙(21.2): 최종 확정류는 deep green primary + red warning context.
// 빨간 filled button은 "삭제"처럼 진짜 파괴적인 작업에만 쓴다(danger prop).

// 2026-10-12 UI 다듬기: Esc로 취소(처리 중 제외), 대화상자 역할·제목 연결, 사유 칸 라벨 연결.
import { useCallback, useId, useState } from 'react'
import useEscapeKey from '../../lib/useEscapeKey'
import Icon from '../ui/Icon'

export default function TypedConfirmDialog({
  open,
  title,
  description,
  fields = [], // [{label, value}]
  confirmPhrase,
  confirmLabel = '확정',
  cancelLabel = '취소',
  onConfirm,
  onCancel,
  submitting = false,
  danger = false, // true면 red filled(삭제 등), false면 deep green(확정 등)
  error,
}) {
  const [text, setText] = useState('')
  const titleId = useId()
  const inputId = useId()
  const cancel = useCallback(() => onCancel?.(), [onCancel])
  useEscapeKey(open && !submitting, cancel)

  if (!open) return null

  const canConfirm = text === confirmPhrase && !submitting

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className={`w-full max-w-md rounded-dialog border-2 bg-surface-card p-6 shadow-xl ${danger ? 'border-status-danger' : 'border-brand-orange'}`}
      >
        <div className="mb-3 flex items-start gap-2">
          <Icon name="alertTriangle" size={20} className={`mt-0.5 ${danger ? 'text-status-danger' : 'text-brand-orangeStrong'}`} />
          <h3 id={titleId} className={`text-base font-semibold ${danger ? 'text-status-danger' : 'text-ink-primary'}`}>{title}</h3>
        </div>

        {description && <p className="mb-4 text-sm text-ink-secondary">{description}</p>}

        {fields.length > 0 && (
          <dl className="mb-4 space-y-1.5 rounded-md bg-surface-subtle p-3 text-sm">
            {fields.map((f) => (
              <div key={f.label} className="flex justify-between">
                <dt className="text-ink-muted">{f.label}</dt>
                <dd className="font-medium text-ink-primary">{f.value}</dd>
              </div>
            ))}
          </dl>
        )}

        <p className="mb-2 text-sm text-ink-secondary">
          <label htmlFor={inputId}>
          계속하려면 <strong className="text-ink-primary">&lsquo;{confirmPhrase}&rsquo;</strong>을 입력하세요.
          </label>
        </p>
        <input
          id={inputId}
          autoComplete="off"
          spellCheck={false}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={confirmPhrase}
          className="mb-4 w-full rounded-md border border-border px-3 py-2 text-sm"
          autoFocus
        />

        {error && <p role="alert" className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onCancel}
            disabled={submitting}
            className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={!canConfirm}
            className={`rounded-md px-4 py-2 text-sm font-semibold text-white disabled:opacity-40 ${
              danger ? 'bg-status-danger hover:opacity-90' : 'bg-brand-deepGreen hover:bg-brand-deepGreenStrong'
            }`}
          >
            {submitting ? '처리 중…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
