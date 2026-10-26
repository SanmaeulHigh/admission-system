// UX1-C — 평가위원 전용 지원자 로스터, "할 일 중심" 재구성.
// 지원 전형·가산점·개인정보·관리자 플래그가 전혀 없는 최소 식별정보만 노출
// (기존 원칙 유지). 여기에 "본인이 이 지원자에 대해 배정 영역을 전부
// 제출했는가"를 계산해 미완료를 먼저 보여준다.

import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import SubmissionState from '../../components/evaluation/SubmissionState'
import FairnessPledgeNotice from '../../components/evaluation/FairnessPledgeNotice'

const DOC_TABLE = { community: 'scores_community', essay: 'scores_essay', opinion: 'scores_opinion' }
const QUANT_TABLE = { attendance: 'scores_attendance', academic: 'scores_academic' }

export default function EvaluationRosterPage() {
  const { userDoc, session } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [roster, setRoster] = useState([])
  const [submittedIds, setSubmittedIds] = useState({}) // { area: Set(applicantId) }
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const evaluatorUid = session?.user?.id
  const myAreas = (userDoc?.assigned_areas || []).filter((a) => DOC_TABLE[a] || QUANT_TABLE[a])

  useEffect(() => {
    if (!evaluatorUid || !YEAR || !ROUND) return
    let active = true

    async function load() {
      setLoading(true)
      const rosterRes = await supabase
        .from('evaluation_roster')
        .select('*')
        .eq('year', YEAR)
        .eq('round', ROUND)
        .eq('evaluation_active', true)
        // 수험번호 순(미부여는 맨 뒤), 같으면 접수번호 순
        .order('exam_no', { ascending: true, nullsFirst: false })
        .order('receipt_no', { ascending: true })

      if (!active) return
      if (rosterRes.error) {
        setError(rosterRes.error.message)
        setLoading(false)
        return
      }

      const areaResults = await Promise.all(
        myAreas.map((area) => {
          const table = DOC_TABLE[area] || QUANT_TABLE[area]
          return supabase
            .from(table)
            .select('applicant_id')
            .eq('evaluator_uid', evaluatorUid)
            .eq('submission_state', 'submitted')
        }),
      )

      if (!active) return
      const byArea = {}
      myAreas.forEach((area, i) => {
        byArea[area] = new Set((areaResults[i].data || []).map((r) => r.applicant_id))
      })

      setRoster(rosterRes.data || [])
      setSubmittedIds(byArea)
      setLoading(false)
    }

    load()
    return () => {
      active = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [evaluatorUid, YEAR, ROUND])

  const rows = roster
    .map((r) => {
      const doneCount = myAreas.filter((area) => submittedIds[area]?.has(r.applicant_id)).length
      return { ...r, doneCount, totalAreas: myAreas.length }
    })
    .sort((a, b) => {
      const aComplete = a.totalAreas > 0 && a.doneCount >= a.totalAreas
      const bComplete = b.totalAreas > 0 && b.doneCount >= b.totalAreas
      if (aComplete !== bComplete) return aComplete ? 1 : -1
      if (!a.exam_no !== !b.exam_no) return a.exam_no ? -1 : 1 // 수험번호 미부여는 뒤로
      return (a.exam_no || '').localeCompare(b.exam_no || '', 'ko', { numeric: true })
        || (a.receipt_no || '').localeCompare(b.receipt_no || '')
    })

  const remainingCount = rows.filter((r) => r.totalAreas > 0 && r.doneCount < r.totalAreas).length

  return (
    <div className="mx-auto max-w-3xl">
      <h2 className="mb-1 text-lg font-semibold text-ink-primary">내 평가</h2>
      <p className="mb-6 text-sm text-ink-secondary">
        {YEAR}학년도 신입생 입학전형 · {roundToText(ROUND)} — 배정된 영역의 서류만 열람 가능합니다.
        {!loading && remainingCount > 0 && ` 아직 ${remainingCount}명 남았습니다.`}
      </p>
      {/* 공정평가 서약 안내(종이 서약, 안내만) — 처음 한 번 팝업, 이후 링크로 다시 보기 */}
      <FairnessPledgeNotice year={YEAR} />

      {loading ? (
        <p className="p-6 text-center text-sm text-ink-muted">불러오는 중…</p>
      ) : error ? (
        <p className="p-6 text-center text-sm text-status-danger">{error}</p>
      ) : rows.length === 0 ? (
        <p className="p-6 text-center text-sm text-ink-muted">
          아직 평가 대상 지원자가 없습니다. (접수가 완료되면 여기 표시됩니다)
        </p>
      ) : (
        <div className="overflow-hidden rounded-lg border border-border bg-surface-card">
          <ul className="divide-y divide-border">
            {rows.map((r) => {
              const complete = r.totalAreas > 0 && r.doneCount >= r.totalAreas
              return (
                <li key={r.applicant_id}>
                  <Link
                    to={`/evaluation/documents/${r.applicant_id}`}
                    className="flex items-center justify-between gap-4 px-4 py-3 hover:bg-surface-subtle"
                  >
                    <div>
                      <p className="text-sm font-medium text-ink-primary">{r.display_name}</p>
                      <p className="font-mono text-xs text-ink-muted">{r.receipt_no}</p>
                    </div>
                    {r.totalAreas > 0 ? (
                      <SubmissionState submitted={r.doneCount} total={r.totalAreas} size="sm" />
                    ) : (
                      <span className="text-xs text-ink-muted">배정 영역 없음</span>
                    )}
                    <span className={`shrink-0 text-xs ${complete ? 'text-brand-deepGreenStrong' : 'text-ink-muted'}`}>
                      {complete ? '완료 ✓' : '열람 →'}
                    </span>
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      )}
    </div>
  )
}
