// M3e 학부모 소견서 채점 (evaluator) — 5기준, 기준당 0~5점 0.5단위, 4인 합산 최대 100.
// 근거: 2026학년도 서류평가 업무 진행 지침 4.(5).
//
// 2026-07-09 수정: 기존 제출 내역 불러오기 + 제출확정 후 읽기전용 처리 추가.

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { CommonPrinciples, Confidential, confirmAllSame, isAllSameScore, useRubric } from '../../components/rubric/Rubric'
import RubricScorePicker from '../../components/rubric/RubricScorePicker'

const CRITERIA = [
  { key: 'altEducationUnderstanding', label: '① 대안교육 이해' },
  { key: 'schoolUnderstanding', label: '② 학교 이해' },
  { key: 'childUnderstanding', label: '③ 자녀 이해' },
  { key: 'childCareerView', label: '④ 자녀 진로관' },
  { key: 'admissionWillParticipation', label: '⑤ 입학·참여의지' },
]

const STEP_OPTIONS = Array.from({ length: 11 }, (_, i) => i * 0.5) // 0, 0.5, ..., 5

// proxy를 넘기면 관리자가 그 평가위원을 대신해 입력하는 모드가 된다.
// 화면·검증은 동일하고 호출 RPC만 admin_* 로 바뀐다(계산은 서버에서 같은 경로).
export default function OpinionScoreForm({ applicantId, onSubmitted, proxy }) {
  const { session } = useAuth()
  const evaluatorUid = proxy?.evaluatorUid ?? session?.user?.id
  const [items, setItems] = useState({})
  const [contradiction, setContradiction] = useState(false)
  const [omittedSensitiveInfo, setOmittedSensitiveInfo] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [loadingExisting, setLoadingExisting] = useState(true)
  const [alreadySubmitted, setAlreadySubmitted] = useState(false)
  const [error, setError] = useState(null)
  const [result, setResult] = useState(null)
  // 채점기준표(대외비, DB에서 권한 확인 후 받아 옴)
  const rubric = useRubric('opinion')
  const deductionText = (key) => (rubric?.deductions || []).find((d) => d.key === key)?.text

  const filledCount = CRITERIA.filter((c) => items[c.key] !== undefined).length

  useEffect(() => {
    if (!evaluatorUid) return
    let active = true
    setLoadingExisting(true)
    setResult(null)
    setAlreadySubmitted(false)
    supabase
      .from('scores_opinion')
      .select('items, server_computed, submission_state, deduction_flags')
      .eq('applicant_id', applicantId)
      .eq('evaluator_uid', evaluatorUid)
      .maybeSingle()
      .then(({ data }) => {
        if (!active) return
        if (data) {
          setItems(data.items || {})
          setContradiction(!!data.deduction_flags?.contradiction)
          setOmittedSensitiveInfo(!!data.deduction_flags?.omittedSensitiveInfo)
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
    if (filledCount < CRITERIA.length) {
      setError('5개 기준을 모두 입력해야 제출할 수 있습니다.')
      return
    }
    if (!proxy && isAllSameScore(items, CRITERIA.map((c) => c.key))
        && !confirmAllSame(CRITERIA.length, Number(items[CRITERIA[0].key]))) {
      return
    }
    setSubmitting(true)
    const opinionArgs = {
      p_applicant_id: applicantId,
      p_items: items,
      p_deduction_flags: { contradiction, omittedSensitiveInfo },
    }
    const { data, error: err } = proxy
      ? await supabase.rpc('admin_submit_opinion_score', {
        ...opinionArgs,
        p_target_evaluator_uid: proxy.evaluatorUid,
        p_reason_code: proxy.reasonCode,
        p_reason_text: proxy.reasonText || null,
      })
      : await supabase.rpc('submit_opinion_score', opinionArgs)
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
      <h3 className="mb-3 text-sm font-semibold text-ink-primary">학부모 소견서 채점</h3>
      {loadingExisting ? (
        <p className="text-xs text-ink-muted">기존 제출 내역 확인 중…</p>
      ) : (
        <>
          {alreadySubmitted ? (
            <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">
              이미 제출확정된 채점입니다 — 합계 {result?.total}점. 수정하려면 관리자에게 재개방을 요청하세요.
            </p>
          ) : (
            <p className="mb-3 text-xs text-ink-muted">
              기준마다 해당하는 문장을 눌러 점수를 고르세요(0.5점 단위).
            </p>
          )}

          <form onSubmit={handleSubmit} className="space-y-3">
            <CommonPrinciples />
            <fieldset disabled={alreadySubmitted} className="space-y-3 disabled:opacity-60">
              {/* 기준표 문장이 곧 점수 버튼(기준표가 없으면 0.5점 단위 숫자 버튼) — 2026-10-16 */}
              <RubricScorePicker
                criteria={CRITERIA}
                rubric={rubric}
                scale="opinion"
                items={items}
                disabled={alreadySubmitted}
                onChange={(key, value) => setItems((prev) => ({ ...prev, [key]: value }))}
              />
              {rubric?.footnote && <p className="select-none text-[11px] text-ink-muted">※ {rubric.footnote}</p>}

              <div className="space-y-1 border-t pt-3">
                <p className="text-xs font-medium text-ink-secondary">감점 사유 표시 (자동 감점 아님 · 위원이 해당 기준 점수에 직접 반영)</p>
                {/* 힌트(?)를 label 밖에 둔다 — 안에 두면 누를 때 체크가 바뀐다 */}
                <div className="flex items-center gap-2">
                  <label className="flex items-center gap-2 text-xs text-ink-secondary">
                    <input type="checkbox" checked={contradiction} onChange={(e) => setContradiction(e.target.checked)} />
                    내용 모순
                  </label>
                  <HintIcon text={deductionText('contradiction')} note={rubric?.deductionNote} />
                </div>
                <div className="flex items-center gap-2">
                  <label className="flex items-center gap-2 text-xs text-ink-secondary">
                    <input
                      type="checkbox"
                      checked={omittedSensitiveInfo}
                      onChange={(e) => setOmittedSensitiveInfo(e.target.checked)}
                    />
                    건강·약물 정보 누락
                  </label>
                  <HintIcon text={deductionText('omittedSensitiveInfo')} note={rubric?.deductionNote} />
                </div>
              </div>
            </fieldset>

            {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

            {!alreadySubmitted && (
              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-md bg-brand-deepGreen py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
              >
                {submitting ? '제출 중…' : '제출확정 (되돌릴 수 없음)'}
              </button>
            )}
          </form>
        </>
      )}
    </div>
  )
}

// 커서를 올리거나(터치·키보드는 눌러서 초점) 보이는 감점 판단 힌트. 내용은 대외비 기준표에서 온다.
const DEDUCTION_FALLBACK = '해당하면 위원이 관련 기준 점수에 직접 반영합니다. 체크 표시는 기록으로만 남고 자동 감점되지 않습니다.'
function HintIcon({ text, note }) {
  return (
    <span className="group relative inline-flex">
      <span
        tabIndex={0}
        role="button"
        aria-label="판단 기준 보기"
        className="flex h-4 w-4 cursor-help items-center justify-center rounded-full border border-ink-muted text-[10px] font-bold leading-none text-ink-muted"
      >
        ?
      </span>
      <Confidential className="pointer-events-none absolute bottom-full left-1/2 z-30 mb-1.5 hidden w-64 -translate-x-1/2 rounded-md bg-ink-primary px-2.5 py-2 text-[11px] font-normal leading-relaxed text-white shadow-lg group-hover:block group-focus-within:block">
        {text && <span className="block">{text}</span>}
        <span className={`block ${text ? 'mt-1 text-white/70' : ''}`}>{note || DEDUCTION_FALLBACK}</span>
      </Confidential>
    </span>
  )
}
