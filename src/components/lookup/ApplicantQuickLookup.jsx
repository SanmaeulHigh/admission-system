// QR·번호로 지원자 빠른 조회 (2026-10-21, 00099)
//
// AdminShell 안 어느 화면에서든 접수증·수험표·화일 표지의 QR을 찍으면 지원자 카드가 뜬다.
//   · 입력칸에 글을 쓰는 중이면 가로채지 않는다. 빠른 연속 입력(리더) + 번호 형식일 때만 반응.
//   · 헤더의 번호 칸(HeaderLookupInput)에 직접 쳐도 된다(같은 이벤트로 연결).
//   · 조회 전용 — 입실 처리 등 아무것도 바꾸지 않는다.
//   · 최고관리자·관리자·접수 담당만. 평가위원에게는 열지 않는다(블라인드 평가).
//   · 접수 담당에게는 접수 정보·서류 현황만, 진행 상황(평가 단계·입실)은 관리자에게만(서버에서 거른다).

import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { loadApplicantPhoto } from '../../lib/applicantPhoto'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import {
  APPLICATION_STATUS_LABEL, EVALUATION_STAGE_LABEL, METHOD_LABEL, roundToText, tracksToText,
} from '../../lib/applicantLabels'
import { isApplicantCode, isEditableTarget, keyEventToChar, normalizeScanText } from '../../lib/scanCode'
import DocumentUrlView from '../pdf/DocumentUrlView'

const LOOKUP_EVENT = 'sanmaeul:applicant-lookup'
const ALLOWED = ['superadmin', 'admin', 'reception']
const MAX_GAP_MS = 60 // 리더 입력은 글자 사이가 수십 ms 이하

const DOC_CHECKS = [
  ['applicationForm', '입학원서'],
  ['photo', '사진'],
  ['studentRecordSource', '학생부'],
  ['essay', '자기소개서'],
  ['opinion', '학부모 소견서'],
  ['consent', '동의서'],
  ['trackEvidence', '전형 증빙'],
]

export function canUseQuickLookup(roles) {
  return (roles || []).some((r) => ALLOWED.includes(r))
}

export function requestApplicantLookup(code) {
  window.dispatchEvent(new CustomEvent(LOOKUP_EVENT, { detail: String(code || '') }))
}

function fmtDateTime(v) {
  if (!v) return '-'
  const d = new Date(v)
  const opt = { timeZone: 'Asia/Seoul' }
  const date = new Intl.DateTimeFormat('ko-KR', { ...opt, year: 'numeric', month: 'numeric', day: 'numeric' }).format(d)
  const wd = new Intl.DateTimeFormat('ko-KR', { ...opt, weekday: 'short' }).format(d)
  const time = new Intl.DateTimeFormat('ko-KR', { ...opt, hour: '2-digit', minute: '2-digit', hour12: false }).format(d)
  return `${date}(${wd}) ${time}`
}

// 헤더용 번호 칸
export function HeaderLookupInput() {
  const { roles } = useAuth()
  const [value, setValue] = useState('')
  if (!canUseQuickLookup(roles)) return null
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault()
        if (value.trim()) requestApplicantLookup(value)
        setValue('')
      }}
      className="hidden lg:block"
    >
      <input
        value={value}
        onChange={(e) => setValue(e.target.value)}
        placeholder="접수·수험번호 / QR"
        aria-label="접수번호 또는 수험번호로 지원자 찾기"
        className="w-40 rounded-lg border border-border bg-surface-subtle px-2.5 py-1.5 text-xs tabular-nums focus:bg-white"
        autoComplete="off"
        spellCheck={false}
      />
    </form>
  )
}

export default function ApplicantQuickLookup() {
  const { roles } = useAuth()
  const { year, round } = useAdmissionCycle()
  const allowed = canUseQuickLookup(roles)
  const [state, setState] = useState(null) // { loading, code } | { data } | { error }
  const [photoUrl, setPhotoUrl] = useState(null)
  const [formView, setFormView] = useState(null)
  const bufRef = useRef({ chars: '', last: 0 })

  const lookup = useCallback(async (raw) => {
    const code = normalizeScanText(raw) // 한글 입력 상태로 들어온 값도 되돌린다
    if (!code || !year) return
    setState({ loading: true, code })
    setPhotoUrl(null)
    setFormView(null)
    const { data, error } = await supabase.rpc('lookup_applicant_by_code', { p_year: year, p_round: round, p_code: code })
    if (error) {
      setState({ error: error.message, code })
      return
    }
    setState({ data })
    if (data?.found && (data.applicant.documents || []).includes('photo')) {
      const p = await loadApplicantPhoto(data.applicant.applicantId)
      if (p.url) setPhotoUrl(p.url)
    }
  }, [year, round])

  // 헤더 칸·다른 화면에서 보낸 조회 요청
  useEffect(() => {
    if (!allowed) return undefined
    const onLookup = (e) => lookup(e.detail)
    window.addEventListener(LOOKUP_EVENT, onLookup)
    return () => window.removeEventListener(LOOKUP_EVENT, onLookup)
  }, [allowed, lookup])

  // 어디서든 리더로 찍은 입력 감지(입력칸에 커서가 있으면 무시)
  useEffect(() => {
    if (!allowed) return undefined
    const onKey = (e) => {
      if (isEditableTarget(e.target) || e.ctrlKey || e.altKey || e.metaKey) {
        bufRef.current = { chars: '', last: 0 }
        return
      }
      const now = performance.now()
      const buf = bufRef.current
      if (e.key === 'Enter') {
        const code = buf.chars
        bufRef.current = { chars: '', last: 0 }
        if (code.length >= 5 && isApplicantCode(code)) {
          e.preventDefault()
          lookup(code)
        }
        return
      }
      const ch = keyEventToChar(e)
      if (!ch) return
      if (buf.last && now - buf.last > MAX_GAP_MS) buf.chars = ''
      buf.chars = (buf.chars + ch).slice(-12)
      buf.last = now
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [allowed, lookup])

  useEffect(() => () => { if (photoUrl) URL.revokeObjectURL(photoUrl) }, [photoUrl])

  const close = useCallback(() => {
    setState(null)
    setFormView(null)
  }, [])

  useEffect(() => {
    if (!state) return undefined
    const onEsc = (e) => {
      if (e.key !== 'Escape') return
      if (formView) setFormView(null)
      else close()
    }
    window.addEventListener('keydown', onEsc)
    return () => window.removeEventListener('keydown', onEsc)
  }, [state, formView, close])

  if (!allowed || !state) return null

  const data = state.data
  const a = data?.found ? data.applicant : null
  const isAdmin = data?.scope === 'admin'
  const docs = new Set(a?.documents || [])

  async function openForm() {
    if (!a?.applicationFormDocId) return
    setFormView({ loading: true })
    try {
      const { url } = await getDocumentViewUrl(a.applicationFormDocId)
      setFormView({ url })
    } catch (err) {
      setFormView({ error: err.message })
    }
  }

  const btn = 'rounded-md border border-border px-3 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle'

  return (
    <div className="fixed inset-0 z-[60] flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:p-10" role="dialog" aria-modal="true" aria-label="지원자 빠른 조회" onClick={close}>
      <div className="w-full max-w-2xl rounded-xl bg-surface-card shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <p className="text-sm font-semibold text-ink-primary">
            지원자 빠른 조회 <span className="ml-1 font-mono text-xs text-ink-muted">{state.code || data?.code}</span>
          </p>
          <button type="button" onClick={close} className="rounded-md border border-border px-3 py-1 text-xs text-ink-secondary hover:bg-surface-subtle">닫기 (Esc)</button>
        </div>

        <div className="p-5">
          {state.loading && <p className="py-10 text-center text-sm text-ink-muted">찾는 중…</p>}
          {state.error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{state.error}</p>}
          {data && !data.found && (
            <p className="py-8 text-center text-sm text-ink-secondary">
              <span className="font-mono font-semibold">{data.code}</span> — {year}학년도 접수번호·수험번호에서 찾지 못했습니다.
            </p>
          )}

          {a && (
            <>
              <div className="flex gap-5">
                <div className="flex h-[40mm] w-[30mm] shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border bg-surface-subtle">
                  {photoUrl ? <img src={photoUrl} alt="지원자 사진" className="h-full w-full object-cover" />
                    : <span className="px-2 text-center text-xs text-ink-muted">{docs.has('photo') ? '사진 불러오는 중…' : '사진 없음'}</span>}
                </div>
                <div className="min-w-0 flex-1">
                  <p className="text-2xl font-bold text-ink-primary">{a.name}</p>
                  <p className="mt-1 font-mono text-sm text-ink-secondary">
                    접수 {a.receiptNo} · 수험 {a.examNo || '미부여'}
                    {a.round !== round && <span className="ml-2 rounded bg-status-warningSoft px-1.5 py-0.5 font-sans text-xs text-status-warning">{roundToText(a.round)}</span>}
                  </p>
                  <dl className="mt-3 grid grid-cols-[6rem_1fr] gap-x-3 gap-y-1.5 text-sm">
                    <dt className="text-ink-muted">지원 전형</dt><dd>{tracksToText(a.tracks)}</dd>
                    <dt className="text-ink-muted">출신 중학교</dt><dd>{a.school || a.academicStatus || '-'}</dd>
                    <dt className="text-ink-muted">접수일시</dt><dd>{fmtDateTime(a.receiptDate)} · {METHOD_LABEL[a.receiptMethod] || '-'}</dd>
                    <dt className="text-ink-muted">접수 상태</dt><dd>{APPLICATION_STATUS_LABEL[a.applicationStatus] || a.applicationStatus}</dd>
                    {isAdmin && (
                      <>
                        <dt className="text-ink-muted">평가 단계</dt><dd>{EVALUATION_STAGE_LABEL[a.evaluationStage] || a.evaluationStage}</dd>
                        <dt className="text-ink-muted">2단계 입실</dt><dd>{a.checkedInAt ? fmtDateTime(a.checkedInAt) : '-'}</dd>
                      </>
                    )}
                  </dl>
                </div>
              </div>

              <div className="mt-4">
                <p className="text-xs font-semibold text-ink-secondary">서류 (시스템 등록)</p>
                <div className="mt-1.5 flex flex-wrap gap-1.5">
                  {DOC_CHECKS.map(([type, label]) => (
                    <span key={type} className={`rounded-full px-2.5 py-0.5 text-xs ${docs.has(type) ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-surface-subtle text-ink-muted'}`}>
                      {docs.has(type) ? '✓ ' : ''}{label}
                    </span>
                  ))}
                </div>
              </div>

              <div className="mt-5 flex flex-wrap gap-2 border-t border-border pt-4">
                <button type="button" onClick={openForm} disabled={!a.applicationFormDocId || formView?.loading}
                  className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
                  {a.applicationFormDocId ? (formView?.loading ? '여는 중…' : '입학원서 스캔본') : '원서 스캔본 없음'}
                </button>
                <Link to={`/reception/receipt/${a.applicantId}`} onClick={close} className={btn}>접수증</Link>
                {isAdmin && a.examNo && <Link to={`/reception/exam-ticket/${a.applicantId}`} onClick={close} className={btn}>수험표</Link>}
                <Link to={`/reception/folder-cover/${a.applicantId}`} onClick={close} className={btn}>화일 표지</Link>
              </div>
              {formView?.error && <p className="mt-2 text-sm text-status-danger">{formView.error}</p>}
              <p className="mt-3 text-[11px] text-ink-muted">조회 전용입니다(입실 처리 안 함). 조회·원서 열람은 감사 기록에 남습니다.</p>
            </>
          )}
        </div>
      </div>

      {formView?.url && a && (
        <div className="fixed inset-0 z-[70] flex flex-col bg-black/70 p-4" onClick={(e) => e.stopPropagation()}>
          <div className="mb-2 flex items-center justify-between rounded-t-lg bg-white px-4 py-2">
            <p className="text-sm font-semibold">입학원서 — <span className="font-mono">{a.receiptNo}</span> {a.name}</p>
            <button type="button" onClick={() => setFormView(null)} className="rounded-md bg-brand-deepGreen px-4 py-1.5 text-sm font-semibold text-white">닫기 (Esc)</button>
          </div>
          <div className="min-h-0 w-full flex-1 overflow-hidden rounded-b-lg bg-surface-subtle"><DocumentUrlView url={formView.url} alt="입학원서" /></div>
        </div>
      )}
    </div>
  )
}
