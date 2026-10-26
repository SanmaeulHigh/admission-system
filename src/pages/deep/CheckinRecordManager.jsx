// 입실 기록 관리 (2026-10-21) — 입실 시각 고치기 · 수기 입실 등록 (00098)
//
// 바코드 화면 아래 접이식 영역. 현장 스캔 흐름을 방해하지 않도록 기본은 접혀 있다.
// 사유는 필수이고 감사 기록에 이전·이후 시각과 함께 남는다. 처음 스캔 시각은 서버에 따로 보존된다.
// 이 영역의 입력칸에 커서가 있는 동안은 바코드 입력칸이 커서를 빼앗지 않는다(document.activeElement 기준).

import { useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'

function pad(n) {
  return String(n).padStart(2, '0')
}
function toDateInput(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}
function toTimeInput(d) {
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}
function fmtTime(v) {
  if (!v) return ''
  const d = new Date(v)
  return toTimeInput(d)
}

export default function CheckinRecordManager({ items, onChanged }) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [editing, setEditing] = useState(null) // { item, mode: 'correct' | 'manual' }
  const [date, setDate] = useState('')
  const [time, setTime] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)

  const list = useMemo(() => {
    const q = query.trim().toUpperCase()
    const base = items.filter((s) => s.eligible || s.checkedInAt)
    if (!q) return base
    return base.filter((s) => (s.name || '').includes(query.trim())
      || (s.examNo || '').toUpperCase().includes(q)
      || (s.receiptNo || '').toUpperCase().includes(q))
  }, [items, query])

  const correctedCount = items.filter((s) => s.correctedAt).length

  function startEdit(item) {
    const mode = item.checkedInAt ? 'correct' : 'manual'
    const base = item.checkedInAt ? new Date(item.checkedInAt) : new Date()
    setEditing({ item, mode })
    setDate(toDateInput(base))
    setTime(toTimeInput(base))
    setReason('')
    setError(null)
    setNotice(null)
  }

  async function save(e) {
    e.preventDefault()
    if (!editing) return
    if (reason.trim().length < 2) {
      setError('사유를 적어 주세요.')
      return
    }
    const at = new Date(`${date}T${time}:00`)
    if (Number.isNaN(at.getTime())) {
      setError('날짜·시각을 확인하세요.')
      return
    }
    if (at.getTime() > Date.now() + 60_000) {
      setError('아직 오지 않은 시각입니다.')
      return
    }
    setBusy(true)
    setError(null)
    const fn = editing.mode === 'correct' ? 'set_checkin_time' : 'manual_checkin'
    const { data, error: err } = await supabase.rpc(fn, {
      p_applicant_id: editing.item.applicantId, p_checked_in_at: at.toISOString(), p_reason: reason.trim(),
    })
    setBusy(false)
    if (err) {
      setError(err.message)
      return
    }
    const who = `${editing.item.examNo || editing.item.receiptNo} ${editing.item.name}`
    setNotice(
      editing.mode === 'correct'
        ? `${who}: 입실 시각을 ${time}로 고쳤습니다.${data?.certificateIssued ? ' 응시 확인서를 이미 뽑았습니다 — 새 시각으로 다시 인쇄하세요(번호는 그대로).' : ''}`
        : `${who}: ${time} 입실로 수기 등록했습니다.`,
    )
    setEditing(null)
    onChanged?.()
  }

  return (
    <section className="mt-4 rounded-card border border-border bg-surface-card">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center justify-between px-4 py-3 text-sm font-semibold text-ink-primary"
      >
        <span>
          입실 기록 관리 <span className="font-normal text-ink-muted">— 시각 고치기 · 수기 입실 등록{correctedCount > 0 ? ` · 고친 기록 ${correctedCount}건` : ''}</span>
        </span>
        <span className="text-xs text-ink-muted">{open ? '접기' : '펼치기'}</span>
      </button>

      {open && (
        <div className="border-t border-border p-4">
          <p className="text-xs text-ink-muted">
            행정 사유로 스캔이 늦었거나 못 찍은 경우에만 쓰세요. 사유는 필수이며, 처음 스캔 시각·고친 사람·사유가 감사 기록에 남습니다.
            시각 고치기는 같은 날 안에서만 됩니다.
          </p>

          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="성명·수험번호·접수번호로 찾기"
            aria-label="성명·수험번호·접수번호로 찾기"
            className="mt-3 w-full max-w-xs rounded-md border border-border px-3 py-1.5 text-sm"
          />

          {notice && <p className="mt-3 rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">{notice}</p>}

          {editing && (
            <form onSubmit={save} className="mt-3 rounded-lg border-2 border-brand-deepGreen bg-white p-4">
              <p className="text-sm font-semibold text-ink-primary">
                {editing.mode === 'correct' ? '입실 시각 고치기' : '수기 입실 등록'} —{' '}
                <span className="tabular-nums">{editing.item.examNo || editing.item.receiptNo}</span> {editing.item.name}
                {editing.mode === 'correct' && (
                  <span className="ml-2 font-normal text-ink-muted">현재 {fmtTime(editing.item.checkedInAt)}</span>
                )}
              </p>
              <div className="mt-3 flex flex-wrap items-end gap-3 text-sm">
                <label className="flex flex-col gap-1">
                  <span className="text-xs text-ink-secondary">날짜</span>
                  <input
                    type="date"
                    value={date}
                    onChange={(e) => setDate(e.target.value)}
                    disabled={editing.mode === 'correct'}
                    className="rounded-md border border-border px-2 py-1.5 disabled:bg-surface-subtle"
                    required
                  />
                </label>
                <label className="flex flex-col gap-1">
                  <span className="text-xs text-ink-secondary">입실 시각</span>
                  <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className="rounded-md border border-border px-2 py-1.5" required />
                </label>
                <label className="flex min-w-[16rem] flex-1 flex-col gap-1">
                  <span className="text-xs text-ink-secondary">사유 (필수)</span>
                  <input
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="예) 접수처 대기로 스캔 지연, 수험표 미지참으로 신분증 확인"
                    className="rounded-md border border-border px-2 py-1.5"
                    maxLength={200}
                    required
                  />
                </label>
                <button
                  type="submit"
                  disabled={busy}
                  className="rounded-md bg-brand-deepGreen px-4 py-1.5 font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
                >
                  {busy ? '저장 중…' : '저장'}
                </button>
                <button type="button" onClick={() => setEditing(null)} className="rounded-md border border-border px-3 py-1.5 text-ink-secondary">
                  닫기
                </button>
              </div>
              {error && <p className="mt-2 text-sm text-status-danger">{error}</p>}
            </form>
          )}

          <div className="mt-3 max-h-96 overflow-y-auto rounded-md border border-border">
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-surface-subtle text-xs text-ink-secondary">
                <tr>
                  <th className="px-3 py-2 text-left">수험번호</th>
                  <th className="px-3 py-2 text-left">성명</th>
                  <th className="px-3 py-2 text-left">입실 시각</th>
                  <th className="px-3 py-2 text-left">비고</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {list.map((s) => (
                  <tr key={s.applicantId} className="border-t border-border">
                    <td className="px-3 py-1.5 font-mono tabular-nums">{s.examNo || s.receiptNo}</td>
                    <td className="px-3 py-1.5 font-semibold text-ink-primary">{s.name}</td>
                    <td className="px-3 py-1.5 tabular-nums">{s.checkedInAt ? fmtTime(s.checkedInAt) : <span className="text-ink-muted">미입실</span>}</td>
                    <td className="px-3 py-1.5 text-xs text-ink-secondary">
                      {s.method === 'manual' && <span className="mr-1 rounded bg-status-warningSoft px-1.5 py-0.5 text-status-warning">수기</span>}
                      {s.originalCheckedInAt && (
                        <span className="mr-1 rounded bg-status-warningSoft px-1.5 py-0.5 text-status-warning">고침 · 원래 {fmtTime(s.originalCheckedInAt)}</span>
                      )}
                      {s.correctionReason && <span title={s.correctionReason}>{s.correctionReason}</span>}
                    </td>
                    <td className="px-3 py-1.5 text-right">
                      {(s.checkedInAt || s.eligible) && (
                        <button
                          type="button"
                          onClick={() => startEdit(s)}
                          className="rounded-md border border-border px-2.5 py-1 text-xs text-ink-secondary hover:bg-surface-subtle"
                        >
                          {s.checkedInAt ? '시각 고치기' : '수기 입실'}
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
                {list.length === 0 && (
                  <tr><td colSpan={5} className="p-4 text-center text-ink-muted">대상자가 없습니다.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  )
}
