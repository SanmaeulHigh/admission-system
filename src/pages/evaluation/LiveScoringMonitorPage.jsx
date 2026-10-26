// 실시간 채점 현황 (최고관리자 전용, 2026-09-28)
//
// 채점 도중 위원별 채점 여부·점수와 위원 간 편차를 한 화면에서 본다.
// 원래 원칙(관리자는 진행률·경보만)을 최고관리자에 한해 완화한 화면이라,
// 조회할 때마다 감사 기록이 남는다(get_live_scoring_monitor, 00071).
// 읽기 전용 — 점수 수정은 재개방·대리 입력 절차로만 한다.
//
// 자동 새로고침은 30초 간격(켜고 끌 수 있음). 채점 테이블은 관리자에게 직접
// 조회 권한이 없어 실시간 구독 대신 주기적으로 다시 불러온다.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import ReopenScoreButton from '../../components/actions/ReopenScoreButton'

const AREAS = [
  { value: 'attendance', label: '출결', group: '서류평가' },
  { value: 'academic', label: '학업성실도', group: '서류평가' },
  { value: 'community', label: '공동체', group: '서류평가' },
  { value: 'essay', label: '자기소개서', group: '서류평가' },
  { value: 'opinion', label: '학부모소견서', group: '서류평가' },
  { value: 'group', label: '모둠활동', group: '심층역량평가' },
  { value: 'interview_student', label: '학생면접', group: '심층역량평가' },
  { value: 'interview_parent', label: '학부모면접', group: '심층역량평가' },
  { value: 'writing', label: '글쓰기', group: '심층역량평가' },
]

const REFRESH_MS = 30000

function fmt(n, digits = 1) {
  if (n === null || n === undefined || Number.isNaN(n)) return '—'
  return Number.isInteger(n) ? String(n) : n.toFixed(digits)
}

function fmtTime(v) {
  if (!v) return '—'
  return new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(v))
}

// 마지막 제출 시각: 오늘이면 시각만, 다른 날이면 날짜도(2026-10-26 — 어제 입력이 오늘처럼 보이던 문제)
function fmtWhen(v) {
  if (!v) return '—'
  const d = new Date(v)
  const now = new Date()
  const time = new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false }).format(d)
  const sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  if (sameDay) return `오늘 ${time}`
  const wd = ['일', '월', '화', '수', '목', '금', '토'][d.getDay()]
  return `${d.getMonth() + 1}. ${d.getDate()}.(${wd}) ${time}`
}

export default function LiveScoringMonitorPage() {
  const { year, round } = useAdmissionCycle()
  const [area, setArea] = useState('essay')
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)
  const [auto, setAuto] = useState(true)
  const [gapInput, setGapInput] = useState('')
  const [onlyFlagged, setOnlyFlagged] = useState(false)
  const [sortBy, setSortBy] = useState('examNo') // examNo | gap | mean

  const load = useCallback(async () => {
    if (!year || !round) return
    setLoading(true)
    const { data: d, error: err } = await supabase.rpc('get_live_scoring_monitor', {
      p_year: year, p_round: round, p_area: area,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setError(null)
    setData(d)
  }, [year, round, area])

  useEffect(() => {
    setData(null)
    setGapInput('')
    load()
  }, [load])

  useEffect(() => {
    if (!auto) return undefined
    const id = setInterval(() => {
      if (document.visibilityState === 'visible') load()
    }, REFRESH_MS)
    return () => clearInterval(id)
  }, [auto, load])

  const threshold = gapInput !== '' ? Number(gapInput) : (data?.alertGap ?? null)

  const model = useMemo(() => {
    if (!data) return null
    const evaluators = data.evaluators || []
    const expected = new Set(data.expectedEvaluatorUids || [])
    const cell = new Map() // applicantId|uid → score row
    for (const s of data.scores || []) cell.set(`${s.applicantId}|${s.evaluatorUid}`, s)

    const rows = (data.roster || []).map((r) => {
      const submitted = evaluators
        .map((e) => cell.get(`${r.applicantId}|${e.uid}`))
        .filter((s) => s?.state === 'submitted' && s.score !== null && s.score !== undefined)
      const values = submitted.map((s) => Number(s.score))
      const mean = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null
      const gap = values.length >= 2 ? Math.max(...values) - Math.min(...values) : null
      return { ...r, submittedCount: values.length, mean, gap, max: values.length ? Math.max(...values) : null, min: values.length ? Math.min(...values) : null }
    })

    // 위원별 진행·성향(평균이 전체 평균보다 얼마나 높은지/낮은지)
    const allValues = (data.scores || []).filter((s) => s.state === 'submitted' && s.score != null).map((s) => Number(s.score))
    const overallMean = allValues.length ? allValues.reduce((a, b) => a + b, 0) / allValues.length : null
    const evalStats = evaluators.map((e) => {
      const mine = (data.scores || []).filter((s) => s.evaluatorUid === e.uid)
      const sub = mine.filter((s) => s.state === 'submitted' && s.score != null)
      const drafts = mine.filter((s) => s.state !== 'submitted').length
      const avg = sub.length ? sub.reduce((a, s) => a + Number(s.score), 0) / sub.length : null
      // 이 위원이 맡은 지원자와 같은 지원자에 대한 다른 위원 평균과 비교
      let diffSum = 0
      let diffN = 0
      for (const s of sub) {
        const others = (data.scores || []).filter((o) => o.applicantId === s.applicantId && o.evaluatorUid !== e.uid && o.state === 'submitted' && o.score != null)
        if (others.length) {
          const om = others.reduce((a, o) => a + Number(o.score), 0) / others.length
          diffSum += Number(s.score) - om
          diffN += 1
        }
      }
      return {
        ...e,
        expected: expected.has(e.uid),
        submitted: sub.length,
        drafts,
        avg,
        lean: diffN ? diffSum / diffN : null,
        lastAt: sub.reduce((m, s) => (s.submittedAt && (!m || s.submittedAt > m) ? s.submittedAt : m), null),
      }
    })

    return { evaluators, cell, rows, overallMean, evalStats }
  }, [data])

  const shownRows = useMemo(() => {
    if (!model) return []
    let rows = model.rows
    if (onlyFlagged && threshold != null) rows = rows.filter((r) => r.gap != null && r.gap >= threshold)
    const sorted = [...rows]
    if (sortBy === 'gap') sorted.sort((a, b) => (b.gap ?? -1) - (a.gap ?? -1))
    else if (sortBy === 'mean') sorted.sort((a, b) => (b.mean ?? -1) - (a.mean ?? -1))
    else sorted.sort((a, b) => String(a.examNo || a.receiptNo).localeCompare(String(b.examNo || b.receiptNo), 'ko', { numeric: true }))
    return sorted
  }, [model, onlyFlagged, threshold, sortBy])

  const rosterCount = data?.roster?.length || 0
  const doneCount = model ? model.rows.filter((r) => data.requiredSubmissions ? r.submittedCount >= data.requiredSubmissions : r.submittedCount > 0).length : 0
  const flaggedCount = model && threshold != null ? model.rows.filter((r) => r.gap != null && r.gap >= threshold).length : 0

  return (
    <div className="mx-auto max-w-7xl space-y-4 pb-16">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold text-ink-primary">실시간 채점 현황</h1>
          <p className="mt-1 text-xs text-ink-muted">
            최고관리자 전용 · 위원별 점수를 이름과 함께 보여줍니다. 조회 기록이 감사 로그에 남습니다. 점수를 누르면 재개방할 수 있습니다.
          </p>
        </div>
        <div className="flex items-center gap-3 text-xs text-ink-secondary">
          <label className="flex items-center gap-1.5">
            <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} />
            30초마다 자동 새로고침
          </label>
          <button
            type="button"
            onClick={load}
            disabled={loading}
            className="rounded-md border border-border bg-white px-3 py-1.5 font-semibold hover:bg-surface-subtle disabled:opacity-40"
          >
            {loading ? '불러오는 중…' : '새로고침'}
          </button>
          {data?.fetchedAt && <span className="text-ink-muted">{fmtTime(data.fetchedAt)} 기준</span>}
        </div>
      </div>

      <div className="space-y-2">
        {['서류평가', '심층역량평가'].map((g) => (
          <div key={g} className="flex flex-wrap items-center gap-2">
            <span className="w-20 text-xs font-semibold text-ink-muted">{g}</span>
            {AREAS.filter((a) => a.group === g).map((a) => (
              <button
                key={a.value}
                type="button"
                onClick={() => setArea(a.value)}
                className={`rounded-full border px-3 py-1.5 text-xs font-semibold ${area === a.value ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border text-ink-secondary'}`}
              >
                {a.label}
              </button>
            ))}
          </div>
        ))}
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {model && (
        <>
          {/* 요약 */}
          <div className="grid gap-3 sm:grid-cols-4">
            <Stat label="대상" value={`${rosterCount}명`} />
            <Stat label="채점 완료" value={`${doneCount} / ${rosterCount}`} sub={data.requiredSubmissions ? `지원자당 ${data.requiredSubmissions}건 필요` : ''} />
            <Stat label="전체 평균" value={fmt(model.overallMean)} />
            <Stat label="편차 기준 이상" value={threshold != null ? `${flaggedCount}명` : '—'} sub={threshold != null ? `최고−최저 ≥ ${threshold}` : '기준 없음'} tone={flaggedCount ? 'warn' : ''} />
          </div>

          {/* 위원별 */}
          <section className="rounded-card border border-border bg-surface-card p-4">
            <h2 className="text-sm font-semibold text-ink-primary">위원별 진행</h2>
            {model.evalStats.length === 0 ? (
              <p className="mt-2 text-sm text-ink-muted">아직 배정되거나 채점한 위원이 없습니다.</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="min-w-full text-sm">
                  <thead className="text-left text-xs text-ink-secondary">
                    <tr>
                      <th className="px-2 py-1.5 font-semibold">위원</th>
                      <th className="px-2 py-1.5 font-semibold">제출</th>
                      <th className="px-2 py-1.5 font-semibold">작성 중</th>
                      <th className="px-2 py-1.5 font-semibold">진행</th>
                      <th className="px-2 py-1.5 font-semibold">평균 점수</th>
                      <th className="px-2 py-1.5 font-semibold" title="같은 지원자를 채점한 다른 위원 평균과의 차이(평균)">다른 위원 대비</th>
                      <th className="px-2 py-1.5 font-semibold">마지막 제출</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-border">
                    {model.evalStats.map((e) => {
                      const pct = rosterCount ? Math.round((e.submitted / rosterCount) * 100) : 0
                      return (
                        <tr key={e.uid}>
                          <td className="px-2 py-1.5 font-semibold text-ink-primary">
                            {e.name}
                            {!e.expected && data.expectedEvaluatorUids?.length > 0 && (
                              <span className="ml-1 text-[11px] font-normal text-ink-muted">(현재 미배정)</span>
                            )}
                          </td>
                          <td className="px-2 py-1.5 tabular-nums">{e.submitted}</td>
                          <td className="px-2 py-1.5 tabular-nums text-ink-muted">{e.drafts || ''}</td>
                          <td className="px-2 py-1.5">
                            <div className="h-2 w-32 rounded-full bg-surface-subtle">
                              <div className="h-2 rounded-full bg-brand-deepGreen" style={{ width: `${Math.min(pct, 100)}%` }} />
                            </div>
                          </td>
                          <td className="px-2 py-1.5 tabular-nums">{fmt(e.avg)}</td>
                          <td className={`px-2 py-1.5 tabular-nums ${e.lean != null && Math.abs(e.lean) >= (threshold ?? Infinity) / 2 ? 'font-semibold text-status-warning' : ''}`}>
                            {e.lean == null ? '—' : `${e.lean > 0 ? '+' : ''}${fmt(e.lean)}`}
                          </td>
                          <td className="px-2 py-1.5 text-xs text-ink-muted">{fmtWhen(e.lastAt)}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {/* 지원자별 */}
          <section className="rounded-card border border-border bg-surface-card p-4">
            <div className="flex flex-wrap items-center gap-3">
              <h2 className="text-sm font-semibold text-ink-primary">지원자별 점수</h2>
              <label className="ml-auto flex items-center gap-1.5 text-xs text-ink-secondary">
                편차 기준
                <input
                  value={gapInput}
                  onChange={(e) => setGapInput(e.target.value.replace(/[^0-9.]/g, ''))}
                  placeholder={data.alertGap != null ? String(data.alertGap) : '예: 10'}
                  className="w-16 rounded-md border-border py-1 text-xs"
                />
                점 이상
              </label>
              <label className="flex items-center gap-1.5 text-xs text-ink-secondary">
                <input type="checkbox" checked={onlyFlagged} onChange={(e) => setOnlyFlagged(e.target.checked)} />
                기준 이상만
              </label>
              <select value={sortBy} onChange={(e) => setSortBy(e.target.value)} className="rounded-md border-border py-1 text-xs">
                <option value="examNo">수험번호순</option>
                <option value="gap">편차 큰 순</option>
                <option value="mean">평균 높은 순</option>
              </select>
            </div>

            <div className="mt-3 overflow-x-auto">
              <table className="min-w-full text-sm">
                <thead className="border-b border-border text-xs text-ink-secondary">
                  <tr>
                    <th className="px-2 py-2 text-left font-semibold">수험번호</th>
                    <th className="px-2 py-2 text-left font-semibold">성명</th>
                    {model.evaluators.map((e) => (
                      <th key={e.uid} className="px-2 py-2 text-center font-semibold">{e.name}</th>
                    ))}
                    <th className="border-l border-border px-2 py-2 text-center font-semibold">평균</th>
                    <th className="px-2 py-2 text-center font-semibold">최고−최저</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {shownRows.map((r) => {
                    const flagged = threshold != null && r.gap != null && r.gap >= threshold
                    return (
                      <tr key={r.applicantId} className={flagged ? 'bg-status-warningSoft' : ''}>
                        <td className="px-2 py-1.5 font-semibold tabular-nums">{r.examNo || <span className="text-xs text-ink-muted">{r.receiptNo}</span>}</td>
                        <td className="px-2 py-1.5">{r.name}</td>
                        {model.evaluators.map((e) => {
                          const s = model.cell.get(`${r.applicantId}|${e.uid}`)
                          const isMax = s?.state === 'submitted' && r.gap && Number(s.score) === r.max
                          const isMin = s?.state === 'submitted' && r.gap && Number(s.score) === r.min
                          return (
                            <td key={e.uid} className="px-2 py-1.5 text-center tabular-nums">
                              {!s ? (
                                <span className="text-ink-muted">·</span>
                              ) : s.state === 'submitted' ? (
                                // 점수를 누르면 재개방 창이 열린다.
                                <ReopenScoreButton
                                  area={area}
                                  applicantId={r.applicantId}
                                  evaluatorUid={e.uid}
                                  label={fmt(Number(s.score))}
                                  targetText={`${r.examNo || r.receiptNo} ${r.name} · ${e.name}`}
                                  onDone={load}
                                  className={`rounded px-1.5 underline decoration-dotted underline-offset-2 hover:bg-status-warningSoft ${isMax ? 'font-bold text-brand-blue' : ''} ${isMin ? 'font-bold text-status-danger' : ''}`}
                                />
                              ) : (
                                <span className="text-[11px] text-ink-muted">{s.state === 'reopened' ? '재개방' : '작성 중'}</span>
                              )}
                            </td>
                          )
                        })}
                        <td className="border-l border-border px-2 py-1.5 text-center font-semibold tabular-nums">{fmt(r.mean)}</td>
                        <td className={`px-2 py-1.5 text-center tabular-nums ${flagged ? 'font-bold text-status-warning' : ''}`}>{r.gap == null ? '—' : fmt(r.gap)}</td>
                      </tr>
                    )
                  })}
                  {shownRows.length === 0 && (
                    <tr>
                      <td colSpan={model.evaluators.length + 4} className="px-2 py-6 text-center text-sm text-ink-muted">
                        {onlyFlagged ? '편차 기준 이상인 지원자가 없습니다.' : '대상 지원자가 없습니다.'}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
            <p className="mt-2 text-[11px] text-ink-muted">
              점수를 누르면 재개방할 수 있습니다 · 파란색 = 그 지원자의 최고점, 빨간색 = 최저점 · &lsquo;·&rsquo; = 아직 채점 안 함 · &lsquo;작성 중&rsquo;은 임시 저장 상태라 점수를 표시하지 않습니다.
            </p>
          </section>
        </>
      )}
    </div>
  )
}

function Stat({ label, value, sub, tone }) {
  return (
    <div className={`rounded-card border p-3 ${tone === 'warn' ? 'border-status-warning bg-status-warningSoft' : 'border-border bg-surface-card'}`}>
      <p className="text-xs text-ink-muted">{label}</p>
      <p className="mt-1 text-xl font-bold tabular-nums text-ink-primary">{value}</p>
      {sub && <p className="text-[11px] text-ink-muted">{sub}</p>}
    </div>
  )
}
