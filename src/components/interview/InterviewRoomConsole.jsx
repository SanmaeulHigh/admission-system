// 면접실 진행 콘솔 — 지원자별 타이머 + 보호자 호출 (2026-10-14)
//
// 면접위원이 면접실에서 한 화면만 보고 진행할 수 있게 만든 카드다. 지금 차례인 지원자 한 명에 집중한다.
//
//   학생 호출 → ▶ 학생 면접 시작(25분 타이머) → (5분 남으면) 보호자 호출 → 학생 면접 종료
//   → ▶ 보호자 면접 시작(20분 타이머) → 보호자 면접 종료 → 다음 지원자로 자동 이동
//
// - 타이머 시작 시각은 서버(started_at, 00090)에 있어 같은 조 위원 2명의 화면이 같이 줄어든다.
//   기기 시계 차이는 대기열 응답의 serverNow 로 보정한다(clockOffsetMs).
// - 남은 시간 5분 이하는 주황(보호자 호출 권장), 0 이하는 빨강으로 초과 시간을 센다.
// - 문자는 모두 보호자 번호로 간다(00088). 호출 기록이 대기실 화면에 함께 뜬다.
// - compact: 채점 화면을 열었을 때 위쪽에 붙는 한 줄짜리 막대(타이머 + 핵심 버튼)

import { useEffect, useState } from 'react'

const DEFAULT_MINUTES = { student: 25, parent: 20 }
const WARN_SECONDS = 5 * 60
const SECTION_LABEL = { student: '학생 면접', parent: '보호자 면접' }

function minutesBetween(from, to) {
  if (!from || !to) return null
  const m = Math.round((new Date(to) - new Date(from)) / 60000)
  return m > 0 ? m : null
}

function fmtClock(value) {
  if (!value) return '-'
  return new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(value))
}

function fmtDuration(totalSeconds) {
  const s = Math.abs(Math.trunc(totalSeconds))
  const mm = String(Math.floor(s / 60)).padStart(2, '0')
  const ss = String(s % 60).padStart(2, '0')
  return `${mm}:${ss}`
}

// 지원자 한 명의 진행 단계
export function applicantPhase(item) {
  const st = item.student || {}
  const pa = item.parent || {}
  if (pa.completedAt) return 'done'
  if (pa.startedAt) return 'parent-running'
  if (st.completedAt) return pa.calledAt ? 'parent-called' : 'parent-wait'
  if (st.startedAt) return 'student-running'
  if (st.calledAt) return 'student-called'
  return 'student-wait'
}

function useNow(clockOffsetMs) {
  const [now, setNow] = useState(() => Date.now() + clockOffsetMs)
  useEffect(() => {
    setNow(Date.now() + clockOffsetMs)
    const id = setInterval(() => setNow(Date.now() + clockOffsetMs), 1000)
    return () => clearInterval(id)
  }, [clockOffsetMs])
  return now
}

function Timer({ state, section, now, size = 'lg' }) {
  const planned = minutesBetween(state.startsAt, state.endsAt) || DEFAULT_MINUTES[section]
  if (!state.startedAt) {
    return (
      <div className={size === 'lg' ? 'text-center' : ''}>
        <p className={`font-mono font-bold text-ink-muted ${size === 'lg' ? 'text-6xl' : 'text-2xl'}`}>{fmtDuration(planned * 60)}</p>
        {size === 'lg' && <p className="mt-1 text-xs text-ink-muted">{planned}분 · 시작 전</p>}
      </div>
    )
  }
  const elapsed = (now - new Date(state.startedAt).getTime()) / 1000
  const remaining = planned * 60 - elapsed
  const over = remaining < 0
  const warn = !over && remaining <= WARN_SECONDS
  const color = over ? 'text-status-danger' : warn ? 'text-brand-orangeStrong' : 'text-brand-deepGreenStrong'
  const barColor = over ? 'bg-status-danger' : warn ? 'bg-brand-orangeStrong' : 'bg-brand-deepGreen'
  const pct = Math.min(100, Math.max(0, (elapsed / (planned * 60)) * 100))

  if (size !== 'lg') {
    return <p className={`font-mono text-2xl font-bold tabular-nums ${color}`}>{over ? '+' : ''}{fmtDuration(remaining)}</p>
  }
  return (
    <div className="text-center" role="timer" aria-live="off">
      <p className={`font-mono text-7xl font-bold tabular-nums leading-none ${color}`}>
        {over ? '+' : ''}{fmtDuration(remaining)}
      </p>
      <p className={`mt-2 text-sm font-semibold ${color}`}>
        {over ? `${planned}분을 넘었습니다` : warn ? '5분 이내 · 마무리할 시간입니다' : `${planned}분 중 남은 시간`}
      </p>
      <div className="mx-auto mt-3 h-2 max-w-md overflow-hidden rounded-full bg-surface-subtle">
        <div className={`h-full ${barColor} transition-[width] duration-1000 ease-linear`} style={{ width: `${pct}%` }} />
      </div>
      <p className="mt-1 text-[11px] text-ink-muted">{fmtClock(state.startedAt)} 시작</p>
    </div>
  )
}

function BigButton({ tone = 'green', busy, onClick, children, disabled }) {
  const tones = {
    green: 'bg-brand-deepGreen text-white hover:bg-brand-deepGreenStrong',
    orange: 'bg-brand-orangeStrong text-white hover:opacity-90',
    outline: 'border-2 border-brand-deepGreen bg-white text-brand-deepGreenStrong hover:bg-brand-greenSoft',
    dark: 'bg-ink-primary text-white hover:opacity-90',
  }
  return (
    <button
      type="button"
      disabled={busy || disabled}
      onClick={onClick}
      className={`min-h-14 w-full rounded-xl px-4 py-3 text-base font-bold active:scale-[0.98] disabled:opacity-50 ${tones[tone]}`}
    >
      {busy ? '처리 중…' : children}
    </button>
  )
}

/**
 * props
 *  items: 대기열 지원자 목록(get_interview_call_queue.items)
 *  clockOffsetMs: 서버시각 - 기기시각
 *  busyKey: 처리 중 버튼 키
 *  actions: { call(applicantItem, section, callType), start(item, section), complete(item, section), cancel(item, section, callType), openScore(applicantId, section) }
 *  compact: 채점 화면이 열려 있을 때의 한 줄 모드
 */
export default function InterviewRoomConsole({ items, clockOffsetMs = 0, busyKey, actions, compact = false }) {
  const now = useNow(clockOffsetMs)
  const ordered = [...(items || [])].sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
  const currentIndex = ordered.findIndex((item) => applicantPhase(item) !== 'done')
  const current = currentIndex >= 0 ? ordered[currentIndex] : null
  const next = currentIndex >= 0 ? ordered[currentIndex + 1] || null : null

  if (!current) {
    return (
      <div className="m-4 rounded-xl border-2 border-dashed border-border p-6 text-center">
        <p className="text-base font-semibold text-ink-primary">이 조의 면접이 모두 끝났습니다.</p>
        <p className="mt-1 text-xs text-ink-muted">채점을 아직 제출하지 않은 지원자가 있는지 아래 목록에서 확인하세요.</p>
      </div>
    )
  }

  const phase = applicantPhase(current)
  const section = phase.startsWith('parent') ? 'parent' : 'student'
  const state = current[section] || {}
  const k = (sec, what) => `${current.applicantId}:${sec}:${what}`
  const parentCalled = Boolean(current.parent?.calledAt)

  // 학생 면접 중 남은 시간
  const studentRemaining = current.student?.startedAt
    ? (minutesBetween(current.student.startsAt, current.student.endsAt) || DEFAULT_MINUTES.student) * 60
      - (now - new Date(current.student.startedAt).getTime()) / 1000
    : null
  const suggestParentCall = phase === 'student-running' && !parentCalled && studentRemaining != null && studentRemaining <= WARN_SECONDS

  const parentCallButton = (
    <BigButton
      tone={suggestParentCall || phase === 'parent-wait' ? 'orange' : 'outline'}
      busy={busyKey === k('parent', 'now')}
      onClick={() => actions.call(current, 'parent', 'now')}
    >
      📣 보호자 호출
    </BigButton>
  )

  // ── 한 줄 모드(채점 화면 위) ──
  if (compact) {
    let primary = null
    if (phase === 'student-running') primary = !parentCalled ? (
      <button type="button" disabled={busyKey === k('parent', 'now')} onClick={() => actions.call(current, 'parent', 'now')} className={`rounded-lg px-3 py-2 text-sm font-bold text-white disabled:opacity-50 ${suggestParentCall ? 'bg-brand-orangeStrong' : 'bg-ink-secondary'}`}>보호자 호출</button>
    ) : <span className="text-xs font-semibold text-brand-deepGreenStrong">보호자 호출됨 {fmtClock(current.parent.calledAt)}</span>
    if (phase === 'student-called' || phase === 'parent-called') primary = (
      <button type="button" disabled={busyKey === k(section, 'start')} onClick={() => actions.start(current, section)} className="rounded-lg bg-brand-deepGreen px-3 py-2 text-sm font-bold text-white disabled:opacity-50">▶ 시작</button>
    )
    if (phase === 'parent-wait') primary = (
      <button type="button" disabled={busyKey === k('parent', 'now')} onClick={() => actions.call(current, 'parent', 'now')} className="rounded-lg bg-brand-orangeStrong px-3 py-2 text-sm font-bold text-white disabled:opacity-50">보호자 호출</button>
    )
    return (
      <div className="sticky top-0 z-20 flex items-center gap-3 rounded-xl border-2 border-brand-deepGreen bg-white px-3 py-2 shadow-sm">
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-bold text-ink-primary">{current.displayName} <span className="font-mono text-xs font-normal text-ink-muted">{current.examNo}</span></p>
          <p className="text-xs text-ink-secondary">{SECTION_LABEL[section]}</p>
        </div>
        <Timer state={state} section={section} now={now} size="sm" />
        {primary}
      </div>
    )
  }

  // ── 전체 콘솔 ──
  return (
    <div className="m-4 overflow-hidden rounded-2xl border-2 border-brand-deepGreen bg-white">
      {/* 지원자 */}
      <div className="flex flex-wrap items-start justify-between gap-2 border-b border-border px-4 py-3">
        <div>
          <p className="text-[11px] font-semibold text-ink-muted">{currentIndex + 1} / {ordered.length}번째 · 예정 {fmtClock(current.student?.startsAt)}</p>
          <p className="text-2xl font-bold text-ink-primary">
            {current.displayName}
            <span className="ml-2 font-mono text-base font-normal text-ink-muted">{current.examNo || '-'}</span>
          </p>
        </div>
        <button
          type="button"
          onClick={() => actions.openScore(current.applicantId, section)}
          className="rounded-lg border border-border px-3 py-2 text-sm font-semibold text-ink-secondary hover:bg-surface-subtle"
        >
          {SECTION_LABEL[section]} 채점 열기 →
        </button>
      </div>

      {/* 단계 표시 */}
      <div className="grid grid-cols-2 text-center text-xs font-semibold">
        {['student', 'parent'].map((sec) => {
          const active = sec === section
          const done = Boolean(current[sec]?.completedAt)
          return (
            <div key={sec} className={`py-2 ${active ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : done ? 'bg-surface-subtle text-ink-muted line-through' : 'text-ink-muted'}`}>
              {sec === 'student' ? '① ' : '② '}{SECTION_LABEL[sec]}{done ? ' ✓' : ''}
            </div>
          )
        })}
      </div>

      {/* 타이머 */}
      <div className="px-4 py-6">
        <Timer state={state} section={section} now={now} />
      </div>

      {/* 단계별 버튼 */}
      <div className="space-y-2 px-4 pb-4">
        {phase === 'student-wait' && (
          <>
            <BigButton busy={busyKey === k('student', 'now')} onClick={() => actions.call(current, 'student', 'now')}>
              학생 호출 · 보호자에게 문자
            </BigButton>
            <button type="button" onClick={() => actions.start(current, 'student')} className="w-full py-1 text-xs text-ink-muted underline">
              진행요원이 이미 데려왔으면 호출 없이 바로 시작
            </button>
          </>
        )}

        {phase === 'student-called' && (
          <>
            <BigButton busy={busyKey === k('student', 'start')} onClick={() => actions.start(current, 'student')}>▶ 학생 면접 시작</BigButton>
            <p className="text-center text-[11px] text-ink-muted">
              {fmtClock(current.student.calledAt)} 호출함 ·{' '}
              <button type="button" onClick={() => actions.cancel(current, 'student', 'now')} className="underline">호출 취소</button>
            </p>
          </>
        )}

        {phase === 'student-running' && (
          <div className="grid gap-2 sm:grid-cols-2">
            {parentCalled ? (
              <div className="flex min-h-14 items-center justify-center rounded-xl bg-brand-greenSoft px-3 text-sm font-semibold text-brand-deepGreenStrong">
                보호자 호출됨 {fmtClock(current.parent.calledAt)} ✓
              </div>
            ) : parentCallButton}
            <BigButton tone="dark" busy={busyKey === k('student', 'done')} onClick={() => actions.complete(current, 'student')}>
              학생 면접 종료
            </BigButton>
          </div>
        )}
        {suggestParentCall && (
          <p className="text-center text-xs font-semibold text-brand-orangeStrong">학생 면접이 5분 남았습니다. 보호자를 미리 불러 두세요.</p>
        )}

        {phase === 'parent-wait' && (
          <>
            {parentCallButton}
            <button type="button" onClick={() => actions.start(current, 'parent')} className="w-full py-1 text-xs text-ink-muted underline">
              보호자가 이미 와 있으면 호출 없이 바로 시작
            </button>
          </>
        )}

        {phase === 'parent-called' && (
          <>
            <BigButton busy={busyKey === k('parent', 'start')} onClick={() => actions.start(current, 'parent')}>▶ 보호자 면접 시작</BigButton>
            <p className="text-center text-[11px] text-ink-muted">
              {fmtClock(current.parent.calledAt)} 호출함 ·{' '}
              <button type="button" onClick={() => actions.cancel(current, 'parent', 'now')} className="underline">호출 취소</button>
            </p>
          </>
        )}

        {phase === 'parent-running' && (
          <BigButton tone="dark" busy={busyKey === k('parent', 'done')} onClick={() => actions.complete(current, 'parent')}>
            보호자 면접 종료 · 다음 지원자로
          </BigButton>
        )}
      </div>

      {/* 다음 지원자 */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border bg-surface-subtle px-4 py-3">
        {next ? (
          <>
            <p className="text-sm text-ink-secondary">
              다음 <span className="font-semibold text-ink-primary">{next.displayName}</span>
              <span className="ml-1 font-mono text-xs text-ink-muted">{next.examNo}</span>
              <span className="ml-2 text-xs text-ink-muted">예정 {fmtClock(next.student?.startsAt)}</span>
            </p>
            {next.student?.advanceCalledAt ? (
              <span className="text-xs font-semibold text-brand-orangeStrong">예고함 {fmtClock(next.student.advanceCalledAt)}</span>
            ) : (
              <button
                type="button"
                disabled={busyKey === `${next.applicantId}:student:advance`}
                onClick={() => actions.call(next, 'student', 'advance')}
                className="rounded-lg border border-brand-orange px-3 py-1.5 text-xs font-semibold text-brand-orangeStrong hover:bg-white disabled:opacity-50"
              >
                곧 순서 예고 · 문자
              </button>
            )}
          </>
        ) : (
          <p className="text-sm text-ink-muted">마지막 지원자입니다.</p>
        )}
      </div>
    </div>
  )
}
