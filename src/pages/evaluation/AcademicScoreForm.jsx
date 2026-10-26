// M3b 학업성실도 채점 (quant)
// 서버가 상위 5과목을 자동 선정하므로, 화면은 학생부에 있는 과목을
// 전부(또는 아는 만큼) 입력하게 하고 "상위 5과목 서버 자동 선정"임을 안내한다.
//
// 2026-07-09 수정: 기존 제출 내역 불러오기 + 제출확정 후 읽기전용 처리 추가.
// 2026-09-28 수정: 과목 입력칸 5개를 기본으로 띄우고, 입학원서에 적힌 반영 학기를
//   화면 위에 보여준다(get_academic_context). 반영 학기는 서버가 원서 값으로 함께 저장한다.

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'

const ACHIEVEMENT_OPTIONS = ['A', 'B', 'C', 'D', 'E']
const DEFAULT_ROWS = 5 // 요강: 반영 학기의 상위 5개 과목

const emptyRow = () => ({ subject: '', achievement: 'A', rawScore: '' })
const fiveRows = () => Array.from({ length: DEFAULT_ROWS }, emptyRow)

// 원서 학적 → 입력 유형. '기타'(동등학력 인정 등)나 알 수 없으면 null — 그때만 화면에서 고른다.
function typeFromStatus(status) {
  if (status === '검정고시') return 'ged'
  if (status === '졸업예정' || status === '졸업') return 'regular'
  return null
}

function semesterLabel(v) {
  const m = /^([1-3])-([12])$/.exec(String(v || ''))
  return m ? `${m[1]}학년 ${m[2]}학기` : v || ''
}

// proxy를 넘기면 관리자가 그 평가위원을 대신해 입력하는 모드가 된다.
// 화면·검증은 동일하고 호출 RPC만 admin_* 로 바뀐다(계산은 서버에서 같은 경로).
export default function AcademicScoreForm({ applicantId, onSubmitted, proxy }) {
  const { session } = useAuth()
  const evaluatorUid = proxy?.evaluatorUid ?? session?.user?.id
  const [noDocument, setNoDocument] = useState(false)
  const [inputType, setInputType] = useState('regular') // 'regular' | 'ged'
  const [subjects, setSubjects] = useState(fiveRows)
  const [appContext, setAppContext] = useState(null) // { semesterChoice, academicStatus } — 입학원서 값
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
    setSubjects(fiveRows())
    supabase.rpc('get_academic_context', { p_applicant_id: applicantId }).then(({ data }) => {
      if (!active) return
      setAppContext(data || null)
      const fixed = typeFromStatus(data?.academicStatus)
      if (fixed) setInputType(fixed)
    })
    supabase
      .from('scores_academic')
      .select('inputs, server_computed, submission_state')
      .eq('applicant_id', applicantId)
      .eq('evaluator_uid', evaluatorUid)
      .maybeSingle()
      .then(({ data }) => {
        if (!active) return
        if (data) {
          setNoDocument(!!data.inputs?.noDocument)
          setInputType(data.inputs?.inputType || 'regular')
          if (Array.isArray(data.inputs?.subjects) && data.inputs.subjects.length > 0) {
            setSubjects(
              [
                ...data.inputs.subjects.map((s) => ({
                  subject: s.subject || '',
                  achievement: s.achievement || 'A',
                  rawScore: s.rawScore ?? '',
                })),
                // 저장된 과목이 5개보다 적으면 빈 칸을 채워 5줄을 유지
                ...Array.from({ length: Math.max(0, DEFAULT_ROWS - data.inputs.subjects.length) }, emptyRow),
              ],
            )
          }
          setResult(data.server_computed)
          setAlreadySubmitted(data.submission_state === 'submitted')
        }
        setLoadingExisting(false)
      })
    return () => {
      active = false
    }
  }, [applicantId, evaluatorUid])

  // 원서 학적이 졸업예정·졸업·검정고시면 입력 유형을 고정한다(선택 실수 방지).
  const lockedType = typeFromStatus(appContext?.academicStatus)

  const updateSubject = (i, field, value) => {
    setSubjects((prev) => prev.map((s, idx) => (idx === i ? { ...s, [field]: value } : s)))
  }
  const addSubject = () => setSubjects((prev) => [...prev, emptyRow()])
  const removeSubject = (i) => setSubjects((prev) => prev.filter((_, idx) => idx !== i))

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)
    const filled = subjects.filter((s) => s.subject.trim()).length
    if (!noDocument && filled === 0) {
      setError('과목을 1개 이상 입력하세요.')
      return
    }
    if (!noDocument && filled < DEFAULT_ROWS
      && !window.confirm(`입력한 과목이 ${filled}개입니다(요강: 상위 5개 과목 반영). 이대로 제출할까요?`)) {
      return
    }
    setSubmitting(true)

    const payload = noDocument
      ? []
      : subjects
          .filter((s) => s.subject.trim())
          .map((s) =>
            inputType === 'regular'
              ? { subject: s.subject, achievement: s.achievement }
              : { subject: s.subject, rawScore: Number(s.rawScore) }
          )

    const academicArgs = {
      p_applicant_id: applicantId,
      p_input_type: inputType,
      p_subjects: payload,
      p_no_document: noDocument,
    }
    const { data, error: err } = proxy
      ? await supabase.rpc('admin_submit_academic_score', {
        ...academicArgs,
        p_target_evaluator_uid: proxy.evaluatorUid,
        p_reason_code: proxy.reasonCode,
        p_reason_text: proxy.reasonText || null,
      })
      : await supabase.rpc('submit_academic_score', academicArgs)
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
      <h3 className="mb-3 text-sm font-semibold text-ink-primary">학업성실도 채점</h3>
      {loadingExisting ? (
        <p className="text-xs text-ink-muted">기존 제출 내역 확인 중…</p>
      ) : (
        <>
          {alreadySubmitted && (
            <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">
              이미 제출확정된 채점입니다 — 서버 산정 점수: {result?.score}점. 수정하려면 관리자에게 재개방을
              요청하세요.
            </p>
          )}
          <form onSubmit={handleSubmit} className="space-y-3">
            <fieldset disabled={alreadySubmitted} className="space-y-3 disabled:opacity-60">
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={noDocument} onChange={(e) => setNoDocument(e.target.checked)} />
                증빙 자체 없음 (무증빙 점수 적용)
              </label>

              {!noDocument && (
                <>
                  {lockedType ? (
                    <p className="text-sm text-ink-secondary">
                      원서 학적 <span className="font-semibold text-ink-primary">{appContext.academicStatus}</span>
                      {' → '}
                      <span className="font-semibold text-brand-deepGreenStrong">
                        {lockedType === 'ged' ? '검정고시 성적증명서 원점수로 입력' : '학교생활기록부 성취도(A~E)로 입력'}
                      </span>
                    </p>
                  ) : (
                  <div className="flex flex-wrap items-center gap-3 text-sm">
                    <span className="text-xs text-ink-muted">
                      원서 학적 {appContext?.academicStatus || '확인 불가'} — 입력 방식을 고르세요:
                    </span>
                    <label className="flex items-center gap-1">
                      <input
                        type="radio"
                        checked={inputType === 'regular'}
                        onChange={() => setInputType('regular')}
                      />
                      일반(성취도)
                    </label>
                    <label className="flex items-center gap-1">
                      <input type="radio" checked={inputType === 'ged'} onChange={() => setInputType('ged')} />
                      검정고시(원점수)
                    </label>
                  </div>
                  )}

                  {inputType === 'regular' ? (
                    <div className="rounded-md border border-brand-deepGreen bg-brand-greenSoft px-3 py-2 text-sm">
                      <span className="text-ink-secondary">입학원서 반영 학기 </span>
                      <span className="font-bold text-brand-deepGreenStrong">
                        {appContext?.semesterChoice ? semesterLabel(appContext.semesterChoice) : '원서에 기재 없음'}
                      </span>
                      {appContext?.academicStatus && (
                        <span className="ml-2 text-xs text-ink-muted">({appContext.academicStatus})</span>
                      )}
                      <p className="mt-0.5 text-xs text-ink-muted">
                        이 학기의 교과 성취도(A~E)를 입력하세요. 과목이 5개보다 많으면 모두 입력해도 됩니다 — 상위 5과목은 서버가 자동으로 골라 합산합니다.
                      </p>
                    </div>
                  ) : (
                    <p className="text-xs text-ink-muted">
                      검정고시 성적증명서의 과목별 원점수를 입력하세요. 상위 5과목은 서버가 자동으로 골라 합산합니다.
                    </p>
                  )}

                  <div className="space-y-2">
                    {subjects.map((s, i) => (
                      <div key={i} className="flex items-center gap-2">
                        <span className="w-4 text-right text-xs text-ink-muted">{i + 1}</span>
                        <input
                          placeholder="과목명"
                          value={s.subject}
                          onChange={(e) => updateSubject(i, 'subject', e.target.value)}
                          className="flex-1 rounded-md border border-border px-2 py-1.5 text-sm"
                        />
                        {inputType === 'regular' ? (
                          <select
                            value={s.achievement}
                            onChange={(e) => updateSubject(i, 'achievement', e.target.value)}
                            className="rounded-md border border-border px-2 py-1.5 text-sm"
                          >
                            {ACHIEVEMENT_OPTIONS.map((a) => (
                              <option key={a} value={a}>
                                {a}
                              </option>
                            ))}
                          </select>
                        ) : (
                          <input
                            type="number"
                            min="0"
                            max="100"
                            placeholder="원점수"
                            value={s.rawScore}
                            onChange={(e) => updateSubject(i, 'rawScore', e.target.value)}
                            className="w-20 rounded-md border border-border px-2 py-1.5 text-sm"
                          />
                        )}
                        <button
                          type="button"
                          onClick={() => removeSubject(i)}
                          className="text-xs text-ink-muted hover:text-status-danger"
                        >
                          삭제
                        </button>
                      </div>
                    ))}
                  </div>
                  <button type="button" onClick={addSubject} className="text-xs text-brand-deepGreenStrong underline">
                    + 과목 추가
                  </button>
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
