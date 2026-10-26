// 면접 실시간 호출 패널 (2026-07-31)
//
// 면접위원 채점 화면 상단에 붙는다. 실제 면접 진행 순서를 그대로 따라간다:
//
//   1번 지원자 학생면접 → 1번 보호자면접 → 2번 지원자 학생면접 → 2번 보호자면접 → …
//
// 즉 대기열의 단위는 "지원자"가 아니라 (지원자, 면접구분)이다. 지원자와
// 보호자는 함께 내려오지 않는다 — 학생 면접이 끝나야 보호자를 부른다.
// 그래서 이 패널은 지원자 목록이 아니라 "순서 목록(steps)"을 만들어 다룬다.
//
// 문자는 학생·보호자 면접 모두 보호자 번호로 간다(2026-10-14, 당일 지원자 휴대전화 수거).
// 보호자 번호가 없으면 서버가 지원자 번호로 대신 보내고 화면에 알려 준다.
// 호출 기록과 문자 발송은 분리되어 있어서, 문자가 실패해도 대기실 화면에는
// 정상적으로 호출이 표시된다.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useInterviewDisplayKey } from '../../lib/interviewDisplayKey'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import InterviewRoomConsole from './InterviewRoomConsole'

const POLL_INTERVAL_MS = 5000

const SECTION_LABEL = { student: '학생 면접', parent: '보호자 면접' }
const SECTION_SHORT = { student: '학생', parent: '보호자' }

function stepStatus(state) {
  if (!state) return 'waiting'
  if (state.completedAt) return 'done'
  if (state.calledAt || state.startedAt) return 'called'
  if (state.advanceCalledAt) return 'advance'
  return 'waiting'
}

function formatTime(value) {
  if (!value) return '-'
  return new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
    .format(new Date(value))
}

// compact: 채점 화면을 연 동안 위에 붙는 한 줄 타이머 막대만 보인다.
// onOpenScore(applicantId, section): 콘솔의 '채점 열기' 버튼
export default function InterviewCallPanel({ compact = false, onOpenScore }) {
  const { url: displayUrl } = useInterviewDisplayKey()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [queue, setQueue] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [busyKey, setBusyKey] = useState(null)
  const [showAll, setShowAll] = useState(false)
  const [clockOffsetMs, setClockOffsetMs] = useState(0) // 서버시각 - 기기시각(타이머 보정)
  const timerRef = useRef(null)

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    const { data, error: err } = await supabase.rpc('get_interview_call_queue', {
      p_year: YEAR,
      p_round: ROUND,
      p_team_id: null,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setError(null)
    setQueue(data)
    if (data?.serverNow) setClockOffsetMs(new Date(data.serverNow).getTime() - Date.now())
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
    timerRef.current = setInterval(load, POLL_INTERVAL_MS)
    return () => clearInterval(timerRef.current)
  }, [load])

  const team = queue?.team || null

  // 지원자 목록을 실제 진행 순서(학생 → 보호자 → 다음 지원자…)로 펼친다.
  const steps = useMemo(() => {
    const out = []
    for (const item of queue?.items || []) {
      for (const section of ['student', 'parent']) {
        const state = item[section] || {}
        out.push({
          key: `${item.applicantId}:${section}`,
          applicantId: item.applicantId,
          examNo: item.examNo,
          displayName: item.displayName,
          sortOrder: item.sortOrder,
          section,
          startsAt: state.startsAt,
          state,
          status: stepStatus(state),
        })
      }
    }
    return out
  }, [queue])

  const doneCount = steps.filter((s) => s.status === 'done').length

  const sendCallSms = async (step, callType) => {
    const { data, error: err } = await supabase.functions.invoke('send-interview-call-sms', {
      body: {
        year: YEAR,
        round: ROUND,
        applicantId: step.applicantId,
        section: step.section,
        callType,
      },
    })
    if (err) return { ok: false, message: err.message }
    const failed = Object.entries(data?.results || {})
      .filter(([, r]) => !r?.sent)
      .map(([, r]) => r?.providerMessage || r?.reason || '발송 실패')
    if (failed.length > 0) return { ok: false, message: `문자 미발송(${failed.join(', ')})` }
    const fellBack = Object.values(data?.results || {}).some((r) => r?.fallbackReason)
    return { ok: true, fellBack }
  }

  const doCall = async (step, callType) => {
    setBusyKey(`${step.key}:${callType}`)
    setError(null)
    setNotice(null)

    const { error: callErr } = await supabase.rpc('call_interview_applicant', {
      p_year: YEAR,
      p_round: ROUND,
      p_applicant_id: step.applicantId,
      p_section: step.section,
      p_call_type: callType,
    })
    if (callErr) {
      setBusyKey(null)
      setError(callErr.message)
      return
    }

    await load()
    const sms = await sendCallSms(step, callType)
    setBusyKey(null)
    await load()

    const what = `${step.displayName} ${SECTION_LABEL[step.section]}`
    const action = callType === 'advance' ? '예고' : '호출'
    setNotice(
      sms.ok
        ? `${what} ${action} 완료 · 보호자에게 문자 발송됨${sms.fellBack ? ' (보호자 번호가 없어 지원자 번호로 보냄)' : ''}`
        : `${what} ${action}은 대기실 화면에 표시되었습니다. 다만 ${sms.message}`,
    )
  }

  const doComplete = async (step) => {
    setBusyKey(`${step.key}:done`)
    setError(null)
    const { error: err } = await supabase.rpc('complete_interview_applicant', {
      p_year: YEAR,
      p_round: ROUND,
      p_applicant_id: step.applicantId,
      p_section: step.section,
    })
    setBusyKey(null)
    if (err) {
      setError(err.message)
      return
    }
    setNotice(`${step.displayName} ${SECTION_LABEL[step.section]} 완료`)
    await load()
  }

  const doCancel = async (step, callType) => {
    setBusyKey(`${step.key}:cancel`)
    setError(null)
    const { error: err } = await supabase.rpc('cancel_interview_call', {
      p_year: YEAR,
      p_round: ROUND,
      p_applicant_id: step.applicantId,
      p_section: step.section,
      p_call_type: callType,
    })
    setBusyKey(null)
    if (err) {
      setError(err.message)
      return
    }
    setNotice('호출을 취소했습니다. (이미 보낸 문자는 회수되지 않습니다)')
    await load()
  }

  const doStart = async (step) => {
    setBusyKey(`${step.key}:start`)
    setError(null)
    const { error: err } = await supabase.rpc('start_interview_section', {
      p_year: YEAR,
      p_round: ROUND,
      p_applicant_id: step.applicantId,
      p_section: step.section,
    })
    setBusyKey(null)
    if (err) {
      setError(err.message)
      return
    }
    setNotice(`${step.displayName} ${SECTION_LABEL[step.section]} 시작`)
    await load()
  }

  // 콘솔은 지원자 단위(item)로 부르므로 기존 단계(step) 모양으로 바꿔 넘긴다.
  const toStep = (item, section) => ({
    key: `${item.applicantId}:${section}`,
    applicantId: item.applicantId,
    displayName: item.displayName,
    examNo: item.examNo,
    section,
  })
  const consoleActions = {
    call: (item, section, callType) => doCall(toStep(item, section), callType),
    start: (item, section) => doStart(toStep(item, section)),
    complete: (item, section) => doComplete(toStep(item, section)),
    cancel: (item, section, callType) => doCancel(toStep(item, section), callType),
    openScore: (applicantId, section) => onOpenScore?.(applicantId, section),
  }

  if (loading) {
    return <div className="rounded-xl border bg-white p-4 text-sm text-ink-muted">면접 대기열을 불러오는 중…</div>
  }

  if (!team) return null // 배정된 면접조가 없으면 패널을 숨긴다

  if (compact) {
    return (
      <div className="space-y-1">
        {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
        <InterviewRoomConsole items={queue?.items || []} clockOffsetMs={clockOffsetMs} busyKey={busyKey} actions={consoleActions} compact />
      </div>
    )
  }

  return (
    <section className="overflow-hidden rounded-xl border-2 border-brand-deepGreen bg-white">
      <div className="flex flex-wrap items-center justify-between gap-3 bg-brand-greenSoft px-4 py-3">
        <div>
          <h2 className="text-sm font-bold text-brand-deepGreenStrong">
            면접 호출 · {team.teamCode}조{team.location ? ` (${team.location})` : ''}
          </h2>
          <p className="mt-0.5 text-xs text-ink-secondary">
            학생 면접 → 보호자 면접 순서로 진행됩니다 · {doneCount}/{steps.length} 완료
          </p>
        </div>
        <a
          href={displayUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-brand-deepGreenStrong hover:bg-white"
        >
          대기실 화면 열기 ↗
        </a>
      </div>

      {error && <p className="mx-4 mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
      {notice && <p className="mx-4 mt-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">{notice}</p>}

      {/* 면접실 진행 콘솔: 지금 차례 지원자 1명 + 타이머 + 보호자 호출 (2026-10-14) */}
      <InterviewRoomConsole items={queue?.items || []} clockOffsetMs={clockOffsetMs} busyKey={busyKey} actions={consoleActions} />

      {/* 전체 순서 */}
      <div className="border-t border-border px-4 pb-4 pt-3">
        <button
          type="button"
          onClick={() => setShowAll((v) => !v)}
          className="text-xs font-semibold text-ink-secondary underline"
        >
          전체 순서 {showAll ? '접기' : `펼치기 (${steps.length}개)`}
        </button>

        {showAll && (
          <ul className="mt-3 space-y-1">
            {steps.map((step) => (
              <li
                key={step.key}
                className={`flex flex-wrap items-center justify-between gap-2 rounded-lg border px-3 py-2 ${
                  step.status === 'called'
                    ? 'border-brand-deepGreen bg-brand-greenSoft'
                    : step.status === 'advance'
                      ? 'border-brand-orange bg-brand-orangeSoft'
                      : step.status === 'done'
                        ? 'border-border bg-surface-subtle'
                        : 'border-border bg-white'
                }`}
              >
                <div className="min-w-0">
                  <p className={`text-sm ${step.status === 'done' ? 'text-ink-muted line-through' : 'text-ink-primary'}`}>
                    <span className="font-semibold">{step.displayName}</span>
                    <span className="ml-1.5 font-mono text-xs text-ink-muted">{step.examNo || '-'}</span>
                    <span className="ml-2 text-xs font-semibold">{SECTION_LABEL[step.section]}</span>
                  </p>
                  <p className="text-[11px] text-ink-muted">
                    예정 {formatTime(step.startsAt)}
                    {step.state.calledAt && ` · 호출 ${formatTime(step.state.calledAt)}`}
                    {step.state.completedAt && ` · 완료 ${formatTime(step.state.completedAt)}`}
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-1.5">
                  {step.status === 'done' && (
                    <span className="rounded-full bg-surface-subtle px-2.5 py-1 text-[11px] font-semibold text-ink-muted">완료</span>
                  )}
                  {step.status === 'called' && (
                    <button
                      type="button"
                      disabled={busyKey === `${step.key}:done`}
                      onClick={() => doComplete(step)}
                      className="rounded-md border border-brand-deepGreen px-2.5 py-1 text-[11px] font-semibold text-brand-deepGreenStrong hover:bg-white disabled:opacity-50"
                    >
                      완료
                    </button>
                  )}
                  {(step.status === 'waiting' || step.status === 'advance') && (
                    <>
                      {step.status === 'waiting' && (
                        <button
                          type="button"
                          disabled={busyKey === `${step.key}:advance`}
                          onClick={() => doCall(step, 'advance')}
                          className="rounded-md border border-brand-orange px-2.5 py-1 text-[11px] font-semibold text-brand-orangeStrong hover:bg-white disabled:opacity-50"
                        >
                          예고
                        </button>
                      )}
                      <button
                        type="button"
                        disabled={busyKey === `${step.key}:now`}
                        onClick={() => doCall(step, 'now')}
                        className="rounded-md bg-brand-deepGreen px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
                      >
                        호출
                      </button>
                    </>
                  )}
                </div>
              </li>
            ))}
            {steps.length === 0 && (
              <li className="rounded-lg border border-dashed border-border px-3 py-4 text-center text-xs text-ink-muted">
                배정된 지원자가 없습니다.
              </li>
            )}
          </ul>
        )}
      </div>
    </section>
  )
}
