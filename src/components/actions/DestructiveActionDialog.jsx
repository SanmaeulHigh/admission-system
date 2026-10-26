// UX1 명세서 21.2 — "삭제: red filled 가능"에 해당하는 진짜 파괴적 작업
// 전용 dialog(지원자 삭제, 계정 비활성화 등). 사유 입력을 항상 요구하고
// 최소 길이를 컴포넌트 자체에서 검증한다(기존에 ReceptionPage가 인라인으로
// 직접 구현하고 있던 패턴을 공통화한 것).

// 2026-10-12 UI 다듬기: Esc로 취소(처리 중 제외), 대화상자 역할·제목 연결, 사유 칸 라벨 연결.
import { useCallback, useId, useState } from 'react'
import useEscapeKey from '../../lib/useEscapeKey'

export default function DestructiveActionDialog({
  open,
  title,
  description,
  fields = [], // [{label, value}]
  reasonLabel = '사유 (필수)',
  reasonMinLength = 5,
  reasonPlaceholder,
  confirmLabel = '삭제 실행',
  cancelLabel = '취소',
  onConfirm, // (reason) => void
  onCancel,
  submitting = false,
  error,
}) {
  const [reason, setReason] = useState('')
  const [localError, setLocalError] = useState(null)
  const titleId = useId()
  const reasonId = useId()
  const cancel = useCallback(() => onCancel?.(), [onCancel])
  useEscapeKey(open && !submitting, cancel)

  if (!open) return null

  const handleConfirm = () => {
    if (reason.trim().length < reasonMinLength) {
      setLocalError(`사유를 ${reasonMinLength}자 이상 입력해야 합니다.`)
      return
    }
    setLocalError(null)
    onConfirm(reason)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className="w-full max-w-md rounded-dialog border-2 border-status-danger bg-surface-card p-6 shadow-xl"
      >
        <h3 id={titleId} className="mb-2 text-base font-semibold text-status-danger">{title}</h3>
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

        <label htmlFor={reasonId} className="mb-1 block text-xs font-medium text-ink-secondary">{reasonLabel}</label>
        <textarea
          id={reasonId}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={3}
          className="mb-3 w-full rounded-md border border-border px-3 py-2 text-sm"
          placeholder={reasonPlaceholder}
        />

        {(localError || error) && (
          <p role="alert" className="mb-3 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">
            {localError || error}
          </p>
        )}

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
            onClick={handleConfirm}
            disabled={submitting}
            className="rounded-md bg-status-danger px-4 py-2 text-sm font-semibold text-white hover:opacity-90 disabled:opacity-50"
          >
            {submitting ? '처리 중…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
