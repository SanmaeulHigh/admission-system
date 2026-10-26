// UX1-D — 1단계 사정 안전 UX (명세서 13장).
// "계산 → 검토 → 확정" 3단계로 나눈다. 확정 버튼은 검토를 마치기 전에는
// 아예 안 보인다. M4 RPC(run_document_decision) 동작 자체는 그대로다 —
// simulation은 몇 번이든, final은 검증 통과 시에만.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import StatusBadge from '../../components/status/StatusBadge'
import DocumentResultSmsPanel from './DocumentResultSmsPanel'

const OUTCOME_LABEL = {
  passed: '합격', failed: '불합격', excluded: '제외', manualDecisionRequired: '동점(위원회 결정 필요)',
}

export default function DocumentDecisionPage() {
  const { userDoc } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [run, setRun] = useState(null)
  const [results, setResults] = useState([])
  const [incompleteCount, setIncompleteCount] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [reviewed, setReviewed] = useState(false)
  const [showFinalConfirm, setShowFinalConfirm] = useState(false)
  const [confirmError, setConfirmError] = useState(null)

  const loadResults = async (runId) => {
    const { data: runData } = await supabase.from('decision_runs').select('*').eq('id', runId).maybeSingle()
    setRun(runData)

    const { data: resultData } = await supabase
      .from('decision_results')
      .select('*, applicants(name, receipt_no)')
      .eq('run_id', runId)
      .order('rank', { ascending: true, nullsFirst: false })
    setResults(resultData || [])

    try {
      const { data: progress } = await supabase.rpc('get_evaluation_progress', {
        target_year: YEAR,
        target_round: ROUND,
      })
      setIncompleteCount((progress || []).filter((row) => !row.complete).length)
    } catch {
      setIncompleteCount(null)
    }
  }

  const handleCalculate = async () => {
    setError(null)
    setLoading(true)
    setReviewed(false)
    const { data, error: err } = await supabase.rpc('run_document_decision', {
      p_year: YEAR,
      p_round: ROUND,
      p_mode: 'simulation',
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    loadResults(data)
  }

  const handleFinalize = async () => {
    setConfirmError(null)
    setLoading(true)
    const { data, error: err } = await supabase.rpc('run_document_decision', {
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
    setReviewed(false)
    loadResults(data)
  }

  const noIncomplete = incompleteCount === 0
  const noTies = run?.unresolved_tie_count === 0
  const noBlocking = run?.blocking_alert_count === 0
  const allReady = run?.status === 'completed' && noIncomplete && noTies && noBlocking
  const passCount = results.filter((r) => r.outcome === 'passed').length
  const alreadyFinalized = run?.status === 'finalized'

  const ChecklistItem = ({ ok, label }) => (
    <li className={`flex items-center gap-2 text-sm ${ok ? 'text-brand-deepGreenStrong' : 'text-status-danger'}`}>
      <span>{ok ? '✓' : '✗'}</span>
      <span>{label}</span>
    </li>
  )

  return (
    <div className="mx-auto max-w-4xl">
      <h2 className="mb-1 text-lg font-semibold text-ink-primary">1단계 사정</h2>
      <p className="mb-6 text-sm text-ink-secondary">{YEAR}학년도 신입생 입학전형 · {roundToText(ROUND)}</p>

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {/* 단계 1: 계산 (또는 이미 확정된 경우 안내) */}
      {alreadyFinalized ? (
        <div className="mb-6 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-4">
          <p className="text-sm font-semibold text-brand-deepGreenStrong">1단계 사정 결과가 확정되어 있습니다.</p>
          <p className="mt-1 text-sm text-ink-secondary">합격 {passCount}명 · 확정 시각 {new Date(run.finalized_at).toLocaleString('ko-KR')}</p>
        </div>
      ) : !run ? (
        <div className="mb-6 rounded-lg border border-border bg-surface-card p-5">
          <p className="mb-3 text-sm text-ink-secondary">
            현재 평가자료를 기준으로 사정 결과를 계산합니다. 계산만으로 결과가 확정되지는 않습니다.
          </p>
          <button
            type="button"
            onClick={handleCalculate}
            disabled={loading}
            className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {loading ? '계산 중…' : '사정 결과 계산'}
          </button>
        </div>
      ) : (
        <>
          {/* 단계 2: 검토 요약 */}
          <div className="mb-6 rounded-lg border border-border bg-surface-card p-5">
            <p className="mb-1 text-sm font-semibold text-ink-primary">사정 결과</p>
            <p className="mb-3 text-sm text-ink-secondary">
              {run.candidate_count}명 대상 · {passCount}명 합격 대상
            </p>
            <ul className="mb-4 space-y-1">
              <ChecklistItem ok={noIncomplete !== false} label={noIncomplete === false ? `평가 미완료 ${incompleteCount}건 있음` : '평가 미완료 없음'} />
              <ChecklistItem ok={noTies} label={noTies ? '처리할 동점자 없음' : `처리할 동점자 ${run.unresolved_tie_count}건 있음`} />
              <ChecklistItem ok={noBlocking} label={noBlocking ? '차단 경보 없음' : `확인이 필요한 항목 ${run.blocking_alert_count}건 있음`} />
            </ul>
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={handleCalculate}
                disabled={loading}
                className="rounded-md border border-border px-4 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
              >
                {loading ? '계산 중…' : '다시 계산하기'}
              </button>
              {!reviewed && (
                <button
                  type="button"
                  onClick={() => setReviewed(true)}
                  className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong"
                >
                  사정 결과 검토하기
                </button>
              )}
            </div>
          </div>

          {/* 결과표 (검토 단계 진입 시) */}
          {reviewed && results.length > 0 && (
            <div className="mb-6 overflow-x-auto rounded-lg border border-border bg-surface-card">
              <table className="min-w-full text-sm">
                <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
                  <tr>
                    <th className="px-3 py-2">순위</th>
                    <th className="px-3 py-2">접수번호</th>
                    <th className="px-3 py-2">성명</th>
                    <th className="px-3 py-2">총점</th>
                    <th className="px-3 py-2">판정</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {results.map((r) => (
                    <tr key={r.applicant_id} className={r.outcome === 'manualDecisionRequired' ? 'bg-brand-orangeSoft' : ''}>
                      <td className="px-3 py-2">{r.rank ?? '—'}</td>
                      <td className="px-3 py-2 font-mono">{r.applicants?.receipt_no}</td>
                      <td className="px-3 py-2">{r.applicants?.name}</td>
                      <td className="px-3 py-2">{r.total_score}</td>
                      <td className="px-3 py-2">
                        <StatusBadge
                          label={OUTCOME_LABEL[r.outcome]}
                          tone={r.outcome === 'passed' ? 'success' : r.outcome === 'manualDecisionRequired' ? 'warning' : 'neutral'}
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {!allReady && reviewed && (
            <p className="mb-4 rounded-md bg-brand-orangeSoft px-3 py-2 text-sm text-brand-orangeStrong">
              확인이 필요한 항목이 남아 있어 결과를 확정할 수 없습니다. 동점은 입학전형위원회 결정을 기록한 뒤 다시
              계산하세요.
            </p>
          )}

          {/* 단계 3: 최종 확정 — 검토 완료 + 준비 완료일 때만 노출 */}
          {reviewed && (
            <div className="rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-5">
              <p className="mb-2 text-sm font-semibold text-ink-primary">사정 결과 검토 완료</p>
              <ul className="mb-4 space-y-1">
                <ChecklistItem ok={noIncomplete !== false} label="평가 미완료 없음" />
                <ChecklistItem ok={noBlocking} label="차단 경보 없음" />
                <ChecklistItem ok={noTies} label="동점자 처리 완료" />
                <ChecklistItem ok={run.candidate_count === run.result_count} label="선발 인원 일치" />
              </ul>
              <button
                type="button"
                onClick={() => setShowFinalConfirm(true)}
                disabled={!allReady}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
              >
                1단계 사정 결과 확정
              </button>
            </div>
          )}
        </>
      )}

      {/* 1단계 결과 개별 통보 SMS (확정된 결과만, 00084) */}
      <DocumentResultSmsPanel year={YEAR} round={ROUND} />

      <TypedConfirmDialog
        open={showFinalConfirm}
        title="1단계 사정 결과를 확정하시겠습니까?"
        description="확정 후에는 평가점수 변경과 사정 결과 재계산이 제한됩니다."
        fields={[
          { label: '확정 대상', value: `${YEAR}학년도 ${roundToText(ROUND)}` },
          { label: '합격 대상', value: `${passCount}명` },
          { label: '확정자', value: userDoc?.display_name || '—' },
        ]}
        confirmPhrase="1단계 사정 확정"
        confirmLabel="결과 확정"
        onConfirm={handleFinalize}
        onCancel={() => setShowFinalConfirm(false)}
        submitting={loading}
        error={confirmError}
      />
    </div>
  )
}
