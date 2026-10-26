import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { supabase } from '../../lib/supabase'
import {
  flushGroupDraftQueue,
  getQueuedGroupDrafts,
  queueGroupDraft,
  removeQueuedGroupDraft,
} from '../../lib/groupDraftQueue'
import { getGroupWorkspaceCache, saveGroupWorkspaceCache } from '../../lib/groupWorkspaceCache'
import FieldShell from '../../components/layout/FieldShell'

const CRITERION_LABELS = {
  contribution: '기여도',
  communication: '소통',
  logicCreativity: '논리·창의',
}

function formatTime(value) {
  if (!value) return ''
  return new Intl.DateTimeFormat('ko-KR', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(value))
}

function sumItems(items) {
  return Object.values(items || {}).reduce((sum, value) => sum + (Number(value) || 0), 0)
}

function queueMap(userId) {
  return Object.fromEntries(
    getQueuedGroupDrafts(userId).map((entry) => [entry.applicantId, entry])
  )
}

function toFieldSaveState(saveStatus) {
  if (saveStatus === 'saving' || saveStatus === 'submitting') return 'saving'
  if (saveStatus === 'saved' || saveStatus === 'submitted') return 'saved'
  if (saveStatus === 'queued') return 'offline'
  if (saveStatus === 'stale') return 'syncNeeded'
  if (saveStatus === 'error') return 'error'
  return null
}

export default function GroupObservationPage() {
  const { session } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const userId = session?.user?.id
  const [workspace, setWorkspace] = useState(null)
  const [activeGroupId, setActiveGroupId] = useState(null)
  const [selectedApplicantId, setSelectedApplicantId] = useState(null)
  const [form, setForm] = useState(null)
  const [dirty, setDirty] = useState(false)
  const [saveStatus, setSaveStatus] = useState('idle')
  const [loading, setLoading] = useState(true)
  const [syncing, setSyncing] = useState(false)
  const [online, setOnline] = useState(navigator.onLine)
  const [workspaceFromCache, setWorkspaceFromCache] = useState(false)
  const [error, setError] = useState(null)
  const saveTimer = useRef(null)

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)

    if (!navigator.onLine) {
      const cached = getGroupWorkspaceCache(userId)
      if (!cached) {
        setWorkspace(null)
        setWorkspaceFromCache(false)
        setError('오프라인에서 사용할 최소 명단 캐시가 없습니다. 온라인 상태에서 이 화면을 한 번 열어 주세요.')
        setLoading(false)
        return
      }

      setWorkspace(cached.workspace)
      setWorkspaceFromCache(true)
      setActiveGroupId((current) => {
        if (current && cached.workspace?.groups?.some((group) => group.groupId === current)) return current
        return cached.workspace?.groups?.[0]?.groupId || null
      })
      setLoading(false)
      return
    }

    const { data, error: loadError } = await supabase.rpc('get_m5b_observation_workspace', {
      p_year: YEAR,
      p_round: ROUND,
    })

    if (loadError) {
      setError(loadError.message)
      setLoading(false)
      return
    }

    saveGroupWorkspaceCache(userId, data)
    setWorkspace(data)
    setWorkspaceFromCache(false)
    setActiveGroupId((current) => {
      if (current && data?.groups?.some((group) => group.groupId === current)) return current
      return data?.groups?.[0]?.groupId || null
    })
    setLoading(false)
  }, [userId, YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    const handleOnline = async () => {
      setOnline(true)
      if (!userId) return
      setSyncing(true)
      await flushGroupDraftQueue(userId)
      setSyncing(false)
      await load()
    }
    const handleOffline = () => setOnline(false)
    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [load, userId])

  useEffect(() => () => clearTimeout(saveTimer.current), [])

  const groups = workspace?.groups || []
  const criteria = workspace?.criteria || []
  const criterionMax = Number(workspace?.criterionMax || 5)
  const scoreStep = Number(workspace?.scoreStep || 1)
  const scoreValues = useMemo(() => {
    const values = []
    for (let value = 0; value <= criterionMax + 1e-9; value += scoreStep) {
      values.push(Number(value.toFixed(2)))
    }
    return values
  }, [criterionMax, scoreStep])

  const segmentMap = useMemo(
    () => Object.fromEntries((workspace?.segments || []).map((segment) => [segment.segmentId, segment])),
    [workspace]
  )

  const activeGroup = groups.find((group) => group.groupId === activeGroupId) || null
  const selectedMember = activeGroup?.members?.find(
    (member) => member.applicantId === selectedApplicantId
  ) || groups.flatMap((group) => group.members || []).find(
    (member) => member.applicantId === selectedApplicantId
  ) || null
  const selectedGroup = groups.find((group) =>
    group.members?.some((member) => member.applicantId === selectedApplicantId)
  ) || null

  const currentSegment = useMemo(() => {
    const now = Date.now()
    return (workspace?.segments || []).find(
      (segment) => new Date(segment.startsAt).getTime() <= now && now < new Date(segment.endsAt).getTime()
    )
  }, [workspace])

  const openMember = (group, member) => {
    const queued = queueMap(userId)[member.applicantId]
    const serverScore = member.myScore
    const useQueued = queued && (
      !serverScore?.clientUpdatedAt
      || new Date(queued.clientUpdatedAt) > new Date(serverScore.clientUpdatedAt)
    )

    const source = useQueued ? queued : {
      observationConfirmed: serverScore?.observationConfirmed ?? group.observerRole === 'primary',
      observedSegmentIds: serverScore?.observedSegmentIds || [],
      items: serverScore?.items || {},
    }

    setActiveGroupId(group.groupId)
    setSelectedApplicantId(member.applicantId)
    setForm({
      observationConfirmed: group.observerRole === 'primary' ? true : Boolean(source.observationConfirmed),
      observedSegmentIds: source.observedSegmentIds || [],
      items: source.items || {},
      submissionState: serverScore?.submissionState || 'draft',
    })
    setDirty(false)
    setSaveStatus(useQueued ? 'queued' : 'idle')
    setError(null)
  }

  const scheduleDraftSave = (nextForm) => {
    if (!selectedApplicantId || nextForm.submissionState === 'submitted') return
    setDirty(true)
    setSaveStatus('saving')
    clearTimeout(saveTimer.current)
    saveTimer.current = setTimeout(async () => {
      const payload = {
        applicantId: selectedApplicantId,
        observationConfirmed: Boolean(nextForm.observationConfirmed),
        observedSegmentIds: nextForm.observedSegmentIds || [],
        items: nextForm.items || {},
        clientUpdatedAt: new Date().toISOString(),
      }

      queueGroupDraft(userId, payload)

      if (!navigator.onLine) {
        setSaveStatus('queued')
        setDirty(false)
        return
      }

      const { data, error: saveError } = await supabase.rpc('save_group_score_draft', {
        p_applicant_id: payload.applicantId,
        p_observation_confirmed: payload.observationConfirmed,
        p_observed_segment_ids: payload.observedSegmentIds,
        p_items: payload.items,
        p_client_updated_at: payload.clientUpdatedAt,
      })

      if (saveError) {
        setSaveStatus('queued')
        setError(`임시저장은 기기에 보관했습니다. 서버 동기화 실패: ${saveError.message}`)
        setDirty(false)
        return
      }

      removeQueuedGroupDraft(userId, payload.applicantId)
      setSaveStatus(data?.accepted === false ? 'stale' : 'saved')
      setDirty(false)
    }, 650)
  }

  const updateForm = (updater) => {
    if (!form || form.submissionState === 'submitted') return
    const next = typeof updater === 'function' ? updater(form) : updater
    setForm(next)
    scheduleDraftSave(next)
  }

  const setCriterionScore = (key, value) => {
    updateForm((current) => ({
      ...current,
      items: { ...current.items, [key]: value },
    }))
  }

  const toggleSegment = (segmentId) => {
    updateForm((current) => {
      const selected = new Set(current.observedSegmentIds || [])
      if (selected.has(segmentId)) selected.delete(segmentId)
      else selected.add(segmentId)
      return { ...current, observedSegmentIds: [...selected] }
    })
  }

  const handleSubmit = async () => {
    if (!form || !selectedMember || !selectedGroup) return
    setError(null)

    if (!navigator.onLine) {
      setError('제출확정은 온라인 상태에서만 가능합니다. 초안은 이 기기에 안전하게 대기 중입니다.')
      return
    }
    if (criteria.some((key) => form.items?.[key] === undefined)) {
      setError('세 평가 기준의 점수를 모두 입력해 주세요.')
      return
    }
    if ((form.observedSegmentIds || []).length === 0) {
      setError('실제로 관찰한 구간을 최소 1개 선택해 주세요.')
      return
    }
    if (selectedGroup.observerRole === 'roving' && !form.observationConfirmed) {
      setError('순환관찰은 충분히 관찰했다고 판단한 지원자만 제출할 수 있습니다.')
      return
    }

    clearTimeout(saveTimer.current)
    setSaveStatus('submitting')
    const { data, error: submitError } = await supabase.rpc('submit_group_score', {
      p_applicant_id: selectedMember.applicantId,
      p_observation_confirmed: form.observationConfirmed,
      p_observed_segment_ids: form.observedSegmentIds,
      p_items: form.items,
    })

    if (submitError) {
      setSaveStatus('error')
      setError(submitError.message)
      return
    }

    removeQueuedGroupDraft(userId, selectedMember.applicantId)
    setSaveStatus('submitted')
    setError(null)
    setSelectedApplicantId(null)
    setForm(null)
    await load()

    return data
  }

  if (loading) {
    return <div className="flex h-screen items-center justify-center bg-surface-canvas p-6 text-sm text-ink-muted">모둠활동 평가 화면을 불러오는 중…</div>
  }

  if (error && !workspace) {
    return (
      <div className="flex h-screen items-center justify-center bg-surface-canvas px-4 py-6">
        <div className="w-full max-w-lg rounded-xl border border-status-danger bg-surface-card p-5">
          <p className="font-semibold text-status-danger">화면을 열 수 없습니다.</p>
          <p className="mt-2 text-sm text-ink-secondary">{error}</p>
        </div>
      </div>
    )
  }

  return (
    <FieldShell
      title="모둠활동 관찰채점"
      contextLine={selectedGroup ? `${selectedGroup.groupCode}모둠 · ${selectedGroup.observerRole === 'primary' ? '주관찰' : '순환관찰'}` : activeGroup ? `${activeGroup.groupCode}모둠` : undefined}
      saveState={selectedApplicantId ? toFieldSaveState(saveStatus) : null}
    >
      <div className="mx-auto max-w-lg pb-24">
        <div className={`mb-3 rounded-lg px-3 py-2 text-xs ${online ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-brand-orangeSoft text-brand-orangeStrong'}`}>
          {syncing ? '기기에 대기 중인 초안을 서버와 동기화하는 중…' : online ? '온라인 · 초안 자동저장 사용 가능' : workspaceFromCache ? '오프라인 · 24시간 최소 명단 캐시 사용 중 · 초안은 기기에 대기하며 제출확정은 온라인 복구 후 가능합니다.' : '오프라인 · 초안은 기기에 대기하며 제출확정은 온라인 복구 후 가능합니다.'}
        </div>

        {currentSegment && (
          <div className="mb-3 rounded-lg bg-ink-primary px-3 py-2 text-xs text-white">
            현재 {currentSegment.segmentCode} · {formatTime(currentSegment.startsAt)}~{formatTime(currentSegment.endsAt)} · 관찰 {groups.find((group) => group.groupId === currentSegment.targetGroupId)?.groupCode || '-'}모둠
          </div>
        )}
        {!workspace?.areaOpen && (
          <div className="mb-4 rounded-xl border border-status-warning bg-status-warningSoft p-4 text-sm text-status-warning">
            현재 `group` 평가영역이 열려 있지 않습니다. 명단 확인은 가능하지만 초안 저장·제출은 서버에서 차단됩니다.
          </div>
        )}

        <div className="flex gap-2 overflow-x-auto pb-2">
          {groups.map((group) => {
            const submitted = group.members.filter((member) => member.myScore?.submissionState === 'submitted').length
            return (
              <button
                key={group.groupId}
                type="button"
                onClick={() => {
                  setActiveGroupId(group.groupId)
                  setSelectedApplicantId(null)
                  setForm(null)
                }}
                className={`min-w-[104px] rounded-xl border px-3 py-3 text-left ${activeGroupId === group.groupId ? 'border-brand-deepGreen bg-brand-greenSoft' : 'border-border bg-white'}`}
              >
                <p className="font-bold text-ink-primary">{group.groupCode}모둠</p>
                <p className="mt-1 text-[11px] text-ink-muted">{group.observerRole === 'primary' ? '주관찰' : '순환관찰'}</p>
                <p className="mt-1 text-xs font-medium text-brand-deepGreenStrong">{submitted}/{group.members.length} 제출</p>
              </button>
            )
          })}
        </div>

        {groups.length === 0 && (
          <div className="mt-4 rounded-xl border border-dashed bg-white p-6 text-center text-sm text-ink-muted">
            현재 평가자에게 배정된 관찰 모둠이 없습니다.
          </div>
        )}

        {activeGroup && !selectedMember && (
          <section className="mt-3 space-y-2">
            <div className="flex items-end justify-between px-1">
              <div>
                <h2 className="text-sm font-bold text-ink-primary">{activeGroup.groupCode}모둠 지원자</h2>
                <p className="text-xs text-ink-muted">
                  {activeGroup.observerRole === 'primary'
                    ? '주관찰위원은 이 모둠 지원자 전원을 평가해야 합니다.'
                    : '충분히 관찰한 지원자만 선택해 평가합니다.'}
                </p>
              </div>
            </div>

            {activeGroup.members.map((member) => {
              const queued = queueMap(userId)[member.applicantId]
              const state = member.myScore?.submissionState
              const total = state === 'submitted'
                ? member.myScore?.serverComputed?.total
                : queued ? sumItems(queued.items) : sumItems(member.myScore?.items)
              return (
                <button
                  key={member.applicantId}
                  type="button"
                  onClick={() => openMember(activeGroup, member)}
                  className="flex w-full items-center justify-between rounded-xl border border-border bg-white p-4 text-left active:scale-[0.99]"
                >
                  <div>
                    <p className="font-semibold text-ink-primary">{member.displayName}</p>
                    <p className="mt-1 text-xs text-ink-muted">수험번호 {member.examNo || '미부여'}</p>
                  </div>
                  <div className="text-right">
                    <p className={`text-xs font-semibold ${state === 'submitted' ? 'text-brand-deepGreenStrong' : queued ? 'text-status-warning' : 'text-ink-muted'}`}>
                      {state === 'submitted' ? '제출완료' : queued ? '기기 대기' : member.myScore ? '임시저장' : '미입력'}
                    </p>
                    {(state === 'submitted' || member.myScore || queued) && <p className="mt-1 text-sm font-bold text-ink-primary">{total ?? 0}/15</p>}
                  </div>
                </button>
              )
            })}
          </section>
        )}

        {selectedMember && selectedGroup && form && (
          <section className="mt-3 rounded-2xl border border-border bg-white p-4 shadow-sm">
            <button
              type="button"
              onClick={() => {
                setSelectedApplicantId(null)
                setForm(null)
              }}
              className="text-xs font-medium text-ink-muted"
            >
              ← {selectedGroup.groupCode}모둠 명단
            </button>

            <div className="mt-3 flex items-start justify-between gap-3">
              <div>
                <p className="text-lg font-bold text-ink-primary">{selectedMember.displayName}</p>
                <p className="text-xs text-ink-muted">{selectedGroup.observerRole === 'primary' ? '주관찰위원 필수평가' : '순환관찰 선택평가'} · {selectedMember.examNo || '수험번호 미부여'}</p>
              </div>
              <div className="rounded-xl bg-ink-primary px-3 py-2 text-center text-white">
                <p className="text-[10px] text-ink-muted">현재 합계</p>
                <p className="text-xl font-bold">{sumItems(form.items)}<span className="text-xs font-normal"> / 15</span></p>
              </div>
            </div>

            <div className="mt-5 space-y-5">
              {criteria.map((key) => (
                <div key={key}>
                  <div className="mb-2 flex items-center justify-between">
                    <p className="text-sm font-bold text-ink-primary">{CRITERION_LABELS[key] || key}</p>
                    <span className="text-lg font-bold text-brand-deepGreenStrong">{form.items?.[key] ?? '-'}</span>
                  </div>
                  <div className="grid grid-cols-6 gap-2">
                    {scoreValues.map((value) => (
                      <button
                        key={value}
                        type="button"
                        disabled={form.submissionState === 'submitted'}
                        onClick={() => setCriterionScore(key, value)}
                        className={`min-h-12 rounded-xl border text-base font-bold ${Number(form.items?.[key]) === value ? 'border-brand-deepGreen bg-brand-deepGreen text-white' : 'border-border bg-surface-subtle text-ink-secondary'} disabled:opacity-50`}
                      >
                        {value}
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>

            <div className="mt-6 border-t pt-5">
              <p className="text-sm font-bold text-ink-primary">실제 관찰 구간</p>
              <p className="mt-1 text-xs text-ink-muted">서버가 내 순환계획과 다시 대조합니다. 실제로 본 구간만 선택하세요.</p>
              <div className="mt-3 flex flex-wrap gap-2">
                {(selectedGroup.allowedSegmentIds || []).map((segmentId) => {
                  const segment = segmentMap[segmentId]
                  const selected = form.observedSegmentIds.includes(segmentId)
                  return (
                    <button
                      key={segmentId}
                      type="button"
                      disabled={form.submissionState === 'submitted'}
                      onClick={() => toggleSegment(segmentId)}
                      className={`rounded-full border px-3 py-2 text-xs font-semibold ${selected ? 'border-ink-primary bg-ink-primary text-white' : 'border-border bg-white text-ink-secondary'}`}
                    >
                      {segment?.segmentCode || '구간'} {formatTime(segment?.startsAt)}~{formatTime(segment?.endsAt)}
                    </button>
                  )
                })}
              </div>
            </div>

            {selectedGroup.observerRole === 'roving' && (
              <label className="mt-5 flex items-start gap-3 rounded-xl border border-status-warning bg-status-warningSoft p-4">
                <input
                  type="checkbox"
                  checked={form.observationConfirmed}
                  disabled={form.submissionState === 'submitted'}
                  onChange={(event) => updateForm((current) => ({ ...current, observationConfirmed: event.target.checked }))}
                  className="mt-0.5 h-5 w-5"
                />
                <span>
                  <span className="block text-sm font-bold text-status-warning">충분히 관찰했습니다.</span>
                  <span className="mt-1 block text-xs text-status-warning">단편적인 장면만 본 경우에는 제출하지 않습니다. 이 확인이 있어야 순환관찰 점수가 집계에 포함됩니다.</span>
                </span>
              </label>
            )}

            <div className="mt-5 min-h-10">
              <p className="text-xs text-ink-muted">
                {saveStatus === 'saving' && '초안 저장 중…'}
                {saveStatus === 'saved' && '서버에 초안 저장됨'}
                {saveStatus === 'queued' && '기기에 초안 대기 중 · 온라인 복구 시 자동 동기화'}
                {saveStatus === 'stale' && '더 최신 초안이 서버에 있어 이전 재전송을 무시했습니다.'}
                {saveStatus === 'submitting' && '제출확정 중…'}
                {saveStatus === 'submitted' && '제출확정 완료'}
                {dirty && saveStatus === 'idle' && '변경사항 있음'}
              </p>
              {error && <p className="mt-2 rounded-lg bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
            </div>

            <button
              type="button"
              disabled={form.submissionState === 'submitted' || saveStatus === 'submitting' || !workspace?.areaOpen}
              onClick={handleSubmit}
              className="mt-3 min-h-14 w-full rounded-xl bg-brand-deepGreen px-4 py-3 text-base font-bold text-white disabled:bg-border-strong"
            >
              {form.submissionState === 'submitted' ? '제출확정 완료 · 수정 잠김' : online ? '제출확정' : '온라인 복구 후 제출확정'}
            </button>
            <p className="mt-2 text-center text-[11px] text-ink-muted">제출확정 후에는 관리자 재개방 전까지 수정할 수 없습니다.</p>
          </section>
        )}
      </div>
    </FieldShell>
  )
}
