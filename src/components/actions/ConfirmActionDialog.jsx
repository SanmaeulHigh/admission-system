// UX1 명세서 21.1 Level 1(일반 확인)·Level 2(업무 상태 변경) 공통 dialog.
// Level 1: reason 없이 결과 설명 + 확인(reasonRequired=false, reasonOptions 없음).
// Level 2: 결과 설명 + 사유 입력/선택 + confirm(reasonRequired=true 또는 reasonOptions 지정).
//
// 색상은 21.2 규칙을 따른다: 재개방=orange(tone="warning"), 취소=neutral(tone="neutral").
// 진짜 파괴적인 작업(지원자 삭제, 계정 비활성화 등)은 이 컴포넌트 대신
// DestructiveActionDialog를 쓴다. Level 3(전형 결과에 중대한 영향)는 TypedConfirmDialog.

// 2026-10-12 UI 다듬기: Esc로 취소(처리 중 제외), 대화상자 역할·제목 연결, 사유 칸 라벨 연결.
import { useCallback, useId, useState } from 'react'
import useEscapeKey from '../../lib/useEscapeKey'

const TONE_BUTTON_CLASS = {
  neutral: 'bg-ink-primary hover:opacity-90',
  warning: 'bg-status-warning hover:bg-brand-orangeStrong',
  success: 'bg-brand-deepGreen hover:bg-brand-deepGreenStrong',
}

const TONE_BORDER_CLASS = {
  neutral: 'border-border',
  warning: 'border-brand-orangeStrong',
  success: 'border-brand-deepGreen',
}

export default function ConfirmActionDialog({
  open,
  title,
  description,
  fields = [], // [{label, value}]
  reasonRequired = false,
  reasonLabel = '사유',
  reasonPlaceholder,
  reasonOptions, // 선택형 사유일 때 [{value, label}]
  confirmLabel = '확인',
  cancelLabel = '취소',
  onConfirm, // (reason) => void
  onCancel,
  submitting = false,
  tone = 'neutral', // neutral | warning | success
  error,
}) {
  const [reason, setReason] = useState('')
  const titleId = useId()
  const reasonId = useId()
  const cancel = useCallback(() => onCancel?.(), [onCancel])
  useEscapeKey(open && !submitting, cancel)

  if (!open) return null

  const canConfirm = (!reasonRequired || reason.trim().length > 0) && !submitting

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className={`w-full max-w-md rounded-dialog border-2 bg-surface-card p-6 shadow-xl ${TONE_BORDER_CLASS[tone]}`}
      >
        <h3 id={titleId} className="mb-2 text-base font-semibold text-ink-primary">{title}</h3>
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

        {(reasonRequired || reasonOptions) && (
          <div className="mb-4">
            <label htmlFor={reasonId} className="mb-1 block text-xs font-medium text-ink-secondary">
              {reasonLabel}
              {reasonRequired && ' (필수)'}
            </label>
            {reasonOptions ? (
              <select
                id={reasonId}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                className="w-full rounded-md border border-border px-3 py-2 text-sm"
              >
                <option value="">선택하세요</option>
                {reasonOptions.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            ) : (
              <textarea
                id={reasonId}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                rows={3}
                placeholder={reasonPlaceholder}
                className="w-full rounded-md border border-border px-3 py-2 text-sm"
              />
            )}
          </div>
        )}

        {error && (
          <p role="alert" className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>
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
            onClick={() => onConfirm(reason)}
            disabled={!canConfirm}
            className={`rounded-md px-4 py-2 text-sm font-semibold text-white disabled:opacity-40 ${TONE_BUTTON_CLASS[tone]}`}
          >
            {submitting ? '처리 중…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
