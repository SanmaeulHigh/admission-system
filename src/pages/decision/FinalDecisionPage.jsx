// M6b 최종 사정 (마스터 스펙 v1.2 섹션 5.5, 5.6)
// M4 1단계 사정과 동일한 엔진 철학: simulation은 몇 번이든 실행 가능, final은
// 검증 통과 시에만 실제 반영되며 되돌릴 수 없다 — 확정 전 반드시 simulation으로
// 먼저 확인해야 한다.
//
// M4와의 차이: 인천학생추천·사회통합 우선사정 + 일반전형 이월(carryToGeneral)이
// 있어 사전점검(get_final_decision_blockers)을 먼저 보여준다. 심층 4영역 미완료자,
// 학폭 소명 등 위원회 결정 대기자, unfilledTrackPolicy 미확정 여부도 여기서 막힌다.

import { useState, useEffect, useCallback } from 'react'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import StatusBadge from '../../components/status/StatusBadge'
import PageHeader from '../../components/layout/PageHeader'
import CutoffPanel, { cutoffSummary, sameCutoffs } from './CutoffPanel'

const OUTCOME_LABEL = {
  passed: '합격', failed: '불합격', excluded: '제외', manualDecisionRequired: '동점(위원회 결정 필요)',
}

const TRACK_LABEL = { incheon: '인천학생추천', social: '사회통합', general: '일반' }

function trackResultSummary(trackResult) {
  if (!trackResult) return '-'
  const applicable = ['incheon', 'social', 'general']
    .filter((k) => trackResult[k] && trackResult[k] !== 'notApplicable')
    .map((k) => `${TRACK_LABEL[k]}:${OUTCOME_LABEL[trackResult[k]] ?? trackResult[k]}`)
  return applicable.length > 0 ? applicable.join(' / ') : '-'
}

// decision_results.rank는 "최종 판정을 받은 전형 안의 순위"다. 서버(run_final_decision)가
// 일반 → 인천학생추천 → 사회통합 순으로 먼저 있는 순위를 쓰므로, 같은 순서로 전형을 고른다.
function rankTrack(trackResult) {
  if (!trackResult) return null
  for (const k of ['general', 'incheon', 'social']) {
    if (trackResult[k] && trackResult[k] !== 'notApplicable') return k
  }
  return null
}

const TRACK_ORDER = { incheon: 0, social: 1, general: 2 }

function sortResults(rows) {
  return [...rows].sort((a, b) => {
    const ta = a.rank == null ? 9 : TRACK_ORDER[rankTrack(a.track_result)] ?? 8
    const tb = b.rank == null ? 9 : TRACK_ORDER[rankTrack(b.track_result)] ?? 8
    if (ta !== tb) return ta - tb
    if ((a.rank ?? 1e9) !== (b.rank ?? 1e9)) return (a.rank ?? 1e9) - (b.rank ?? 1e9)
    return Number(b.total_score ?? 0) - Number(a.total_score ?? 0)
  })
}

export default function FinalDecisionPage() {
  const { userDoc } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [blockers, setBlockers] = useState(null)
  const [blockersLoading, setBlockersLoading] = useState(true)
  const [run, setRun] = useState(null)
  const [results, setResults] = useState([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [confirmError, setConfirmError] = useState(null)
  const [showFinalConfirm, setShowFinalConfirm] = useState(false)
  const [currentCutoffs, setCurrentCutoffs] = useState(null) // 저장된 합격선·과락선(00080)

  const loadBlockers = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setBlockersLoading(true)
    const { data, error: err } = await supabase.rpc('get_final_decision_blockers', {
      p_year: YEAR,
      p_round: ROUND,
    })
    setBlockersLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setBlockers(data)
  }, [YEAR, ROUND])

  useEffect(() => {
    loadBlockers()
  }, [loadBlockers])

  const loadResults = async (runId) => {
    const { data: runData } = await supabase.from('decision_runs').select('*').eq('id', runId).maybeSingle()
    setRun(runData)

    const { data: resultData } = await supabase
      .from('decision_results')
      .select('*, applicants(name, receipt_no, exam_no, tracks)')
      .eq('run_id', runId)
      .order('rank', { ascending: true, nullsFirst: false })
    setResults(sortResults(resultData || []))
  }

  const handleSimulate = async () => {
    setError(null)
    setLoading(true)
    const { data, error: err } = await supabase.rpc('run_final_decision', {
      p_year: YEAR,
      p_round: ROUND,
      p_mode: 'simulation',
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    await loadResults(data)
    await loadBlockers()
  }

  const handleFinalize = async () => {
    setConfirmError(null)
    setLoading(true)
    const { data, error: err } = await supabase.rpc('run_final_decision', {
      p_year: YEAR,
      p_round: ROUND,
      p_mode: 'final',
    })
    setLoading(false)
    if (err) {
      setConfirmError(err.message)
      return
    }
    setShowFinalConfirm(false)
    await loadResults(data)
    await loadBlockers()
  }

  // 시뮬레이션 뒤에 기준을 바꿨다면, 미리 보지 않은 기준으로 확정하지 않도록 막는다.
  const cutoffsChangedSinceRun = Boolean(run && currentCutoffs && !sameCutoffs(run.cutoffs || {}, currentCutoffs))
  const belowCutoffCount = results.filter((r) => r.track_result?.cutoffReason).length

  const canFinalize =
    run && run.mode === 'simulation' && run.status === 'completed' &&
    run.unresolved_tie_count === 0 && run.blocking_alert_count === 0 &&
    blockers?.ready === true && !cutoffsChangedSinceRun

  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      <PageHeader
        title="최종 사정"
        description={`${YEAR}학년도 신입생 입학전형 · ${roundToText(ROUND)} · 인천학생추천 → 사회통합 → 일반전형 순 우선사정`}
      />

      {/* 사전점검 패널 */}
      <div className="mb-6 rounded-lg border border-border bg-white p-4">
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-ink-primary">사전점검</h3>
          <button
            type="button"
            onClick={loadBlockers}
            disabled={blockersLoading}
            className="text-xs text-ink-muted underline hover:text-ink-secondary disabled:opacity-50"
          >
            새로고침
          </button>
        </div>

        {blockersLoading && <p className="text-sm text-ink-muted">확인 중…</p>}

        {!blockersLoading && blockers?.reason === 'NO_DOCUMENT_FINAL_RUN' && (
          <p className="rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
            확정된 1단계 서류사정(M4 final)이 아직 없습니다. 1단계 사정을 먼저 확정하세요.
          </p>
        )}

        {!blockersLoading && blockers && blockers.reason !== 'NO_DOCUMENT_FINAL_RUN' && (
          <>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
              {[
                { label: '심층평가 완료 후보', value: blockers.candidateCount },
                { label: '심층 미완료', value: blockers.incompleteDeepCount, warn: blockers.incompleteDeepCount > 0 },
                { label: '위원회 결정 대기', value: blockers.reviewPendingCount, warn: blockers.reviewPendingCount > 0 },
                { label: '제외', value: blockers.excludedCount },
                { label: '확인 필요 경보', value: blockers.blockingAlertCount, warn: blockers.blockingAlertCount > 0 },
              ].map((c) => (
                <div key={c.label} className={`rounded-lg border p-3 ${c.warn ? 'border-status-danger bg-status-dangerSoft' : 'border-border'}`}>
                  <p className="text-xs text-ink-muted">{c.label}</p>
                  <p className={`text-lg font-semibold ${c.warn ? 'text-status-danger' : 'text-ink-primary'}`}>{c.value}</p>
                </div>
              ))}
            </div>

            <p className="mt-3 text-xs text-ink-muted">
              모집정원 — 일반 {blockers.quota?.general} / 인천학생추천 {blockers.quota?.incheon} / 사회통합{' '}
              {blockers.quota?.social} · 미충원 정책:{' '}
              <span className={blockers.unfilledTrackPolicy === 'pending' ? 'font-semibold text-status-danger' : 'font-medium text-ink-secondary'}>
                {blockers.unfilledTrackPolicy === 'carryToGeneral' && '일반전형 이월'}
                {blockers.unfilledTrackPolicy === 'remainVacant' && '결원 유지'}
                {(!blockers.unfilledTrackPolicy || blockers.unfilledTrackPolicy === 'pending') && '미확정'}
              </span>
            </p>

            {(blockers.incompleteDeepCount > 0 || blockers.reviewPendingCount > 0 || blockers.blockingAlertCount > 0 ||
              blockers.unfilledTrackPolicy === 'pending' || !blockers.unfilledTrackPolicy) && (
              <p className="mt-3 rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
                위 항목이 해소되지 않으면 최종 확정(final)이 차단됩니다. 시뮬레이션 미리보기는 계속 실행할 수 있습니다.
              </p>
            )}
          </>
        )}
      </div>

      <CutoffPanel year={YEAR} round={ROUND} onLoaded={setCurrentCutoffs} />

      <div className="mb-6 flex flex-wrap gap-2">
        <button
          type="button"
          onClick={handleSimulate}
          disabled={loading || blockers?.reason === 'NO_DOCUMENT_FINAL_RUN'}
          className="rounded-md border border-border px-4 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {loading ? '실행 중…' : '최종 사정 시뮬레이션 실행'}
        </button>
        {run && run.mode === 'simulation' && run.status === 'completed' && (
          <button
            type="button"
            onClick={() => { setConfirmError(null); setShowFinalConfirm(true) }}
            disabled={!canFinalize}
            className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            최종 확정 (되돌릴 수 없음)
          </button>
        )}
      </div>

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {run && (
        <div className="mb-6 grid grid-cols-2 gap-3 sm:grid-cols-5">
          {[
            { label: '상태', value: run.status },
            { label: '후보', value: run.candidate_count },
            { label: '결과', value: run.result_count },
            { label: '미해결 동점', value: run.unresolved_tie_count, warn: run.unresolved_tie_count > 0 },
            { label: '확인 필요 경보', value: run.blocking_alert_count, warn: run.blocking_alert_count > 0 },
          ].map((c) => (
            <div key={c.label} className={`rounded-lg border bg-white p-3 ${c.warn ? 'border-status-danger' : 'border-border'}`}>
              <p className="text-xs text-ink-muted">{c.label}</p>
              <p className={`text-lg font-semibold ${c.warn ? 'text-status-danger' : 'text-ink-primary'}`}>{c.value}</p>
            </div>
          ))}
        </div>
      )}

      {run && (
        <p className="mb-4 text-xs text-ink-muted">
          이 결과에 적용된 기준: {cutoffSummary(run.cutoffs || {})}
          {belowCutoffCount > 0 && <> · <b className="text-status-danger">기준 미달 불합격 {belowCutoffCount}명</b></>}
        </p>
      )}

      {cutoffsChangedSinceRun && run?.mode === 'simulation' && (
        <p className="mb-4 rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
          합격선·과락선이 이 시뮬레이션 뒤에 바뀌었습니다. 시뮬레이션을 다시 실행해 결과를 확인해야 최종 확정할 수 있습니다.
        </p>
      )}

      {run?.unresolved_tie_count > 0 && (
        <p className="mb-4 rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
          미해결 동점이 있어 최종 확정이 막혀있습니다. 아래 표에서 "동점(위원회 결정 필요)"로 표시된 지원자에
          대해 입학전형위원회 결정을 기록(record_committee_decision)한 뒤 다시 시뮬레이션하세요.
        </p>
      )}

      {results.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-border bg-white">
          <table className="min-w-full text-sm">
            <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
              <tr>
                <th className="px-3 py-2">순위</th>
                <th className="px-3 py-2">수험번호</th>
                <th className="px-3 py-2">접수번호</th>
                <th className="px-3 py-2">성명</th>
                <th className="px-3 py-2">총점</th>
                <th className="px-3 py-2">전형별 결과</th>
                <th className="px-3 py-2">최종 판정</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {results.map((r) => (
                <tr key={r.applicant_id} className={r.outcome === 'manualDecisionRequired' ? 'bg-status-warningSoft' : ''}>
                  <td className="whitespace-nowrap px-3 py-2">
                    {r.rank == null ? '-' : `${TRACK_LABEL[rankTrack(r.track_result)] ?? ''} ${r.rank}위`.trim()}
                  </td>
                  <td className="px-3 py-2 font-mono font-semibold">{r.applicants?.exam_no || '-'}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-muted">{r.applicants?.receipt_no}</td>
                  <td className="px-3 py-2">{r.applicants?.name}</td>
                  <td className="px-3 py-2">{r.total_score ?? '-'}</td>
                  <td className="px-3 py-2 text-xs text-ink-secondary">{trackResultSummary(r.track_result)}</td>
                  <td className="px-3 py-2">
                    <StatusBadge
                      label={OUTCOME_LABEL[r.outcome]}
                      tone={r.outcome === 'passed' ? 'success' : r.outcome === 'manualDecisionRequired' ? 'warning' : 'neutral'}
                    />
                    {r.track_result?.cutoffReason && (
                      <p className="mt-1 text-[11px] text-status-danger">{r.track_result.cutoffReason}</p>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <TypedConfirmDialog
        open={showFinalConfirm}
        title="최종 확정 — 되돌릴 수 없습니다"
        description="확정하면 최종 합격자가 전형별로 일괄 결정됩니다."
        fields={[
          { label: '확정 대상', value: `${YEAR}학년도 ${roundToText(ROUND)}` },
          { label: '합격선·과락선', value: cutoffSummary(currentCutoffs || {}) },
          { label: '확정자', value: userDoc?.display_name || '—' },
        ]}
        confirmPhrase="확정합니다"
        confirmLabel="최종 확정 실행"
        onConfirm={handleFinalize}
        onCancel={() => setShowFinalConfirm(false)}
        submitting={loading}
        error={confirmError}
      />
    </div>
  )
}
