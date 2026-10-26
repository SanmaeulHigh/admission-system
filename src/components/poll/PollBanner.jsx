// 교직원 투표 안내 띠 + 투표 창 (2026-10-26, 00104)
// 아직 투표하지 않았으면 머리글 아래에 띠를 띄운다. 투표하면 띠는 '결과 보기'로 작아진다.
// 결과는 투표한 사람·최고관리자에게만(서버에서 거른다). 누가 무엇을 골랐는지는 보이지 않는다.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'

// 띠 닫기(2026-10-26): 투표 전이면 '오늘 하루' 닫고, 투표했거나 마감됐으면 이 투표가 끝날 때까지 닫는다(이 PC 기억).
const HIDE_KEY = (id) => `sanmaeul.pollHide.${id}`
function todayKey() {
  const d = new Date()
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`
}
function isHidden(poll) {
  try {
    const v = localStorage.getItem(HIDE_KEY(poll.id))
    if (!v) return false
    if (v === 'done') return Boolean(poll.myChoice) || poll.closed
    return v === todayKey()
  } catch { return false }
}

// 선택지 로고 시안(2026-10-26, ChatGPT 시안) — public/poll/<key 소문자>.png 가 있으면 보여 준다
const OPTION_IMAGES = {} // 예: { A: '/poll/a.png' } — public/poll/ 에 그림을 넣고 선택지 key 와 이어 준다

function fmtClose(v) {
  const d = new Date(v)
  const wd = ['일', '월', '화', '수', '목', '금', '토'][d.getDay()]
  return `${d.getMonth() + 1}. ${d.getDate()}.(${wd}) ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

export default function PollBanner() {
  const [poll, setPoll] = useState(null)
  const [open, setOpen] = useState(false)
  const [choice, setChoice] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [hidden, setHidden] = useState(false)

  const load = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('get_active_poll')
    if (err) return // 함수가 아직 없으면(배포 전) 조용히 넘어간다
    setPoll(data || null)
    setChoice(data?.myChoice || null)
    if (data) setHidden(isHidden(data))
  }, [])

  useEffect(() => { load() }, [load])

  if (!poll) return null
  const voted = Boolean(poll.myChoice)

  const hideBar = () => {
    try { localStorage.setItem(HIDE_KEY(poll.id), voted || poll.closed ? 'done' : todayKey()) } catch { /* 기억만 못 함 */ }
    setHidden(true)
  }
  const closeBtn = (
    <button type="button" onClick={hideBar} aria-label="투표 안내 닫기"
      title={voted || poll.closed ? '이 안내 닫기' : '오늘 하루 닫기'}
      className="ml-1 rounded px-1.5 text-base leading-none text-ink-muted hover:bg-black/5 hover:text-ink-primary">×</button>
  )

  async function vote() {
    if (!choice) return
    setBusy(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('cast_poll_vote', { p_poll_id: poll.id, p_choice: choice })
    setBusy(false)
    if (err) { setError(err.message); return }
    setPoll(data)
  }

  const total = poll.results ? Object.values(poll.results).reduce((a, b) => a + b, 0) : 0

  return (
    <>
      {hidden ? null : !poll.closed && !voted ? (
        <div className="flex shrink-0 flex-wrap items-center justify-center gap-3 border-b border-brand-deepGreen/30 bg-brand-greenSoft px-4 py-2 text-sm print:hidden">
          <span className="font-semibold text-brand-deepGreenStrong">{poll.title}</span>
          <span className="text-ink-secondary">마감 {fmtClose(poll.closesAt)} · {poll.voters}명 참여</span>
          <button type="button" onClick={() => setOpen(true)} className="rounded-md bg-brand-deepGreen px-3 py-1 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong">투표하기</button>
          <span className="text-xs text-ink-muted">오늘 하루 닫기</span>{closeBtn}
        </div>
      ) : (
        <div className="flex shrink-0 items-center justify-end gap-2 border-b border-border bg-surface-card px-4 py-1 text-xs text-ink-secondary print:hidden">
          <span>{poll.closed ? '투표 마감' : '투표 완료'} · {poll.title}</span>
          <button type="button" onClick={() => setOpen(true)} className="underline hover:text-ink-primary">{poll.closed ? '결과 보기' : '결과 보기·다시 고르기'}</button>
          {closeBtn}
        </div>
      )}

      {open && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-labelledby="poll-title" onClick={() => setOpen(false)}>
          <div className="max-h-[92vh] w-full max-w-xl overflow-y-auto rounded-xl bg-surface-card p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <h2 id="poll-title" className="text-lg font-bold text-ink-primary">{poll.title}</h2>
            {poll.description && <p className="mt-1 text-sm text-ink-secondary">{poll.description}</p>}
            <p className="mt-1 text-xs text-ink-muted">마감 {fmtClose(poll.closesAt)} · 한 사람 한 표 · 누가 무엇을 골랐는지는 공개되지 않습니다</p>

            <div className="mt-4 space-y-2" role="radiogroup" aria-label="선택지">
              {poll.options.map((o) => {
                const n = poll.results?.[o.key] || 0
                const pct = total ? Math.round((n / total) * 100) : 0
                const on = choice === o.key
                return (
                  <label key={o.key}
                    className={`relative block cursor-pointer overflow-hidden rounded-lg border-2 px-4 py-3 ${on ? 'border-brand-deepGreen' : 'border-border'} ${poll.closed ? 'cursor-default' : ''}`}>
                    {poll.results && <span className="absolute inset-y-0 left-0 bg-brand-greenSoft" style={{ width: `${pct}%` }} aria-hidden="true" />}
                    <span className="relative flex items-start gap-3">
                      <input type="radio" name="poll" value={o.key} checked={on} disabled={poll.closed} onChange={() => setChoice(o.key)} className="mt-1" />
                      <span className="min-w-0 flex-1">
                        {OPTION_IMAGES[o.key] && (
                          <img src={OPTION_IMAGES[o.key]} alt={`${o.key} 로고 시안`} loading="lazy"
                            className="mb-2 h-16 w-auto max-w-full rounded bg-white object-contain p-1" />
                        )}
                        <span className="block font-bold text-ink-primary">{o.label}</span>
                        <span className="block text-xs text-ink-secondary">{o.desc}</span>
                      </span>
                      {poll.results && <span className="shrink-0 text-sm font-semibold tabular-nums text-ink-primary">{n}표 · {pct}%</span>}
                    </span>
                  </label>
                )
              })}
            </div>

            <p className="mt-3 text-xs text-ink-muted">
              참여 {poll.voters} / {poll.eligible}명{!poll.results && ' · 결과는 투표한 뒤에 보입니다'}
            </p>
            {error && <p className="mt-2 text-sm text-status-danger">{error}</p>}

            <div className="mt-5 flex justify-end gap-2">
              <button type="button" onClick={() => setOpen(false)} className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary">닫기</button>
              {!poll.closed && (
                <button type="button" onClick={vote} disabled={!choice || busy || choice === poll.myChoice}
                  className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
                  {busy ? '저장 중…' : voted ? '다시 고르기' : '투표하기'}
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  )
}
