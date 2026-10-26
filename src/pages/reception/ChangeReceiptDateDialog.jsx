// 접수일 바꾸기(우편 도착일 소급) + 접수번호 다시 매기기 (2026-10-25, 00100)
// 관리자만, 수험번호 부여 전만. 사유 필수 → 감사 기록.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

function kstDate(v) {
  const d = v ? new Date(v) : new Date()
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Seoul' }).format(d) // YYYY-MM-DD
}

export default function ChangeReceiptDateDialog({ applicant, onClose, onChanged }) {
  const current = kstDate(applicant.receiptDate)
  const today = kstDate()
  const [date, setDate] = useState(current)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit(e) {
    e.preventDefault()
    if (date === current) { setError('지금 접수일과 같은 날짜입니다.'); return }
    if (reason.trim().length < 2) { setError('사유를 적어 주세요.'); return }
    if (!window.confirm(`접수일을 ${date}로 바꾸고 접수번호를 새로 매깁니다.\n(지금 번호 ${applicant.receiptNo}는 더 쓰지 않습니다)\n계속할까요?`)) return
    setBusy(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('change_receipt_date', {
      p_applicant_id: applicant.id, p_date: date, p_reason: reason.trim(),
    })
    setBusy(false)
    if (err) { setError(err.message); return }
    onChanged?.(data)
  }

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-labelledby="crd-title">
      <form onSubmit={submit} className="w-full max-w-md rounded-xl bg-surface-card p-6 shadow-xl">
        <h2 id="crd-title" className="text-base font-bold text-ink-primary">접수일 바꾸기 — {applicant.name}</h2>
        <p className="mt-1 text-xs text-ink-muted">
          우편 도착일로 소급할 때 씁니다. 접수번호 앞 6자리가 접수일이라 <b>번호도 새로 매겨집니다</b>
          (바꾼 날짜·같은 전형의 다음 순번). 접수 시각(시:분)은 그대로입니다.
        </p>

        <dl className="mt-4 grid grid-cols-[6rem_1fr] gap-y-1.5 text-sm">
          <dt className="text-ink-muted">지금 접수번호</dt><dd className="font-mono">{applicant.receiptNo}</dd>
          <dt className="text-ink-muted">지금 접수일</dt><dd className="tabular-nums">{current}</dd>
        </dl>

        <label className="mt-4 flex flex-col gap-1 text-sm">
          <span className="text-xs text-ink-secondary">바꿀 접수일 (우편 도착일)</span>
          <input type="date" value={date} max={today} onChange={(e) => setDate(e.target.value)} required
            className="rounded-md border border-border px-2 py-1.5" />
        </label>
        <label className="mt-3 flex flex-col gap-1 text-sm">
          <span className="text-xs text-ink-secondary">사유 (필수, 감사 기록에 남음)</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} required
            placeholder="예) 10. 23. 등기 도착분을 10. 24.에 입력"
            className="rounded-md border border-border px-2 py-1.5" />
        </label>

        {error && <p className="mt-3 text-sm text-status-danger">{error}</p>}

        <div className="mt-5 flex justify-end gap-2">
          <button type="button" onClick={onClose} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary">취소</button>
          <button type="submit" disabled={busy} className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
            {busy ? '바꾸는 중…' : '접수일 바꾸기'}
          </button>
        </div>
      </form>
    </div>
  )
}
