// 자기소개서·학부모 소견서 입력본 보기 (위원·관리자 공용, 2026-10-25, 00102)
// 문항 제목과 지원자 글을 차례로 보여 준다. 원본과 다르면 원본이 우선이라는 안내를 항상 띄운다.

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { getTranscriptionForm } from '../../config/transcriptionForms'

// 글자 크기(px). 고른 크기는 이 PC에 기억한다(2026-10-26).
const FONT_STEPS = [14, 15, 17, 19, 22, 26, 30]
const FONT_KEY = 'sanmaeul.transcriptionFontPx'
function readFont() {
  try {
    const v = Number(localStorage.getItem(FONT_KEY))
    return FONT_STEPS.includes(v) ? v : 17
  } catch { return 17 }
}

function fmt(v) {
  if (!v) return ''
  const d = new Date(v)
  return `${d.getMonth() + 1}. ${d.getDate()}. ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

export default function TranscriptionView({ applicantId, type, year, onShowOriginal }) {
  const form = getTranscriptionForm(year, type)
  const [state, setState] = useState({ loading: true })
  const [showPrompt, setShowPrompt] = useState(false)
  const [fontPx, setFontPxState] = useState(readFont)
  const setFontPx = (v) => {
    setFontPxState(v)
    try { localStorage.setItem(FONT_KEY, String(v)) } catch { /* 기억만 못 함 */ }
  }
  const fi = FONT_STEPS.indexOf(fontPx)

  useEffect(() => {
    let active = true
    setState({ loading: true })
    supabase.rpc('get_document_transcription', { p_applicant_id: applicantId, p_document_type: type })
      .then(({ data, error }) => {
        if (!active) return
        if (error) setState({ error: error.message })
        else setState({ data })
      })
    return () => { active = false }
  }, [applicantId, type])

  if (state.loading) return <p className="p-6 text-sm text-ink-muted">입력본 불러오는 중…</p>
  if (state.error) return <p className="p-6 text-sm text-status-danger">{state.error}</p>
  const data = state.data
  if (!data?.exists || Object.keys(data.answers || {}).length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-10 text-center">
        <div>
          <p className="text-base font-semibold text-ink-primary">아직 {form?.label || '서류'} 입력본이 없습니다</p>
          <p className="mt-1 text-sm text-ink-muted">원본(스캔본)으로 읽어 주세요.</p>
          {onShowOriginal && (
            <button type="button" onClick={onShowOriginal} className="mt-4 rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white">원본 보기</button>
          )}
        </div>
      </div>
    )
  }

  return (
    <div className="h-full overflow-y-auto bg-surface-subtle">
      <div className={`mx-auto px-4 py-4 ${fontPx >= 22 ? 'max-w-5xl' : 'max-w-3xl'}`}>
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-status-warning bg-status-warningSoft px-3 py-2 text-xs text-status-warning">
          <span className="font-semibold">참고용 입력본</span>
          <span>원본을 그대로 옮긴 글입니다(맞춤법을 고치지 않음). 원본과 다르면 원본이 우선합니다.</span>
          <span className="ml-auto">
            {data.completed ? '입력 끝' : '입력 중'} · {fmt(data.updatedAt)}
          </span>
        </div>
        <div className="sticky top-0 z-10 -mx-4 mb-3 flex flex-wrap items-center gap-3 bg-surface-subtle/95 px-4 py-2 backdrop-blur">
          <label className="flex items-center gap-1.5 text-xs text-ink-secondary">
            <input type="checkbox" checked={showPrompt} onChange={(e) => setShowPrompt(e.target.checked)} />
            문항 전문 보기
          </label>
          <div className="ml-auto flex items-center gap-1" role="group" aria-label="글자 크기">
            <span className="mr-1 text-xs text-ink-secondary">글자 크기</span>
            <button type="button" aria-label="글자 작게" disabled={fi <= 0} onClick={() => setFontPx(FONT_STEPS[fi - 1])}
              className="h-9 w-9 rounded-md border border-border bg-white text-sm font-bold text-ink-secondary disabled:opacity-30">가−</button>
            <button type="button" onClick={() => setFontPx(17)} title="기본 크기로"
              className="min-w-[48px] rounded-md px-1 text-xs tabular-nums text-ink-secondary">{Math.round((fontPx / 17) * 100)}%</button>
            <button type="button" aria-label="글자 크게" disabled={fi >= FONT_STEPS.length - 1} onClick={() => setFontPx(FONT_STEPS[fi + 1])}
              className="h-9 w-9 rounded-md border border-border bg-white text-base font-bold text-ink-secondary disabled:opacity-30">가+</button>
          </div>
        </div>
        <ol className="space-y-3">
          {form.questions.map((q) => {
            const text = data.answers?.[String(q.no)] || ''
            return (
              <li key={q.no} className="rounded-lg border border-border bg-white p-4">
                <p className="font-bold text-ink-primary" style={{ fontSize: Math.max(14, fontPx - 2) }}>
                  <span className="mr-1.5 inline-flex h-5 w-5 items-center justify-center rounded-full bg-brand-deepGreen text-[11px] text-white">{q.no}</span>
                  {q.title}
                </p>
                {showPrompt && <p className="mt-1 leading-relaxed text-ink-muted" style={{ fontSize: Math.max(12, fontPx - 4) }}>{q.prompt}</p>}
                {text ? (
                  <p className="mt-2 whitespace-pre-wrap break-keep text-ink-primary" style={{ fontSize: fontPx, lineHeight: 1.85 }}>{text}</p>
                ) : (
                  <p className="mt-2 text-sm text-ink-muted">(입력 없음 — 원본 확인)</p>
                )}
              </li>
            )
          })}
        </ol>
      </div>
    </div>
  )
}
