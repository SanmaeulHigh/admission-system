// 최종 사정 합격선·과락선 설정 (2026-10-01)
//
// 기준(모두 선택, 비우면 미적용, 전 전형 공통) — "이 점수 미만이면 불합격":
//   최종 총점 합격선 / 서류평가 / 모둠활동 / 면접(학생+학부모) / 글쓰기 과락선
// 걸린 지원자는 순위 경쟁 전에 불합격되고, 기준을 넘은 지원자끼리 정원을 채운다
// (run_final_decision, 00080). 저장은 set_final_cutoffs(슈퍼관리자, 감사 기록).
// 최종 사정이 확정된 회차는 서버가 변경을 막는다.

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'

export const CUTOFF_FIELDS = [
  { key: 'finalTotal', label: '최종 총점 합격선', hint: '서류+심층 최종 총점' },
  { key: 'document', label: '서류평가 과락선', hint: '1단계 서류 점수' },
  { key: 'group', label: '모둠활동 과락선', hint: '' },
  { key: 'interview', label: '면접 과락선', hint: '학생+학부모 면접 합계' },
  { key: 'writing', label: '글쓰기 과락선', hint: '' },
]

export function cutoffSummary(cutoffs) {
  const parts = CUTOFF_FIELDS.filter((f) => cutoffs && cutoffs[f.key] != null).map((f) => `${f.label.replace(/ (합격선|과락선)$/, '')} ${cutoffs[f.key]}점`)
  return parts.length ? `${parts.join(', ')} 미만 불합격` : '적용 안 함'
}

const sameCutoffs = (a, b) => CUTOFF_FIELDS.every((f) => (a?.[f.key] ?? null) === (b?.[f.key] ?? null))
export { sameCutoffs }

export default function CutoffPanel({ year, round, onLoaded }) {
  const { hasRole } = useAuth()
  const canEdit = hasRole('superadmin')
  const [saved, setSaved] = useState(null)
  const [form, setForm] = useState({})
  const [locked, setLocked] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)

  const load = async () => {
    if (!year || !round) return
    const [{ data: roundRow, error: err }, { data: finalized }] = await Promise.all([
      supabase.from('admission_rounds').select('final_cutoffs').eq('year', year).eq('round', round).maybeSingle(),
      supabase.from('decision_runs').select('id').eq('year', year).eq('round', round)
        .eq('decision_type', 'final').eq('status', 'finalized').limit(1),
    ])
    if (err) {
      setError(err.message)
      return
    }
    const c = roundRow?.final_cutoffs || {}
    setSaved(c)
    setForm(Object.fromEntries(CUTOFF_FIELDS.map((f) => [f.key, c[f.key] ?? ''])))
    setLocked((finalized || []).length > 0)
    onLoaded?.(c)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [year, round])

  const parsed = () => {
    const out = {}
    for (const f of CUTOFF_FIELDS) {
      const raw = String(form[f.key] ?? '').trim()
      if (raw === '') continue
      const n = Number(raw)
      if (!Number.isFinite(n) || n < 0) throw new Error(`${f.label}: 0 이상의 숫자를 입력하세요.`)
      out[f.key] = n
    }
    return out
  }

  let pending = null
  let formError = null
  try {
    pending = parsed()
  } catch (e) {
    formError = e.message
  }
  const changed = saved && pending && !sameCutoffs(saved, pending)

  const save = async () => {
    if (!pending) return
    // eslint-disable-next-line no-alert
    if (!window.confirm(`합격선·과락선을 다음으로 저장합니다.\n\n${cutoffSummary(pending)}\n\n저장 후 시뮬레이션을 다시 실행해 결과를 확인하세요.`)) return
    setSaving(true)
    setError(null)
    setNotice(null)
    const { error: err } = await supabase.rpc('set_final_cutoffs', { p_year: year, p_round: round, p_cutoffs: pending })
    setSaving(false)
    if (err) {
      setError(err.message)
      return
    }
    setNotice('저장했습니다. 시뮬레이션을 다시 실행하면 새 기준이 적용됩니다.')
    await load()
  }

  return (
    <div className="mb-6 rounded-lg border border-border bg-white p-4">
      <div className="mb-1 flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-primary">합격선·과락선</h3>
        {saved && <span className="text-xs text-ink-muted">현재: {cutoffSummary(saved)}</span>}
      </div>
      <p className="mb-3 text-xs text-ink-muted">
        입력한 점수 <b>미만</b>이면 정원 안에 들어도 불합격합니다. 기준을 넘은 지원자끼리 정원을 채우고, 남는 자리는 미충원으로 둡니다.
        빈칸은 적용하지 않으며, 모든 전형에 같은 기준을 씁니다.
      </p>
      {locked && (
        <p className="mb-3 rounded-md bg-surface-subtle px-3 py-2 text-xs text-ink-secondary">최종 사정이 이미 확정된 회차라 기준을 바꿀 수 없습니다.</p>
      )}
      {!canEdit && !locked && (
        <p className="mb-3 rounded-md bg-status-warningSoft px-3 py-2 text-xs text-status-warning">기준 변경은 슈퍼관리자만 할 수 있습니다.</p>
      )}
      <div className="grid gap-3 sm:grid-cols-5">
        {CUTOFF_FIELDS.map((f) => (
          <label key={f.key} className="text-xs font-medium text-ink-secondary">
            {f.label}
            <input
              type="number"
              min="0"
              step="0.1"
              inputMode="decimal"
              value={form[f.key] ?? ''}
              placeholder="적용 안 함"
              disabled={!canEdit || locked}
              onChange={(e) => setForm((cur) => ({ ...cur, [f.key]: e.target.value }))}
              className="mt-1 w-full rounded-md border border-border px-2 py-1.5 text-sm disabled:bg-surface-subtle"
            />
            {f.hint && <span className="mt-0.5 block text-[11px] font-normal text-ink-muted">{f.hint}</span>}
          </label>
        ))}
      </div>
      {(formError || error) && <p className="mt-2 text-xs text-status-danger">{formError || error}</p>}
      {notice && <p className="mt-2 text-xs text-brand-deepGreenStrong">{notice}</p>}
      {canEdit && !locked && (
        <button
          type="button"
          onClick={save}
          disabled={saving || !changed}
          className="mt-3 rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
        >
          {saving ? '저장 중…' : '기준 저장'}
        </button>
      )}
    </div>
  )
}
