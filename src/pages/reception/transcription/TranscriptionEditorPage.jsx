// 자기소개서·학부모 소견서 받아 적기 (2026-10-25, 00102)
//
// 왼쪽: 스캔 원본(pdf.js) / 오른쪽: 문항별 입력칸.
// 입력하다 3초 멈추면 자동 저장(Ctrl+S로 바로 저장). 저장하면 바로 위원 화면에 '입력본'으로 보인다.
// 원칙: 원문 그대로(맞춤법·띄어쓰기를 고치지 않음), 읽을 수 없는 글자는 [판독불가].
// 최고관리자·관리자·접수 담당.

import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../../../lib/supabase'
import { getDocumentViewUrl } from '../../../lib/documentAccess'
import { getTranscriptionForm, TRANSCRIPTION_TYPES } from '../../../config/transcriptionForms'
import DocumentUrlView from '../../../components/pdf/DocumentUrlView'

const AUTOSAVE_MS = 3000

function clock(v) {
  const d = new Date(v)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`
}

export default function TranscriptionEditorPage() {
  const { applicantId, type } = useParams()
  const navigate = useNavigate()
  const [applicant, setApplicant] = useState(null)
  const [docUrl, setDocUrl] = useState(null)
  const [docState, setDocState] = useState('loading') // loading | none | error
  const [answers, setAnswers] = useState({})
  const [completed, setCompleted] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [savedAt, setSavedAt] = useState(null)
  const [error, setError] = useState(null)
  const timer = useRef(null)
  const latest = useRef({ answers: {}, completed: false })

  const form = applicant ? getTranscriptionForm(applicant.year, type) : null

  // 지원자 + 기존 입력본 + 원본
  useEffect(() => {
    if (!TRANSCRIPTION_TYPES.includes(type)) return undefined
    let active = true
    setLoaded(false)
    setDirty(false)
    setSavedAt(null)
    setError(null)
    setDocUrl(null)
    setDocState('loading')
    ;(async () => {
      const { data: a, error: aErr } = await supabase
        .from('applicants').select('id, year, round, name, receipt_no, exam_no').eq('id', applicantId).maybeSingle()
      if (!active) return
      if (aErr || !a) { setError(aErr?.message || '지원자를 찾을 수 없습니다.'); return }
      setApplicant(a)

      const { data: t, error: tErr } = await supabase.rpc('get_document_transcription', { p_applicant_id: applicantId, p_document_type: type })
      if (!active) return
      if (tErr) { setError(tErr.message); return }
      const ans = t?.answers || {}
      setAnswers(ans)
      setCompleted(Boolean(t?.completed))
      latest.current = { answers: ans, completed: Boolean(t?.completed) }
      if (t?.updatedAt) setSavedAt(t.updatedAt)
      setLoaded(true)

      const { data: doc } = await supabase
        .from('admission_documents').select('id')
        .eq('applicant_id', applicantId).eq('document_type', type).eq('active', true)
        .order('uploaded_at', { ascending: false }).limit(1).maybeSingle()
      if (!active) return
      if (!doc) { setDocState('none'); return }
      try {
        const { url } = await getDocumentViewUrl(doc.id)
        if (active) setDocUrl(url)
      } catch {
        if (active) setDocState('error')
      }
    })()
    return () => { active = false }
  }, [applicantId, type])

  const save = useCallback(async () => {
    clearTimeout(timer.current)
    setSaving(true)
    const snap = latest.current
    const { data, error: err } = await supabase.rpc('save_document_transcription', {
      p_applicant_id: applicantId, p_document_type: type, p_answers: snap.answers, p_completed: snap.completed,
    })
    setSaving(false)
    if (err) { setError(err.message); return false }
    setError(null)
    setSavedAt(data?.savedAt || new Date().toISOString())
    if (latest.current === snap) setDirty(false)
    return true
  }, [applicantId, type])

  const schedule = () => {
    setDirty(true)
    clearTimeout(timer.current)
    timer.current = setTimeout(save, AUTOSAVE_MS)
  }

  const setAnswer = (no, text) => {
    const next = { ...latest.current.answers, [String(no)]: text }
    latest.current = { ...latest.current, answers: next }
    setAnswers(next)
    schedule()
  }

  const toggleCompleted = (v) => {
    latest.current = { ...latest.current, completed: v }
    setCompleted(v)
    schedule()
  }

  // Ctrl+S 저장, 저장 안 된 채 나가기 경고
  useEffect(() => {
    const onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save() }
    }
    const onUnload = (e) => { if (dirty) { e.preventDefault(); e.returnValue = '' } }
    window.addEventListener('keydown', onKey)
    window.addEventListener('beforeunload', onUnload)
    return () => { window.removeEventListener('keydown', onKey); window.removeEventListener('beforeunload', onUnload) }
  }, [save, dirty])

  useEffect(() => () => clearTimeout(timer.current), [])

  const go = async (to) => {
    if (dirty && !(await save())) return
    navigate(to)
  }

  if (!TRANSCRIPTION_TYPES.includes(type)) return <p className="p-6 text-sm text-status-danger">입력본은 자기소개서·학부모 소견서만 있습니다.</p>

  const filled = Object.values(answers).filter((v) => String(v || '').trim()).length

  return (
    <div className="flex h-full min-h-[600px] flex-col">
      <header className="flex flex-wrap items-center gap-3 border-b border-border bg-surface-card px-4 py-2.5">
        <button type="button" onClick={() => go('/reception/transcriptions')} className="text-sm text-ink-muted underline">← 입력 현황</button>
        <div className="min-w-0">
          <p className="text-base font-bold text-ink-primary">
            {applicant?.name || '…'} <span className="ml-1 font-mono text-xs font-normal text-ink-muted">{applicant?.receipt_no}{applicant?.exam_no ? ` · ${applicant.exam_no}` : ''}</span>
          </p>
        </div>
        <div className="flex rounded-lg border border-border bg-surface-subtle p-0.5">
          {TRANSCRIPTION_TYPES.map((t) => (
            <button key={t} type="button" onClick={() => t !== type && go(`/reception/transcriptions/${applicantId}/${t}`)}
              className={`rounded-md px-3 py-1 text-xs font-semibold ${t === type ? 'bg-brand-deepGreen text-white' : 'text-ink-secondary'}`}>
              {getTranscriptionForm(applicant?.year || 2027, t).label}
            </button>
          ))}
        </div>
        <div className="ml-auto flex items-center gap-3 text-xs">
          <label className="flex items-center gap-1.5 font-semibold text-ink-primary">
            <input type="checkbox" checked={completed} onChange={(e) => toggleCompleted(e.target.checked)} disabled={!loaded} />
            입력 끝
          </label>
          <span className={dirty ? 'text-status-warning' : 'text-ink-muted'}>
            {saving ? '저장 중…' : dirty ? '저장 안 됨' : savedAt ? `저장됨 ${clock(savedAt)}` : '아직 저장 안 함'}
          </span>
          <button type="button" onClick={save} disabled={!loaded || saving}
            className="rounded-md bg-brand-deepGreen px-3 py-1.5 font-semibold text-white disabled:opacity-40">저장 (Ctrl+S)</button>
        </div>
      </header>

      {error && <p className="border-b border-border bg-status-dangerSoft px-4 py-2 text-sm text-status-danger">{error}</p>}

      <div className="flex min-h-0 flex-1">
        {/* 원본 */}
        <section className="hidden min-w-0 flex-1 border-r border-border bg-surface-subtle lg:block">
          {docUrl ? <DocumentUrlView url={docUrl} alt={form?.label} />
            : docState === 'none' ? <p className="p-6 text-sm text-ink-muted">이 지원자의 {form?.label || '서류'} 스캔본이 아직 없습니다. 종이 원본을 보며 입력하세요.</p>
              : docState === 'error' ? <p className="p-6 text-sm text-status-danger">원본을 열 권한이 없거나 열지 못했습니다.</p>
                : <p className="p-6 text-sm text-ink-muted">원본 불러오는 중…</p>}
        </section>

        {/* 입력 */}
        <section className="w-full max-w-[640px] shrink-0 overflow-y-auto bg-surface-card lg:w-[46%]">
          <div className="space-y-1 border-b border-border px-4 py-3 text-xs text-ink-secondary">
            <p><b className="text-ink-primary">원문 그대로</b> 옮깁니다. 맞춤법·띄어쓰기를 고치지 마세요. 읽을 수 없는 글자는 <code className="rounded bg-surface-subtle px-1">[판독불가]</code>.</p>
            <p>3초 동안 입력이 없으면 자동 저장되고, 저장하면 바로 위원 화면에 보입니다. {form ? `${filled}/${form.questions.length}문항 입력` : ''}</p>
          </div>
          {!loaded ? <p className="p-6 text-sm text-ink-muted">불러오는 중…</p> : (
            <ol className="space-y-4 p-4">
              {form.questions.map((q) => {
                const v = answers[String(q.no)] || ''
                return (
                  <li key={q.no}>
                    <label className="block">
                      <span className="flex items-baseline gap-1.5 text-sm font-bold text-ink-primary">
                        <span className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-deepGreen text-[11px] text-white">{q.no}</span>
                        {q.title}
                      </span>
                      <span className="mt-0.5 block text-[11px] leading-snug text-ink-muted">{q.prompt}</span>
                      <textarea
                        value={v}
                        onChange={(e) => setAnswer(q.no, e.target.value)}
                        rows={Math.min(14, Math.max(4, Math.ceil(v.length / 45) + 1))}
                        className="mt-1.5 w-full rounded-md border border-border px-3 py-2 text-[15px] leading-7 focus:border-brand-deepGreen focus:outline-none"
                        spellCheck={false}
                      />
                    </label>
                    <p className="text-right text-[11px] text-ink-muted">{v.length.toLocaleString()}자</p>
                  </li>
                )
              })}
            </ol>
          )}
          <div className="border-t border-border p-4 text-right">
            <Link to="/reception/transcriptions" onClick={(e) => { if (dirty) { e.preventDefault(); go('/reception/transcriptions') } }}
              className="text-sm text-ink-muted underline">입력 현황으로</Link>
          </div>
        </section>
      </div>
    </div>
  )
}
