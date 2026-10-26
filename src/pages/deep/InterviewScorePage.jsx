import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import FieldShell from '../../components/layout/FieldShell'
import StatusBadge from '../../components/status/StatusBadge'
import InterviewCallPanel from '../../components/interview/InterviewCallPanel'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

function toFieldSaveState(saveStatus) {
  if (saveStatus === 'saving' || saveStatus === 'submitting') return 'saving'
  if (saveStatus === 'saved' || saveStatus === 'submitted') return 'saved'
  if (saveStatus === 'stale') return 'syncNeeded'
  if (saveStatus === 'error') return 'error'
  return null
}

function formatTime(value) {
  if (!value) return '-'
  return new Intl.DateTimeFormat('ko-KR', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(value))
}

function sectionLabel(section) {
  return section === 'student' ? '학생면접' : '학부모면접'
}

function sumItems(items) {
  return Object.values(items || {}).reduce((sum, value) => sum + (Number(value) || 0), 0)
}

export default function InterviewScorePage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [workspace, setWorkspace] = useState(null)
  const [selectedApplicantId, setSelectedApplicantId] = useState(null)
  const [section, setSection] = useState('student')
  const [form, setForm] = useState({ items: {}, memo: '', submissionState: 'draft' })
  const [loading, setLoading] = useState(true)
  const [saveStatus, setSaveStatus] = useState('idle')
  const [error, setError] = useState(null)
  const saveTimers = useRef(new Map())

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: loadError } = await supabase.rpc('get_m5c_interview_workspace', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (loadError) {
      setWorkspace(null)
      setError(loadError.message)
      setLoading(false)
      return
    }
    setWorkspace(data)
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
    return () => {
      saveTimers.current.forEach((timer) => clearTimeout(timer))
      saveTimers.current.clear()
    }
  }, [load])

  const schedule = workspace?.schedule || []
  const selectedApplicant = schedule.find((item) => item.applicantId === selectedApplicantId) || null
  const sectionConfig = workspace?.[section] || { criteria: [], perEvaluatorMax: 0 }
  const submitted = form.submissionState === 'submitted'

  const timeline = useMemo(() => {
    const events = schedule.flatMap((item) => [
      {
        applicantId: item.applicantId,
        displayName: item.displayName,
        examNo: item.examNo,
        section: 'student',
        startsAt: item.studentStartsAt,
        endsAt: item.studentEndsAt,
      },
      {
        applicantId: item.applicantId,
        displayName: item.displayName,
        examNo: item.examNo,
        section: 'parent',
        startsAt: item.parentStartsAt,
        endsAt: item.parentEndsAt,
      },
    ]).sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt))

    const now = Date.now()
    return {
      current: events.find((event) => new Date(event.startsAt).getTime() <= now && now < new Date(event.endsAt).getTime()) || null,
      next: events.find((event) => new Date(event.startsAt).getTime() > now) || null,
    }
  }, [schedule])

  const openScore = (applicantId, nextSection) => {
    const applicant = schedule.find((item) => item.applicantId === applicantId)
    const score = applicant?.myScore?.[nextSection]
    setSelectedApplicantId(applicantId)
    setSection(nextSection)
    setForm({
      items: score?.items || {},
      memo: score?.memo || '',
      submissionState: score?.submissionState || 'draft',
    })
    setSaveStatus('idle')
    setError(null)
  }

  const scheduleDraftSave = (nextForm, applicantId = selectedApplicantId, targetSection = section) => {
    if (!applicantId || nextForm.submissionState === 'submitted') return
    setSaveStatus('saving')
    const timerKey = `${applicantId}:${targetSection}`
    clearTimeout(saveTimers.current.get(timerKey))
    const timer = setTimeout(async () => {
      const clientUpdatedAt = new Date().toISOString()
      const { data, error: saveError } = await supabase.rpc('save_interview_score_draft', {
        p_applicant_id: applicantId,
        p_section: targetSection,
        p_items: nextForm.items,
        p_memo: nextForm.memo || null,
        p_client_updated_at: clientUpdatedAt,
      })
      if (saveError) {
        setSaveStatus('error')
        setError(saveError.message)
        return
      }
      setSaveStatus(data?.accepted === false ? 'stale' : 'saved')
      saveTimers.current.delete(timerKey)
    }, 650)
    saveTimers.current.set(timerKey, timer)
  }

  const updateForm = (updater) => {
    if (submitted) return
    const next = typeof updater === 'function' ? updater(form) : updater
    setForm(next)
    setWorkspace((current) => {
      if (!current) return current
      return {
        ...current,
        schedule: (current.schedule || []).map((item) => {
          if (item.applicantId !== selectedApplicantId) return item
          const myScore = item.myScore || { student: null, parent: null }
          return {
            ...item,
            myScore: {
              ...myScore,
              [section]: {
                ...(myScore?.[section] || {}),
                items: next.items,
                memo: next.memo,
                submissionState: next.submissionState,
              },
            },
          }
        }),
      }
    })
    scheduleDraftSave(next)
  }

  const setScore = (key, value) => {
    updateForm((current) => ({
      ...current,
      items: { ...current.items, [key]: value },
    }))
  }

  const submit = async () => {
    if (!selectedApplicant) return
    const missing = (sectionConfig.criteria || []).filter((criterion) => form.items?.[criterion.key] === undefined)
    if (missing.length > 0) {
      setError(`미입력 기준: ${missing.map((criterion) => criterion.label).join(', ')}`)
      return
    }

    const timerKey = `${selectedApplicant.applicantId}:${section}`
    clearTimeout(saveTimers.current.get(timerKey))
    saveTimers.current.delete(timerKey)
    setSaveStatus('submitting')
    setError(null)
    const { error: submitError } = await supabase.rpc('submit_interview_score', {
      p_applicant_id: selectedApplicant.applicantId,
      p_section: section,
      p_items: form.items,
      p_memo: form.memo || null,
    })
    if (submitError) {
      setSaveStatus('error')
      setError(submitError.message)
      return
    }

    setSaveStatus('submitted')
    setSelectedApplicantId(null)
    setForm({ items: {}, memo: '', submissionState: 'draft' })
    await load()
  }

  if (loading) {
    return <div className="flex h-screen items-center justify-center bg-surface-canvas p-6 text-sm text-ink-muted">면접 채점 화면을 불러오는 중…</div>
  }

  return (
    <FieldShell
      title="학생·학부모 면접 채점"
      contextLine={workspace?.team ? `${workspace.team.teamCode}조 · ${workspace.team.location || '장소 미지정'} · 타 위원 점수 비노출` : undefined}
      saveState={selectedApplicant ? toFieldSaveState(saveStatus) : null}
    >
      <div className="mx-auto max-w-5xl space-y-4 pb-6">
        {/* 면접실 진행 콘솔(타이머·보호자 호출). 채점을 열면 위쪽 한 줄 막대로 줄어든다. */}
        <InterviewCallPanel compact={Boolean(selectedApplicant)} onOpenScore={openScore} />

        {!workspace?.areaOpen && (
          <div className="rounded-lg border border-brand-orangeStrong bg-brand-orangeSoft p-3 text-sm text-brand-orangeStrong">평가 영역이 열려 있지 않습니다.</div>
        )}
        {error && (
          <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>
        )}

        {workspace && (
          <section className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-xl border bg-white p-4">
              <p className="text-xs font-medium text-ink-muted">현재 면접</p>
              {timeline.current ? (
                <button
                  type="button"
                  onClick={() => openScore(timeline.current.applicantId, timeline.current.section)}
                  className="mt-2 w-full text-left"
                >
                  <p className="text-base font-semibold text-ink-primary">{timeline.current.displayName} · {sectionLabel(timeline.current.section)}</p>
                  <p className="mt-1 text-sm text-brand-deepGreenStrong">{formatTime(timeline.current.startsAt)}–{formatTime(timeline.current.endsAt)} · 채점 열기 →</p>
                </button>
              ) : <p className="mt-2 text-sm text-ink-muted">현재 진행 중인 면접이 없습니다.</p>}
            </div>
            <div className="rounded-xl border bg-white p-4">
              <p className="text-xs font-medium text-ink-muted">다음 면접</p>
              {timeline.next ? (
                <button
                  type="button"
                  onClick={() => openScore(timeline.next.applicantId, timeline.next.section)}
                  className="mt-2 w-full text-left"
                >
                  <p className="text-base font-semibold text-ink-primary">{timeline.next.displayName} · {sectionLabel(timeline.next.section)}</p>
                  <p className="mt-1 text-sm text-ink-secondary">{formatTime(timeline.next.startsAt)} 시작 · 미리 채점화면 열기 →</p>
                </button>
              ) : <p className="mt-2 text-sm text-ink-muted">예정된 다음 면접이 없습니다.</p>}
            </div>
          </section>
        )}

        {!workspace && (
          <section className="rounded-xl border bg-white p-6 text-sm text-ink-secondary">
            최종확정된 본인 면접조 배정을 불러오지 못했습니다.
          </section>
        )}

        {workspace && !selectedApplicant && (
          <section className="rounded-xl border bg-white p-4">
            <h2 className="text-sm font-semibold text-ink-primary">내 면접 일정</h2>
            <div className="mt-3 space-y-2">
              {schedule.map((item) => {
                const studentState = item.myScore?.student?.submissionState || 'draft'
                const parentState = item.myScore?.parent?.submissionState || 'draft'
                return (
                  <article key={item.applicantId} className="rounded-lg border p-3">
                    <div className="flex items-center justify-between gap-3">
                      <div>
                        <p className="font-semibold text-ink-primary">{item.displayName}</p>
                        <p className="text-xs text-ink-muted">{item.examNo || '-'}</p>
                      </div>
                      <span className="text-xs text-ink-muted">#{item.sortOrder}</span>
                    </div>
                    <div className="mt-3 grid grid-cols-2 gap-2">
                      <button
                        type="button"
                        onClick={() => openScore(item.applicantId, 'student')}
                        className="rounded-lg border p-3 text-left hover:border-brand-deepGreen"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="text-sm font-semibold">학생면접</span>
                          <StatusBadge status={studentState} />
                        </div>
                        <p className="mt-1 text-xs text-ink-muted">{formatTime(item.studentStartsAt)}–{formatTime(item.studentEndsAt)}</p>
                      </button>
                      <button
                        type="button"
                        onClick={() => openScore(item.applicantId, 'parent')}
                        className="rounded-lg border p-3 text-left hover:border-brand-deepGreen"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="text-sm font-semibold">학부모면접</span>
                          <StatusBadge status={parentState} />
                        </div>
                        <p className="mt-1 text-xs text-ink-muted">{formatTime(item.parentStartsAt)}–{formatTime(item.parentEndsAt)}</p>
                      </button>
                    </div>
                  </article>
                )
              })}
            </div>
          </section>
        )}

        {selectedApplicant && (
          <section className="rounded-xl border bg-white">
            <div className="border-b p-4">
              <button type="button" onClick={() => { setSelectedApplicantId(null); setError(null) }} className="text-xs text-ink-muted hover:text-ink-primary">← 일정 목록</button>
              <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h2 className="text-lg font-semibold text-ink-primary">{selectedApplicant.displayName}</h2>
                  <p className="text-xs text-ink-muted">{selectedApplicant.examNo || '-'}</p>
                </div>
                <div className="text-right">
                  <p className="text-2xl font-bold text-brand-deepGreenStrong">{sumItems(form.items)}점</p>
                  <p className="text-xs text-ink-muted">위원별 {sectionConfig.perEvaluatorMax}점 만점</p>
                </div>
              </div>

              <div className="mt-4 grid grid-cols-2 gap-2">
                {['student', 'parent'].map((tab) => {
                  const score = selectedApplicant.myScore?.[tab]
                  const state = score?.submissionState || 'draft'
                  return (
                    <button
                      key={tab}
                      type="button"
                      onClick={() => openScore(selectedApplicant.applicantId, tab)}
                      className={`rounded-lg border px-3 py-2 text-sm font-semibold ${section === tab ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'text-ink-secondary'}`}
                    >
                      {sectionLabel(tab)} · {state === 'submitted' ? '제출완료' : '작성'}
                    </button>
                  )
                })}
              </div>
            </div>

            <div className="space-y-5 p-4">
              {(sectionConfig.criteria || []).map((criterion) => (
                <div key={criterion.key}>
                  <div className="flex items-center justify-between gap-2">
                    <p className="text-sm font-semibold text-ink-primary">{criterion.label}</p>
                    <span className="text-sm font-bold text-brand-deepGreenStrong">{form.items?.[criterion.key] ?? '-'}점</span>
                  </div>
                  <div className={`mt-2 grid gap-2 ${criterion.scoreValues?.length === 6 ? 'grid-cols-3 sm:grid-cols-6' : 'grid-cols-5'}`}>
                    {(criterion.scoreValues || []).map((value) => (
                      <button
                        key={value}
                        type="button"
                        onClick={() => setScore(criterion.key, Number(value))}
                        disabled={submitted || !workspace.areaOpen}
                        className={`min-h-12 rounded-lg border text-base font-semibold disabled:cursor-not-allowed ${Number(form.items?.[criterion.key]) === Number(value) ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen disabled:opacity-50'}`}
                      >
                        {value}
                      </button>
                    ))}
                  </div>
                </div>
              ))}

              <label className="block text-sm font-semibold text-ink-primary">
                면접 메모 <span className="font-normal text-ink-muted">(본인 기록 · 최대 2,000자)</span>
                <textarea
                  value={form.memo}
                  onChange={(event) => updateForm((current) => ({ ...current, memo: event.target.value }))}
                  disabled={submitted || !workspace.areaOpen}
                  maxLength={2000}
                  rows={4}
                  className="mt-2 w-full rounded-lg border-border text-sm disabled:bg-surface-subtle"
                  placeholder="면접 판단 근거가 되는 관찰 내용을 간단히 기록하세요."
                />
              </label>

              <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-4">
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
                  {submitted ? `${sectionLabel(section)} 제출완료` : saveStatus === 'submitting' ? '제출 중…' : `${sectionLabel(section)} 제출확정`}
                </button>
              </div>
            </div>
          </section>
        )}

        <p className="text-xs text-ink-muted">학생면접과 학부모면접은 별도 제출·잠금 상태입니다. 다른 면접위원의 점수·임시합계·제출점수는 이 화면에 표시되지 않습니다.</p>
      </div>
    </FieldShell>
  )
}
