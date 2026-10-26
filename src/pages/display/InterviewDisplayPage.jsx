// 면접 대기실 프로젝터 송출 화면 (2026-07-31)
//
// 본관 2층 대기실 프로젝터에 종일 띄워두는 화면. 로그인 없이 열린다
// (/display/interview) — 종일 송출이라 세션 만료로 화면이 멈추는 사고를
// 막기 위해서다. 대신 서버 RPC가 수험번호와 마스킹된 성명(홍*동)만 내려준다.
// 대기실에는 다른 지원자와 학부모가 함께 있으므로 실명·연락처·점수는 절대
// 표시하지 않는다.
//
// 화면 설계 기준은 "대기실 뒤쪽에서도 읽히는가"다. 그래서:
//  - 지금 호출된 사람을 화면 절반 가까이 차지하는 크기로 띄운다.
//  - 학생 면접인지 보호자 면접인지를 색과 큰 글씨로 구분한다
//    (학생과 보호자는 따로 내려오므로 이 구분이 가장 중요하다).
//  - 나머지(곧 순서 / 조별 현황)는 아래쪽에 작게 둔다.
//
// 2026-10-14: 주소에 표시 화면 열쇠(?key=…)가 있어야 명단이 나온다(00087). 교외(본관)에서는
// 이 RPC만 휴대폰 인증 관문을 건너뛰므로, 주소를 아는 아무나 명단을 보지 못하게 하기 위해서다.
// 열쇠는 면접 호출 화면의 '대기실 화면 열기' 링크에 자동으로 붙는다. 한 번 열면 이 브라우저에 기억한다.
//
// 갱신은 3초 폴링이다. 익명 클라이언트가 Realtime 구독을 받으려면 마스킹 전
// 원본 행에 접근 권한을 열어야 해서, 프로젝터에서 체감되지 않는 3초 지연을
// 택하고 개인정보 보호를 우선했다.

import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import schoolLogo from '../../assets/school-logo.png'

const POLL_INTERVAL_MS = 3000
const KEY_STORAGE = 'sanmaeul.displayKey.interview'

// 주소의 ?key= 를 우선 쓰고, 없으면 이 브라우저에 기억해 둔 열쇠를 쓴다.
function readDisplayKey() {
  const fromUrl = new URLSearchParams(window.location.search).get('key')
  try {
    if (fromUrl) {
      localStorage.setItem(KEY_STORAGE, fromUrl)
      return fromUrl
    }
    return localStorage.getItem(KEY_STORAGE)
  } catch {
    return fromUrl
  }
}

const SECTION_LABEL = { student: '학생 면접', parent: '보호자 면접' }

function formatClock(date) {
  return new Intl.DateTimeFormat('ko-KR', {
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).format(date)
}

function sectionStatus(state) {
  if (!state) return 'waiting'
  if (state.completedAt) return 'done'
  if (state.calledAt) return 'called'
  if (state.advanceCalledAt) return 'advance'
  return 'waiting'
}

/** 전 조의 모든 (지원자 × 면접구분) 순서를 평평하게 펼친다 */
function flattenSteps(board) {
  const steps = []
  for (const team of board?.teams || []) {
    for (const item of team.items || []) {
      for (const section of ['student', 'parent']) {
        steps.push({
          key: `${team.teamId}:${item.examNo}:${section}`,
          teamCode: team.teamCode,
          location: team.location,
          examNo: item.examNo,
          maskedName: item.maskedName,
          section,
          status: sectionStatus(item[section]),
        })
      }
    }
  }
  return steps
}

export default function InterviewDisplayPage() {
  const [board, setBoard] = useState(null)
  const [error, setError] = useState(null)
  const [clock, setClock] = useState(new Date())
  const timerRef = useRef(null)
  const [displayKey] = useState(readDisplayKey)

  const load = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('get_interview_display_board', { p_key: displayKey || null })
    if (err) {
      setError(err.message)
      return
    }
    setError(null)
    setBoard(data)
  }, [displayKey])

  useEffect(() => {
    load()
    timerRef.current = setInterval(load, POLL_INTERVAL_MS)
    return () => clearInterval(timerRef.current)
  }, [load])

  useEffect(() => {
    const tick = setInterval(() => setClock(new Date()), 1000)
    return () => clearInterval(tick)
  }, [])

  const steps = flattenSteps(board)
  const called = steps.filter((s) => s.status === 'called')
  const upcoming = steps.filter((s) => s.status === 'advance')

  // 진행 중인 전형 이름을 화면 제목으로 쓴다(예: 2027학년도 신입생 입학전형).
  // 아직 전형이 지정되지 않았을 때만 학교 이름으로 대체한다.
  const cycleTitle = board?.year
    ? `${board.year}학년도 신입생 입학전형`
    : '새봄고등학교 신입생 입학전형'
  // 본전형일 때는 회차를 굳이 적지 않는다(기본값이라 정보가 없음).
  // 추가모집일 때만 앞에 붙여 구분한다.
  const cycleSubtitle = board?.round && board.round !== 'main'
    ? `${roundToText(board.round)} · 심층역량평가 · 면접`
    : '심층역량평가 · 면접'

  return (
    <div className="relative flex min-h-screen flex-col overflow-hidden bg-[#0b1220] px-10 py-6 text-white">
      {/* 배경 워터마크 로고 — 어두운 프로젝터 화면이 너무 허전하지 않도록.
          pointer-events-none으로 어떤 상호작용도 가로채지 않는다. */}
      <img
        src={schoolLogo}
        alt=""
        aria-hidden="true"
        className="pointer-events-none absolute left-1/2 top-1/2 z-0 w-[46vw] max-w-[720px] -translate-x-1/2 -translate-y-1/2 select-none opacity-[0.055]"
      />
      {/* 은은한 상단 브랜드 글로우 */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 z-0 h-64 bg-gradient-to-b from-emerald-500/10 to-transparent"
      />

      {/* 헤더 */}
      <header className="relative z-10 flex items-center justify-between gap-6 border-b-2 border-white/10 pb-4">
        <div className="flex items-center gap-5">
          <img src={schoolLogo} alt="" aria-hidden="true" className="h-16 w-auto select-none opacity-90" />
          <div>
            <h1 className="text-4xl font-bold tracking-tight text-white">{cycleTitle}</h1>
            <p className="mt-1 text-xl font-medium text-emerald-300/70">{cycleSubtitle}</p>
          </div>
        </div>
        <p className="font-mono text-6xl font-bold tabular-nums tracking-tight text-white/85">
          {formatClock(clock)}
        </p>
      </header>

      {error && (
        <p className="relative z-10 mt-6 rounded-xl bg-rose-950/70 px-6 py-4 text-xl text-rose-200">
          연결이 일시적으로 끊겼습니다. 자동으로 다시 시도합니다.
        </p>
      )}

      {/* 준비 전 상태 */}
      {board && !board.ready && (
        <div className="relative z-10 flex flex-1 flex-col items-center justify-center">
          <p className="text-5xl font-bold text-white/75">잠시만 기다려 주세요</p>
          <p className="mt-6 text-2xl text-white/40">
            {board.reason === 'KEY_INVALID'
              ? '화면 주소가 올바르지 않습니다. 면접 호출 화면의 ‘대기실 화면 열기’로 다시 열어 주세요.'
              : board.reason === 'PLAN_NOT_FINALIZED'
                ? '면접 준비가 완료되면 이 화면에 순서가 표시됩니다.'
                : '진행 중인 전형이 지정되지 않았습니다.'}
          </p>
        </div>
      )}

      {board?.ready && (
        <main className="relative z-10 flex flex-1 flex-col gap-6 pt-6">
          {/* ── 지금 호출 (화면의 주인공) ── */}
          <section className="flex-1">
            {called.length === 0 ? (
              <div className="flex h-full min-h-[300px] items-center justify-center rounded-3xl border-2 border-dashed border-white/12">
                <p className="text-4xl font-semibold text-white/30">현재 호출된 순서가 없습니다</p>
              </div>
            ) : (
              <div
                className={`grid h-full gap-5 ${
                  called.length === 1 ? 'grid-cols-1' : called.length === 2 ? 'grid-cols-2' : 'grid-cols-3'
                }`}
              >
                {called.map((s) => {
                  const isStudent = s.section === 'student'
                  return (
                    <div
                      key={s.key}
                      className={`flex flex-col justify-center rounded-3xl border-4 px-10 py-8 ${
                        isStudent
                          ? 'border-emerald-400 bg-emerald-400/10'
                          : 'border-sky-400 bg-sky-400/10'
                      }`}
                    >
                      <p
                        className={`inline-flex w-fit rounded-full px-5 py-1.5 text-2xl font-bold ${
                          isStudent ? 'bg-emerald-400 text-emerald-950' : 'bg-sky-400 text-sky-950'
                        }`}
                      >
                        {SECTION_LABEL[s.section]}
                      </p>
                      <p
                        className={`mt-5 font-mono text-[7rem] font-black leading-none tabular-nums ${
                          isStudent ? 'text-emerald-300' : 'text-sky-300'
                        }`}
                      >
                        {s.examNo}
                      </p>
                      <p className="mt-3 text-6xl font-bold text-white/95">{s.maskedName}</p>
                      <p className="mt-5 text-3xl font-semibold text-white/60">
                        {s.teamCode}조{s.location ? ` · ${s.location}` : ''}
                      </p>
                      <p className={`mt-2 text-2xl ${isStudent ? 'text-emerald-200/80' : 'text-sky-200/80'}`}>
                        {isStudent ? '지원자 본인만 이동해 주세요' : '보호자님만 이동해 주세요'}
                      </p>
                    </div>
                  )
                })}
              </div>
            )}
          </section>

          {/* ── 곧 순서 ── */}
          <section>
            <h2 className="mb-2 text-xl font-bold tracking-wide text-amber-300/90">
              곧 순서입니다 — 대기실에서 준비해 주세요
            </h2>
            {upcoming.length === 0 ? (
              <p className="rounded-2xl border border-white/10 px-6 py-4 text-xl text-white/25">
                예고된 순서가 없습니다
              </p>
            ) : (
              <div className="flex flex-wrap gap-3">
                {upcoming.map((s) => (
                  <div
                    key={s.key}
                    className="flex items-center gap-4 rounded-2xl border-2 border-amber-400/60 bg-amber-400/10 px-6 py-3"
                  >
                    <span className="font-mono text-4xl font-bold tabular-nums text-amber-200">{s.examNo}</span>
                    <span className="text-3xl font-semibold text-white/90">{s.maskedName}</span>
                    <span className="rounded-full bg-amber-400/25 px-3 py-1 text-lg font-semibold text-amber-100">
                      {SECTION_LABEL[s.section]}
                    </span>
                    <span className="text-lg text-white/40">{s.teamCode}조</span>
                  </div>
                ))}
              </div>
            )}
          </section>

          {/* ── 조별 진행 현황 (작게) ── */}
          <section>
            <h2 className="mb-2 text-lg font-bold tracking-wide text-white/40">조별 진행 현황</h2>
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
              {(board.teams || []).map((team) => {
                const items = team.items || []
                const total = items.length * 2
                const done = items.reduce(
                  (n, i) => n + (i.student?.completedAt ? 1 : 0) + (i.parent?.completedAt ? 1 : 0),
                  0,
                )
                const pct = total > 0 ? Math.round((done / total) * 100) : 0
                return (
                  <div key={team.teamId} className="rounded-2xl border border-white/10 bg-white/5 px-5 py-4">
                    <div className="flex items-baseline justify-between">
                      <p className="text-2xl font-bold text-white/90">
                        {team.teamCode}조
                        {team.location && (
                          <span className="ml-2 text-base font-normal text-white/35">{team.location}</span>
                        )}
                      </p>
                      <p className="text-lg text-white/45">{done} / {total}</p>
                    </div>
                    <div className="mt-3 h-2.5 overflow-hidden rounded-full bg-white/10">
                      <div
                        className="h-full rounded-full bg-emerald-400/80 transition-[width] duration-500"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                  </div>
                )
              })}
            </div>
          </section>
        </main>
      )}

      <footer className="relative z-10 mt-6 border-t border-white/10 pt-4 text-center text-lg text-white/35">
        학생 면접과 보호자 면접은 따로 진행됩니다. 화면에 표시된 분만 면접실로 이동해 주세요.
      </footer>
    </div>
  )
}
