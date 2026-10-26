// UX1-B 6.3 — 평가위원 Dashboard.
// 관리자용 전체 카드를 보여주지 않는다. 본인이 배정된 영역의 진행 상황만 보여준다.
//
// 2026-10-12 재구성(시안 승인):
//  - 인사 카드에 "오늘 남은 서류평가 N건"과 서류평가 마감 D-day, 전체 진행률 원형 표시
//  - 영역마다 할 일 카드(진행 막대 + "이어서 채점"), 끝난 영역은 뒤로
//  - 심층역량평가는 종이 채점표로 운영하므로 시스템 입력 버튼 대신 안내 카드
//  - 버그 수정: 제출 건수를 셀 때 연도·차수로 거르지 않아 테스트 차수 점수까지
//    합산되던 문제

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { getScheduleForDashboard, daysUntil, formatMonthDay } from '../../config/printNotices'
import Icon from '../../components/ui/Icon'

const DOC_AREAS = {
  attendance: { label: '출결', table: 'scores_attendance' },
  academic: { label: '학업성실도', table: 'scores_academic' },
  community: { label: '공동체생활적합성', table: 'scores_community' },
  essay: { label: '자기소개서', table: 'scores_essay' },
  opinion: { label: '학부모소견서', table: 'scores_opinion' },
}
const DEEP_AREAS = {
  group: '모둠활동 관찰',
  interview: '학생·학부모 면접',
  writing: '글쓰기',
}

function dLabel(days) {
  if (days === 0) return '오늘'
  if (days > 0) return `D-${days}`
  return '지남'
}

function ProgressRing({ percent }) {
  const r = 30
  const c = 2 * Math.PI * r
  return (
    <div className="relative h-20 w-20 shrink-0" role="img" aria-label={`전체 진행률 ${percent}%`}>
      <svg viewBox="0 0 72 72" className="h-20 w-20 -rotate-90">
        <circle cx="36" cy="36" r={r} fill="none" stroke="#F1F3F0" strokeWidth="7" />
        <circle
          cx="36" cy="36" r={r} fill="none" stroke="var(--brand-deep-green)" strokeWidth="7" strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={c * (1 - percent / 100)}
          className="transition-[stroke-dashoffset] duration-300"
        />
      </svg>
      <span className="absolute inset-0 flex items-center justify-center text-lg font-bold tabular-nums text-ink-primary">
        {percent}<span className="text-xs font-semibold text-ink-muted">%</span>
      </span>
    </div>
  )
}

export default function EvaluatorDashboard() {
  const { userDoc, session } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [loading, setLoading] = useState(true)
  const [rosterTotal, setRosterTotal] = useState(0)
  const [docDone, setDocDone] = useState({})

  const assignedAreas = userDoc?.assigned_areas || []
  const docAreas = assignedAreas.filter((a) => DOC_AREAS[a])
  const deepAreas = assignedAreas.filter((a) => DEEP_AREAS[a])
  const evaluatorUid = session?.user?.id

  useEffect(() => {
    if (!evaluatorUid || !YEAR || !ROUND) return
    let cancelled = false

    async function load() {
      setLoading(true)
      const [rosterRes, ...docResults] = await Promise.all([
        supabase
          .from('evaluation_roster')
          .select('applicant_id', { count: 'exact', head: true })
          .eq('year', YEAR)
          .eq('round', ROUND)
          .eq('evaluation_active', true),
        ...docAreas.map((area) =>
          supabase
            .from(DOC_AREAS[area].table)
            .select('applicant_id', { count: 'exact', head: true })
            .eq('year', YEAR)
            .eq('round', ROUND)
            .eq('evaluator_uid', evaluatorUid)
            .eq('submission_state', 'submitted'),
        ),
      ])

      if (cancelled) return
      setRosterTotal(rosterRes.count ?? 0)
      setDocDone(Object.fromEntries(docAreas.map((a, i) => [a, docResults[i].count ?? 0])))
      setLoading(false)
    }

    load()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [evaluatorUid, YEAR, ROUND, assignedAreas.join(',')])

  const schedule = useMemo(() => getScheduleForDashboard(YEAR, ROUND), [YEAR, ROUND])
  const docRow = schedule?.find((r) => r.label.includes('서류평가'))
  const deepRow = schedule?.find((r) => r.label.includes('심층'))

  const cards = docAreas
    .map((area) => {
      const done = Math.min(docDone[area] ?? 0, rosterTotal)
      return { area, done, remaining: Math.max(0, rosterTotal - done) }
    })
    .sort((x, y) => (x.remaining === 0) - (y.remaining === 0))

  const totalNeeded = rosterTotal * docAreas.length
  const totalDone = cards.reduce((s, c) => s + c.done, 0)
  const totalRemaining = totalNeeded - totalDone
  const percent = totalNeeded ? Math.round((totalDone / totalNeeded) * 100) : 0
  const name = userDoc?.display_name ? `${userDoc.display_name} 선생님` : '선생님'

  let subline = ''
  if (!loading && docAreas.length > 0) {
    if (rosterTotal === 0) subline = '아직 평가할 지원자가 없습니다. 접수가 끝나면 이곳에 표시됩니다.'
    else if (totalRemaining === 0) subline = '맡으신 서류평가를 모두 마치셨습니다. 수고하셨습니다.'
    else subline = `남은 서류평가는 ${totalRemaining}건입니다.`
  }

  return (
    <div className="space-y-5">
      {/* 인사 */}
      <section className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-border bg-surface-card p-5 sm:p-6">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold tracking-tight text-ink-primary">안녕하세요, {name}.</h1>
          {subline && <p className="mt-1.5 text-sm text-ink-secondary">{subline}</p>}
          {docRow && docAreas.length > 0 && totalRemaining > 0 && (
            <p className="mt-3 inline-flex items-center rounded-full bg-brand-orangeSoft px-3 py-1 text-xs font-bold text-brand-orangeStrong">
              서류평가 {formatMonthDay(docRow.end)}까지 · {dLabel(daysUntil(docRow.end))}
            </p>
          )}
        </div>
        {!loading && totalNeeded > 0 && <ProgressRing percent={percent} />}
      </section>

      {loading ? (
        <p className="text-sm text-ink-muted">불러오는 중…</p>
      ) : (
        <>
          {cards.length > 0 && (
            <section aria-labelledby="my-doc-title">
              <h2 id="my-doc-title" className="mb-3 text-base font-semibold text-ink-primary">내 서류평가</h2>
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {cards.map(({ area, done, remaining }) => {
                  const finished = remaining === 0 && rosterTotal > 0
                  const pct = rosterTotal ? (done / rosterTotal) * 100 : 0
                  return (
                    <div
                      key={area}
                      className={`flex flex-col rounded-xl border p-4 ${finished ? 'border-border bg-surface-subtle' : 'border-border bg-surface-card'}`}
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="rounded-md bg-brand-greenSoft px-2 py-0.5 text-xs font-semibold text-brand-deepGreenStrong">서류평가</span>
                        {finished && (
                          <span className="inline-flex items-center gap-1 text-xs font-semibold text-brand-deepGreenStrong">
                            <Icon name="check" size={14} strokeWidth={3} />완료
                          </span>
                        )}
                      </div>
                      <p className="mt-2 text-base font-bold text-ink-primary">{DOC_AREAS[area].label}</p>
                      <p className="mt-0.5 text-xs tabular-nums text-ink-muted">
                        {rosterTotal}명 중 {done}명 완료{remaining > 0 ? ` · ${remaining}명 남음` : ''}
                      </p>
                      <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-surface-subtle" role="presentation">
                        <div className="h-full rounded-full bg-brand-deepGreen transition-[width] duration-300" style={{ width: `${pct}%` }} />
                      </div>
                      <Link
                        to="/evaluation"
                        className={`mt-4 inline-flex items-center justify-center gap-1 rounded-lg px-3 py-2.5 text-sm font-semibold ${
                          finished
                            ? 'border border-border bg-surface-card text-ink-secondary hover:border-brand-deepGreen'
                            : 'bg-brand-deepGreen text-white hover:bg-brand-deepGreenStrong'
                        }`}
                      >
                        {finished ? '다시 보기' : '이어서 채점'}
                        {!finished && <Icon name="chevronRight" size={16} />}
                      </Link>
                    </div>
                  )
                })}
              </div>
            </section>
          )}

          {deepAreas.length > 0 && (
            <section aria-labelledby="my-deep-title">
              <h2 id="my-deep-title" className="mb-3 text-base font-semibold text-ink-primary">심층역량평가</h2>
              <div className="rounded-xl border border-border bg-surface-card p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-sm font-bold text-ink-primary">
                      {deepAreas.map((a) => DEEP_AREAS[a]).join(' · ')}
                    </p>
                    <p className="mt-1 text-sm text-ink-secondary">
                      당일 종이 채점표로 채점하고, 끝나면 담당자에게 제출해 주세요.
                    </p>
                    <p className="mt-0.5 text-xs text-ink-muted">시스템 입력은 관리자가 합니다.</p>
                  </div>
                  {deepRow && (
                    <span className="inline-flex items-center rounded-full bg-brand-blueSoft px-3 py-1 text-xs font-bold text-brand-blue">
                      {formatMonthDay(deepRow.start)} · {dLabel(daysUntil(deepRow.start))}
                    </span>
                  )}
                </div>
              </div>
            </section>
          )}

          {docAreas.length === 0 && deepAreas.length === 0 && (
            <p className="rounded-xl border border-dashed border-border bg-surface-card p-4 text-sm text-ink-muted">
              아직 배정된 평가 영역이 없습니다. 관리자에게 문의하세요.
            </p>
          )}
        </>
      )}
    </div>
  )
}
