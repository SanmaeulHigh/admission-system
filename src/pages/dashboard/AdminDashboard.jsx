// UX1-B 6.2 — 총괄/관리자 Dashboard.
// "기능 카드 목록"이 아니라 "현재 업무 브리핑"이다: 지금 전형이 어디까지
// 왔는지, 문제가 있는지, 다음 확정 작업이 뭔지를 로그인 즉시 보여준다.
//
// 2026-10-12 재구성(시안 승인):
//  - 브리핑 카드 오른쪽에 "다음 일정까지 D-day"와 다음 할 일 버튼
//  - 진행 단계 막대에 요강의 실제 일정 날짜(config/printNotices.js)
//  - 숫자 카드에 진행률 막대·세부 내용, 확인 필요 목록과 영역별 진행률을 나란히
//  - 자주 쓰는 메뉴 바로가기
//  2026-10-22: 온라인 서류작성기 이용 카드(구글 시트 집계, components/dashboard/FormToolUsageCard)
//
// 전부 기존 RLS·기존 RPC로만 조회한다(새 aggregate RPC 없음 — 명세서 26.10).

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { SeverityIcon } from '../../components/ui/Icon'
import Icon from '../../components/ui/Icon'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { roundToText } from '../../lib/applicantLabels'
import { getScheduleForDashboard, daysUntil, formatMonthDay } from '../../config/printNotices'
import FormToolUsageCard from '../../components/dashboard/FormToolUsageCard'

const STAGE_STEPS = ['원서 접수', '1단계 서류평가', '1단계 사정·발표', '2단계 심층역량평가', '최종 사정·발표']

const AREA_LABEL = {
  attendance: '출결',
  academic: '학업성실도',
  community: '공동체',
  essay: '자기소개서',
  opinion: '학부모소견서',
}
const AREA_ORDER = ['attendance', 'academic', 'community', 'essay', 'opinion']

function computeStageIndex({ stage, hasDocumentDecision }) {
  if (stage === 'pre_receipt') return -1
  if (stage === 'receipt') return 0
  if (stage === 'document_review') return hasDocumentDecision ? 2 : 1
  if (stage === 'deep_evaluation') return 3
  if (stage === 'decision' || stage === 'closed') return 4
  return 0
}

function formatToday() {
  return new Intl.DateTimeFormat('ko-KR', { month: 'long', day: 'numeric', weekday: 'long' }).format(new Date())
}

function stageSentence(data) {
  if (data.stage === 'pre_receipt') return '아직 접수가 시작되지 않았습니다.'
  if (data.stage === 'receipt') return '현재 원서 접수 중입니다.'
  if (data.stage === 'document_review' && !data.hasDocumentDecision) return '1단계 서류평가가 진행 중입니다.'
  if (data.stage === 'document_review' && data.hasDocumentDecision)
    return '1단계 사정이 확정되었습니다. 심층역량평가를 준비하세요.'
  if (data.stage === 'deep_evaluation') return '심층역량평가 준비·진행 중입니다.'
  if (data.stage === 'decision' && !data.hasFinalDecision) return '최종 사정을 검토·확정하는 단계입니다.'
  if (data.stage === 'decision' && data.hasFinalDecision) return '최종 사정이 확정되었습니다. 발표를 준비하세요.'
  if (data.stage === 'closed') return '이번 전형 절차가 종료되었습니다.'
  return ''
}

// 단계별로 "지금 할 일"을 하나만 제시한다. 대시보드에 숫자만 있으면
// 전형 절차에 익숙하지 않은 선생님은 다음에 무엇을 눌러야 할지 알 수 없다.
function nextAction(data) {
  if (data.stage === 'pre_receipt') {
    return { label: '전형 회차 설정 확인', to: '/admin/admission-cycle',
      hint: '접수를 시작하려면 회차 단계를 ‘접수’로 열어야 합니다.' }
  }
  if (data.stage === 'receipt') {
    return { label: '지원자 접수하기', to: '/reception',
      hint: '원서를 받는 대로 등록하고 서류를 올립니다.' }
  }
  if (data.stage === 'document_review' && !data.hasDocumentDecision) {
    return { label: '평가 진행 현황 보기', to: '/evaluation/monitor',
      hint: '평가위원별 제출 상태를 확인하고, 다 끝나면 1단계 사정을 진행합니다.' }
  }
  if (data.stage === 'document_review' && data.hasDocumentDecision) {
    return { label: '심층역량평가 준비 시작', to: '/deep/group-plan',
      hint: '모둠활동·면접·글쓰기 계획을 세우고 확정합니다.' }
  }
  if (data.stage === 'deep_evaluation') {
    return { label: '종이 채점 일괄 입력', to: '/deep/paper-entry',
      hint: '심층역량평가 종이 채점표를 위원별로 입력합니다.' }
  }
  if (data.stage === 'decision' && !data.hasFinalDecision) {
    return { label: '최종 사정 검토·확정', to: '/decision/final',
      hint: '시뮬레이션으로 먼저 확인한 뒤 확정하세요.' }
  }
  if (data.stage === 'decision' && data.hasFinalDecision) {
    return { label: '발표 자료 준비', to: '/decision/final/announce',
      hint: '합격자 문자 발송과 홈페이지 게시용 자료를 만듭니다.' }
  }
  return null
}

// 오늘 기준 다음 일정: 진행 중인 일정이면 "끝나는 날까지", 아니면 "시작하는 날까지"
function upcomingMilestone(schedule) {
  if (!schedule) return null
  const today = new Date()
  for (const row of schedule) {
    const toEnd = daysUntil(row.end, today)
    if (toEnd < 0) continue
    const toStart = daysUntil(row.start, today)
    if (toStart <= 0) {
      return { text: `${row.label} 마감까지 ${toEnd === 0 ? '오늘' : `D-${toEnd}`}`, date: formatMonthDay(row.end) }
    }
    return { text: `${row.label}까지 D-${toStart}`, date: formatMonthDay(row.start) }
  }
  return null
}

function ProgressBar({ percent, tone = 'green' }) {
  const color = tone === 'danger' ? 'bg-status-danger' : 'bg-brand-deepGreen'
  return (
    <div className="h-1.5 overflow-hidden rounded-full bg-surface-subtle" role="presentation">
      <div className={`h-full rounded-full ${color} transition-[width] duration-300`} style={{ width: `${Math.max(0, Math.min(100, percent))}%` }} />
    </div>
  )
}

function StatCard({ label, value, unit, to, warn, children }) {
  return (
    <Link
      to={to}
      className={`group block rounded-xl border p-4 hover:border-brand-deepGreen ${
        warn ? 'border-status-danger/40 bg-status-dangerSoft' : 'border-border bg-surface-card'
      }`}
    >
      <p className="text-xs font-medium text-ink-muted">{label}</p>
      <p className={`mt-1 text-3xl font-bold tabular-nums ${warn ? 'text-status-danger' : 'text-ink-primary'}`}>
        {value}
        {unit && <span className="ml-0.5 text-sm font-semibold text-ink-muted">{unit}</span>}
      </p>
      <div className="mt-2.5">{children}</div>
    </Link>
  )
}

export default function AdminDashboard() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const { hasRole } = useAuth()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [data, setData] = useState(null)

  useEffect(() => {
    if (!YEAR || !ROUND) return
    let cancelled = false

    async function load() {
      setLoading(true)
      setError(null)

      const [roundRes, alertsRes, rosterRes, finalRunRes] = await Promise.all([
        supabase
          .from('admission_rounds')
          .select('stage, stage_status, document_decision_run_id')
          .eq('year', YEAR)
          .eq('round', ROUND)
          .maybeSingle(),
        supabase
          .from('evaluation_alerts')
          .select('id, area, severity, summary, created_at')
          .eq('year', YEAR)
          .eq('round', ROUND)
          .eq('status', 'open')
          .order('severity', { ascending: true })
          .order('created_at', { ascending: false })
          .limit(5),
        supabase
          .from('evaluation_roster')
          .select('applicant_id', { count: 'exact', head: true })
          .eq('year', YEAR)
          .eq('round', ROUND)
          .eq('evaluation_active', true),
        supabase
          .from('decision_runs')
          .select('id, status')
          .eq('year', YEAR)
          .eq('round', ROUND)
          .eq('decision_type', 'final')
          .eq('status', 'finalized')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle(),
      ])

      if (cancelled) return

      const err = roundRes.error || alertsRes.error || rosterRes.error || finalRunRes.error
      if (err) {
        setError(err.message)
        setLoading(false)
        return
      }

      const round = roundRes.data
      const documentRunId = round?.document_decision_run_id || null

      let documentPassedCount = null
      if (documentRunId) {
        const { count } = await supabase
          .from('decision_results')
          .select('applicant_id', { count: 'exact', head: true })
          .eq('run_id', documentRunId)
          .eq('outcome', 'passed')
        documentPassedCount = count
      }

      // 영역별 서류평가 진행(지원자×영역 단위로 필요 제출 수를 채웠는지)
      let progressRows = null
      try {
        const { data: progress, error: progressErr } = await supabase.rpc('get_evaluation_progress', {
          target_year: YEAR,
          target_round: ROUND,
        })
        if (!progressErr) progressRows = progress || []
      } catch {
        progressRows = null
      }

      if (cancelled) return

      setData({
        stage: round?.stage || 'pre_receipt',
        stageStatus: round?.stage_status || 'closed',
        hasDocumentDecision: !!documentRunId,
        hasFinalDecision: !!finalRunRes.data,
        alerts: alertsRes.data || [],
        candidateCount: rosterRes.count ?? 0,
        documentPassedCount,
        progressRows,
      })
      setLoading(false)
    }

    load()
    return () => {
      cancelled = true
    }
  }, [YEAR, ROUND])

  const schedule = useMemo(() => getScheduleForDashboard(YEAR, ROUND), [YEAR, ROUND])

  const areaStats = useMemo(() => {
    if (!data?.progressRows) return null
    const by = {}
    for (const row of data.progressRows) {
      if (!by[row.area]) by[row.area] = { done: 0, total: 0 }
      by[row.area].total += 1
      if (row.complete) by[row.area].done += 1
    }
    return AREA_ORDER.filter((a) => by[a]).map((a) => ({ area: a, ...by[a] }))
  }, [data])

  if (loading) return <p className="text-sm text-ink-muted">불러오는 중…</p>
  if (error) return <p role="alert" className="rounded-md bg-status-dangerSoft px-4 py-3 text-sm text-status-danger">{error}</p>
  if (!data) return null

  const stageIndex = computeStageIndex(data)
  const blockingCount = data.alerts.filter((a) => a.severity === 'blocking').length
  const action = nextAction(data)
  const milestone = upcomingMilestone(schedule)
  // 일정 날짜는 본전형처럼 단계 수(5)가 맞을 때만 단계 막대에 붙인다
  const stepDates = schedule && schedule.length === STAGE_STEPS.length ? schedule : null

  const totalCells = areaStats?.reduce((s, a) => s + a.total, 0) ?? 0
  const doneCells = areaStats?.reduce((s, a) => s + a.done, 0) ?? 0
  const percent = totalCells ? Math.round((doneCells / totalCells) * 100) : null
  const incompleteCells = totalCells - doneCells
  const behindAreas = (areaStats || [])
    .filter((a) => a.done < a.total)
    .sort((x, y) => (y.total - y.done) - (x.total - x.done))
    .slice(0, 2)

  const quickLinks = [
    { label: '지원자 목록', hint: '접수·서류 관리', to: '/reception' },
    hasRole('superadmin')
      ? { label: '실시간 채점 현황', hint: '점수·편차·재개방', to: '/evaluation/live-monitor' }
      : { label: '평가 진행 현황', hint: '영역별 제출 상태', to: '/evaluation/monitor' },
    { label: '수험표 일괄 인쇄', hint: 'A4 실제 크기', to: '/reception/exam-tickets' },
    { label: '1단계 사정', hint: '시뮬레이션 → 확정', to: '/decision/document' },
  ]

  return (
    <div className="space-y-5">
      {/* 브리핑 + 진행 단계 */}
      <section className="overflow-hidden rounded-2xl border border-border bg-surface-card" aria-labelledby="briefing-title">
        <div className="flex flex-wrap items-start justify-between gap-4 p-5 sm:p-6">
          <div className="min-w-0">
            <p className="text-sm text-ink-muted">
              {YEAR}학년도 {roundToText(ROUND)} · {formatToday()}
            </p>
            <h1 id="briefing-title" className="mt-1.5 text-2xl font-bold leading-snug tracking-tight text-ink-primary">
              {stageSentence(data)}
            </h1>
            {action && <p className="mt-1 text-sm text-ink-secondary">{action.hint}</p>}
          </div>
          <div className="flex flex-col items-start gap-3 sm:items-end">
            {milestone && (
              <span className="inline-flex items-center rounded-full bg-brand-orangeSoft px-3 py-1 text-xs font-bold text-brand-orangeStrong">
                {milestone.text} · {milestone.date}
              </span>
            )}
            {action && (
              <Link
                to={action.to}
                className="inline-flex items-center gap-1.5 rounded-xl bg-brand-deepGreen px-5 py-3 text-sm font-bold text-white hover:bg-brand-deepGreenStrong"
              >
                {action.label}
                <Icon name="chevronRight" size={16} />
              </Link>
            )}
          </div>
        </div>

        <ol className="grid grid-cols-1 border-t border-border sm:grid-cols-5" aria-label="전형 진행 단계">
          {STAGE_STEPS.map((label, i) => {
            const state = i < stageIndex ? 'done' : i === stageIndex ? 'current' : 'pending'
            const row = stepDates?.[i]
            const dateText = row
              ? row.start.getTime() === row.end.getTime()
                ? formatMonthDay(row.start)
                : `${formatMonthDay(row.start)} ~ ${formatMonthDay(row.end)}`
              : null
            return (
              <li
                key={label}
                aria-current={state === 'current' ? 'step' : undefined}
                className={`relative border-border px-4 py-3.5 sm:border-r sm:last:border-r-0 ${
                  state === 'current' ? 'bg-brand-orangeSoft' : ''
                } ${i > 0 ? 'border-t sm:border-t-0' : ''}`}
              >
                <div className="flex items-center gap-2">
                  <span
                    className={`inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
                      state === 'done'
                        ? 'bg-brand-deepGreen text-white'
                        : state === 'current'
                          ? 'bg-brand-orange text-white'
                          : 'bg-surface-subtle text-ink-muted'
                    }`}
                  >
                    {state === 'done' ? <Icon name="check" size={14} strokeWidth={3} /> : i + 1}
                  </span>
                  <span className={`text-sm ${state === 'current' ? 'font-bold text-ink-primary' : state === 'done' ? 'font-medium text-ink-secondary' : 'text-ink-muted'}`}>
                    {label}
                  </span>
                </div>
                {(dateText || state === 'current') && (
                  <p className="mt-1 pl-8 text-xs tabular-nums text-ink-muted">
                    {dateText}
                    {state === 'current' && <span className="font-semibold text-brand-orangeStrong">{dateText ? ' · ' : ''}지금 단계</span>}
                  </p>
                )}
                {state === 'current' && <span className="absolute inset-x-0 bottom-0 h-0.5 bg-brand-orange" aria-hidden="true" />}
              </li>
            )
          })}
        </ol>
      </section>

      {/* 숫자 카드 */}
      <section className="grid grid-cols-2 gap-3 lg:grid-cols-4" aria-label="오늘의 현황">
        <StatCard label="평가 대상 지원자" value={data.candidateCount} unit="명" to="/reception">
          <p className="text-xs text-ink-muted">
            {data.candidateCount === 0
              ? '접수가 완료되면 표시됩니다'
              : data.documentPassedCount !== null
                ? `1단계 합격 ${data.documentPassedCount}명`
                : '1단계 사정 전'}
          </p>
        </StatCard>
        <StatCard
          label="서류평가 진행률"
          value={percent === null ? '—' : percent}
          unit={percent === null ? '' : '%'}
          to="/evaluation/monitor"
        >
          {percent === null ? (
            <p className="text-xs text-ink-muted">평가가 시작되면 표시됩니다</p>
          ) : (
            <ProgressBar percent={percent} />
          )}
        </StatCard>
        <StatCard
          label="미제출 평가"
          value={percent === null ? '—' : incompleteCells}
          unit={percent === null ? '' : '건'}
          to="/evaluation/monitor"
          warn={incompleteCells > 0 && percent !== null}
        >
          <p className={`text-xs ${incompleteCells > 0 ? 'text-status-danger' : 'text-ink-muted'}`}>
            {percent === null
              ? '평가가 시작되면 표시됩니다'
              : incompleteCells === 0
                ? '모든 영역 제출 완료'
                : behindAreas.map((a) => `${AREA_LABEL[a.area]} ${a.total - a.done}`).join(' · ') + ' 남음'}
          </p>
        </StatCard>
        <StatCard label="확인 필요 경보" value={data.alerts.length} unit="건" to="/evaluation/monitor" warn={blockingCount > 0}>
          <p className={`text-xs ${blockingCount > 0 ? 'text-status-danger' : 'text-ink-muted'}`}>
            {blockingCount > 0 ? `사정을 막는 문제 ${blockingCount}건` : '사정을 막는 문제 없음'}
          </p>
        </StatCard>
      </section>

      {/* 확인 필요 + 영역별 진행 */}
      <div className="grid gap-4 lg:grid-cols-5">
        <section className="rounded-2xl border border-border bg-surface-card p-5 lg:col-span-3" aria-labelledby="alerts-title">
          <div className="mb-2 flex items-center justify-between gap-2">
            <h2 id="alerts-title" className="text-base font-semibold text-ink-primary">지금 확인이 필요합니다</h2>
            <Link to="/evaluation/monitor" className="text-xs font-semibold text-brand-blue hover:underline">
              평가 진행 현황 →
            </Link>
          </div>
          {data.alerts.length === 0 ? (
            <p className="flex items-center gap-2 py-3 text-sm text-ink-secondary">
              <Icon name="check" size={16} className="text-brand-deepGreen" />
              지금 확인할 문제가 없습니다.
            </p>
          ) : (
            <ul className="divide-y divide-border">
              {data.alerts.map((alert) => (
                <li key={alert.id} className="flex items-start gap-2.5 py-2.5">
                  <SeverityIcon severity={alert.severity || 'warning'} className="mt-0.5" />
                  <div className="min-w-0">
                    <p className="text-sm text-ink-primary">{alert.summary}</p>
                    <p className="text-xs text-ink-muted">
                      {new Intl.DateTimeFormat('ko-KR', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(alert.created_at))}
                    </p>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="rounded-2xl border border-border bg-surface-card p-5 lg:col-span-2" aria-labelledby="areas-title">
          <div className="mb-2 flex items-center justify-between gap-2">
            <h2 id="areas-title" className="text-base font-semibold text-ink-primary">영역별 서류평가</h2>
            <Link to="/evaluation/monitor" className="text-xs font-semibold text-brand-blue hover:underline">
              자세히 →
            </Link>
          </div>
          {!areaStats || areaStats.length === 0 ? (
            <p className="py-3 text-sm text-ink-muted">평가가 시작되면 영역별 진행률이 표시됩니다.</p>
          ) : (
            <ul className="space-y-2.5 pt-1">
              {areaStats.map((a) => (
                <li key={a.area} className="grid grid-cols-[6.5rem_1fr_3.5rem] items-center gap-3">
                  <span className="text-sm text-ink-secondary">{AREA_LABEL[a.area]}</span>
                  <ProgressBar percent={a.total ? (a.done / a.total) * 100 : 0} />
                  <span className="text-right text-xs tabular-nums text-ink-secondary">
                    {a.done}/{a.total}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      {/* 온라인 서류작성기 이용(구글 시트 집계) — 접수 전후에만 의미가 있어 서류평가 단계까지 보인다 */}
      {['pre_receipt', 'receipt', 'document_review'].includes(data.stage) && (
        <FormToolUsageCard receivedCount={data.stage === 'pre_receipt' ? null : data.candidateCount} />
      )}

      {/* 자주 쓰는 메뉴 */}
      <nav aria-label="자주 쓰는 메뉴" className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {quickLinks.map((q) => (
          <Link
            key={q.to}
            to={q.to}
            className="flex items-center justify-between gap-2 rounded-xl border border-border bg-surface-card px-4 py-3 hover:border-brand-deepGreen"
          >
            <span className="min-w-0">
              <span className="block text-sm font-semibold text-ink-primary">{q.label}</span>
              <span className="block text-xs text-ink-muted">{q.hint}</span>
            </span>
            <Icon name="chevronRight" size={16} className="text-ink-muted" />
          </Link>
        ))}
      </nav>
    </div>
  )
}
