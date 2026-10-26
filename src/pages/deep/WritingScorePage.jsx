import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import StatusBadge from '../../components/status/StatusBadge'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import DocumentUrlView from '../../components/pdf/DocumentUrlView'

function sumItems(items) {
  return Object.values(items || {}).reduce((sum, value) => sum + (Number(value) || 0), 0)
}

function normalizeResponses(responses) {
  return Array.isArray(responses)
    ? responses.map((response) => ({
      questionId: response.questionId,
      items: response.items || {},
    }))
    : []
}

export default function WritingScorePage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [workspace, setWorkspace] = useState(null)
  const [selectedApplicantId, setSelectedApplicantId] = useState(null)
  const selectedApplicantIdRef = useRef(null)
  const [form, setForm] = useState({ responses: [], memo: '', submissionState: 'draft' })
  const [viewUrl, setViewUrl] = useState(null)
  const [documentLoading, setDocumentLoading] = useState(false)
  const [loading, setLoading] = useState(true)
  const [saveStatus, setSaveStatus] = useState('idle')
  const [error, setError] = useState(null)
  const saveTimers = useRef(new Map())

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: loadError } = await supabase.rpc('get_m5d_writing_workspace', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (loadError) {
      setWorkspace(null)
      setError(loadError.message)
    } else {
      setWorkspace(data)
    }
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
    return () => {
      saveTimers.current.forEach((timer) => clearTimeout(timer))
      saveTimers.current.clear()
    }
  }, [load])

  const candidates = workspace?.candidates || []
  const config = workspace?.config || {}
  const questions = config?.questions || []
  const pickCount = Number(config?.questionRule?.pick || 2)
  const selectedApplicant = candidates.find((candidate) => candidate.applicantId === selectedApplicantId) || null
  const submitted = form.submissionState === 'submitted'
  const selectedQuestionIds = form.responses.map((response) => response.questionId)
  const total = useMemo(
    () => form.responses.reduce((sum, response) => sum + sumItems(response.items), 0),
    [form.responses],
  )

  const openAnswer = useCallback(async (candidate) => {
    setViewUrl(null)
    if (!candidate?.answerDocument?.documentId) return
    setDocumentLoading(true)
    try {
      const { url } = await getDocumentViewUrl(candidate.answerDocument.documentId)
      setViewUrl(`${url}#toolbar=0&navpanes=0`)
    } catch (err) {
      setError(err.message)
    } finally {
      setDocumentLoading(false)
    }
  }, [])

  const openScore = async (applicantId) => {
    const candidate = candidates.find((item) => item.applicantId === applicantId)
    const score = candidate?.myScore
    selectedApplicantIdRef.current = applicantId
    setSelectedApplicantId(applicantId)
    setForm({
      responses: normalizeResponses(score?.responses),
      memo: score?.memo || '',
      submissionState: score?.submissionState || 'draft',
    })
    setSaveStatus('idle')
    setError(null)
    await openAnswer(candidate)
  }

  const scheduleDraftSave = (nextForm, applicantId = selectedApplicantId) => {
    if (!applicantId || nextForm.submissionState === 'submitted') return
    setSaveStatus('saving')
    const timerKey = applicantId
    clearTimeout(saveTimers.current.get(timerKey))
    const timer = setTimeout(async () => {
      const { data, error: saveError } = await supabase.rpc('save_writing_score_draft', {
        p_applicant_id: applicantId,
        p_responses: nextForm.responses,
        p_memo: nextForm.memo || null,
        p_client_updated_at: new Date().toISOString(),
      })
      const isCurrentApplicant = selectedApplicantIdRef.current === applicantId
      if (saveError) {
        if (isCurrentApplicant) {
          setSaveStatus('error')
          setError(saveError.message)
        }
      } else if (data?.accepted === false && data?.serverDraft) {
        const serverForm = {
          responses: normalizeResponses(data.serverDraft.responses),
          memo: data.serverDraft.memo || '',
          submissionState: data.submissionState || 'draft',
        }
        setWorkspace((current) => {
          if (!current) return current
          return {
            ...current,
            candidates: (current.candidates || []).map((candidate) => (
              candidate.applicantId === applicantId
                ? {
                  ...candidate,
                  myScore: {
                    ...(candidate.myScore || {}),
                    responses: serverForm.responses,
                    memo: serverForm.memo,
                    submissionState: serverForm.submissionState,
                    revision: data.serverDraft.revision,
                    serverComputed: {
                      ...(candidate.myScore?.serverComputed || {}),
                      total: data.draftTotal,
                    },
                    clientUpdatedAt: data.serverClientUpdatedAt,
                  },
                }
                : candidate
            )),
          }
        })
        if (isCurrentApplicant) {
          setForm(serverForm)
          setSaveStatus('stale')
        }
      } else if (isCurrentApplicant) {
        setSaveStatus('saved')
      }
      saveTimers.current.delete(timerKey)
    }, 650)
    saveTimers.current.set(timerKey, timer)
  }

  const updateForm = (updater) => {
    if (submitted || !workspace?.areaOpen) return
    const next = typeof updater === 'function' ? updater(form) : updater
    if (Object.is(next, form)) return
    setForm(next)
    setWorkspace((current) => {
      if (!current) return current
      return {
        ...current,
        candidates: (current.candidates || []).map((candidate) => (
          candidate.applicantId === selectedApplicantId
            ? {
              ...candidate,
              myScore: {
                ...(candidate.myScore || {}),
                responses: next.responses,
                memo: next.memo,
                submissionState: next.submissionState,
              },
            }
            : candidate
        )),
      }
    })
    scheduleDraftSave(next)
  }

  const toggleQuestion = (questionId) => {
    updateForm((current) => {
      const exists = current.responses.some((response) => response.questionId === questionId)
      if (exists) {
        return {
          ...current,
          responses: current.responses.filter((response) => response.questionId !== questionId),
        }
      }
      if (current.responses.length >= pickCount) {
        setError(`${pickCount}개 문항만 선택할 수 있습니다. 기존 선택 문항 하나를 먼저 해제하세요.`)
        return current
      }
      setError(null)
      return {
        ...current,
        responses: [...current.responses, { questionId, items: {} }],
      }
    })
  }

  const setScore = (questionId, criterionKey, value) => {
    updateForm((current) => ({
      ...current,
      responses: current.responses.map((response) => (
        response.questionId === questionId
          ? { ...response, items: { ...response.items, [criterionKey]: Number(value) } }
          : response
      )),
    }))
  }

  const submit = async () => {
    if (!selectedApplicant) return
    if (form.responses.length !== pickCount) {
      setError(`${questions.length}문항 중 ${pickCount}문항을 정확히 선택해야 합니다.`)
      return
    }

    const missing = []
    for (const response of form.responses) {
      const question = questions.find((item) => item.id === response.questionId)
      for (const criterion of question?.criteria || []) {
        if (response.items?.[criterion.key] === undefined) {
          missing.push(`${question.label} · ${criterion.label}`)
        }
      }
    }
    if (missing.length > 0) {
      setError(`미입력 기준: ${missing.join(', ')}`)
      return
    }

    const timerKey = selectedApplicant.applicantId
    clearTimeout(saveTimers.current.get(timerKey))
    saveTimers.current.delete(timerKey)
    setSaveStatus('submitting')
    setError(null)

    const { error: submitError } = await supabase.rpc('submit_writing_score', {
      p_applicant_id: selectedApplicant.applicantId,
      p_responses: form.responses,
      p_memo: form.memo || null,
    })
    if (submitError) {
      setSaveStatus('error')
      setError(submitError.message)
      return
    }

    setSaveStatus('submitted')
    selectedApplicantIdRef.current = null
    setSelectedApplicantId(null)
    setForm({ responses: [], memo: '', submissionState: 'draft' })
    setViewUrl(null)
    await load()
  }

  if (loading) {
    return <div className="flex h-screen items-center justify-center bg-surface-canvas p-6 text-sm text-ink-muted">글쓰기 채점 화면을 불러오는 중…</div>
  }

  return (
    <div className="min-h-screen bg-surface-canvas">
      <header className="sticky top-0 z-20 border-b border-border bg-surface-card px-4 py-3 shadow-sm">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-3">
          <div>
            <Link to="/" className="text-xs font-medium text-ink-muted underline">나가기</Link>
            <h1 className="mt-1 text-base font-semibold text-ink-primary">지원자 글쓰기 독립채점</h1>
            <p className="text-xs text-ink-muted">{questions.length}문항 중 {pickCount}택 · 위원별 {config?.perEvaluatorMax || 200}점 · 타 위원 점수 비노출</p>
          </div>
          <StatusBadge
            label={workspace?.areaOpen ? '평가 열림' : '평가 닫힘'}
            tone={workspace?.areaOpen ? 'success' : 'danger'}
          />
        </div>
      </header>

      <main className="mx-auto max-w-7xl space-y-4 px-3 py-4 sm:px-6">
        {error && <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>}

        {!workspace && (
          <section className="rounded-xl border bg-white p-6 text-sm text-ink-secondary">
            최종확정된 본인 글쓰기 평가 배정을 불러오지 못했습니다.
          </section>
        )}

        {workspace && !selectedApplicant && (
          <section className="rounded-xl border bg-white p-4">
            <div className="flex items-center justify-between gap-3">
              <div>
                <h2 className="text-sm font-semibold text-ink-primary">내 글쓰기 채점 대상</h2>
                <p className="mt-1 text-xs text-ink-muted">1단계 사정 합격자 확정본 기준 · 답안이 준비된 지원자만 채점할 수 있습니다.</p>
              </div>
              <span className="text-xs text-ink-muted">{candidates.length}명</span>
            </div>
            <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {candidates.map((candidate) => {
                const state = candidate.myScore?.submissionState || 'draft'
                const scoreTotal = candidate.myScore?.serverComputed?.total
                return (
                  <button
                    key={candidate.applicantId}
                    type="button"
                    onClick={() => openScore(candidate.applicantId)}
                    disabled={!candidate.answerDocument}
                    className="rounded-lg border p-3 text-left hover:border-brand-deepGreen disabled:cursor-not-allowed disabled:bg-surface-subtle disabled:opacity-60"
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div>
                        <p className="font-semibold text-ink-primary">{candidate.displayName}</p>
                        <p className="text-xs text-ink-muted">{candidate.examNo || '-'}</p>
                      </div>
                      <StatusBadge status={state} />
                    </div>
                    <div className="mt-3 flex items-center justify-between text-xs">
                      <span className={candidate.answerDocument ? 'text-brand-deepGreenStrong' : 'text-status-danger'}>
                        {candidate.answerDocument ? `답안 v${candidate.answerDocument.version}` : '답안 미등록'}
                      </span>
                      <span className="font-semibold text-brand-deepGreenStrong">{scoreTotal ?? 0}/{config?.perEvaluatorMax || 200}</span>
                    </div>
                  </button>
                )
              })}
            </div>
          </section>
        )}

        {selectedApplicant && (
          <section className="overflow-hidden rounded-xl border bg-white">
            <div className="border-b p-4">
              <button
                type="button"
                onClick={() => { selectedApplicantIdRef.current = null; setSelectedApplicantId(null); setViewUrl(null); setError(null) }}
                className="text-xs text-ink-muted hover:text-ink-primary"
              >
                ← 채점 대상 목록
              </button>
              <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h2 className="text-lg font-semibold text-ink-primary">{selectedApplicant.displayName}</h2>
                  <p className="text-xs text-ink-muted">{selectedApplicant.examNo || '-'} · 답안 v{selectedApplicant.answerDocument?.version || '-'}</p>
                </div>
                <div className="text-right">
                  <p className="text-2xl font-bold text-brand-deepGreenStrong">{total}점</p>
                  <p className="text-xs text-ink-muted">위원별 {config?.perEvaluatorMax || 200}점 만점</p>
                </div>
              </div>
            </div>

            <div className="grid min-h-[70vh] md:grid-cols-[minmax(0,1.35fr)_minmax(360px,0.65fr)]">
              <div className="border-b bg-surface-subtle md:border-b-0 md:border-r">
                <div className="flex items-center justify-between border-b bg-white px-3 py-2">
                  <p className="text-xs font-semibold text-ink-secondary">글쓰기 답안</p>
                  <button
                    type="button"
                    onClick={() => openAnswer(selectedApplicant)}
                    className="text-xs text-brand-deepGreenStrong hover:underline"
                  >
                    서명 URL 새로고침
                  </button>
                </div>
                <div className="h-[52vh] md:h-full md:min-h-[70vh]">
                  {documentLoading ? (
                    <p className="p-6 text-sm text-ink-muted">답안을 불러오는 중…</p>
                  ) : viewUrl ? (
                    <DocumentUrlView url={viewUrl} alt="글쓰기 답안" />
                  ) : (
                    <p className="p-6 text-sm text-status-danger">글쓰기 답안을 열 수 없습니다.</p>
                  )}
                </div>
              </div>

              <div className="overflow-y-auto p-4 md:max-h-[78vh]">
                <div>
                  <p className="text-sm font-semibold text-ink-primary">선택문항</p>
                  <p className="mt-1 text-xs text-ink-muted">지원자가 작성한 {pickCount}문항을 선택하세요. 미서술 문항을 선택해야 하는 경우 0점 단계로 평가합니다.</p>
                  <div className="mt-3 grid grid-cols-3 gap-2">
                    {questions.map((question) => {
                      const active = selectedQuestionIds.includes(question.id)
                      return (
                        <button
                          key={question.id}
                          type="button"
                          onClick={() => toggleQuestion(question.id)}
                          disabled={submitted || !workspace.areaOpen}
                          className={`rounded-lg border px-3 py-3 text-sm font-semibold disabled:opacity-50 ${active ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border text-ink-secondary'}`}
                        >
                          {question.label}
                        </button>
                      )
                    })}
                  </div>
                  <p className="mt-2 text-right text-xs text-ink-muted">{selectedQuestionIds.length}/{pickCount} 선택</p>
                </div>

                <div className="mt-5 space-y-6">
                  {form.responses.map((response) => {
                    const question = questions.find((item) => item.id === response.questionId)
                    if (!question) return null
                    return (
                      <article key={response.questionId} className="rounded-xl border p-4">
                        <div className="flex items-center justify-between gap-2">
                          <h3 className="text-sm font-bold text-ink-primary">{question.label}</h3>
                          <span className="text-lg font-bold text-brand-deepGreenStrong">{sumItems(response.items)}/{config?.questionRule?.each || 100}</span>
                        </div>
                        <div className="mt-4 space-y-5">
                          {(question.criteria || []).map((criterion) => (
                            <div key={criterion.key}>
                              <div className="flex items-center justify-between gap-2">
                                <p className="text-sm font-semibold text-ink-primary">{criterion.label}</p>
                                <span className="text-sm font-bold text-brand-deepGreenStrong">{response.items?.[criterion.key] ?? '-'}점</span>
                              </div>
                              <div className="mt-2 grid grid-cols-3 gap-2 sm:grid-cols-6 md:grid-cols-3 xl:grid-cols-6">
                                {(criterion.scoreValues || []).map((value) => (
                                  <button
                                    key={value}
                                    type="button"
                                    onClick={() => setScore(response.questionId, criterion.key, value)}
                                    disabled={submitted || !workspace.areaOpen}
                                    className={`min-h-11 rounded-lg border text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-50 ${Number(response.items?.[criterion.key]) === Number(value) ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen'}`}
                                  >
                                    {value}
                                  </button>
                                ))}
                              </div>
                            </div>
                          ))}
                        </div>
                      </article>
                    )
                  })}
                </div>

                <label className="mt-5 block text-sm font-semibold text-ink-primary">
                  글쓰기 평가 메모 <span className="font-normal text-ink-muted">(본인 기록 · 최대 2,000자)</span>
                  <textarea
                    value={form.memo}
                    onChange={(event) => updateForm((current) => ({ ...current, memo: event.target.value }))}
                    disabled={submitted || !workspace.areaOpen}
                    maxLength={2000}
                    rows={4}
                    className="mt-2 w-full rounded-lg border-border text-sm disabled:bg-surface-subtle"
                    placeholder="평가 판단 근거를 간단히 기록하세요."
                  />
                </label>

                <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t pt-4">
                  <p className="text-xs text-ink-muted">
                    {saveStatus === 'saving' && '자동 임시저장 중…'}
                    {saveStatus === 'saved' && '서버에 임시저장됨'}
                    {saveStatus === 'stale' && '더 최신인 서버 초안을 유지했습니다.'}
                    {saveStatus === 'error' && '임시저장 오류'}
                    {saveStatus === 'submitted' && '제출확정 완료'}
                    {saveStatus === 'idle' && (submitted ? '제출확정되어 잠겼습니다.' : '점수 변경 시 자동 임시저장됩니다.')}
                  </p>
                  <button
                    type="button"
                    onClick={submit}
                    disabled={submitted || !workspace.areaOpen || saveStatus === 'submitting'}
                    className="rounded-lg bg-brand-deepGreenStrong px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    {submitted ? '글쓰기 제출완료' : saveStatus === 'submitting' ? '제출 중…' : '글쓰기 제출확정'}
                  </button>
                </div>
              </div>
            </div>
          </section>
        )}

        <p className="text-xs text-ink-muted">글쓰기 위원 2인은 독립 채점합니다. 다른 위원의 응답·점수·임시합계·제출점수는 이 화면에 표시되지 않습니다.</p>
      </main>
    </div>
  )
}
