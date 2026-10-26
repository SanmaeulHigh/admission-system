// 면접 진행표 출력 (2026-09-28)
//
// 면접 조편성(순서·시간)을 조별 종이 진행표로 뽑는다. 본관에서도 교외 주소 + 휴대폰 인증으로
// 접속해 면접위원 화면에서 호출·타이머를 쓰지만, 통신이 끊길 때를 대비해 진행 요원이 이 표로
// 학생·보호자를 안내하고 호출·완료 시각을 적을 수 있게 한다.
// 인쇄 본문은 interviewRunSheetHtml.js.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { buildInterviewRunSheetHtml, fmtTime } from '../../lib/interviewRunSheetHtml'

const COPY_OPTIONS = [
  { value: 'both', label: '진행 요원용 + 면접실용 (조마다 2장)', copies: ['진행 요원용', '면접실용'] },
  { value: 'staff', label: '진행 요원용만', copies: ['진행 요원용'] },
  { value: 'room', label: '면접실용만', copies: ['면접실용'] },
]

export default function InterviewRunSheetPage() {
  const { year, round } = useAdmissionCycle()
  const [plan, setPlan] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)
  const [copyMode, setCopyMode] = useState('both')

  const load = useCallback(async () => {
    if (!year || !round) return
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('get_m5c_interview_plan_admin', { p_year: year, p_round: round })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setPlan(data)
  }, [year, round])

  useEffect(() => {
    load()
  }, [load])

  const candidates = useMemo(() => new Map((plan?.candidates || []).map((c) => [c.applicantId, c])), [plan])
  const evaluators = useMemo(() => new Map((plan?.evaluators || []).map((e) => [e.uid, e.displayName])), [plan])
  const teams = useMemo(
    () => (plan?.teams || []).slice().sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0)),
    [plan],
  )
  const isFinal = ['final', 'finalized'].includes(plan?.validation?.status)

  const print = (teamIds) => {
    if (!plan) return
    const copies = COPY_OPTIONS.find((o) => o.value === copyMode)?.copies
    const w = window.open('', '_blank')
    if (!w) {
      alert('팝업이 차단되었습니다. 이 사이트의 팝업을 허용해 주세요.')
      return
    }
    w.document.open()
    w.document.write(buildInterviewRunSheetHtml(plan, { teamIds, copies }))
    w.document.close()
  }

  return (
    <div className="mx-auto max-w-5xl space-y-4 pb-16">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link to="/deep/paper-backup" className="text-xs text-ink-muted underline">종이 채점표 출력</Link>
          <h1 className="mt-1 text-lg font-semibold text-ink-primary">면접 진행표 출력</h1>
          <p className="mt-1 text-sm text-ink-muted">
            면접조별 순서·예정 시각이 인쇄된 진행표입니다. 진행 요원이 이 표를 보고 글쓰기 고사실에서 학생을 불러오고,
            호출·완료 시각을 적습니다. 평소에는 면접위원 화면의 호출·타이머를 쓰고, 통신이 끊기면 이 표로 그대로 진행합니다.
            면접 조편성과 순서·시간은 &lsquo;면접&rsquo; 계획 화면에서 정합니다.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <select value={copyMode} onChange={(e) => setCopyMode(e.target.value)} className="rounded-md border-border text-sm">
            {COPY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
          <button
            type="button"
            onClick={() => print(null)}
            disabled={!teams.length}
            className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
          >
            전체 조 인쇄
          </button>
        </div>
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}

      {plan && !isFinal && teams.length > 0 && (
        <p className="rounded-md border border-status-warning bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
          면접 계획이 아직 확정되지 않았습니다. 인쇄물에 &lsquo;확정 전 계획 — 운영용 아님&rsquo; 표시가 붙습니다.
        </p>
      )}

      {plan && teams.length === 0 && (
        <p className="rounded-md border border-dashed border-border bg-white p-6 text-center text-sm text-ink-muted">
          면접조가 아직 편성되지 않았습니다. 심층역량평가 → 면접 화면에서 조편성과 순서·시간을 먼저 정하세요.
        </p>
      )}

      <div className="grid gap-3 md:grid-cols-2">
        {teams.map((t) => {
          const schedule = (t.schedule || []).slice().sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
          const first = schedule[0]
          const last = schedule[schedule.length - 1]
          return (
            <section key={t.teamId} className="rounded-card border border-border bg-surface-card p-4">
              <div className="flex items-center justify-between gap-2">
                <h2 className="text-base font-semibold text-ink-primary">
                  면접조 {t.teamCode}
                  {t.location && <span className="ml-2 text-sm font-normal text-ink-secondary">{t.location}</span>}
                </h2>
                <button
                  type="button"
                  onClick={() => print([t.teamId])}
                  className="rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft"
                >
                  이 조만 인쇄
                </button>
              </div>
              <p className="mt-1 text-xs text-ink-secondary">
                위원 {(t.memberUids || []).map((u) => evaluators.get(u)).filter(Boolean).join(', ') || '미배정'}
                {' · '}{schedule.length}명
                {first && ` · ${fmtTime(first.studentStartsAt)} ~ ${fmtTime(last.parentEndsAt)}`}
              </p>
              <ol className="mt-2 space-y-0.5 text-sm">
                {schedule.map((s, i) => {
                  const c = candidates.get(s.applicantId) || {}
                  return (
                    <li key={s.scheduleId || s.applicantId} className="flex gap-2">
                      <span className="w-5 text-right text-xs text-ink-muted">{i + 1}</span>
                      <span className="w-14 font-semibold tabular-nums">{c.examNo}</span>
                      <span className="flex-1">{c.displayName}</span>
                      <span className="text-xs text-ink-muted">
                        학생 {fmtTime(s.studentStartsAt)} · 학부모 {fmtTime(s.parentStartsAt)}
                      </span>
                    </li>
                  )
                })}
              </ol>
            </section>
          )
        })}
      </div>
    </div>
  )
}
