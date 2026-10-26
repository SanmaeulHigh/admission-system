// M3a 출결 채점 (quant)
//
// 2026-07-09 수정: 기존 제출 내역을 불러와 표시한다. 제출된 채점은 서버가
// 재제출을 거부하므로(관리자 재개방 필요), 이미 제출된 경우 폼을 읽기전용으로
// 바꾼다 — "다시 제출하면 덮어씁니다"는 틀린 안내라 쓰지 않는다.
import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'

// proxy를 넘기면 관리자가 그 평가위원을 대신해 입력하는 모드가 된다.
// 화면·검증은 동일하고 호출 RPC만 admin_* 로 바뀐다(계산은 서버에서 같은 경로).
export default function AttendanceScoreForm({ applicantId, onSubmitted, proxy }) {
  const { session } = useAuth()
  const evaluatorUid = proxy?.evaluatorUid ?? session?.user?.id
  const [noRecord, setNoRecord] = useState(false)
  const [unexcused, setUnexcused] = useState('')
  const [tardyEtc, setTardyEtc] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [loadingExisting, setLoadingExisting] = useState(true)
  const [alreadySubmitted, setAlreadySubmitted] = useState(false)
  const [error, setError] = useState(null)
  const [result, setResult] = useState(null)

  useEffect(() => {
    if (!evaluatorUid) return
    let active = true
    setLoadingExisting(true)
    setResult(null)
    setAlreadySubmitted(false)
    supabase
      .from('scores_attendance')
      .select('inputs, server_computed, submission_state')
      .eq('applicant_id', applicantId)
      .eq('evaluator_uid', evaluatorUid)
      .maybeSingle()
      .then(({ data }) => {
        if (!active) return
        if (data) {
          setNoRecord(!!data.inputs?.noRecord)
          setUnexcused(data.inputs?.unexcusedAbsences ?? '')
          setTardyEtc(data.inputs?.tardyEarlyResultCount ?? '')
          setResult(data.server_computed)
          setAlreadySubmitted(data.submission_state === 'submitted')
        }
        setLoadingExisting(false)
      })
    return () => {
      active = false
    }
  }, [applicantId, evaluatorUid])

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)
    setSubmitting(true)
    const attendanceArgs = {
      p_applicant_id: applicantId,
      p_unexcused_absences: noRecord ? null : Number(unexcused || 0),
      p_tardy_early_result_count: noRecord ? null : Number(tardyEtc || 0),
      p_no_record: noRecord,
    }
    const { data, error: err } = proxy
      ? await supabase.rpc('admin_submit_attendance_score', {
        ...attendanceArgs,
        p_target_evaluator_uid: proxy.evaluatorUid,
        p_reason_code: proxy.reasonCode,
        p_reason_text: proxy.reasonText || null,
      })
      : await supabase.rpc('submit_attendance_score', attendanceArgs)
    setSubmitting(false)
    if (err) {
      setError(err.message)
      return
    }
    setResult(data)
    setAlreadySubmitted(true)
    onSubmitted?.()
  }

  return (
    <div>
      <h3 className="mb-3 text-sm font-semibold text-ink-primary">출결 채점</h3>
      {loadingExisting ? (
        <p className="text-xs text-ink-muted">기존 제출 내역 확인 중…</p>
      ) : (
        <>
          {alreadySubmitted && (
            <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">
              이미 제출확정된 채점입니다 — 서버 산정 점수: {result?.score}점
              {result?.effectiveAbsenceDays !== null && result?.effectiveAbsenceDays !== undefined
                ? ` (환산 결석 ${result.effectiveAbsenceDays}일)`
                : ''}
              . 수정하려면 관리자에게 재개방을 요청하세요.
            </p>
          )}
          <form onSubmit={handleSubmit} className="space-y-3">
            <fieldset disabled={alreadySubmitted} className="space-y-3 disabled:opacity-60">
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={noRecord} onChange={(e) => setNoRecord(e.target.checked)} />
                학생부 기록 없음 (검정고시 등 — 무증빙 점수 적용)
              </label>

              {!noRecord && (
                <>
                  <div>
                    <label className="mb-1 block text-xs font-medium text-ink-secondary">미인정 결석 (일)</label>
                    <input
                      type="number"
                      min="0"
                      value={unexcused}
                      onChange={(e) => setUnexcused(e.target.value)}
                      className="w-full rounded-md border border-border px-3 py-2 text-sm"
                      required
                    />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs font-medium text-ink-secondary">
                      지각·조퇴·결과 합산 횟수 (3회 = 결석 1일 환산)
                    </label>
                    <input
                      type="number"
                      min="0"
                      value={tardyEtc}
                      onChange={(e) => setTardyEtc(e.target.value)}
                      className="w-full rounded-md border border-border px-3 py-2 text-sm"
                      required
                    />
                  </div>
                </>
              )}
            </fieldset>

            {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

            {!alreadySubmitted && (
              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-md bg-brand-deepGreen py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
              >
                {submitting ? '제출 중…' : '채점 제출'}
              </button>
            )}
          </form>
        </>
      )}
    </div>
  )
}
