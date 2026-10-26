import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import Stepper from '../../components/layout/Stepper'
import AlertBanner from '../../components/feedback/AlertBanner'
import BlockingPanel from '../../components/feedback/BlockingPanel'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import { translateAlert } from '../../config/alertMessages'
import { newUuid } from '../../lib/uuid'
import { buildGroupSheetHtml } from '../../lib/groupSheetHtml'

const STEP_LABELS = ['모둠 편성', '관찰위원 배정', '순환 관찰', '검토·확정']

const DEEP_EVALUATION_DATE = '2026-11-14'
const FINAL_CONFIRM_TEXT = '모둠편성 확정'

function newId() {
  return newUuid()
}

function toLocalDateTime(value) {
  if (!value) return ''
  const date = new Date(value)
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function addMinutes(localValue, minutes) {
  const date = new Date(localValue)
  date.setMinutes(date.getMinutes() + minutes)
  return toLocalDateTime(date)
}

function average(values) {
  if (values.length === 0) return null
  return values.reduce((sum, value) => sum + value, 0) / values.length
}

function nextGroupCode(groups) {
  const used = new Set(groups.map((group) => group.groupCode.trim()))
  for (let index = 0; index < 26; index += 1) {
    const code = String.fromCharCode(65 + index)
    if (!used.has(code)) return code
  }
  let number = groups.length + 1
  while (used.has(`모둠${number}`)) number += 1
  return `모둠${number}`
}

// 2부제 운영 반(00089). 빈 값('')은 '반 없음' — 모든 구간·모든 모둠에 해당(1부제).
const SHIFT_OPTIONS = [
  { value: '', label: '반 없음(전체)' },
  { value: '오전', label: '오전반' },
  { value: '오후', label: '오후반' },
]
const SHIFT_DEFAULT_START = { 오전: '09:05', 오후: '12:35' }

function shiftLabel(code) {
  return SHIFT_OPTIONS.find((o) => o.value === (code || ''))?.label || code
}

// 구간 반이 비었거나 모둠 반이 비었거나 서로 같으면 그 구간의 대상 모둠이다(서버 _m5a_segment_covers_group과 같은 규칙).
function segmentCoversGroup(segment, group) {
  return !segment.shiftCode || !group.shiftCode || segment.shiftCode === group.shiftCode
}

function nextSegmentCode(segments) {
  const used = new Set(segments.map((segment) => segment.segmentCode.trim()))
  let number = 1
  while (used.has(`S${number}`)) number += 1
  return `S${number}`
}

export default function GroupPlanningPage() {
  const { userDoc } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [currentStep, setCurrentStep] = useState(0)
  const [candidates, setCandidates] = useState([])
  const [evaluators, setEvaluators] = useState([])
  const [groups, setGroups] = useState([])
  const [segments, setSegments] = useState([])
  const [validation, setValidation] = useState(null)
  const [planStatus, setPlanStatus] = useState(null)
  const [planRevision, setPlanRevision] = useState(null)
  const [documentSourceRunId, setDocumentSourceRunId] = useState(null)
  const [currentDocumentSourceRunId, setCurrentDocumentSourceRunId] = useState(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [dirty, setDirty] = useState(false)
  const [showFinalize, setShowFinalize] = useState(false)

  const readOnly = planStatus === 'finalized'

  const candidateMap = useMemo(
    () => Object.fromEntries(candidates.map((candidate) => [candidate.applicantId, candidate])),
    [candidates]
  )

  const evaluatorMap = useMemo(
    () => Object.fromEntries(evaluators.map((evaluator) => [evaluator.uid, evaluator])),
    [evaluators]
  )

  const assignedIds = useMemo(
    () => new Set(groups.flatMap((group) => group.members)),
    [groups]
  )

  const primaryGroupByEvaluator = useMemo(() => {
    const result = {}
    groups.forEach((group) => {
      group.primaryObservers.filter(Boolean).forEach((uid) => {
        result[uid] = group.id
      })
    })
    return result
  }, [groups])

  const unassignedCandidates = candidates.filter((candidate) => !assignedIds.has(candidate.applicantId))

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: loadError } = await supabase.rpc('get_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })

    if (loadError) {
      setError(loadError.message)
      setLoading(false)
      return
    }

    setCandidates(data?.candidates || [])
    setEvaluators(data?.groupEvaluators || [])
    setGroups(
      (data?.groups || []).map((group) => ({
        ...group,
        shiftCode: group.shiftCode || '',
        members: group.members || [],
        primaryObservers: [...(group.primaryObservers || []), null, null].slice(0, 2),
      }))
    )
    setSegments(
      (data?.segments || []).map((segment) => ({
        ...segment,
        startsAt: toLocalDateTime(segment.startsAt),
        endsAt: toLocalDateTime(segment.endsAt),
        shiftCode: segment.shiftCode || '',
        assignments: segment.assignments || [],
      }))
    )
    const { data: validated } = await supabase.rpc('validate_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    setValidation(validated || data?.validation || null)
    setPlanStatus(data?.planStatus || null)
    setPlanRevision(data?.planRevision || null)
    setDocumentSourceRunId(data?.documentSourceRunId || null)
    setCurrentDocumentSourceRunId(data?.currentDocumentSourceRunId || null)
    setDirty(false)
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    const beforeUnload = (event) => {
      if (!dirty || readOnly) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', beforeUnload)
    return () => window.removeEventListener('beforeunload', beforeUnload)
  }, [dirty, readOnly])

  // 4단계(검토·확정) 진입 시 "서버 검증" 버튼 없이 자동으로 최신 상태를 검증한다
  // (명세서 14.6: "서버 검증 버튼을 사용자 주행동으로 보여주지 않는다").
  useEffect(() => {
    if (currentStep === 3 && !loading) {
      validateServer()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentStep])

  const translatedBlockingIssues = useMemo(
    () => (validation?.blockingIssues || []).map((issue) => translateAlert(issue)),
    [validation],
  )
  const isStale = Boolean(
    documentSourceRunId && currentDocumentSourceRunId && documentSourceRunId !== currentDocumentSourceRunId,
  )

  // 모둠표는 인쇄 전용 문서를 새 창에 만들어 인쇄한다(앱 화면을 그대로 찍지 않는다).
  const printGroupSheet = () => {
    const w = window.open('', '_blank')
    if (!w) {
      alert('팝업이 차단되었습니다. 이 사이트의 팝업을 허용해 주세요.')
      return
    }
    w.document.open()
    w.document.write(buildGroupSheetHtml({ year: YEAR, round: ROUND, groups, candidateMap, evaluatorMap, finalized: readOnly }))
    w.document.close()
  }

  const updateGroups = (updater) => {
    if (readOnly) return
    setGroups(updater)
    setDirty(true)
  }

  const updateSegments = (updater) => {
    if (readOnly) return
    setSegments(updater)
    setDirty(true)
  }

  const moveApplicant = (applicantId, targetGroupId) => {
    updateGroups((current) =>
      current.map((group) => ({
        ...group,
        members: group.id === targetGroupId
          ? [...group.members.filter((id) => id !== applicantId), applicantId]
          : group.members.filter((id) => id !== applicantId),
      }))
    )
  }

  const handleDragStart = (event, applicantId) => {
    event.dataTransfer.setData('text/applicant-id', applicantId)
    event.dataTransfer.effectAllowed = 'move'
  }

  const handleDrop = (event, targetGroupId) => {
    event.preventDefault()
    const applicantId = event.dataTransfer.getData('text/applicant-id')
    if (!applicantId || readOnly) return
    moveApplicant(applicantId, targetGroupId)
  }

  const addGroup = () => {
    updateGroups((current) => [
      ...current,
      {
        id: newId(),
        groupCode: nextGroupCode(current),
        shiftCode: current.at(-1)?.shiftCode || '',
        sortOrder: current.length + 1,
        members: [],
        primaryObservers: [],
      },
    ])
  }

  const removeGroup = (groupId) => {
    updateGroups((current) => current.filter((group) => group.id !== groupId))
    updateSegments((current) =>
      current.map((segment) => ({
        ...segment,
        assignments: segment.assignments.filter((assignment) => assignment.targetGroupId !== groupId),
      }))
    )
  }

  const setPrimaryObserver = (groupId, slot, uid) => {
    updateGroups((current) =>
      current.map((group) => {
        if (group.id !== groupId) return group
        const next = [...group.primaryObservers, null, null].slice(0, 2)
        next[slot] = uid || null
        return { ...group, primaryObservers: next }
      })
    )
  }

  const addSegment = () => {
    updateSegments((current) => {
      // 앞 구간의 반·끝 시각을 이어받는다. 첫 구간은 오전반 모둠 시작(09:05).
      const previous = current.at(-1)
      const shiftCode = previous?.shiftCode || ''
      const startsAt = previous?.endsAt || `${DEEP_EVALUATION_DATE}T${SHIFT_DEFAULT_START[shiftCode] || SHIFT_DEFAULT_START.오전}`
      const endsAt = addMinutes(startsAt, 20)
      return [
        ...current,
        {
          id: newId(),
          segmentCode: nextSegmentCode(current),
          shiftCode,
          startsAt,
          endsAt,
          sortOrder: current.length + 1,
          assignments: [],
        },
      ]
    })
  }

  const updateSegmentField = (segmentId, key, value) => {
    updateSegments((current) =>
      current.map((segment) => (segment.id === segmentId ? { ...segment, [key]: value } : segment))
    )
  }

  // 구간 반을 바꾸면 그 반에 없는 모둠을 보던 배정은 지운다.
  const setSegmentShift = (segmentId, shiftCode) => {
    updateSegments((current) =>
      current.map((segment) => {
        if (segment.id !== segmentId) return segment
        const next = { ...segment, shiftCode }
        return {
          ...next,
          assignments: segment.assignments.filter((assignment) => {
            const group = groups.find((g) => g.id === assignment.targetGroupId)
            return group && segmentCoversGroup(next, group)
          }),
        }
      })
    )
  }

  const removeSegment = (segmentId) => {
    updateSegments((current) => current.filter((segment) => segment.id !== segmentId))
  }

  const setRotationAssignment = (segmentId, evaluatorUid, targetGroupId) => {
    updateSegments((current) =>
      current.map((segment) => {
        if (segment.id !== segmentId) return segment
        const otherAssignments = segment.assignments.filter(
          (assignment) => assignment.evaluatorUid !== evaluatorUid
        )
        return {
          ...segment,
          assignments: targetGroupId
            ? [...otherAssignments, { evaluatorUid, targetGroupId }]
            : otherAssignments,
        }
      })
    )
  }

  const buildPayload = () => ({
    groups: groups.map((group, index) => ({
      id: group.id,
      groupCode: group.groupCode.trim(),
      shiftCode: group.shiftCode || null,
      sortOrder: index + 1,
      members: group.members,
      primaryObservers: group.primaryObservers.filter(Boolean).slice(0, 2),
    })),
    segments: segments.map((segment, index) => ({
      id: segment.id,
      segmentCode: segment.segmentCode.trim(),
      shiftCode: segment.shiftCode || null,
      startsAt: segment.startsAt ? new Date(segment.startsAt).toISOString() : null,
      endsAt: segment.endsAt ? new Date(segment.endsAt).toISOString() : null,
      sortOrder: index + 1,
      assignments: segment.assignments.filter(
        (assignment) => assignment.evaluatorUid && assignment.targetGroupId
      ),
    })),
  })

  const saveDraft = async () => {
    setSaving(true)
    setError(null)
    const payload = buildPayload()
    const { data, error: saveError } = await supabase.rpc('save_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
      p_groups: payload.groups,
      p_segments: payload.segments,
    })
    setSaving(false)

    if (saveError) {
      setError(saveError.message)
      return false
    }

    const { data: validated, error: validateAfterSaveError } = await supabase.rpc('validate_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (validateAfterSaveError) {
      setError(validateAfterSaveError.message)
      return false
    }

    setValidation(validated || data)
    setPlanStatus(data?.status || 'draft')
    setPlanRevision(data?.revision || planRevision)
    setDirty(false)
    return true
  }

  const validateServer = async () => {
    setError(null)
    if (dirty) {
      const saved = await saveDraft()
      if (!saved) return
    }
    const { data, error: validateError } = await supabase.rpc('validate_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (validateError) setError(validateError.message)
    else setValidation(data)
  }

  const finalize = async () => {
    setSaving(true)
    setError(null)
    if (dirty) {
      const saved = await saveDraft()
      if (!saved) {
        setSaving(false)
        return
      }
    }

    const { data, error: finalizeError } = await supabase.rpc('finalize_m5a_group_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    setSaving(false)

    if (finalizeError) {
      setError(finalizeError.message)
      setShowFinalize(false)
      return
    }

    setValidation(data)
    setPlanStatus('finalized')
    setShowFinalize(false)
    await load()
  }

  const groupAverage = (group) => {
    const scores = group.members
      .map((id) => Number(candidateMap[id]?.documentScore))
      .filter(Number.isFinite)
    return average(scores)
  }

  const segmentCoverage = (segment, group) => {
    const primaryUids = group.primaryObservers.filter(Boolean)
    return primaryUids.filter((uid) =>
      segment.assignments.some(
        (assignment) => assignment.evaluatorUid === uid && assignment.targetGroupId === group.id
      )
    ).length
  }

  if (loading) {
    return <p className="p-8 text-center text-sm text-ink-muted">모둠편성 계획을 불러오는 중…</p>
  }

  // 확정 완료 상태면 스텝 진행 없이 결과 요약 + 인쇄만 보여준다.
  if (readOnly) {
    return (
      <>
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
          <div>
            <h1 className="text-lg font-semibold text-ink-primary">모둠 편성</h1>
            <p className="text-sm text-ink-secondary">{YEAR}학년도 신입생 입학전형 · {roundToText(ROUND)}</p>
          </div>
          <button type="button" onClick={printGroupSheet} className="rounded-md border border-border px-3 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
            모둠표 인쇄
          </button>
        </div>

        <div className="mb-5 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-4">
          <p className="text-sm font-semibold text-brand-deepGreenStrong">모둠활동 준비가 확정되었습니다.</p>
        </div>

        <div className="mx-auto max-w-7xl grid grid-cols-1 gap-4 lg:grid-cols-2 xl:grid-cols-3">
          {groups.map((group) => {
            const avg = groupAverage(group)
            return (
              <article key={group.id} className="rounded-lg border border-border bg-surface-card p-4">
                <h3 className="text-base font-semibold text-ink-primary">
                  {group.groupCode} 모둠
                  {group.shiftCode && <span className="ml-2 rounded-full bg-surface-subtle px-2 py-0.5 text-xs font-normal text-ink-secondary">{shiftLabel(group.shiftCode)}</span>}
                </h3>
                <p className="mt-1 text-xs text-ink-muted">{group.members.length}명 · 서류평균 {avg == null ? '—' : avg.toFixed(2)}</p>
                <p className="mt-2 text-xs text-ink-secondary">
                  주관찰: {group.primaryObservers.map((uid) => evaluatorMap[uid]?.displayName || uid).join(' · ') || '미배정'}
                </p>
                <div className="mt-3 space-y-1.5">
                  {group.members.map((applicantId) => {
                    const candidate = candidateMap[applicantId]
                    if (!candidate) return null
                    return <ApplicantChip key={applicantId} candidate={candidate} draggable={false} onDragStart={() => {}} full />
                  })}
                </div>
              </article>
            )
          })}
        </div>
      </>
    )
  }

  return (
    <>
      <div className="mb-1 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-ink-primary">모둠 편성</h1>
          <p className="text-sm text-ink-secondary">{YEAR}학년도 신입생 입학전형 · {roundToText(ROUND)}</p>
        </div>
        <span className="text-xs font-medium text-brand-deepGreenStrong">
          {saving ? '저장 중…' : dirty ? '저장 안 된 변경사항 있음' : '임시 저장됨 ✓'}
        </span>
      </div>

      <Stepper steps={STEP_LABELS} currentIndex={currentStep} onStepClick={setCurrentStep} />

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-4 py-3 text-sm text-status-danger">{error}</p>}

      {isStale && (
        <div className="mb-4">
          <AlertBanner {...translateAlert({ code: 'DOCUMENT_SOURCE_STALE' })} />
        </div>
      )}

      <div className="mx-auto max-w-7xl">
        {/* ── Step 1: 모둠 편성 ─────────────────────────────────── */}
        {currentStep === 0 && (
          <section>
            <div className="mb-3 flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold text-ink-primary">
                  모둠 편성 <span className="ml-2 text-sm font-normal text-ink-muted">{assignedIds.size}명 / {candidates.length}명 배정</span>
                </h2>
                <p className="text-xs text-ink-muted">지원자를 모둠 사이로 이동해 균형을 조정합니다.</p>
              </div>
              <button type="button" onClick={addGroup} className="rounded-md border border-border px-3 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
                + 모둠 추가
              </button>
            </div>

            <div className="mb-4 rounded-lg border border-dashed border-border bg-surface-card p-3" onDragOver={(event) => event.preventDefault()} onDrop={(event) => handleDrop(event, null)}>
              <p className="mb-2 text-xs font-medium text-ink-secondary">미배정 지원자 ({unassignedCandidates.length})</p>
              <div className="flex min-h-12 flex-wrap gap-2">
                {unassignedCandidates.length === 0 && <span className="text-xs text-ink-muted">모든 1단계 합격자가 배정되었습니다.</span>}
                {unassignedCandidates.map((candidate) => (
                  <ApplicantChip key={candidate.applicantId} candidate={candidate} draggable onDragStart={handleDragStart} />
                ))}
              </div>
            </div>

            <div className="grid grid-cols-1 gap-4 lg:grid-cols-2 xl:grid-cols-3">
              {groups.map((group, groupIndex) => {
                const avg = groupAverage(group)
                return (
                  <article key={group.id} className="rounded-lg border border-border bg-surface-card p-4" onDragOver={(event) => event.preventDefault()} onDrop={(event) => handleDrop(event, group.id)}>
                    <div className="mb-3 flex items-start justify-between gap-2">
                      <div className="flex-1">
                        <input
                          value={group.groupCode}
                          onChange={(event) => updateGroups((current) => current.map((item) => item.id === group.id ? { ...item, groupCode: event.target.value } : item))}
                          className="w-28 rounded-md border border-border px-2 py-1 text-sm font-semibold"
                          aria-label={`${groupIndex + 1}번째 모둠 코드`}
                        />
                        <p className="mt-1 text-xs text-ink-muted">{group.members.length}명 · 서류평균 {avg == null ? '—' : avg.toFixed(2)}</p>
                        <select
                          value={group.shiftCode || ''}
                          onChange={(event) => updateGroups((current) => current.map((item) => item.id === group.id ? { ...item, shiftCode: event.target.value } : item))}
                          className="mt-2 rounded-md border border-border px-2 py-1 text-xs"
                          aria-label={`${group.groupCode} 모둠 운영 반`}
                        >
                          {SHIFT_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                        </select>
                      </div>
                      <button type="button" onClick={() => removeGroup(group.id)} className="text-xs text-status-danger hover:opacity-80">삭제</button>
                    </div>
                    <div className="min-h-24 space-y-2">
                      {group.members.map((applicantId) => {
                        const candidate = candidateMap[applicantId]
                        if (!candidate) return null
                        return <ApplicantChip key={applicantId} candidate={candidate} draggable onDragStart={handleDragStart} full />
                      })}
                      {group.members.length === 0 && <p className="py-6 text-center text-xs text-ink-muted">지원자를 이곳으로 끌어오세요.</p>}
                    </div>
                  </article>
                )
              })}
            </div>

            <StepFooter onNext={() => { saveDraft(); setCurrentStep(1) }} nextLabel="다음: 관찰위원 배정 →" onSaveDraft={saveDraft} saving={saving} />
          </section>
        )}

        {/* ── Step 2: 관찰위원 배정 ─────────────────────────────── */}
        {currentStep === 1 && (
          <section>
            <h2 className="mb-1 text-base font-semibold text-ink-primary">관찰위원 배정</h2>
            <p className="mb-4 text-xs text-ink-muted">각 모둠에 주관찰위원 2명을 배정합니다. 같은 위원을 여러 모둠 주관찰로 겹쳐 배정할 수 없습니다.</p>

            <div className="space-y-4">
              {groups.map((group) => (
                <div key={group.id} className="rounded-lg border border-border bg-surface-card p-4">
                  <p className="mb-3 text-sm font-semibold text-ink-primary">{group.groupCode}모둠</p>
                  <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                    {[0, 1].map((slot) => (
                      <label key={slot} className="text-xs text-ink-secondary">
                        주관찰위원 {slot + 1}
                        <select
                          value={group.primaryObservers[slot] || ''}
                          onChange={(event) => setPrimaryObserver(group.id, slot, event.target.value)}
                          className="mt-1 w-full rounded-md border border-border px-2 py-2 text-sm"
                        >
                          <option value="">선택하세요</option>
                          {evaluators.map((evaluator) => (
                            <option
                              key={evaluator.uid}
                              value={evaluator.uid}
                              disabled={
                                group.primaryObservers.some((uid, index) => index !== slot && uid === evaluator.uid)
                                || (primaryGroupByEvaluator[evaluator.uid] && primaryGroupByEvaluator[evaluator.uid] !== group.id)
                              }
                            >
                              {evaluator.displayName}
                            </option>
                          ))}
                        </select>
                      </label>
                    ))}
                  </div>
                  {group.primaryObservers.filter(Boolean).length < 2 && (
                    <p className="mt-2 text-xs text-status-danger">🔴 {group.groupCode}모둠의 주관찰위원이 아직 다 배정되지 않았습니다.</p>
                  )}
                </div>
              ))}
            </div>

            <StepFooter
              onPrev={() => setCurrentStep(0)}
              onNext={() => { saveDraft(); setCurrentStep(2) }}
              nextLabel="다음: 순환 관찰 →"
              onSaveDraft={saveDraft}
              saving={saving}
            />
          </section>
        )}

        {/* ── Step 3: 순환 관찰 ─────────────────────────────────── */}
        {currentStep === 2 && (
          <section>
            <div className="mb-4 flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold text-ink-primary">순환 관찰</h2>
                <p className="text-xs text-ink-muted">주관찰위원이 다른 모둠을 관찰할 시간을 지정합니다. 2부제면 구간마다 반(오전·오후)을 고르세요 — 그 반 모둠만 검사·배정 대상이 됩니다.</p>
              </div>
              <button type="button" onClick={addSegment} className="rounded-md border border-border px-3 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
                + 순환 관찰 시간 추가
              </button>
            </div>

            <div className="space-y-4">
              {segments.map((segment, segIndex) => {
                const scopedGroups = groups.filter((group) => segmentCoversGroup(segment, group))
                const allCovered = scopedGroups.every((group) => segmentCoverage(segment, group) >= 1)
                return (
                  <div key={segment.id} className={`rounded-lg border p-4 ${allCovered ? 'border-border' : 'border-status-danger'}`}>
                    <div className="mb-3 grid grid-cols-1 gap-2 sm:grid-cols-[8rem_8rem_1fr_1fr_auto]">
                      <input value={segment.segmentCode} onChange={(event) => updateSegmentField(segment.id, 'segmentCode', event.target.value)} className="rounded-md border border-border px-3 py-2 text-sm" aria-label="순환 관찰 이름" />
                      <select value={segment.shiftCode || ''} onChange={(event) => setSegmentShift(segment.id, event.target.value)} className="rounded-md border border-border px-2 py-2 text-sm" aria-label={`${segment.segmentCode} 반`}>
                        {SHIFT_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                      </select>
                      <input type="datetime-local" value={segment.startsAt} onChange={(event) => updateSegmentField(segment.id, 'startsAt', event.target.value)} className="rounded-md border border-border px-3 py-2 text-sm" aria-label={`${segment.segmentCode} 시작시간`} />
                      <input type="datetime-local" value={segment.endsAt} onChange={(event) => updateSegmentField(segment.id, 'endsAt', event.target.value)} className="rounded-md border border-border px-3 py-2 text-sm" aria-label={`${segment.segmentCode} 종료시간`} />
                      <button type="button" onClick={() => removeSegment(segment.id)} className="px-2 text-xs text-status-danger">삭제</button>
                    </div>

                    <div className="mb-3 flex flex-wrap gap-2">
                      {scopedGroups.map((group) => {
                        const count = segmentCoverage(segment, group)
                        return (
                          <span key={group.id} className={`rounded-full px-2 py-1 text-xs ${count >= 1 ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-status-dangerSoft text-status-danger'}`}>
                            {group.groupCode} 주관찰 잔류 {count}/2
                          </span>
                        )
                      })}
                    </div>
                    {!allCovered && <p className="mb-3 text-xs text-status-danger">🔴 일부 모둠에 남아있는 주관찰위원이 없습니다.</p>}

                    <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
                      {evaluators.map((evaluator) => {
                        const target = segment.assignments.find((assignment) => assignment.evaluatorUid === evaluator.uid)?.targetGroupId || ''
                        const homeGroup = groups.find((group) => group.primaryObservers.includes(evaluator.uid))
                        // 반 구간에서는 그 반 모둠의 주관찰위원만 배정이 필수, 나머지는 '관찰 안 함'이 허용된다.
                        const required = !segment.shiftCode || (homeGroup && segmentCoversGroup(segment, homeGroup))
                        return (
                          <label key={evaluator.uid} className="rounded-md bg-surface-subtle p-2 text-xs text-ink-secondary">
                            <span className="font-medium">{evaluator.displayName}</span>
                            {homeGroup && <span className="ml-1 text-ink-muted">(주관찰 {homeGroup.groupCode})</span>}
                            <select value={target} onChange={(event) => setRotationAssignment(segment.id, evaluator.uid, event.target.value)} className="mt-1 w-full rounded-md border border-border bg-surface-card px-2 py-2 text-xs">
                              <option value="">{required ? '관찰대상 미배정' : '관찰 안 함'}</option>
                              {scopedGroups.map((group) => <option key={group.id} value={group.id}>{group.groupCode} 모둠</option>)}
                            </select>
                          </label>
                        )
                      })}
                    </div>
                    <p className="mt-2 text-xs text-ink-muted">{segIndex + 1}차 순환 관찰</p>
                  </div>
                )
              })}

              {segments.length === 0 && <p className="rounded-md border border-dashed border-border py-8 text-center text-sm text-ink-muted">아직 순환 관찰 시간이 없습니다.</p>}
            </div>

            <StepFooter
              onPrev={() => setCurrentStep(1)}
              onNext={() => { saveDraft(); setCurrentStep(3) }}
              nextLabel="다음: 검토·확정 →"
              onSaveDraft={saveDraft}
              saving={saving}
            />
          </section>
        )}

        {/* ── Step 4: 검토·확정 ─────────────────────────────────── */}
        {currentStep === 3 && (
          <section>
            <h2 className="mb-4 text-base font-semibold text-ink-primary">모둠활동 준비 검토</h2>

            <div className="mb-5 rounded-lg border border-border bg-surface-card p-4">
              <ReviewRow label="지원자 배정" ok={assignedIds.size === candidates.length} text={`${assignedIds.size} / ${candidates.length}`} />
              <ReviewRow label="빈 모둠" ok={groups.every((g) => g.members.length > 0)} text={groups.every((g) => g.members.length > 0) ? '없음' : '있음'} />
              <ReviewRow label="주관찰위원 배정" ok={groups.every((g) => g.primaryObservers.filter(Boolean).length === 2)} text={`${groups.filter((g) => g.primaryObservers.filter(Boolean).length === 2).length * 2} / ${groups.length * 2}`} />
              <ReviewRow label="순환 관찰 시간" ok={segments.length > 0} text={`${segments.length}회`} />
              <ReviewRow label="관찰 공백" ok={validation?.complete === true} text={validation?.complete === true ? '없음' : '확인 필요'} last />
            </div>

            {(validation?.warnings || []).map((warning) => (
              <div key={warning.code} className="mb-3 rounded-md border border-status-warning bg-status-warningSoft px-4 py-3 text-sm text-status-warning">
                <p>{warning.message}</p>
                {warning.items?.length > 0 && <p className="mt-1 text-xs">{warning.items.map((item) => item.displayName).join(', ')}</p>}
              </div>
            ))}

            {validation?.complete ? (
              <p className="mb-4 rounded-md bg-brand-greenSoft px-4 py-3 text-sm font-medium text-brand-deepGreenStrong">
                모둠활동을 시작할 준비가 되었습니다.
              </p>
            ) : (
              <div className="mb-4">
                <BlockingPanel issues={translatedBlockingIssues} />
              </div>
            )}

            <div className="flex flex-wrap justify-between gap-2">
              <button type="button" onClick={() => setCurrentStep(2)} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
                ← 이전
              </button>
              <div className="flex gap-2">
                <button type="button" onClick={printGroupSheet} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
                  모둠표 미리보기
                </button>
                <button
                  type="button"
                  onClick={() => setShowFinalize(true)}
                  disabled={dirty || validation?.complete !== true || saving}
                  className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:cursor-not-allowed disabled:opacity-40"
                >
                  모둠활동 준비 확정
                </button>
              </div>
            </div>
          </section>
        )}
      </div>

      <TypedConfirmDialog
        open={showFinalize}
        title="모둠활동 준비를 확정하시겠습니까?"
        description="확정하면 지원자별 모둠 배정이 평가용 명단에 반영되고, 관리자 재개방 절차 전에는 일반 수정이 불가능합니다."
        fields={[
          { label: '확정 대상', value: `${YEAR}학년도 ${roundToText(ROUND)}` },
          { label: '모둠 수', value: `${groups.length}개` },
          { label: '확정자', value: userDoc?.display_name || '—' },
        ]}
        confirmPhrase={FINAL_CONFIRM_TEXT}
        confirmLabel="준비 확정"
        onConfirm={finalize}
        onCancel={() => setShowFinalize(false)}
        submitting={saving}
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
          <button type="button" onClick={onPrev} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
            ← 이전
          </button>
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

function SummaryCard({ label, value, warn = false }) {
  return (
    <div className={`rounded-lg border bg-white p-3 ${warn ? 'border-status-warning' : 'border-border'}`}>
      <p className="text-xs text-ink-muted">{label}</p>
      <p className={`mt-1 text-lg font-semibold ${warn ? 'text-status-warning' : 'text-ink-primary'}`}>{value}</p>
    </div>
  )
}

function ApplicantChip({ candidate, draggable, onDragStart, full = false }) {
  return (
    <div
      draggable={draggable}
      onDragStart={(event) => onDragStart(event, candidate.applicantId)}
      className={`rounded-md border border-border bg-surface-subtle px-3 py-2 ${draggable ? 'cursor-grab active:cursor-grabbing' : ''} ${full ? 'flex items-center justify-between gap-2' : ''}`}
    >
      <div>
        <p className="text-sm font-medium text-ink-primary">{candidate.examNo || '수험번호 미발급'} · {candidate.displayName}</p>
        {full && <p className="text-[11px] text-ink-muted">1단계 {candidate.rank}위</p>}
      </div>
      <span className="text-xs font-semibold text-brand-deepGreenStrong">{Number(candidate.documentScore).toFixed(2)}</span>
    </div>
  )
}
