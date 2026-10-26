// UX1-B 6.4 — 정량평가 담당 Dashboard.
// 출결·학업성실도 담당자는 본인 담당 영역(미입력·재개방·자료미비)만 본다.

import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

const AREA_LABEL = { attendance: '출결', academic: '학업성실도' }
const AREA_TABLE = { attendance: 'scores_attendance', academic: 'scores_academic' }

export default function QuantDashboard() {
  const { userDoc, session } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [loading, setLoading] = useState(true)
  const [rosterTotal, setRosterTotal] = useState(0)
  const [progress, setProgress] = useState({})
  const [reopenedCount, setReopenedCount] = useState(0)

  const assignedAreas = (userDoc?.assigned_areas || []).filter((a) => AREA_TABLE[a])
  const evaluatorUid = session?.user?.id

  useEffect(() => {
    if (!evaluatorUid || !YEAR || !ROUND) return
    let cancelled = false

    async function load() {
      setLoading(true)
      const { count: total } = await supabase
        .from('evaluation_roster')
        .select('applicant_id', { count: 'exact', head: true })
        .eq('year', YEAR)
        .eq('round', ROUND)
        .eq('evaluation_active', true)

      const results = await Promise.all(
        assignedAreas.map((area) =>
          supabase
            .from(AREA_TABLE[area])
            .select('applicant_id', { count: 'exact', head: true })
            .eq('evaluator_uid', evaluatorUid)
            .eq('submission_state', 'submitted'),
        ),
      )
      const reopenedResults = await Promise.all(
        assignedAreas.map((area) =>
          supabase
            .from(AREA_TABLE[area])
            .select('applicant_id', { count: 'exact', head: true })
            .eq('evaluator_uid', evaluatorUid)
            .eq('submission_state', 'reopened'),
        ),
      )

      if (cancelled) return
      setRosterTotal(total ?? 0)
      setProgress(Object.fromEntries(assignedAreas.map((a, i) => [a, results[i].count ?? 0])))
      setReopenedCount(reopenedResults.reduce((sum, r) => sum + (r.count ?? 0), 0))
      setLoading(false)
    }

    load()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [evaluatorUid, YEAR, ROUND])

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-ink-primary">안녕하세요, {userDoc?.display_name ? `${userDoc.display_name} 선생님` : '선생님'}.</h1>
        <p className="mt-1 text-sm text-ink-secondary">정량평가(출결·학업성실도) 담당 화면입니다.</p>
      </div>

      {loading ? (
        <p className="text-sm text-ink-muted">불러오는 중…</p>
      ) : (
        <>
          <div>
            <h2 className="mb-3 text-base font-semibold text-ink-primary">내 입력 현황</h2>
            <div className="space-y-3">
              {assignedAreas.map((area) => {
                const done = progress[area] ?? 0
                const remaining = Math.max(0, rosterTotal - done)
                return (
                  <div
                    key={area}
                    className="flex items-center justify-between rounded-lg border border-border bg-surface-card px-4 py-3"
                  >
                    <div>
                      <p className="text-sm font-semibold text-ink-primary">{AREA_LABEL[area]}</p>
                      <p className="text-xs text-ink-muted">
                        {done} / {rosterTotal} 입력 완료{remaining > 0 ? ` · 미입력 ${remaining}명` : ''}
                      </p>
                    </div>
                    <Link
                      to="/evaluation"
                      className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong"
                    >
                      {remaining > 0 ? '입력 계속하기' : '확인하기'}
                    </Link>
                  </div>
                )
              })}
              {assignedAreas.length === 0 && (
                <p className="rounded-lg border border-dashed border-border bg-surface-card p-4 text-sm text-ink-muted">
                  아직 배정된 정량평가 영역이 없습니다. 관리자에게 문의하세요.
                </p>
              )}
            </div>
          </div>

          {reopenedCount > 0 && (
            <div className="rounded-lg border border-brand-orangeStrong bg-brand-orangeSoft px-4 py-3">
              <p className="text-sm font-semibold text-brand-orangeStrong">재개방된 평가가 {reopenedCount}건 있습니다</p>
              <p className="mt-1 text-xs text-ink-secondary">관리자가 수정을 요청한 건입니다. 다시 확인해 주세요.</p>
              <Link to="/evaluation" className="mt-2 inline-block text-xs font-semibold text-brand-orangeStrong hover:underline">
                확인하기 →
              </Link>
            </div>
          )}
        </>
      )}
    </div>
  )
}
