// UX1-E — 글쓰기 준비 Workspace (명세서 16장). 3단계: 평가위원 배정 →
// 답안 준비 → 검토·확정. 로직(save/validate/finalize RPC 호출)은 그대로,
// 화면 구성만 재편했다.
//
// 2026-07-09 발견: finalize()가 window.prompt()(브라우저 네이티브 프롬프트)로
// 확인문구를 받고 있었다 — Level 3 위험작업에 맞지 않아 TypedConfirmDialog로
// 교체했다.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import Stepper from '../../components/layout/Stepper'
import BlockingPanel from '../../components/feedback/BlockingPanel'
import StatusBadge from '../../components/status/StatusBadge'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import { translateAlert } from '../../config/alertMessages'
import WritingAnswerList from './WritingAnswerList'

const FINAL_CONFIRM_TEXT = '글쓰기 계획 확정'
const STEP_LABELS = ['평가위원 배정', '답안 준비', '검토·확정']

export default function WritingPlanningPage() {
  const { userDoc } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [currentStep, setCurrentStep] = useState(0)
  const [data, setData] = useState(null)
  const [memberUids, setMemberUids] = useState(['', ''])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [message, setMessage] = useState(null)
  const [showFinalize, setShowFinalize] = useState(false)

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data: nextData, error: loadError } = await supabase.rpc('get_m5d_writing_plan_admin', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (loadError) {
      setData(null)
      setError(loadError.message)
    } else {
      setData(nextData)
      const nextMembers = nextData?.memberUids || []
      setMemberUids([nextMembers[0] || '', nextMembers[1] || ''])
    }
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  // 답안 업로드 뒤 목록만 조용히 갱신한다(load는 전체 화면을 '불러오는 중'으로 바꿔 안내 문구가 사라진다).
  const refreshCandidates = async () => {
    const { data: nextData } = await supabase.rpc('get_m5d_writing_plan_admin', { p_year: YEAR, p_round: ROUND })
    if (nextData) setData(nextData)
  }

  const evaluators = data?.evaluators || []
  const candidates = data?.candidates || []
  const validation = data?.validation || {}
  const finalized = validation?.status === 'finalized'
  const missingAnswers = useMemo(
    () => candidates.filter((candidate) => !candidate.answerDocumentId),
    [candidates],
  )
  const translatedBlockingIssues = useMemo(
    () => (validation?.blockingIssues || []).map((issue) => translateAlert(issue)),
    [validation],
  )

  const updateMember = (slotIndex, uid) => {
    setMemberUids((current) => {
      const next = [...current]
      next[slotIndex] = uid
      return next
    })
  }

  const save = async () => {
    setBusy(true)
    setError(null)
    setMessage(null)
    const selected = memberUids.filter(Boolean)
    if (new Set(selected).size !== selected.length) {
      setError('같은 평가위원을 1번·2번 슬롯에 중복 배정할 수 없습니다.')
      setBusy(false)
      return
    }

    const { error: saveError } = await supabase.rpc('save_m5d_writing_plan', {
      p_year: YEAR,
      p_round: ROUND,
      p_member_uids: selected,
    })
    if (saveError) setError(saveError.message)
    setBusy(false)
    await load()
  }

  const validate = async () => {
    setBusy(true)
    setError(null)
    setMessage(null)
    const { error: validateError } = await supabase.rpc('validate_m5d_writing_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (validateError) setError(validateError.message)
    setBusy(false)
    await load()
  }

  // 3단계(검토) 진입 시 자동으로 최신 상태를 검증한다("서버 검증" 버튼을
  // 사용자 주행동으로 보여주지 않는다).
  useEffect(() => {
    if (currentStep === 2 && !loading) {
      validate()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentStep])

  const finalize = async () => {
    setBusy(true)
    setError(null)
    setMessage(null)
    const { data: result, error: finalizeError } = await supabase.rpc('finalize_m5d_writing_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    setBusy(false)
    if (finalizeError) {
      setError(finalizeError.message)
      return
    }
    setMessage(`글쓰기 평가계획 확정 완료 · 지원자 ${result?.candidateCount ?? candidates.length}명`)
    setShowFinalize(false)
    await load()
  }

  if (loading) {
    return <p className="p-6 text-sm text-ink-muted">글쓰기 평가계획을 불러오는 중…</p>
  }

  if (finalized) {
    return (
      <div className="mx-auto max-w-5xl">
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
          <div>
            <h1 className="text-lg font-semibold text-ink-primary">글쓰기 평가위원 배정</h1>
            <p className="mt-1 text-sm text-ink-secondary">1단계 서류사정 합격자 전원을 동일한 위원 2인이 독립 채점합니다.</p>
          </div>
          <StatusBadge status="finalized" />
        </div>
        <div className="rounded-xl border border-border bg-surface-card p-5">
          <p className="text-sm text-ink-primary">
            평가위원: {evaluators.filter((e) => memberUids.includes(e.uid)).map((e) => e.displayName).join(' · ')}
          </p>
          <p className="mt-1 text-sm text-ink-secondary">평가 대상 {candidates.length}명 · 답안 준비 {candidates.length - missingAnswers.length}/{candidates.length}</p>
        </div>
        {/* 확정 뒤에도 잘못 스캔한 답안을 교체할 수 있게 목록을 둔다. */}
        <h2 className="mb-2 mt-6 text-base font-semibold text-ink-primary">글쓰기 답안</h2>
        <WritingAnswerList candidates={candidates} finalized onChanged={refreshCandidates} />
      </div>
    )
  }

  return (
    <>
      <div className="mb-1 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-ink-primary">글쓰기 준비</h1>
          <p className="text-sm text-ink-secondary">1단계 서류사정 합격자 전원을 동일한 위원 2인이 독립 채점합니다.</p>
        </div>
        <span className="text-xs font-medium text-brand-deepGreenStrong">{busy ? '처리 중…' : '임시 저장됨 ✓'}</span>
      </div>

      <Stepper steps={STEP_LABELS} currentIndex={currentStep} onStepClick={setCurrentStep} />

      {error && <p className="mb-4 rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</p>}
      {message && <p className="mb-4 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-3 text-sm text-brand-deepGreenStrong">{message}</p>}

      <div className="mx-auto max-w-5xl">
        {/* ── Step 1: 평가위원 배정 ─────────────────────────────── */}
        {currentStep === 0 && (
          <section>
            <div className="rounded-xl border border-border bg-surface-card p-5">
              <h2 className="text-sm font-semibold text-ink-primary">글쓰기 평가위원</h2>
              <p className="mt-1 text-xs text-ink-muted">두 평가위원은 동일한 지원자 답안을 독립적으로 채점합니다. 서로의 점수는 볼 수 없습니다.</p>
              <div className="mt-4 grid gap-3 sm:grid-cols-2">
                {[0, 1].map((slotIndex) => (
                  <label key={slotIndex} className="text-sm font-medium text-ink-secondary">
                    평가위원 {slotIndex + 1}
                    <select
                      value={memberUids[slotIndex] || ''}
                      onChange={(event) => updateMember(slotIndex, event.target.value)}
                      className="mt-2 w-full rounded-lg border border-border text-sm"
                    >
                      <option value="">선택하세요</option>
                      {evaluators.map((evaluator) => {
                        const usedOther = memberUids.some((uid, index) => index !== slotIndex && uid === evaluator.uid)
                        return (
                          <option key={evaluator.uid} value={evaluator.uid} disabled={usedOther}>
                            {evaluator.displayName} · {evaluator.email}
                          </option>
                        )
                      })}
                    </select>
                  </label>
                ))}
              </div>
              {evaluators.length < 2 && (
                <p className="mt-3 rounded-lg bg-brand-orangeSoft p-3 text-xs text-brand-orangeStrong">
                  현재 글쓰기 영역 평가위원이 {evaluators.length}명입니다. 확정하려면 2명이 필요합니다.
                </p>
              )}
            </div>
            <StepFooter onNext={() => { save(); setCurrentStep(1) }} nextLabel="다음: 답안 준비 →" onSaveDraft={save} saving={busy} />
          </section>
        )}

        {/* ── Step 2: 답안 준비 ─────────────────────────────────── */}
        {currentStep === 1 && (
          <section>
            <h2 className="mb-1 text-base font-semibold text-ink-primary">
              글쓰기 답안 <span className="ml-2 text-sm font-normal text-ink-muted">{candidates.length - missingAnswers.length} / {candidates.length} 준비</span>
            </h2>
            <p className="mb-4 text-xs text-ink-muted">평가용 답안 문서가 없으면 계획을 확정할 수 없습니다. 시험이 끝나면 답안을 스캔해 여기서 올리세요.</p>
            <WritingAnswerList candidates={candidates} finalized={false} onChanged={refreshCandidates} />
            <StepFooter onPrev={() => setCurrentStep(0)} onNext={() => setCurrentStep(2)} nextLabel="다음: 검토·확정 →" onSaveDraft={save} saving={busy} />
          </section>
        )}

        {/* ── Step 3: 검토·확정 ─────────────────────────────────── */}
        {currentStep === 2 && (
          <section>
            <h2 className="mb-4 text-base font-semibold text-ink-primary">글쓰기 준비 검토</h2>
            <div className="mb-5 rounded-lg border border-border bg-surface-card p-4">
              <ReviewRow label="평가위원 정확히 2인" ok={memberUids.filter(Boolean).length === 2} text={`${memberUids.filter(Boolean).length} / 2`} />
              <ReviewRow label="답안 전원 준비" ok={missingAnswers.length === 0} text={`${candidates.length - missingAnswers.length} / ${candidates.length}`} last />
            </div>

            {validation?.complete ? (
              <p className="mb-4 rounded-md bg-brand-greenSoft px-4 py-3 text-sm font-medium text-brand-deepGreenStrong">글쓰기 채점을 시작할 준비가 되었습니다.</p>
            ) : (
              <div className="mb-4"><BlockingPanel issues={translatedBlockingIssues} /></div>
            )}

            <div className="flex justify-between">
              <button type="button" onClick={() => setCurrentStep(1)} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">← 이전</button>
              <button
                type="button"
                onClick={() => setShowFinalize(true)}
                disabled={busy || !validation?.complete}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
              >
                글쓰기 계획 확정
              </button>
            </div>
          </section>
        )}
      </div>

      <TypedConfirmDialog
        open={showFinalize}
        title="글쓰기 평가계획을 확정하시겠습니까?"
        description="확정하면 일반 수정이 잠기고 배정된 위원 기준으로 채점이 시작됩니다."
        fields={[
          { label: '평가 대상', value: `${candidates.length}명` },
          { label: '확정자', value: userDoc?.display_name || '—' },
        ]}
        confirmPhrase={FINAL_CONFIRM_TEXT}
        confirmLabel="확정"
        onConfirm={finalize}
        onCancel={() => setShowFinalize(false)}
        submitting={busy}
        error={error}
      />
    </>
  )
}

function StepFooter({ onPrev, onNext, nextLabel, onSaveDraft, saving }) {
  return (
    <div className="mt-5 flex items-center justify-between border-t border-border pt-4">
      <div>
        {onPrev && (
          <button type="button" onClick={onPrev} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">← 이전</button>
        )}
      </div>
      <div className="flex gap-2">
        <button type="button" onClick={onSaveDraft} disabled={saving} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50">
          {saving ? '저장 중…' : '임시 저장'}
        </button>
        <button type="button" onClick={onNext} className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong">
          {nextLabel}
        </button>
      </div>
    </div>
  )
}

function ReviewRow({ label, ok, text, last = false }) {
  return (
    <div className={`flex items-center justify-between py-2 text-sm ${last ? '' : 'border-b border-border'}`}>
      <span className="text-ink-secondary">{label}</span>
      <span className={`flex items-center gap-1 font-medium ${ok ? 'text-brand-deepGreenStrong' : 'text-status-danger'}`}>
        {text} {ok ? '✓' : '✗'}
      </span>
    </div>
  )
}
