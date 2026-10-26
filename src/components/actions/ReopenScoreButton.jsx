// 채점 재개방 버튼 + 사유 입력 창 (2026-09-28)
//
// "지원자 + 위원 + 영역"만 알면 재개방한다(reopen_score_entry, 00073).
// 제출확정된 채점을 다시 '수정 가능' 상태로 되돌리며, 사유는 감사 기록에 남는다.
// 면접·글쓰기 재개방은 최고관리자만 가능하다(서버에서 확인).
//
// area: attendance | academic | community | essay | opinion | group |
//       interview_student | interview_parent | writing

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

const QUICK_REASONS = ['입력 오류 정정', '평가위원 요청에 따른 수정', '편차 확인 후 재채점', '종이 채점표와 대조 결과 불일치']

export default function ReopenScoreButton({
  area,
  applicantId,
  evaluatorUid,
  label = '재개방',
  targetText = '',
  onDone,
  className = '',
}) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const submit = async () => {
    setError(null)
    if (reason.trim().length < 5) {
      setError('사유를 5자 이상 입력하세요.')
      return
    }
    setBusy(true)
    const { error: err } = await supabase.rpc('reopen_score_entry', {
      p_area: area,
      p_applicant_id: applicantId,
      p_evaluator_uid: evaluatorUid,
      p_reason: reason.trim(),
    })
    setBusy(false)
    if (err) {
      setError(err.message)
      return
    }
    setOpen(false)
    setReason('')
    onDone?.()
  }

  return (
    <>
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          setOpen(true)
        }}
        className={className || 'rounded-md border border-status-warning bg-white px-3 py-1.5 text-xs font-semibold text-status-warning hover:bg-status-warningSoft'}
      >
        {label}
      </button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={() => !busy && setOpen(false)}>
          <div className="w-full max-w-md rounded-lg bg-surface-card p-5" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-base font-semibold text-ink-primary">채점 재개방</h3>
            <p className="mt-1 text-xs text-ink-muted">
              {targetText && <span className="font-semibold text-ink-secondary">{targetText} · </span>}
              제출확정된 점수를 다시 수정할 수 있게 엽니다. 재개방 후에는 다시 제출확정해야 점수에 반영됩니다.
              사유는 감사 기록에 남습니다.
            </p>
            <div className="mt-3 flex flex-wrap gap-1.5">
              {QUICK_REASONS.map((r) => (
                <button
                  key={r}
                  type="button"
                  onClick={() => setReason(r)}
                  className={`rounded-full border px-2.5 py-1 text-xs ${reason === r ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border text-ink-secondary'}`}
                >
                  {r}
                </button>
              ))}
            </div>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              placeholder="재개방 사유 (5자 이상)"
              className="mt-2 w-full rounded-lg border-border text-sm"
            />
            {error && <p className="mt-2 text-xs text-status-danger">{error}</p>}
            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setOpen(false)}
                disabled={busy}
                className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary"
              >
                취소
              </button>
              <button
                type="button"
                onClick={submit}
                disabled={busy}
                className="rounded-md bg-status-warning px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
              >
                {busy ? '재개방 중…' : '재개방'}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}
