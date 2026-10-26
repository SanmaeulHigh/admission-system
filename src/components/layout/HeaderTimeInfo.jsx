// 머리글 날짜·일정·서버 시각 (2026-10-19) — PC(폭 1280px 이상)에서만 보인다.
//  - HeaderToday: 오늘 날짜 + 다가오는 전형 일정 D-day(1280px 이상 1개, 1536px 이상 2개, 마우스를 올리면 전체 일정)
//  - HeaderServerClock: 서버 시각(기기 시계가 틀려도 서버 기준). 기기와 5초 넘게 차이 나면 표시
// 일정은 요강 일정(config/printNotices.js)에서 가져오고, '오늘'도 서버 시각 기준으로 센다.

import { useMemo } from 'react'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { ADMISSION_MODES, useAdmissionMode } from '../../lib/admissionMode'
import { getScheduleForDashboard, daysUntil, formatMonthDay } from '../../config/printNotices'
import { useServerClock } from '../../lib/serverClock'

const WEEKDAY = ['일', '월', '화', '수', '목', '금', '토']

// 진행 중이면 '마감까지', 앞으로면 '시작까지'
export function milestones(schedule, today) {
  if (!schedule) return []
  const out = []
  for (const row of schedule) {
    const toEnd = daysUntil(row.end, today)
    if (toEnd < 0) continue
    const toStart = daysUntil(row.start, today)
    const ongoing = toStart <= 0
    const days = ongoing ? toEnd : toStart
    out.push({
      key: row.label,
      label: ongoing && toEnd > 0 ? `${row.label} 마감` : row.label,
      dday: days === 0 ? (ongoing ? '오늘' : 'D-day') : `D-${days}`,
      date: formatMonthDay(ongoing ? row.end : row.start),
      ongoing,
      urgent: days <= 3,
    })
  }
  return out
}

export function HeaderToday() {
  const { year, round } = useAdmissionCycle()
  const mode = useAdmissionMode()
  const { now } = useServerClock()
  const dayKey = `${now.getFullYear()}-${now.getMonth()}-${now.getDate()}`
  const list = useMemo(
    () => (mode === ADMISSION_MODES.NEW ? milestones(getScheduleForDashboard(year, round), now) : []),
    // 날짜가 바뀔 때만 다시 계산
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [year, round, mode, dayKey],
  )

  return (
    <div className="group relative hidden items-center gap-2 xl:flex">
      <span className="whitespace-nowrap text-sm font-semibold text-ink-primary">
        {now.getFullYear()}년 {now.getMonth() + 1}월 {now.getDate()}일({WEEKDAY[now.getDay()]})
      </span>
      {list.slice(0, 2).map((m, i) => (
        <span
          key={m.key}
          className={`${i > 0 ? 'hidden 2xl:inline' : ''} whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ${
            m.urgent ? 'bg-status-dangerSoft text-status-danger' : m.ongoing ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-surface-subtle text-ink-secondary'
          }`}
        >
          {m.label} <strong>{m.dday}</strong>
        </span>
      ))}
      {list.length > 0 && (
        <div className="invisible absolute left-0 top-full z-40 mt-2 w-[22rem] rounded-xl border border-border bg-surface-card p-3 opacity-0 shadow-lg transition-opacity group-hover:visible group-hover:opacity-100">
          <p className="mb-2 px-1 text-sm font-semibold text-ink-primary">{year}학년도 전형 일정</p>
          <ScheduleList list={list} />
        </div>
      )}
    </div>
  )
}

// 일정 목록(마우스를 올리면 나오는 상자)
export function ScheduleList({ list }) {
  return (
      <ul className="divide-y divide-border">
        {list.map((m) => (
          <li key={m.key} className="flex items-center gap-3 px-1 py-2">
            {/* 남은 날: 둥근 배지(3일 이내 빨강 · 진행 중 초록 · 그 밖 회색) */}
            <span
              className={`inline-flex h-7 w-14 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
                m.urgent ? 'bg-status-danger text-white' : m.ongoing ? 'bg-brand-deepGreen text-white' : 'bg-surface-subtle text-ink-primary'
              }`}
            >
              {m.dday}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium text-ink-primary">{m.label}</span>
              {m.ongoing && <span className="block text-[11px] text-brand-deepGreenStrong">진행 중</span>}
            </span>
            <span className="shrink-0 text-sm tabular-nums text-ink-secondary">{m.date}</span>
          </li>
        ))}
      </ul>
  )
}

export function HeaderServerClock() {
  const { now, synced, offsetMs } = useServerClock()
  const pad = (n) => String(n).padStart(2, '0')
  const drift = Math.round(offsetMs / 1000)
  return (
    <div
      className="hidden items-center gap-1.5 whitespace-nowrap xl:flex"
      title={synced ? `서버 시각 기준${Math.abs(drift) >= 5 ? ` · 이 PC 시계와 ${Math.abs(drift)}초 차이` : ''}` : '서버 시각을 맞추는 중'}
    >
      <span className={`h-1.5 w-1.5 rounded-full ${synced ? 'bg-brand-deepGreen' : 'bg-ink-muted'}`} aria-hidden="true" />
      <span className="text-xs text-ink-muted">서버</span>
      <span className="font-mono text-sm font-semibold tabular-nums text-ink-primary">
        {pad(now.getHours())}:{pad(now.getMinutes())}:{pad(now.getSeconds())}
      </span>
      {synced && Math.abs(drift) >= 5 && (
        <span className="rounded bg-status-warningSoft px-1 text-[10px] font-semibold text-status-warning">PC 시계 {drift > 0 ? '늦음' : '빠름'}</span>
      )}
    </div>
  )
}
