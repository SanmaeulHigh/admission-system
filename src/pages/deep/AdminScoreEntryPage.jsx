// 관리자 대리 채점 입력 화면 (2026-07-14 추가)
//
// 배경: 본관(모둠활동·면접·글쓰기 평가 장소)은 학교 내부망이 안 닿을 수
// 있어 종이로 채점 후 나중에 시스템에 옮겨 적는 방식을 쓰기로 했다. 원칙은
// 평가위원 본인이 직접 로그인해서 입력하는 것(기존 채점 화면 그대로)이지만,
// 그게 어려운 경우(계정 문제, 자리 이탈 등)를 대비해 superadmin/admin이
// 평가위원을 대신해 입력할 수 있는 경로를 제공한다.
//
// admin_submit_group_score/admin_submit_interview_score/admin_submit_writing_score는
// 기존 submit_*_score와 완전히 동일한 검증(배정 확인, 문항 완결성, 중복제출
// 차단, 평가영역 오픈 여부)을 재사용하고, 반드시 사유코드를 남긴다. 이미
// 제출확정된 건은 이 화면에서 덮어쓸 수 없다 — 먼저 reopen_*_score로
// 재개방해야 한다(평가위원 실수 정정과 동일한 절차 강제).

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import StatusBadge from '../../components/status/StatusBadge'
import AdminDocumentScoreEntry from './AdminDocumentScoreEntry'
import ReopenScoreButton from '../../components/actions/ReopenScoreButton'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import ExcelScoreEntry from './ExcelScoreEntry'

const REASON_OPTIONS = ['평가위원 접속 불가(종이채점 대리입력)', '평가위원 요청', '입력 오류 정정', '기타']

// 2026-09-28: 서류평가 5개 영역을 추가했다. 대리 입력이 필요한 상황(평가위원
// 로그인 불가 등)은 심층역량평가만의 일이 아니라서, 한 화면에서 전 영역을
// 다루도록 모았다. 서류평가 쪽은 AdminDocumentScoreEntry가 담당한다.
const DOCUMENT_AREAS = ['attendance', 'academic', 'community', 'essay', 'opinion']

const AREA_TABS = [
  { value: 'attendance', label: '출결', group: '서류평가' },
  { value: 'academic', label: '학업성실도', group: '서류평가' },
  { value: 'community', label: '공동체', group: '서류평가' },
  { value: 'essay', label: '자기소개서', group: '서류평가' },
  { value: 'opinion', label: '학부모소견서', group: '서류평가' },
  { value: 'group', label: '모둠활동', group: '심층역량평가' },
  { value: 'interview', label: '면접', group: '심층역량평가' },
  { value: 'writing', label: '글쓰기', group: '심층역량평가' },
]

const GROUP_CRITERION_LABELS = {
  contribution: '기여도',
  communication: '소통',
  logicCreativity: '논리·창의',
}

function sumItems(items) {
  return Object.values(items || {}).reduce((sum, value) => sum + (Number(value) || 0), 0)
}

function formatTime(value) {
  if (!value) return '-'
  return new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(value))
}

function sectionLabel(section) {
  return section === 'student' ? '학생면접' : '학부모면접'
}

export default function AdminScoreEntryPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [area, setArea] = useState('group')
  // 'single' = 한 명씩 입력, 'excel' = 엑셀 양식으로 일괄 입력(2026-10-01)
  const [entryMode, setEntryMode] = useState('single')
  const [evaluators, setEvaluators] = useState([])
  const [evaluatorUid, setEvaluatorUid] = useState('')
  const [context, setContext] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [submitting, setSubmitting] = useState(false)

  const [selectedApplicantId, setSelectedApplicantId] = useState(null)
  const [section, setSection] = useState('student')
  const [reasonCode, setReasonCode] = useState(REASON_OPTIONS[0])
  const [reasonText, setReasonText] = useState('')

  const [groupForm, setGroupForm] = useState(null)
  const [interviewForm, setInterviewForm] = useState(null)
  const [writingForm, setWritingForm] = useState(null)

  const resetSelection = () => {
    setSelectedApplicantId(null)
    setGroupForm(null)
    setInterviewForm(null)
    setWritingForm(null)
    setError(null)
    setReasonCode(REASON_OPTIONS[0])
    setReasonText('')
  }

  // 평가영역 탭 변경 시 평가위원 목록 갱신
  useEffect(() => {
    setEvaluatorUid('')
    setContext(null)
    resetSelection()
    setNotice(null)
    supabase.rpc('admin_list_score_entry_evaluators', { p_area: area }).then(({ data, error: err }) => {
      if (err) setError(err.message)
      else setEvaluators(data || [])
    })
  }, [area])

  const isDocumentArea = DOCUMENT_AREAS.includes(area)

  const loadContext = useCallback(async (targetUid) => {
    // 서류평가 영역은 AdminDocumentScoreEntry가 자체적으로 조회한다.
    if (DOCUMENT_AREAS.includes(area)) {
      setContext(null)
      return
    }
    if (!targetUid || !YEAR || !ROUND) {
      setContext(null)
      return
    }
    setLoading(true)
    setError(null)
    const rpcName = area === 'group'
      ? 'admin_get_group_score_entry_context'
      : area === 'interview'
        ? 'admin_get_interview_score_entry_context'
        : 'admin_get_writing_score_entry_context'
    const { data, error: err } = await supabase.rpc(rpcName, {
      p_year: YEAR,
      p_round: ROUND,
      p_target_evaluator_uid: targetUid,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      setContext(null)
      return
    }
    setContext(data)
  }, [area, YEAR, ROUND])

  useEffect(() => {
    resetSelection()
    loadContext(evaluatorUid)
  }, [evaluatorUid, loadContext])

  // ---------- 모둠활동 ----------
  const groups = context?.groups || []
  const groupCriteria = context?.criteria || []
  const criterionMax = Number(context?.criterionMax || 5)
  const scoreStep = Number(context?.scoreStep || 1)
  const groupScoreValues = useMemo(() => {
    const values = []
    for (let value = 0; value <= criterionMax + 1e-9; value += scoreStep) {
      values.push(Number(value.toFixed(2)))
    }
    return values
  }, [criterionMax, scoreStep])
  const segmentMap = useMemo(
    () => Object.fromEntries((context?.segments || []).map((segment) => [segment.segmentId, segment])),
    [context],
  )
  const selectedGroup = groups.find((group) => group.members?.some((member) => member.applicantId === selectedApplicantId)) || null
  const selectedGroupMember = selectedGroup?.members?.find((member) => member.applicantId === selectedApplicantId) || null

  const openGroupMember = (group, member) => {
    resetSelection()
    setSelectedApplicantId(member.applicantId)
    setGroupForm({
      observationConfirmed: member.myScore?.observationConfirmed ?? (group.observerRole === 'primary'),
      observedSegmentIds: member.myScore?.observedSegmentIds || [],
      items: member.myScore?.items || {},
    })
  }

  const submitGroup = async () => {
    if (!selectedGroupMember || !selectedGroup || !groupForm) return
    setError(null)
    if (reasonCode === '기타' && !reasonText.trim()) {
      setError('사유가 "기타"인 경우 사유 내용을 입력해야 합니다.')
      return
    }
    if (groupCriteria.some((key) => groupForm.items?.[key] === undefined)) {
      setError('세 평가 기준의 점수를 모두 입력해 주세요.')
      return
    }
    if ((groupForm.observedSegmentIds || []).length === 0) {
      setError('실제로 관찰한 구간을 최소 1개 선택해 주세요.')
      return
    }
    if (selectedGroup.observerRole === 'roving' && !groupForm.observationConfirmed) {
      setError('순환관찰은 충분히 관찰했다고 판단한 지원자만 제출할 수 있습니다.')
      return
    }
    setSubmitting(true)
    const { data, error: err } = await supabase.rpc('admin_submit_group_score', {
      p_applicant_id: selectedGroupMember.applicantId,
      p_target_evaluator_uid: evaluatorUid,
      p_observation_confirmed: groupForm.observationConfirmed,
      p_observed_segment_ids: groupForm.observedSegmentIds,
      p_items: groupForm.items,
      p_reason_code: reasonCode,
      p_reason_text: reasonCode === '기타' ? reasonText.trim() : null,
    })
    setSubmitting(false)
    if (err) {
      setError(err.message)
      return
    }
    setNotice(`제출확정 완료 · 합계 ${data?.total ?? 0}점`)
    resetSelection()
    await loadContext(evaluatorUid)
  }

  // ---------- 면접 ----------
  const schedule = context?.schedule || []
  const sectionConfig = context?.[section] || { criteria: [], perEvaluatorMax: 0 }
  const selectedInterviewApplicant = schedule.find((item) => item.applicantId === selectedApplicantId) || null

  const openInterviewScore = (applicantId, nextSection) => {
    resetSelection()
    const applicant = schedule.find((item) => item.applicantId === applicantId)
    const score = applicant?.myScore?.[nextSection]
    setSelectedApplicantId(applicantId)
    setSection(nextSection)
    setInterviewForm({ items: score?.items || {}, memo: score?.memo || '' })
  }

  const submitInterview = async () => {
    if (!selectedInterviewApplicant || !interviewForm) return
    setError(null)
    if (reasonCode === '기타' && !reasonText.trim()) {
      setError('사유가 "기타"인 경우 사유 내용을 입력해야 합니다.')
      return
    }
    const missing = (sectionConfig.criteria || []).filter((criterion) => interviewForm.items?.[criterion.key] === undefined)
    if (missing.length > 0) {
      setError(`미입력 기준: ${missing.map((criterion) => criterion.label).join(', ')}`)
      return
    }
    setSubmitting(true)
    const { data, error: err } = await supabase.rpc('admin_submit_interview_score', {
      p_applicant_id: selectedInterviewApplicant.applicantId,
      p_section: section,
      p_target_evaluator_uid: evaluatorUid,
      p_items: interviewForm.items,
      p_memo: interviewForm.memo || null,
      p_reason_code: reasonCode,
      p_reason_text: reasonCode === '기타' ? reasonText.trim() : null,
    })
    setSubmitting(false)
    if (err) {
      setError(err.message)
      return
    }
    setNotice(`${sectionLabel(section)} 제출확정 완료 · 합계 ${data?.total ?? 0}점`)
    resetSelection()
    await loadContext(evaluatorUid)
  }

  // ---------- 글쓰기 ----------
  const candidates = context?.candidates || []
  const writingConfig = context?.config || {}
  const questions = writingConfig?.questions || []
  const pickCount = Number(writingConfig?.questionRule?.pick || 2)
  const selectedCandidate = candidates.find((candidate) => candidate.applicantId === selectedApplicantId) || null
  const writingTotal = useMemo(
    () => (writingForm?.responses || []).reduce((sum, response) => sum + sumItems(response.items), 0),
    [writingForm],
  )

  const openWritingScore = (applicantId) => {
    resetSelection()
    const candidate = candidates.find((item) => item.applicantId === applicantId)
    const score = candidate?.myScore
    setSelectedApplicantId(applicantId)
    setWritingForm({
      responses: Array.isArray(score?.responses)
        ? score.responses.map((response) => ({ questionId: response.questionId, items: response.items || {} }))
        : [],
      memo: score?.memo || '',
    })
  }

  const toggleWritingQuestion = (questionId) => {
    setWritingForm((current) => {
      const exists = current.responses.some((response) => response.questionId === questionId)
      if (exists) {
        return { ...current, responses: current.responses.filter((response) => response.questionId !== questionId) }
      }
      if (current.responses.length >= pickCount) {
        setError(`${pickCount}개 문항만 선택할 수 있습니다. 기존 선택 문항 하나를 먼저 해제하세요.`)
        return current
      }
      setError(null)
      return { ...current, responses: [...current.responses, { questionId, items: {} }] }
    })
  }

  const setWritingScore = (questionId, criterionKey, value) => {
    setWritingForm((current) => ({
      ...current,
      responses: current.responses.map((response) => (
        response.questionId === questionId
          ? { ...response, items: { ...response.items, [criterionKey]: Number(value) } }
          : response
      )),
    }))
  }

  const submitWriting = async () => {
    if (!selectedCandidate || !writingForm) return
    setError(null)
    if (reasonCode === '기타' && !reasonText.trim()) {
      setError('사유가 "기타"인 경우 사유 내용을 입력해야 합니다.')
      return
    }
    if (writingForm.responses.length !== pickCount) {
      setError(`${questions.length}문항 중 ${pickCount}문항을 정확히 선택해야 합니다.`)
      return
    }
    const missing = []
    for (const response of writingForm.responses) {
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
    setSubmitting(true)
    const { data, error: err } = await supabase.rpc('admin_submit_writing_score', {
      p_applicant_id: selectedCandidate.applicantId,
      p_target_evaluator_uid: evaluatorUid,
      p_responses: writingForm.responses,
      p_memo: writingForm.memo || null,
      p_reason_code: reasonCode,
      p_reason_text: reasonCode === '기타' ? reasonText.trim() : null,
    })
    setSubmitting(false)
    if (err) {
      setError(err.message)
      return
    }
    setNotice(`글쓰기 제출확정 완료 · 합계 ${data?.total ?? 0}점`)
    resetSelection()
    await loadContext(evaluatorUid)
  }

  const isGroupLocked = selectedGroupMember?.myScore?.submissionState === 'submitted'
  const isInterviewLocked = selectedInterviewApplicant?.myScore?.[section]?.submissionState === 'submitted'
  const isWritingLocked = selectedCandidate?.myScore?.submissionState === 'submitted'
  const hasSelection = Boolean(selectedGroupMember || selectedInterviewApplicant || selectedCandidate)

  const reasonBlock = (
    <div className="mt-5 space-y-3 border-t pt-4">
      <div>
        <p className="text-sm font-semibold text-ink-primary">대리 입력 사유</p>
        <div className="mt-2 flex flex-wrap gap-2">
          {REASON_OPTIONS.map((option) => (
            <button
              key={option}
              type="button"
              onClick={() => setReasonCode(option)}
              className={`rounded-full border px-3 py-1.5 text-xs font-semibold ${reasonCode === option ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border text-ink-secondary'}`}
            >
              {option}
            </button>
          ))}
        </div>
      </div>
      {reasonCode === '기타' && (
        <textarea
          value={reasonText}
          onChange={(event) => setReasonText(event.target.value)}
          rows={2}
          placeholder="사유를 구체적으로 입력하세요."
          className="w-full rounded-lg border-border text-sm"
        />
      )}
    </div>
  )

  return (
    <div className="mx-auto max-w-6xl space-y-4 pb-16">
      <div>
        <Link to="/deep/paper-backup" className="text-xs text-ink-muted underline">현장 종이 백업 화면 바로가기</Link>
        <h1 className="mt-1 text-lg font-semibold text-ink-primary">관리자 대리 채점 입력</h1>
        <p className="mt-1 text-xs text-ink-muted">
          평가위원 본인이 직접 로그인해 입력하는 것이 원칙입니다. 이 화면은 접속 불가 등 부득이한 경우에만 사용하며, 모든 입력은 사유와 함께 감사 기록에 남습니다.
          이미 제출확정된 채점은 지원자를 고른 뒤 '재개방' 버튼으로 연 다음 다시 입력하세요.
        </p>
      </div>

      {/* 영역이 8개로 늘어 한 줄에 나열하면 구분이 안 된다. 서류평가와
          심층역량평가로 묶어서 보여준다. */}
      <div className="space-y-3">
        {['서류평가', '심층역량평가'].map((groupName) => (
          <div key={groupName}>
            <p className="mb-1.5 text-xs font-semibold text-ink-muted">{groupName}</p>
            <div className="flex flex-wrap gap-2">
              {AREA_TABS.filter((t) => t.group === groupName).map((tab) => (
                <button
                  key={tab.value}
                  type="button"
                  onClick={() => setArea(tab.value)}
                  className={`rounded-lg border px-4 py-2 text-sm font-semibold ${area === tab.value ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen'}`}
                >
                  {tab.label}
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="rounded-xl border bg-white p-4">
        <label className="block text-sm font-semibold text-ink-primary">
          대상 평가위원
          <select
            value={evaluatorUid}
            onChange={(event) => setEvaluatorUid(event.target.value)}
            className="mt-2 w-full rounded-lg border-border text-sm"
          >
            <option value="">평가위원을 선택하세요</option>
            {evaluators.map((evaluator) => (
              <option key={evaluator.uid} value={evaluator.uid}>{evaluator.displayName} ({evaluator.email})</option>
            ))}
          </select>
        </label>
        <div className="mt-3 flex gap-2" role="tablist" aria-label="입력 방식">
          {[['single', '한 명씩 입력'], ['excel', '엑셀로 일괄 입력']].map(([mode, label]) => (
            <button
              key={mode}
              type="button"
              role="tab"
              aria-selected={entryMode === mode}
              onClick={() => setEntryMode(mode)}
              className={`rounded-lg border px-4 py-2 text-sm font-semibold ${entryMode === mode ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen'}`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      {entryMode === 'excel' ? (
        <ExcelScoreEntry
          area={area}
          areaLabel={AREA_TABS.find((t) => t.value === area)?.label || area}
          evaluatorUid={evaluatorUid}
          evaluatorName={evaluators.find((e) => e.uid === evaluatorUid)?.displayName || ''}
        />
      ) : (<>
      {notice && <div className="rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-3 text-sm text-brand-deepGreenStrong">{notice}</div>}
      {error && <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>}
      {loading && <div className="text-sm text-ink-muted">불러오는 중…</div>}

      {!evaluatorUid && !loading && !isDocumentArea && (
        <div className="rounded-xl border border-dashed bg-white p-6 text-center text-sm text-ink-muted">평가위원을 선택하면 배정 명단이 표시됩니다.</div>
      )}

      {/* ---------- 서류평가 5개 영역 ----------
          채점 입력은 평가위원이 쓰는 폼을 그대로 재사용한다. 사유는 아래
          reasonBlock에서 받은 값을 그대로 넘긴다. */}
      {isDocumentArea && (
        <>
          <div className="rounded-xl border bg-white p-4">{reasonBlock}</div>
          <AdminDocumentScoreEntry
            area={area}
            evaluatorUid={evaluatorUid}
            reasonCode={reasonCode}
            reasonText={reasonText}
            onSubmitted={() => setNotice('대리 입력이 저장되었습니다. 감사 기록에 사유와 함께 남았습니다.')}
          />
        </>
      )}

      {context && !context.areaOpen && (
        <div className="rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
          현재 이 평가영역이 열려있지 않아 제출확정이 서버에서 차단됩니다.
        </div>
      )}

      {/* ---------- 모둠활동 ---------- */}
      {area === 'group' && context && !hasSelection && (
        <div className="space-y-3">
          {groups.map((group) => (
            <section key={group.groupId} className="rounded-xl border bg-white p-4">
              <div className="flex items-center justify-between">
                <p className="text-sm font-bold text-ink-primary">{group.groupCode}모둠 · {group.observerRole === 'primary' ? '주관찰' : '순환관찰'}</p>
              </div>
              <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                {(group.members || []).map((member) => {
                  const state = member.myScore?.submissionState
                  return (
                    <button
                      key={member.applicantId}
                      type="button"
                      onClick={() => openGroupMember(group, member)}
                      className="rounded-lg border p-3 text-left hover:border-brand-deepGreen"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <p className="font-semibold text-ink-primary">{member.displayName}</p>
                        <StatusBadge status={state || 'draft'} label={state ? undefined : '미입력'} />
                      </div>
                      <p className="mt-1 text-xs text-ink-muted">{member.examNo || '수험번호 미부여'}</p>
                      {member.myScore && <p className="mt-1 text-xs font-semibold text-brand-deepGreenStrong">{sumItems(member.myScore.items)}/15</p>}
                    </button>
                  )
                })}
              </div>
            </section>
          ))}
          {groups.length === 0 && <div className="rounded-xl border border-dashed bg-white p-6 text-center text-sm text-ink-muted">이 평가위원에게 배정된 관찰 모둠이 없습니다.</div>}
        </div>
      )}

      {area === 'group' && selectedGroupMember && selectedGroup && groupForm && (
        <section className="rounded-xl border bg-white p-4">
          <button type="button" onClick={resetSelection} className="text-xs text-ink-muted hover:text-ink-primary">← 명단으로</button>
          <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold text-ink-primary">{selectedGroupMember.displayName}</h2>
              <p className="text-xs text-ink-muted">{selectedGroup.groupCode}모둠 · {selectedGroup.observerRole === 'primary' ? '주관찰' : '순환관찰'} · {selectedGroupMember.examNo || '-'}</p>
            </div>
            <p className="text-2xl font-bold text-brand-deepGreenStrong">{sumItems(groupForm.items)}/15</p>
          </div>

          {isGroupLocked && (
            <div className="mt-3 rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>이미 제출확정된 채점입니다. 고치려면 먼저 재개방하세요.</span>
                <ReopenScoreButton
                  area="group"
                  applicantId={selectedGroupMember.applicantId}
                  evaluatorUid={evaluatorUid}
                  targetText={selectedGroupMember.displayName}
                  onDone={async () => { setNotice('재개방했습니다. 점수를 고친 뒤 다시 제출확정하세요.'); await loadContext(evaluatorUid) }}
                />
              </div>
            </div>
          )}

          <div className="mt-5 space-y-5">
            {groupCriteria.map((key) => (
              <div key={key}>
                <div className="mb-2 flex items-center justify-between">
                  <p className="text-sm font-bold text-ink-primary">{GROUP_CRITERION_LABELS[key] || key}</p>
                  <span className="text-lg font-bold text-brand-deepGreenStrong">{groupForm.items?.[key] ?? '-'}</span>
                </div>
                <div className="grid grid-cols-6 gap-2">
                  {groupScoreValues.map((value) => (
                    <button
                      key={value}
                      type="button"
                      disabled={isGroupLocked}
                      onClick={() => setGroupForm((current) => ({ ...current, items: { ...current.items, [key]: value } }))}
                      className={`min-h-12 rounded-xl border text-base font-bold disabled:opacity-50 ${Number(groupForm.items?.[key]) === value ? 'border-brand-deepGreen bg-brand-deepGreen text-white' : 'border-border bg-surface-subtle text-ink-secondary'}`}
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
            <div className="mt-3 flex flex-wrap gap-2">
              {(selectedGroup.allowedSegmentIds || []).map((segmentId) => {
                const segment = segmentMap[segmentId]
                const selected = groupForm.observedSegmentIds.includes(segmentId)
                return (
                  <button
                    key={segmentId}
                    type="button"
                    disabled={isGroupLocked}
                    onClick={() => setGroupForm((current) => {
                      const set = new Set(current.observedSegmentIds || [])
                      if (set.has(segmentId)) set.delete(segmentId)
                      else set.add(segmentId)
                      return { ...current, observedSegmentIds: [...set] }
                    })}
                    className={`rounded-full border px-3 py-2 text-xs font-semibold disabled:opacity-50 ${selected ? 'border-ink-primary bg-ink-primary text-white' : 'border-border bg-white text-ink-secondary'}`}
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
                checked={groupForm.observationConfirmed}
                disabled={isGroupLocked}
                onChange={(event) => setGroupForm((current) => ({ ...current, observationConfirmed: event.target.checked }))}
                className="mt-0.5 h-5 w-5"
              />
              <span className="text-sm font-bold text-status-warning">충분히 관찰했습니다.</span>
            </label>
          )}

          {reasonBlock}

          <button
            type="button"
            disabled={isGroupLocked || submitting || !context?.areaOpen}
            onClick={submitGroup}
            className="mt-5 min-h-12 w-full rounded-xl bg-brand-deepGreen px-4 py-3 text-base font-bold text-white disabled:bg-border-strong"
          >
            {submitting ? '제출 중…' : '대리 제출확정'}
          </button>
        </section>
      )}

      {/* ---------- 면접 ---------- */}
      {area === 'interview' && context && !hasSelection && (
        <section className="rounded-xl border bg-white p-4">
          <p className="text-sm font-semibold text-ink-primary">{context?.team ? `${context.team.teamCode}조 · ${context.team.location || '장소 미지정'}` : '면접 일정'}</p>
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
                    <button type="button" onClick={() => openInterviewScore(item.applicantId, 'student')} className="rounded-lg border p-3 text-left hover:border-brand-deepGreen">
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-sm font-semibold">학생면접</span>
                        <StatusBadge status={studentState} />
                      </div>
                      <p className="mt-1 text-xs text-ink-muted">{formatTime(item.studentStartsAt)}–{formatTime(item.studentEndsAt)}</p>
                    </button>
                    <button type="button" onClick={() => openInterviewScore(item.applicantId, 'parent')} className="rounded-lg border p-3 text-left hover:border-brand-deepGreen">
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
            {schedule.length === 0 && <p className="text-sm text-ink-muted">이 평가위원에게 배정된 면접 일정이 없습니다.</p>}
          </div>
        </section>
      )}

      {area === 'interview' && selectedInterviewApplicant && interviewForm && (
        <section className="rounded-xl border bg-white p-4">
          <button type="button" onClick={resetSelection} className="text-xs text-ink-muted hover:text-ink-primary">← 일정 목록</button>
          <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold text-ink-primary">{selectedInterviewApplicant.displayName}</h2>
              <p className="text-xs text-ink-muted">{selectedInterviewApplicant.examNo || '-'} · {sectionLabel(section)}</p>
            </div>
            <p className="text-2xl font-bold text-brand-deepGreenStrong">{sumItems(interviewForm.items)}점</p>
          </div>

          <div className="mt-4 grid grid-cols-2 gap-2">
            {['student', 'parent'].map((tab) => (
              <button
                key={tab}
                type="button"
                onClick={() => openInterviewScore(selectedInterviewApplicant.applicantId, tab)}
                className={`rounded-lg border px-3 py-2 text-sm font-semibold ${section === tab ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'text-ink-secondary'}`}
              >
                {sectionLabel(tab)}
              </button>
            ))}
          </div>

          {isInterviewLocked && (
            <div className="mt-3 rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>이미 제출확정된 채점입니다. 고치려면 먼저 재개방하세요(최고관리자).</span>
                <ReopenScoreButton
                  area={section === 'student' ? 'interview_student' : 'interview_parent'}
                  applicantId={selectedInterviewApplicant.applicantId}
                  evaluatorUid={evaluatorUid}
                  targetText={`${selectedInterviewApplicant.displayName} · ${sectionLabel(section)}`}
                  onDone={async () => { setNotice('재개방했습니다. 점수를 고친 뒤 다시 제출확정하세요.'); await loadContext(evaluatorUid) }}
                />
              </div>
            </div>
          )}

          <div className="mt-5 space-y-5">
            {(sectionConfig.criteria || []).map((criterion) => (
              <div key={criterion.key}>
                <div className="flex items-center justify-between gap-2">
                  <p className="text-sm font-semibold text-ink-primary">{criterion.label}</p>
                  <span className="text-sm font-bold text-brand-deepGreenStrong">{interviewForm.items?.[criterion.key] ?? '-'}점</span>
                </div>
                <div className={`mt-2 grid gap-2 ${criterion.scoreValues?.length === 6 ? 'grid-cols-3 sm:grid-cols-6' : 'grid-cols-5'}`}>
                  {(criterion.scoreValues || []).map((value) => (
                    <button
                      key={value}
                      type="button"
                      disabled={isInterviewLocked}
                      onClick={() => setInterviewForm((current) => ({ ...current, items: { ...current.items, [criterion.key]: Number(value) } }))}
                      className={`min-h-12 rounded-lg border text-base font-semibold disabled:opacity-50 ${Number(interviewForm.items?.[criterion.key]) === Number(value) ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen'}`}
                    >
                      {value}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>

          <label className="mt-5 block text-sm font-semibold text-ink-primary">
            면접 메모 <span className="font-normal text-ink-muted">(최대 2,000자)</span>
            <textarea
              value={interviewForm.memo}
              onChange={(event) => setInterviewForm((current) => ({ ...current, memo: event.target.value }))}
              disabled={isInterviewLocked}
              maxLength={2000}
              rows={4}
              className="mt-2 w-full rounded-lg border-border text-sm disabled:bg-surface-subtle"
            />
          </label>

          {reasonBlock}

          <button
            type="button"
            disabled={isInterviewLocked || submitting || !context?.areaOpen}
            onClick={submitInterview}
            className="mt-5 w-full rounded-lg bg-brand-deepGreenStrong px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            {submitting ? '제출 중…' : `${sectionLabel(section)} 대리 제출확정`}
          </button>
        </section>
      )}

      {/* ---------- 글쓰기 ---------- */}
      {area === 'writing' && context && !hasSelection && (
        <section className="rounded-xl border bg-white p-4">
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {candidates.map((candidate) => {
              const state = candidate.myScore?.submissionState
              const total = candidate.myScore?.serverComputed?.total
              return (
                <button
                  key={candidate.applicantId}
                  type="button"
                  onClick={() => openWritingScore(candidate.applicantId)}
                  className="rounded-lg border p-3 text-left hover:border-brand-deepGreen"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <p className="font-semibold text-ink-primary">{candidate.displayName}</p>
                      <p className="text-xs text-ink-muted">{candidate.examNo || '-'}</p>
                    </div>
                    <StatusBadge status={state || 'draft'} label={state ? undefined : '미입력'} />
                  </div>
                  {candidate.myScore && <p className="mt-3 text-right text-xs font-semibold text-brand-deepGreenStrong">{total ?? 0}/{writingConfig?.perEvaluatorMax || 200}</p>}
                </button>
              )
            })}
            {candidates.length === 0 && <p className="text-sm text-ink-muted">이 평가위원에게 배정된 글쓰기 채점 대상이 없습니다.</p>}
          </div>
        </section>
      )}

      {area === 'writing' && selectedCandidate && writingForm && (
        <section className="rounded-xl border bg-white p-4">
          <button type="button" onClick={resetSelection} className="text-xs text-ink-muted hover:text-ink-primary">← 대상 목록</button>
          <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold text-ink-primary">{selectedCandidate.displayName}</h2>
              <p className="text-xs text-ink-muted">{selectedCandidate.examNo || '-'}</p>
            </div>
            <p className="text-2xl font-bold text-brand-deepGreenStrong">{writingTotal}점</p>
          </div>

          {isWritingLocked && (
            <div className="mt-3 rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>이미 제출확정된 채점입니다. 고치려면 먼저 재개방하세요(최고관리자).</span>
                <ReopenScoreButton
                  area="writing"
                  applicantId={selectedCandidate.applicantId}
                  evaluatorUid={evaluatorUid}
                  targetText={selectedCandidate.displayName}
                  onDone={async () => { setNotice('재개방했습니다. 점수를 고친 뒤 다시 제출확정하세요.'); await loadContext(evaluatorUid) }}
                />
              </div>
            </div>
          )}

          <div className="mt-5">
            <p className="text-sm font-semibold text-ink-primary">선택문항</p>
            <div className="mt-3 grid grid-cols-3 gap-2">
              {questions.map((question) => {
                const active = writingForm.responses.some((response) => response.questionId === question.id)
                return (
                  <button
                    key={question.id}
                    type="button"
                    disabled={isWritingLocked}
                    onClick={() => toggleWritingQuestion(question.id)}
                    className={`rounded-lg border px-3 py-3 text-sm font-semibold disabled:opacity-50 ${active ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border text-ink-secondary'}`}
                  >
                    {question.label}
                  </button>
                )
              })}
            </div>
            <p className="mt-2 text-right text-xs text-ink-muted">{writingForm.responses.length}/{pickCount} 선택</p>
          </div>

          <div className="mt-5 space-y-6">
            {writingForm.responses.map((response) => {
              const question = questions.find((item) => item.id === response.questionId)
              if (!question) return null
              return (
                <article key={response.questionId} className="rounded-xl border p-4">
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="text-sm font-bold text-ink-primary">{question.label}</h3>
                    <span className="text-lg font-bold text-brand-deepGreenStrong">{sumItems(response.items)}/{writingConfig?.questionRule?.each || 100}</span>
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
                              disabled={isWritingLocked}
                              onClick={() => setWritingScore(response.questionId, criterion.key, value)}
                              className={`min-h-11 rounded-lg border text-sm font-semibold disabled:opacity-50 ${Number(response.items?.[criterion.key]) === Number(value) ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen'}`}
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
            글쓰기 평가 메모 <span className="font-normal text-ink-muted">(최대 2,000자)</span>
            <textarea
              value={writingForm.memo}
              onChange={(event) => setWritingForm((current) => ({ ...current, memo: event.target.value }))}
              disabled={isWritingLocked}
              maxLength={2000}
              rows={4}
              className="mt-2 w-full rounded-lg border-border text-sm disabled:bg-surface-subtle"
            />
          </label>

          {reasonBlock}

          <button
            type="button"
            disabled={isWritingLocked || submitting || !context?.areaOpen}
            onClick={submitWriting}
            className="mt-5 w-full rounded-lg bg-brand-deepGreenStrong px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            {submitting ? '제출 중…' : '글쓰기 대리 제출확정'}
          </button>
        </section>
      )}
      </>)}
    </div>
  )
}
