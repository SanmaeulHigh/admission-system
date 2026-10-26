import { Fragment, useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import Stepper from '../../components/layout/Stepper'
import BlockingPanel from '../../components/feedback/BlockingPanel'
import StatusBadge from '../../components/status/StatusBadge'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import InterviewDisplayKeyBox from '../../components/interview/InterviewDisplayKeyBox'
import { translateAlert } from '../../config/alertMessages'
import { newUuid } from '../../lib/uuid'

const STEP_LABELS = ['면접조 편성', '평가위원 배정', '시간표 생성', '검토·확정']

const DEEP_EVALUATION_DATE = '2026-11-14'
const DEFAULT_START = `${DEEP_EVALUATION_DATE}T13:00`
// 면접조 수는 관리자가 1~10개로 정한다(2026-10-01, 기존 4개 고정에서 변경).
const DEFAULT_TEAM_COUNT = 4
const MIN_TEAMS = 1
const MAX_TEAMS = 10
const TEAM_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
// 쉬는 시간(2026-10-01): 학생+학부모 면접 한 세트가 끝날 때마다 위원이 쉴 수 있게
// 조별로 "N명마다 M분"을 넣는다. DB에는 각 지원자의 시각만 저장되므로, 다시 열 때는
// 저장된 시각 사이 간격을 보고 설정을 되살린다(inferBreak).
const DEFAULT_BREAK_EVERY = 1
const DEFAULT_BREAK_MINUTES = 10
const FINAL_CONFIRM_TEXT = '면접조 확정'
// 2회차(2026-10-14, 2부제): 오전·오후처럼 한 조가 두 번 나눠 진행할 때 "N번째 가정부터 HH:MM 다시 시작".
// 이 이상 비는 간격은 쉬는 시간이 아니라 회차 사이(점심)로 본다.
const SESSION_GAP_MINUTES = 30

function newId() {
  return newUuid()
}

function toLocalDateTime(value) {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function addMinutes(value, minutes) {
  const date = new Date(value)
  date.setMinutes(date.getMinutes() + minutes)
  return toLocalDateTime(date)
}

function makeTeam(teamCode, sortOrder) {
  return {
    teamId: newId(),
    teamCode,
    location: `면접실 ${teamCode}`,
    sortOrder,
    memberUids: ['', ''],
    startAt: DEFAULT_START,
    breakEvery: DEFAULT_BREAK_EVERY,
    breakMinutes: DEFAULT_BREAK_MINUTES,
    secondFromIndex: '',
    secondStartAt: '',
    schedule: [],
  }
}

function makeEmptyTeams(count = DEFAULT_TEAM_COUNT) {
  return Array.from({ length: count }, (_, index) => makeTeam(TEAM_LETTERS[index], index + 1))
}

// 아직 안 쓴 첫 번째 조 이름(A, B, C …)
function nextTeamCode(teams) {
  const used = new Set(teams.map((team) => team.teamCode))
  return [...TEAM_LETTERS].find((code) => !used.has(code)) || `${teams.length + 1}`
}

// 화면 문구용: "A~F조", 1개면 "A조"
function teamRangeLabel(teams) {
  if (teams.length === 0) return '면접조 없음'
  if (teams.length === 1) return `${teams[0].teamCode}조`
  return `${teams[0].teamCode}~${teams[teams.length - 1].teamCode}조`
}

function minutesBetween(from, to) {
  if (!from || !to) return 0
  return Math.round((new Date(to) - new Date(from)) / 60000)
}

// 저장된 시간표에서 쉬는 시간 설정을 되살린다. 간격이 없으면 0분(쉬는 시간 없음),
// 시간표가 비어 있으면 기본값을 쓴다.
// 30분 이상 빈 곳은 2회차 시작(점심 등)으로 보고, 쉬는 시간 추정에서 뺀다.
// 쉬는 시간 위치는 회차 안에서 센다(2회차 첫 가정부터 다시 1번).
function inferBreak(schedule) {
  const none = { secondFromIndex: '', secondStartAt: '' }
  if (schedule.length < 2) return { breakEvery: DEFAULT_BREAK_EVERY, breakMinutes: DEFAULT_BREAK_MINUTES, ...none }
  const gaps = schedule.slice(1).map((slot, i) => minutesBetween(schedule[i].parentEndsAt, slot.studentStartsAt))
  const sessionGap = gaps.findIndex((gap) => gap >= SESSION_GAP_MINUTES)
  const second = sessionGap >= 0
    ? { secondFromIndex: sessionGap + 2, secondStartAt: schedule[sessionGap + 1].studentStartsAt }
    : none
  const blockStart = sessionGap >= 0 ? sessionGap + 1 : Infinity // 2회차 첫 가정의 0-based 위치
  const positions = []
  gaps.forEach((gap, i) => {
    if (gap <= 0 || gap >= SESSION_GAP_MINUTES) return
    const posInBlock = i < blockStart ? i + 1 : i + 1 - blockStart
    positions.push({ posInBlock, gap })
  })
  if (positions.length === 0) return { breakEvery: DEFAULT_BREAK_EVERY, breakMinutes: 0, ...second }
  return { breakEvery: positions[0].posInBlock, breakMinutes: positions[0].gap, ...second }
}

function normalizeTeam(team) {
  const schedule = (team.schedule || []).map((slot) => ({
    ...slot,
    studentStartsAt: toLocalDateTime(slot.studentStartsAt),
    studentEndsAt: toLocalDateTime(slot.studentEndsAt),
    parentStartsAt: toLocalDateTime(slot.parentStartsAt),
    parentEndsAt: toLocalDateTime(slot.parentEndsAt),
  }))

  return {
    ...team,
    memberUids: [...(team.memberUids || []), '', ''].slice(0, 2),
    startAt: schedule[0]?.studentStartsAt || DEFAULT_START,
    ...inferBreak(schedule),
    schedule,
  }
}

function rebuildSchedule(team, studentMinutes, parentMinutes) {
  let cursor = team.startAt || DEFAULT_START
  const applicantIds = (team.schedule || []).map((slot) => slot.applicantId)
  // 2회차: secondFromIndex(1부터 셈)번째 가정부터 secondStartAt에 다시 시작, 쉬는 시간 세기도 새로.
  const secondFrom = Number(team.secondFromIndex) || 0
  const hasSecond = secondFrom >= 2 && secondFrom <= applicantIds.length && Boolean(team.secondStartAt)
  let blockStart = 0
  const schedule = applicantIds.map((applicantId, index) => {
    if (hasSecond && index === secondFrom - 1) {
      cursor = team.secondStartAt
      blockStart = index
    }
    const studentStartsAt = cursor
    const studentEndsAt = addMinutes(studentStartsAt, studentMinutes)
    const parentStartsAt = studentEndsAt
    const parentEndsAt = addMinutes(parentStartsAt, parentMinutes)
    cursor = parentEndsAt
    // N명마다 쉬는 시간(마지막 지원자 뒤에는 넣지 않는다)
    const every = Number(team.breakEvery) || 0
    const rest = Number(team.breakMinutes) || 0
    const nextIsSessionStart = hasSecond && index + 1 === secondFrom - 1
    if (every > 0 && rest > 0 && (index - blockStart + 1) % every === 0 && index < applicantIds.length - 1 && !nextIsSessionStart) {
      cursor = addMinutes(cursor, rest)
    }
    return {
      scheduleId: null,
      applicantId,
      studentStartsAt,
      studentEndsAt,
      parentStartsAt,
      parentEndsAt,
      sortOrder: index + 1,
    }
  })
  return { ...team, schedule }
}

function formatScore(value) {
  if (value === null || value === undefined) return '-'
  return Number(value).toFixed(1)
}

export default function InterviewPlanningPage() {
  const { userDoc } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [currentStep, setCurrentStep] = useState(0)
  const [candidates, setCandidates] = useState([])
  const [evaluators, setEvaluators] = useState([])
  const [teams, setTeams] = useState([])
  const [validation, setValidation] = useState(null)
  const [studentMinutes, setStudentMinutes] = useState(25)
  const [parentMinutes, setParentMinutes] = useState(20)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [dirty, setDirty] = useState(false)
  const [showFinalize, setShowFinalize] = useState(false)

  const readOnly = validation?.status === 'finalized'

  const candidateMap = useMemo(
    () => Object.fromEntries(candidates.map((candidate) => [candidate.applicantId, candidate])),
    [candidates]
  )

  const evaluatorMap = useMemo(
    () => Object.fromEntries(evaluators.map((evaluator) => [evaluator.uid, evaluator])),
    [evaluators]
  )

  const candidateTeamMap = useMemo(() => {
    const result = {}
    teams.forEach((team) => {
      team.schedule.forEach((slot) => {
        result[slot.applicantId] = team.teamId
      })
    })
    return result
  }, [teams])

  const usedEvaluatorMap = useMemo(() => {
    const result = {}
    teams.forEach((team) => {
      team.memberUids.filter(Boolean).forEach((uid) => {
        result[uid] = team.teamId
      })
    })
    return result
  }, [teams])

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: loadError } = await supabase.rpc('get_m5c_interview_plan_admin', {
      p_year: YEAR,
      p_round: ROUND,
    })

    if (loadError) {
      setError(loadError.message)
      setLoading(false)
      return
    }

    setCandidates(data?.candidates || [])
    setEvaluators(data?.evaluators || [])
    setStudentMinutes(data?.studentDurationMinutes || 25)
    setParentMinutes(data?.parentDurationMinutes || 20)
    setTeams((data?.teams || []).length > 0 ? data.teams.map(normalizeTeam) : makeEmptyTeams())
    setValidation(data?.validation || null)
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

  // 4단계(검토·확정) 진입 시 변경사항이 있으면 자동으로 저장·검증한다
  // (명세서: "서버 검증" 버튼을 사용자 주행동으로 보여주지 않는다).
  useEffect(() => {
    if (currentStep === 3 && !loading && dirty) {
      save()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentStep])

  const translatedBlockingIssues = useMemo(
    () => (validation?.blockingIssues || []).map((issue) => translateAlert(issue)),
    [validation],
  )

  const updateTeams = (updater) => {
    if (readOnly) return
    setTeams(updater)
    setDirty(true)
  }

  const updateTeamField = (teamId, key, value) => {
    updateTeams((current) => current.map((team) => (
      team.teamId === teamId ? { ...team, [key]: value } : team
    )))
  }

  // 순서 이동 — 면접 순서는 시간표 자동생성 순서를 그대로 따르므로,
  // 순서를 바꾸면 그 조의 시간표를 다시 계산한다(뒤 순서가 밀려 내려간다).
  const moveSlot = (teamId, index, direction) => {
    updateTeams((current) => current.map((team) => {
      if (team.teamId !== teamId) return team
      const target = index + direction
      if (target < 0 || target >= team.schedule.length) return team
      const schedule = [...team.schedule]
      const [moved] = schedule.splice(index, 1)
      schedule.splice(target, 0, moved)
      return rebuildSchedule({ ...team, schedule }, studentMinutes, parentMinutes)
    }))
  }

  // 개별 시간 직접 수정 — 자동 생성값을 손으로 덮어쓸 수 있게 한다.
  // (예: 특정 지원자만 늦게 도착, 중간에 휴식시간을 끼워 넣는 경우)
  // 여기서 고친 값은 "시간표 재생성"을 누르면 다시 자동값으로 덮어써진다.
  const updateSlotTime = (teamId, applicantId, key, value) => {
    updateTeams((current) => current.map((team) => {
      if (team.teamId !== teamId) return team
      return {
        ...team,
        schedule: team.schedule.map((slot) => (
          slot.applicantId === applicantId ? { ...slot, [key]: value } : slot
        )),
      }
    }))
  }

  const setMember = (teamId, slotIndex, uid) => {
    updateTeams((current) => current.map((team) => {
      if (team.teamId !== teamId) return team
      const memberUids = [...team.memberUids]
      memberUids[slotIndex] = uid
      return { ...team, memberUids }
    }))
  }

  // 쉬는 시간 설정을 바꾸면 그 조 시간표를 바로 다시 계산한다.
  const updateTeamBreak = (teamId, key, value) => {
    const n = Math.max(0, Math.min(key === 'breakEvery' ? 20 : 120, Number(value) || 0))
    updateTeams((current) => current.map((team) => (
      team.teamId === teamId ? rebuildSchedule({ ...team, [key]: n }, studentMinutes, parentMinutes) : team
    )))
  }

  // 2회차 설정: 시각은 HH:MM으로 받아 1회차 날짜에 붙인다. 바꾸면 그 조 시간표를 다시 계산한다.
  const updateTeamSession = (teamId, key, value) => {
    updateTeams((current) => current.map((team) => {
      if (team.teamId !== teamId) return team
      let next
      if (key === 'secondStartAt') {
        const day = (team.startAt || DEFAULT_START).slice(0, 10)
        next = { ...team, secondStartAt: value ? `${day}T${value}` : '' }
      } else {
        next = { ...team, secondFromIndex: value === '' ? '' : Math.max(2, Number(value) || 2) }
      }
      return rebuildSchedule(next, studentMinutes, parentMinutes)
    }))
  }

  const regenerateTeamSchedule = (teamId) => {
    updateTeams((current) => current.map((team) => (
      team.teamId === teamId ? rebuildSchedule(team, studentMinutes, parentMinutes) : team
    )))
  }

  const assignCandidate = (applicantId, targetTeamId) => {
    updateTeams((current) => {
      const moved = current.map((team) => ({
        ...team,
        schedule: team.schedule.filter((slot) => slot.applicantId !== applicantId),
      }))

      const next = moved.map((team) => {
        if (team.teamId !== targetTeamId) return team
        const schedule = [
          ...team.schedule,
          {
            scheduleId: null,
            applicantId,
            studentStartsAt: '',
            studentEndsAt: '',
            parentStartsAt: '',
            parentEndsAt: '',
            sortOrder: team.schedule.length + 1,
          },
        ]
        return rebuildSchedule({ ...team, schedule }, studentMinutes, parentMinutes)
      })

      return next.map((team) => (
        team.teamId === targetTeamId
          ? team
          : rebuildSchedule(team, studentMinutes, parentMinutes)
      ))
    })
  }

  // 면접조 수 조절 — 늘리면 빈 조를 뒤에 붙이고, 줄이면 맨 뒤 조부터 지운다.
  // 지울 조에 지원자·위원이 있으면 미배정으로 돌아간다는 확인을 먼저 받는다.
  const changeTeamCount = (nextCount) => {
    if (nextCount < MIN_TEAMS || nextCount > MAX_TEAMS || nextCount === teams.length) return
    if (nextCount > teams.length) {
      updateTeams((current) => {
        const next = [...current]
        while (next.length < nextCount) next.push(makeTeam(nextTeamCode(next), next.length + 1))
        return next
      })
      return
    }
    const removed = teams.slice(nextCount)
    const applicantCount = removed.reduce((sum, team) => sum + team.schedule.length, 0)
    const memberCount = removed.reduce((sum, team) => sum + team.memberUids.filter(Boolean).length, 0)
    if (applicantCount + memberCount > 0) {
      const names = removed.map((team) => `${team.teamCode}조`).join(', ')
      // eslint-disable-next-line no-alert
      if (!window.confirm(`${names}를 삭제합니다.
배정된 지원자 ${applicantCount}명, 평가위원 ${memberCount}명이 미배정으로 돌아갑니다.
계속할까요?`)) return
    }
    updateTeams((current) => current.slice(0, nextCount))
  }

  const autoBalance = () => {
    if (teams.length === 0) return
    updateTeams((current) => {
      const cleared = current.map((team) => ({ ...team, schedule: [] }))
      candidates.forEach((candidate, index) => {
        cleared[index % cleared.length].schedule.push({ applicantId: candidate.applicantId })
      })
      return cleared.map((team) => rebuildSchedule(team, studentMinutes, parentMinutes))
    })
  }

  const serializeTeams = () => teams.map((team, index) => ({
    teamId: team.teamId,
    teamCode: team.teamCode,
    location: team.location,
    sortOrder: index + 1,
    memberUids: team.memberUids.filter(Boolean),
    schedule: team.schedule.map((slot, slotIndex) => ({
      applicantId: slot.applicantId,
      studentStartsAt: new Date(slot.studentStartsAt).toISOString(),
      studentEndsAt: new Date(slot.studentEndsAt).toISOString(),
      parentStartsAt: new Date(slot.parentStartsAt).toISOString(),
      parentEndsAt: new Date(slot.parentEndsAt).toISOString(),
      sortOrder: slotIndex + 1,
    })),
  }))

  const validateLocalSchedule = () => {
    for (const team of teams) {
      for (const slot of team.schedule) {
        const values = [slot.studentStartsAt, slot.studentEndsAt, slot.parentStartsAt, slot.parentEndsAt]
        if (values.some((value) => !value || Number.isNaN(new Date(value).getTime()))) {
          return `${team.teamCode}조 시간표에 비어 있거나 잘못된 시간이 있습니다.`
        }
      }
    }
    return null
  }

  const save = async () => {
    const localError = validateLocalSchedule()
    if (localError) {
      setError(localError)
      return
    }
    setSaving(true)
    setError(null)
    const { data, error: saveError } = await supabase.rpc('save_m5c_interview_plan', {
      p_year: YEAR,
      p_round: ROUND,
      p_teams: serializeTeams(),
    })
    if (saveError) {
      setError(saveError.message)
      setSaving(false)
      return
    }
    setValidation(data)
    setDirty(false)
    await load()
    setSaving(false)
  }

  const finalize = async () => {
    setSaving(true)
    setError(null)
    const { data, error: finalizeError } = await supabase.rpc('finalize_m5c_interview_plan', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (finalizeError) {
      setError(finalizeError.message)
      setSaving(false)
      return
    }
    setValidation(data)
    setShowFinalize(false)
    await load()
    setSaving(false)
  }

  if (loading) {
    return <p className="p-6 text-sm text-ink-muted">면접조 계획을 불러오는 중…</p>
  }

  if (readOnly) {
    return (
      <div className="mx-auto max-w-7xl">
        <div className="mb-5 flex items-center justify-between gap-3 border-b border-border pb-4">
          <div>
            <h1 className="text-lg font-semibold text-ink-primary">학생·학부모면접 조 편성·시간표</h1>
            <p className="mt-1 text-xs text-ink-muted">{teamRangeLabel(teams)} 2인 독립채점 · 학생 {studentMinutes}분 · 학부모 {parentMinutes}분</p>
          </div>
          <StatusBadge status="finalized" />
        </div>
        <InterviewDisplayKeyBox />
        <div className="grid gap-4 xl:grid-cols-2">
          {teams.map((team) => (
            <article key={team.teamId} className="rounded-xl border border-border bg-surface-card p-4">
              <h2 className="text-base font-semibold text-ink-primary">{team.teamCode}조</h2>
              <p className="mt-1 text-xs text-ink-muted">
                {team.memberUids.map((uid) => evaluatorMap[uid]?.displayName).filter(Boolean).join(' · ') || '위원 미배정'} · {team.location}
              </p>
              <table className="mt-3 min-w-full text-left text-xs">
                <thead className="border-b border-border text-ink-muted">
                  <tr><th className="px-2 py-2">지원자</th><th className="px-2 py-2">학생면접</th><th className="px-2 py-2">학부모면접</th></tr>
                </thead>
                <tbody>
                  {team.schedule.map((slot) => {
                    const candidate = candidateMap[slot.applicantId]
                    return (
                      <tr key={slot.applicantId} className="border-b border-border last:border-0">
                        <td className="px-2 py-2">{candidate?.displayName}</td>
                        <td className="px-2 py-2">{toLocalDateTime(slot.studentStartsAt).slice(11)}–{toLocalDateTime(slot.studentEndsAt).slice(11)}</td>
                        <td className="px-2 py-2">{toLocalDateTime(slot.parentStartsAt).slice(11)}–{toLocalDateTime(slot.parentEndsAt).slice(11)}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </article>
          ))}
        </div>
        <p className="mt-4 text-xs text-ink-muted">개별 면접위원의 실제 채점값은 이 관리자 편성 화면에 표시되지 않습니다.</p>
      </div>
    )
  }

  return (
    <>
      <div className="mb-1 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-ink-primary">면접 준비</h1>
          <p className="text-sm text-ink-secondary">{teamRangeLabel(teams)} 2인 독립채점 · 학생 {studentMinutes}분 · 학부모 {parentMinutes}분</p>
        </div>
        <span className="text-xs font-medium text-brand-deepGreenStrong">
          {saving ? '저장 중…' : dirty ? '저장 안 된 변경사항 있음' : '임시 저장됨 ✓'}
        </span>
      </div>

      <Stepper steps={STEP_LABELS} currentIndex={currentStep} onStepClick={setCurrentStep} />

      {error && <p className="mb-4 rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</p>}

      <div className="mx-auto max-w-7xl space-y-5">
        {/* ── Step 1: 면접조 편성 ───────────────────────────────── */}
        {currentStep === 0 && (
          <section>
            <div className="mb-3 flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold text-ink-primary">면접조 편성</h2>
                <p className="text-xs text-ink-muted">지원자를 {teamRangeLabel(teams)}에 배정합니다. 조 수를 바꾼 뒤 균형배정을 누르면 다시 나눕니다.</p>
              </div>
              <div className="flex items-center gap-2">
                <div className="flex items-center gap-1 rounded-lg border border-border bg-surface-card px-2 py-1">
                  <span className="mr-1 text-sm text-ink-secondary">면접조 수</span>
                  <button
                    type="button"
                    onClick={() => changeTeamCount(teams.length - 1)}
                    disabled={teams.length <= MIN_TEAMS}
                    aria-label="면접조 줄이기"
                    className="h-7 w-7 rounded-md border border-border text-base font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30"
                  >
                    −
                  </button>
                  <span className="w-6 text-center text-sm font-semibold tabular-nums text-ink-primary">{teams.length}</span>
                  <button
                    type="button"
                    onClick={() => changeTeamCount(teams.length + 1)}
                    disabled={teams.length >= MAX_TEAMS}
                    aria-label="면접조 늘리기"
                    className="h-7 w-7 rounded-md border border-border text-base font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30"
                  >
                    +
                  </button>
                </div>
                <button type="button" onClick={autoBalance} className="rounded-lg border border-border px-3 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">
                  지원자 균형배정
                </button>
              </div>
            </div>
            <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {candidates.map((candidate) => (
                <div key={candidate.applicantId} className="flex items-center justify-between gap-2 rounded-lg border border-border bg-surface-card p-3">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-ink-primary">{candidate.displayName}</p>
                    <p className="text-xs text-ink-muted">{candidate.examNo || '-'} · 서류 {formatScore(candidate.documentScore)}</p>
                  </div>
                  <select
                    value={candidateTeamMap[candidate.applicantId] || ''}
                    onChange={(event) => assignCandidate(candidate.applicantId, event.target.value)}
                    className="rounded-lg border border-border text-sm"
                  >
                    <option value="">미배정</option>
                    {teams.map((team) => <option key={team.teamId} value={team.teamId}>{team.teamCode}조</option>)}
                  </select>
                </div>
              ))}
            </div>
            <StepFooter onNext={() => { save(); setCurrentStep(1) }} nextLabel="다음: 평가위원 배정 →" onSaveDraft={save} saving={saving} />
          </section>
        )}

        {/* ── Step 2: 평가위원 배정 ─────────────────────────────── */}
        {currentStep === 1 && (
          <section>
            <h2 className="mb-1 text-base font-semibold text-ink-primary">평가위원 배정</h2>
            <p className="mb-4 text-xs text-ink-muted">각 조에 평가위원 2명을 배정합니다. 두 위원은 같은 지원자를 독립적으로 채점합니다.</p>
            <div className="grid gap-4 xl:grid-cols-2">
              {teams.map((team) => (
                <article key={team.teamId} className="rounded-xl border border-border bg-surface-card p-4">
                  <h3 className="text-base font-semibold text-ink-primary">{team.teamCode}조</h3>
                  <div className="mt-3 grid gap-3 sm:grid-cols-2">
                    {[0, 1].map((slotIndex) => (
                      <label key={slotIndex} className="text-xs font-medium text-ink-secondary">
                        평가위원 {slotIndex + 1}
                        <select
                          value={team.memberUids[slotIndex] || ''}
                          onChange={(event) => setMember(team.teamId, slotIndex, event.target.value)}
                          className="mt-1 w-full rounded-lg border border-border text-sm"
                        >
                          <option value="">선택하세요</option>
                          {evaluators.map((evaluator) => {
                            const usedBy = usedEvaluatorMap[evaluator.uid]
                            const duplicatedInTeam = team.memberUids.some(
                              (memberUid, memberIndex) => memberIndex !== slotIndex && memberUid === evaluator.uid
                            )
                            const disabled = Boolean(duplicatedInTeam || (usedBy && usedBy !== team.teamId))
                            return (
                              <option key={evaluator.uid} value={evaluator.uid} disabled={disabled}>
                                {evaluator.displayName || evaluator.email}{disabled ? ' · 다른 조 배정' : ''}
                              </option>
                            )
                          })}
                        </select>
                      </label>
                    ))}
                  </div>
                  {team.memberUids.filter(Boolean).length < 2 && (
                    <p className="mt-2 text-xs text-status-danger">🔴 {team.teamCode}조 평가위원이 아직 다 배정되지 않았습니다.</p>
                  )}
                </article>
              ))}
            </div>
            <StepFooter onPrev={() => setCurrentStep(0)} onNext={() => { save(); setCurrentStep(2) }} nextLabel="다음: 시간표 생성 →" onSaveDraft={save} saving={saving} />
          </section>
        )}

        {/* ── Step 3: 시간표 생성 ───────────────────────────────── */}
        {currentStep === 2 && (
          <section>
            <h2 className="mb-1 text-base font-semibold text-ink-primary">시간표 생성</h2>
            <p className="mb-4 text-xs text-ink-muted">조별 면접 장소·시작 시각을 정하고 시간표를 생성합니다.</p>
            <div className="grid gap-4 xl:grid-cols-2">
              {teams.map((team) => {
                const teamCandidates = team.schedule.map((slot) => candidateMap[slot.applicantId]).filter(Boolean)
                const average = teamCandidates.length > 0
                  ? teamCandidates.reduce((sum, candidate) => sum + Number(candidate.documentScore || 0), 0) / teamCandidates.length
                  : null
                return (
                  <article key={team.teamId} className="rounded-xl border border-border bg-surface-card p-4">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <h3 className="text-base font-semibold text-ink-primary">{team.teamCode}조</h3>
                        <p className="mt-1 text-xs text-ink-muted">{teamCandidates.length}명 · 서류평균 {formatScore(average)}</p>
                      </div>
                      <button type="button" onClick={() => regenerateTeamSchedule(team.teamId)} className="rounded border border-border px-2 py-1 text-xs hover:bg-surface-subtle">시간표 재생성</button>
                    </div>
                    <div className="mt-3 grid gap-3 sm:grid-cols-2">
                      <label className="text-xs font-medium text-ink-secondary">
                        장소
                        <input value={team.location || ''} onChange={(event) => updateTeamField(team.teamId, 'location', event.target.value)} className="mt-1 w-full rounded-lg border border-border text-sm" />
                      </label>
                      <label className="text-xs font-medium text-ink-secondary">
                        시작 시각
                        <input type="datetime-local" value={team.startAt || ''} onChange={(event) => updateTeamField(team.teamId, 'startAt', event.target.value)} className="mt-1 w-full rounded-lg border border-border text-sm" />
                      </label>
                    </div>
                    <div className="mt-3 flex flex-wrap items-center gap-2 rounded-lg bg-surface-subtle px-3 py-2 text-xs text-ink-secondary">
                      <span className="font-medium">쉬는 시간</span>
                      <input
                        type="number"
                        min="1"
                        max="20"
                        value={team.breakEvery ?? DEFAULT_BREAK_EVERY}
                        onChange={(event) => updateTeamBreak(team.teamId, 'breakEvery', event.target.value)}
                        className="w-14 rounded-md border border-border px-2 py-1 text-sm"
                        aria-label="몇 명마다"
                      />
                      <span>명마다</span>
                      <input
                        type="number"
                        min="0"
                        max="120"
                        step="5"
                        value={team.breakMinutes ?? DEFAULT_BREAK_MINUTES}
                        onChange={(event) => updateTeamBreak(team.teamId, 'breakMinutes', event.target.value)}
                        className="w-16 rounded-md border border-border px-2 py-1 text-sm"
                        aria-label="쉬는 시간(분)"
                      />
                      <span>분 (학생+학부모 면접 1세트 = 1명, 0분이면 쉬는 시간 없음)</span>
                    </div>
                    {/* 2회차(오전·오후 2부제) — 점심 뒤 다시 시작하는 시각 */}
                    <div className="mt-2 flex flex-wrap items-center gap-2 rounded-lg bg-surface-subtle px-3 py-2 text-xs text-ink-secondary">
                      <span className="font-medium">2회차</span>
                      <input
                        type="number"
                        min="2"
                        max={Math.max(2, team.schedule.length)}
                        value={team.secondFromIndex ?? ''}
                        onChange={(event) => updateTeamSession(team.teamId, 'secondFromIndex', event.target.value)}
                        className="w-14 rounded-md border border-border px-2 py-1 text-sm"
                        aria-label="2회차 시작 순서"
                        placeholder="-"
                      />
                      <span>번째 지원자부터</span>
                      <input
                        type="time"
                        value={(team.secondStartAt || '').slice(11, 16)}
                        onChange={(event) => updateTeamSession(team.teamId, 'secondStartAt', event.target.value)}
                        className="rounded-md border border-border px-2 py-1 text-sm"
                        aria-label="2회차 시작 시각"
                      />
                      <span>에 다시 시작 (비우면 1회차로 이어서 진행)</span>
                    </div>
                    <p className="mt-4 text-[11px] text-ink-muted">
                      순서를 바꾸면 그 조의 시간이 자동으로 다시 계산됩니다. 시간은 직접 고칠 수도 있고,
                      &ldquo;시간표 재생성&rdquo;을 누르면 시작 시각 기준 자동값으로 되돌아갑니다.
                    </p>
                    <div className="mt-2 overflow-x-auto">
                      <table className="min-w-full text-left text-xs">
                        <thead className="border-b border-border text-ink-muted">
                          <tr>
                            <th className="px-2 py-2">순서</th>
                            <th className="px-2 py-2">지원자</th>
                            <th className="px-2 py-2">학생면접</th>
                            <th className="px-2 py-2">학부모면접</th>
                          </tr>
                        </thead>
                        <tbody>
                          {team.schedule.length === 0 && (
                            <tr><td colSpan="4" className="px-2 py-5 text-center text-ink-muted">배정된 지원자가 없습니다.</td></tr>
                          )}
                          {team.schedule.map((slot, slotIndex) => {
                            const candidate = candidateMap[slot.applicantId]
                            const nextSlot = team.schedule[slotIndex + 1]
                            const restMinutes = nextSlot ? minutesBetween(slot.parentEndsAt, nextSlot.studentStartsAt) : 0
                            return (
                              <Fragment key={slot.applicantId}>
                              <tr className="border-b border-border">
                                <td className="px-2 py-2 align-top">
                                  <div className="flex items-center gap-1">
                                    <span className="w-4 font-semibold text-ink-primary">{slotIndex + 1}</span>
                                    <div className="flex flex-col">
                                      <button
                                        type="button"
                                        disabled={readOnly || slotIndex === 0}
                                        onClick={() => moveSlot(team.teamId, slotIndex, -1)}
                                        className="rounded border border-border px-1 leading-none text-ink-secondary hover:bg-surface-subtle disabled:opacity-25"
                                        aria-label="위로"
                                      >
                                        ▲
                                      </button>
                                      <button
                                        type="button"
                                        disabled={readOnly || slotIndex === team.schedule.length - 1}
                                        onClick={() => moveSlot(team.teamId, slotIndex, 1)}
                                        className="mt-0.5 rounded border border-border px-1 leading-none text-ink-secondary hover:bg-surface-subtle disabled:opacity-25"
                                        aria-label="아래로"
                                      >
                                        ▼
                                      </button>
                                    </div>
                                  </div>
                                </td>
                                <td className="px-2 py-2 align-top">
                                  <p className="font-medium text-ink-primary">{candidate?.displayName || '지원자'}</p>
                                  <p className="text-ink-muted">{candidate?.examNo || '-'}</p>
                                </td>
                                <td className="px-2 py-2 align-top">
                                  <input
                                    type="datetime-local"
                                    value={slot.studentStartsAt || ''}
                                    disabled={readOnly}
                                    onChange={(event) => updateSlotTime(team.teamId, slot.applicantId, 'studentStartsAt', event.target.value)}
                                    className="w-full rounded border border-border px-1.5 py-1 text-[11px] disabled:bg-surface-subtle"
                                  />
                                  <input
                                    type="datetime-local"
                                    value={slot.studentEndsAt || ''}
                                    disabled={readOnly}
                                    onChange={(event) => updateSlotTime(team.teamId, slot.applicantId, 'studentEndsAt', event.target.value)}
                                    className="mt-1 w-full rounded border border-border px-1.5 py-1 text-[11px] disabled:bg-surface-subtle"
                                  />
                                </td>
                                <td className="px-2 py-2 align-top">
                                  <input
                                    type="datetime-local"
                                    value={slot.parentStartsAt || ''}
                                    disabled={readOnly}
                                    onChange={(event) => updateSlotTime(team.teamId, slot.applicantId, 'parentStartsAt', event.target.value)}
                                    className="w-full rounded border border-border px-1.5 py-1 text-[11px] disabled:bg-surface-subtle"
                                  />
                                  <input
                                    type="datetime-local"
                                    value={slot.parentEndsAt || ''}
                                    disabled={readOnly}
                                    onChange={(event) => updateSlotTime(team.teamId, slot.applicantId, 'parentEndsAt', event.target.value)}
                                    className="mt-1 w-full rounded border border-border px-1.5 py-1 text-[11px] disabled:bg-surface-subtle"
                                  />
                                </td>
                              </tr>
                              {restMinutes > 0 && (
                                <tr className="border-b border-border bg-brand-orangeSoft/40">
                                  <td colSpan="4" className="px-2 py-1.5 text-center text-[11px] font-medium text-brand-orangeStrong">
                                    {restMinutes >= SESSION_GAP_MINUTES ? '🍚 점심·회차 사이' : '☕ 쉬는 시간'} {slot.parentEndsAt.slice(11)}~{nextSlot.studentStartsAt.slice(11)} ({restMinutes}분)
                                  </td>
                                </tr>
                              )}
                              </Fragment>
                            )
                          })}
                        </tbody>
                      </table>
                    </div>
                  </article>
                )
              })}
            </div>
            <StepFooter onPrev={() => setCurrentStep(1)} onNext={() => { save(); setCurrentStep(3) }} nextLabel="다음: 검토·확정 →" onSaveDraft={save} saving={saving} />
          </section>
        )}

        {/* ── Step 4: 검토·확정 ─────────────────────────────────── */}
        {currentStep === 3 && (
          <section>
            <h2 className="mb-4 text-base font-semibold text-ink-primary">면접 준비 검토</h2>
            <div className="mb-5 rounded-lg border border-border bg-surface-card p-4">
              <ReviewRow label="지원자 전원 배정" ok={candidates.every((c) => candidateTeamMap[c.applicantId])} text={`${Object.keys(candidateTeamMap).length} / ${candidates.length}`} />
              <ReviewRow label="각 조 위원 정확히 2인" ok={teams.every((t) => t.memberUids.filter(Boolean).length === 2)} text={teams.every((t) => t.memberUids.filter(Boolean).length === 2) ? '완료' : '미완료'} />
              <ReviewRow label="시간표 생성 완료" ok={teams.every((t) => t.schedule.length === 0 || t.schedule.every((s) => s.studentStartsAt))} text="확인됨" last />
            </div>

            {validation?.complete ? (
              <p className="mb-4 rounded-md bg-brand-greenSoft px-4 py-3 text-sm font-medium text-brand-deepGreenStrong">면접을 시작할 준비가 되었습니다.</p>
            ) : (
              <div className="mb-4"><BlockingPanel issues={translatedBlockingIssues} /></div>
            )}

            <div className="flex justify-between">
              <button type="button" onClick={() => setCurrentStep(2)} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle">← 이전</button>
              <button
                type="button"
                onClick={() => setShowFinalize(true)}
                disabled={!validation?.complete || dirty || saving}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:cursor-not-allowed disabled:opacity-40"
              >
                면접조·시간표 확정
              </button>
            </div>
          </section>
        )}
      </div>

      <TypedConfirmDialog
        open={showFinalize}
        title="면접조 계획을 확정하시겠습니까?"
        description="확정 후 일반 수정은 차단되고 지원자의 면접조 배정이 평가 명단에 반영됩니다."
        fields={[
          { label: '면접조 수', value: `${teams.length}개` },
          { label: '확정자', value: userDoc?.display_name || '—' },
        ]}
        confirmPhrase={FINAL_CONFIRM_TEXT}
        confirmLabel="확정"
        onConfirm={finalize}
        onCancel={() => setShowFinalize(false)}
        submitting={saving}
        error={error}
      />

      <p className="mt-4 text-xs text-ink-muted">개별 면접위원의 실제 채점값은 이 관리자 편성 화면에 표시되지 않습니다.</p>
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
