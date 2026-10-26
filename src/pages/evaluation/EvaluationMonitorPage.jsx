// M3f 관리자 모니터 (스펙 섹션 3.18, 6.10)
// 기본 화면은 진행률·경보만 표시. 개별점수는 사유 선택 후 별도 조회.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import EmptyState from '../../components/feedback/EmptyState'
import ErrorState from '../../components/feedback/ErrorState'
import PageHeader from '../../components/layout/PageHeader'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { CommunityReviewPanel, ScoringQualityPanel } from './DocumentReviewPanels'

const AREA_LABEL = {
  attendance: '출결', academic: '학업성실도', community: '공동체',
  essay: '자소서', opinion: '소견서',
}

const REASON_OPTIONS = ['편차 경보 확인', '입력 오류 확인', '입학전형위원회 협의', '이의·감사 대응', '기타']

export default function EvaluationMonitorPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [recomputing, setRecomputing] = useState(false)
  const [detailTarget, setDetailTarget] = useState(null) // { applicantId, area }

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setError(null)
    const { data, error: err } = await supabase.rpc('get_evaluation_progress', {
      target_year: YEAR,
      target_round: ROUND,
    })
    if (err) setError(err.message)
    else setRows(data || [])
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  const handleRecompute = async () => {
    setRecomputing(true)
    const { error: err } = await supabase.rpc('recompute_evaluation_alerts', {
      target_year: YEAR,
      target_round: ROUND,
    })
    setRecomputing(false)
    if (err) {
      setError(err.message)
      return
    }
    load()
  }

  // 지원자별로 묶기
  const byApplicant = rows.reduce((acc, r) => {
    acc[r.applicant_id] ??= { receiptNo: r.receipt_no, displayName: r.display_name, areas: [] }
    acc[r.applicant_id].areas.push(r)
    return acc
  }, {})

  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      <PageHeader
        title="평가 진행률·경보 모니터"
        description={`${YEAR}학년도 ${roundToText(ROUND)} — 기본 화면에는 진행률·경보만 표시됩니다. 개별점수는 사유 기록 후 조회합니다.`}
        secondaryActions={[{ label: recomputing ? '재계산 중…' : '경보 재계산', onClick: handleRecompute, disabled: recomputing }]}
      />

      {error && <ErrorState description={error} />}

      {loading ? (
        <p className="p-6 text-center text-sm text-ink-muted">불러오는 중…</p>
      ) : Object.keys(byApplicant).length === 0 ? (
        <EmptyState title="평가 대상 지원자가 없습니다" />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-white">
          <table className="min-w-full text-sm">
            <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
              <tr>
                <th className="px-4 py-2 font-medium">접수번호</th>
                <th className="px-4 py-2 font-medium">성명</th>
                {Object.keys(AREA_LABEL).map((a) => (
                  <th key={a} className="px-3 py-2 text-center font-medium">
                    {AREA_LABEL[a]}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {Object.entries(byApplicant).map(([applicantId, info]) => (
                <tr key={applicantId}>
                  <td className="px-4 py-2 font-mono">{info.receiptNo}</td>
                  <td className="px-4 py-2">{info.displayName}</td>
                  {Object.keys(AREA_LABEL).map((area) => {
                    const cell = info.areas.find((a) => a.area === area)
                    if (!cell) return <td key={area} className="px-3 py-2 text-center text-ink-muted">—</td>
                    return (
                      <td key={area} className="px-3 py-2 text-center">
                        <button
                          type="button"
                          onClick={() => setDetailTarget({ applicantId, area })}
                          className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs ${
                            cell.complete
                              ? 'bg-brand-greenSoft text-brand-deepGreenStrong'
                              : 'bg-status-warningSoft text-status-warning'
                          }`}
                        >
                          {cell.submitted}/{cell.required ?? '?'}
                          {cell.open_alerts > 0 && <span className="text-status-danger">⚠{cell.open_alerts}</span>}
                        </button>
                      </td>
                    )
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* 중간 점검(10. 23., 10. 30.) · 공동체 상호 검토 — 2026-10-16 */}
      <ScoringQualityPanel year={YEAR} round={ROUND} />
      <CommunityReviewPanel year={YEAR} round={ROUND} />

      {detailTarget && (
        <ScoreDetailModal
          applicantId={detailTarget.applicantId}
          area={detailTarget.area}
          onClose={() => setDetailTarget(null)}
        />
      )}
    </div>
  )
}

function ScoreDetailModal({ applicantId, area, onClose }) {
  const [reasonCode, setReasonCode] = useState(REASON_OPTIONS[0])
  const [reasonText, setReasonText] = useState('')
  const [evaluatorUid, setEvaluatorUid] = useState('')
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)

  const handleFetch = async () => {
    setError(null)
    setResult(null)
    if (!evaluatorUid.trim()) {
      setError('조회할 위원의 UID를 입력하세요 (users 테이블 id).')
      return
    }
    setLoading(true)
    const { data, error: err } = await supabase.rpc('get_evaluation_score_detail', {
      p_applicant_id: applicantId,
      p_area: area,
      p_target_evaluator_uid: evaluatorUid,
      p_reason_code: reasonCode,
      p_reason_text: reasonCode === '기타' ? reasonText : null,
    })
    setLoading(false)
    if (err) setError(err.message)
    else setResult(data)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-6">
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-base font-semibold text-ink-primary">
            개별점수 상세조회 — {AREA_LABEL[area]}
          </h3>
          <button type="button" onClick={onClose} className="text-sm text-ink-muted hover:text-ink-secondary">
            닫기
          </button>
        </div>

        <p className="mb-3 text-xs text-status-warning">
          이 조회는 감사 로그에 기록됩니다. 정당한 사유가 있을 때만 사용하세요.
        </p>

        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-xs font-medium text-ink-secondary">조회 사유</label>
            <select
              value={reasonCode}
              onChange={(e) => setReasonCode(e.target.value)}
              className="w-full rounded-md border border-border px-3 py-2 text-sm"
            >
              {REASON_OPTIONS.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </div>
          {reasonCode === '기타' && (
            <input
              placeholder="사유를 직접 입력하세요"
              value={reasonText}
              onChange={(e) => setReasonText(e.target.value)}
              className="w-full rounded-md border border-border px-3 py-2 text-sm"
            />
          )}
          <div>
            <label className="mb-1 block text-xs font-medium text-ink-secondary">
              위원 UID (users 테이블에서 확인)
            </label>
            <input
              placeholder="00000000-0000-0000-0000-000000000000"
              value={evaluatorUid}
              onChange={(e) => setEvaluatorUid(e.target.value)}
              className="w-full rounded-md border border-border px-3 py-2 font-mono text-xs"
            />
          </div>

          {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
          {result && (
            <pre className="max-h-64 overflow-auto rounded-md bg-surface-subtle p-3 text-xs">
              {JSON.stringify(result, null, 2)}
            </pre>
          )}

          <button
            type="button"
            onClick={handleFetch}
            disabled={loading}
            className="w-full rounded-md bg-brand-deepGreen py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {loading ? '조회 중…' : '조회 (감사로그 기록됨)'}
          </button>
        </div>
      </div>
    </div>
  )
}
