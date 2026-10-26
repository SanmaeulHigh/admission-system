// 온라인 서류작성기 이용 현황 카드(관리자 대시보드).
// 숫자는 학교 서버가 아니라 이 화면을 연 브라우저가 구글 Apps Script에서 직접 받아 온다.
// 받아 오지 못해도 대시보드의 다른 부분에는 영향이 없다.

import { useCallback, useEffect, useState } from 'react'
import Icon from '../ui/Icon'
import { FORM_TRACKING } from '../../config/formTracking'

const TRACKS = ['일반', '인천추천', '사회통합']
const TRACK_TEXT = { 일반: '일반전형만', 인천추천: '인천학생추천', 사회통합: '사회통합' }
const DAYS_SHOWN = 14

function formatTime(iso) {
  if (!iso) return ''
  return new Intl.DateTimeFormat('ko-KR', {
    month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(iso))
}

function Metric({ label, value, strong, note }) {
  return (
    <div className={`rounded-xl px-4 py-3 ${strong ? 'bg-brand-deepGreen text-white' : 'bg-surface-subtle'}`}>
      <p className={`text-xs font-medium ${strong ? 'text-white/85' : 'text-ink-muted'}`}>{label}</p>
      <p className={`mt-0.5 text-2xl font-bold tabular-nums ${strong ? 'text-white' : 'text-ink-primary'}`}>
        {value}
        <span className={`ml-0.5 text-sm font-semibold ${strong ? 'text-white/85' : 'text-ink-muted'}`}>명</span>
      </p>
      {note && <p className={`mt-0.5 text-xs ${strong ? 'text-white/85' : 'text-ink-muted'}`}>{note}</p>}
    </div>
  )
}

function DailyBars({ daily }) {
  const rows = daily.slice(-DAYS_SHOWN)
  if (rows.length === 0) return <p className="py-2 text-sm text-ink-muted">아직 기록이 없습니다.</p>
  const max = Math.max(1, ...rows.map((r) => r.saved))
  return (
    <div>
      <div className="flex h-24 items-end gap-1" role="img" aria-label="최근 날짜별 인쇄·저장 인원">
        {rows.map((r) => (
          <div key={r.date} className="flex flex-1 flex-col items-center justify-end gap-1" title={`${r.date} · 인쇄·저장 ${r.saved}명 · 연 사람 ${r.open}명`}>
            <span className="text-[10px] tabular-nums text-ink-muted">{r.saved || ''}</span>
            <div
              className="w-full rounded-t bg-brand-deepGreen"
              style={{ height: `${Math.max(r.saved ? 6 : 2, (r.saved / max) * 64)}px`, opacity: r.saved ? 1 : 0.25 }}
            />
          </div>
        ))}
      </div>
      <div className="mt-1 flex gap-1">
        {rows.map((r) => (
          <span key={r.date} className="flex-1 text-center text-[10px] tabular-nums text-ink-muted">
            {Number(r.date.slice(8))}
          </span>
        ))}
      </div>
    </div>
  )
}

export default function FormToolUsageCard({ receivedCount }) {
  const [state, setState] = useState({ status: 'loading', data: null })

  const load = useCallback(async () => {
    const { summaryUrl, key } = FORM_TRACKING
    if (!summaryUrl || !key) {
      setState({ status: 'off', data: null })
      return
    }
    setState((s) => ({ status: 'loading', data: s.data }))
    try {
      const res = await fetch(`${summaryUrl}?mode=summary&key=${encodeURIComponent(key)}`, { cache: 'no-store' })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || 'error')
      setState({ status: 'ok', data: json })
    } catch {
      setState((s) => ({ status: 'error', data: s.data }))
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  if (state.status === 'off') return null
  const d = state.data
  const t = d?.totals

  return (
    <section className="rounded-2xl border border-border bg-surface-card p-5" aria-labelledby="formtool-title">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 id="formtool-title" className="text-base font-semibold text-ink-primary">온라인 서류작성기 이용</h2>
          <p className="text-xs text-ink-muted">
            {d ? `마지막 기록 ${formatTime(d.lastEventAt) || '없음'} · 집계 ${formatTime(d.generatedAt)}` : '구글 시트에서 불러옵니다'}
          </p>
        </div>
        <div className="flex items-center gap-3">
          {FORM_TRACKING.sheetUrl && (
            <a
              href={FORM_TRACKING.sheetUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1 text-xs font-semibold text-brand-blue hover:underline"
            >
              시트 열기 <Icon name="externalLink" size={12} />
            </a>
          )}
          <button
            type="button"
            onClick={load}
            disabled={state.status === 'loading'}
            className="rounded-lg border border-border px-2.5 py-1 text-xs font-semibold text-ink-secondary hover:border-brand-deepGreen disabled:opacity-50"
          >
            {state.status === 'loading' ? '불러오는 중…' : '새로고침'}
          </button>
        </div>
      </div>

      {state.status === 'error' && (
        <p role="alert" className="mb-3 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">
          집계를 불러오지 못했습니다. 이 컴퓨터에서 구글(script.google.com) 접속이 되는지 확인하세요.
          {d && ' 아래는 마지막으로 불러온 숫자입니다.'}
        </p>
      )}

      {!d ? (
        state.status === 'loading' && <p className="text-sm text-ink-muted">불러오는 중…</p>
      ) : (
        <div className="grid gap-5 lg:grid-cols-5">
          <div className="space-y-3 lg:col-span-3">
            <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-4">
              <Metric label="작성기를 연 사람" value={t.open} />
              <Metric label="인쇄 창을 연 사람" value={t.print} note="버튼·Ctrl+P" />
              <Metric label="휴대전화 PDF 저장" value={t.pdfSaved} note={`만든 사람 ${t.pdfMade}명`} />
              <Metric
                label="인쇄 또는 저장"
                value={t.saved}
                strong
                note={receivedCount != null ? `접수 등록 ${receivedCount}명` : undefined}
              />
            </div>
            <p className="text-xs leading-relaxed text-ink-secondary">
              <span className="font-semibold text-ink-primary">고른 전형</span>{' '}
              {TRACKS.map((k) => `${TRACK_TEXT[k]} ${d.byTrack?.[k] ?? 0}`).join(' · ')}
              <span className="mx-2 text-border">|</span>
              <span className="font-semibold text-ink-primary">기기</span> PC {d.byDevice?.PC ?? 0} · 모바일 {d.byDevice?.['모바일'] ?? 0}
            </p>
          </div>
          <div className="lg:col-span-2">
            <p className="mb-1 text-xs font-medium text-ink-muted">최근 {DAYS_SHOWN}일 · 날짜별 인쇄·저장 인원</p>
            <DailyBars daily={d.daily || []} />
          </div>
        </div>
      )}

      <p className="mt-3 text-[11px] leading-relaxed text-ink-muted">
        사람 수는 브라우저별 익명 번호로 셉니다. 인쇄 창을 연 뒤 실제로 인쇄했는지는 알 수 없고, 한 사람이 휴대전화와 PC를 함께 쓰면 두 명으로 셉니다.
      </p>
    </section>
  )
}
