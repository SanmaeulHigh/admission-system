// 2단계 심층역량평가 입실 확인 (바코드, 2026-09-28)
//
// USB 바코드 리더는 키보드처럼 동작한다(코드를 타이핑하고 Enter). 이 화면은 입력칸에
// 커서를 계속 붙잡아 두고, 찍힌 값으로 checkin_scan(00072)을 호출해 본인 확인 정보를
// 크게 띄우고 입실 시각을 기록한다. 수험표(수험번호)와 접수증(접수번호) 모두 된다.
//
// 한글 입력 상태 대응: PC가 한글 모드면 리더가 'A1001'을 'ㅁ1001'로 입력한다.
// 두벌식 자판 위치대로 영문으로 되돌려 읽는다.

import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { loadApplicantPhoto } from '../../lib/applicantPhoto'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import { tracksToText } from '../../lib/applicantLabels'
import CheckinRecordManager from './CheckinRecordManager'
import DocumentUrlView from '../../components/pdf/DocumentUrlView'

// 두벌식 한글 자모 → 같은 자리 영문(대문자)
const HANGUL_TO_QWERTY = {
  ㅂ: 'Q', ㅈ: 'W', ㄷ: 'E', ㄱ: 'R', ㅅ: 'T', ㅛ: 'Y', ㅕ: 'U', ㅑ: 'I', ㅐ: 'O', ㅔ: 'P',
  ㅁ: 'A', ㄴ: 'S', ㅇ: 'D', ㄹ: 'F', ㅎ: 'G', ㅗ: 'H', ㅓ: 'J', ㅏ: 'K', ㅣ: 'L',
  ㅋ: 'Z', ㅌ: 'X', ㅊ: 'C', ㅍ: 'V', ㅠ: 'B', ㅜ: 'N', ㅡ: 'M',
  ㅃ: 'Q', ㅉ: 'W', ㄸ: 'E', ㄲ: 'R', ㅆ: 'T', ㅒ: 'O', ㅖ: 'P',
}

export function normalizeScan(raw) {
  return String(raw || '')
    .split('')
    .map((ch) => HANGUL_TO_QWERTY[ch] || ch)
    .join('')
    .replace(/\s/g, '')
    .toUpperCase()
}

// 짧은 알림음(성공: 높은 음 한 번, 주의: 낮은 음 두 번)
function beep(kind) {
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    const tones = kind === 'ok' ? [[880, 0]] : [[330, 0], [330, 0.22]]
    tones.forEach(([freq, at]) => {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.frequency.value = freq
      gain.gain.value = 0.15
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(ctx.currentTime + at)
      osc.stop(ctx.currentTime + at + 0.16)
    })
    setTimeout(() => ctx.close(), 800)
  } catch {
    // 소리는 부가 기능 — 실패해도 무시
  }
}

function fmtTime(v) {
  if (!v) return ''
  return new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(v))
}

function fmtBirth(d) {
  if (!d) return '-'
  const [y, m, day] = String(d).split('-')
  return `${y}. ${Number(m)}. ${Number(day)}.`
}

export default function CheckinPage() {
  const { year, round } = useAdmissionCycle()
  const inputRef = useRef(null)
  const lastScanRef = useRef(null)
  const [code, setCode] = useState('')
  const [result, setResult] = useState(null)
  const [photoUrl, setPhotoUrl] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [status, setStatus] = useState([])
  const [recent, setRecent] = useState([])
  const [rehearsal, setRehearsal] = useState(false)
  const [showMissing, setShowMissing] = useState(false)
  const [formDoc, setFormDoc] = useState(null) // { id } | { missing: true } | null(조회 중)
  const [formView, setFormView] = useState(null) // { url } | { loading } | { error }

  const loadStatus = useCallback(async () => {
    if (!year || !round) return
    const { data, error: err } = await supabase.rpc('get_checkin_status', { p_year: year, p_round: round })
    if (!err) setStatus(data?.items || [])
  }, [year, round])

  useEffect(() => {
    loadStatus()
    const id = setInterval(loadStatus, 20000) // 다른 PC에서 찍은 것도 반영
    return () => clearInterval(id)
  }, [loadStatus])

  // 입력칸에 커서를 계속 둔다(다른 곳을 눌러도 되돌아옴). 입력칸 이외의 버튼 조작은 허용.
  useEffect(() => {
    const id = setInterval(() => {
      const el = document.activeElement
      if (!el || el === document.body) inputRef.current?.focus()
    }, 500)
    return () => clearInterval(id)
  }, [])

  useEffect(() => () => {
    if (photoUrl) URL.revokeObjectURL(photoUrl)
  }, [photoUrl])

  const scan = async (raw) => {
    const value = normalizeScan(raw)
    setCode('')
    if (!value || busy) return
    setBusy(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('checkin_scan', {
      p_year: year, p_round: round, p_code: value, p_allow_ineligible: rehearsal,
    })
    setBusy(false)
    if (err) {
      setError(err.message)
      setResult(null)
      beep('warn')
      return
    }
    setResult(data)
    setPhotoUrl(null)
    setFormDoc(null)
    setFormView(null)
    lastScanRef.current = data?.applicant?.applicantId || null
    const good = data?.found && data.recorded
    beep(good ? 'ok' : 'warn')
    if (data?.found) {
      setRecent((cur) => [{
        key: `${Date.now()}`,
        name: data.applicant.name,
        examNo: data.applicant.examNo,
        state: data.recorded ? '입실' : data.alreadyCheckedIn ? '중복' : '대상 아님',
        at: new Date().toISOString(),
      }, ...cur].slice(0, 8))
      // 입학원서 스캔본이 있는지(열람은 버튼을 눌렀을 때만 — 열람 감사 기록이 남는다)
      supabase
        .from('admission_documents')
        .select('id')
        .eq('applicant_id', data.applicant.applicantId)
        .eq('document_type', 'applicationForm')
        .eq('active', true)
        .order('uploaded_at', { ascending: false })
        .limit(1)
        .maybeSingle()
        .then(({ data: doc }) => {
          // 그사이 다른 수험생을 찍었으면 버린다
          if (lastScanRef.current !== data.applicant.applicantId) return
          setFormDoc(doc ? { id: doc.id } : { missing: true })
        })
      if (data.applicant.hasPhoto) {
        const p = await loadApplicantPhoto(data.applicant.applicantId)
        if (p.url) setPhotoUrl(p.url)
      }
      loadStatus()
    }
    inputRef.current?.focus()
  }

  const cancel = async () => {
    if (!result?.applicant) return
    if (!window.confirm(`${result.applicant.name}(${result.applicant.examNo || result.applicant.receiptNo})의 입실 기록을 취소할까요?`)) return
    const { error: err } = await supabase.rpc('cancel_checkin', { p_applicant_id: result.applicant.applicantId })
    if (err) {
      setError(err.message)
      return
    }
    setResult((cur) => ({ ...cur, recorded: false, alreadyCheckedIn: false, checkedInAt: null, cancelled: true }))
    loadStatus()
    inputRef.current?.focus()
  }

  const openForm = async () => {
    if (!formDoc?.id) return
    setFormView({ loading: true })
    try {
      const { url } = await getDocumentViewUrl(formDoc.id)
      setFormView({ url })
    } catch (err) {
      setFormView({ error: err.message })
    }
  }

  const closeForm = () => {
    setFormView(null)
    inputRef.current?.focus()
  }

  useEffect(() => {
    if (!formView?.url) return undefined
    const onKey = (e) => { if (e.key === 'Escape') closeForm() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  const eligible = status.filter((s) => s.eligible)
  const checkedCount = eligible.filter((s) => s.checkedInAt).length
  const missing = eligible.filter((s) => !s.checkedInAt)

  let banner = null
  if (error) banner = { tone: 'danger', title: '오류', text: error }
  else if (result && !result.found) banner = { tone: 'danger', title: '찾을 수 없는 번호', text: `${result.code} — 이 차수의 수험번호·접수번호가 아닙니다.` }
  else if (result?.cancelled) banner = { tone: 'neutral', title: '입실 취소됨', text: '입실 기록을 지웠습니다.' }
  else if (result?.recorded) banner = { tone: 'ok', title: '입실 확인', text: `${fmtTime(result.checkedInAt)} 입실 기록` }
  else if (result?.alreadyCheckedIn) banner = { tone: 'warn', title: '이미 입실한 수험생', text: `${fmtTime(result.checkedInAt)}에 이미 입실 처리됨 — 수험표 중복 여부를 확인하세요.` }
  else if (result?.found && !result.eligible) banner = { tone: 'danger', title: '2단계 심층역량평가 대상이 아님', text: '1단계 합격자가 아니거나 철회·제외된 지원자입니다. 입실 기록을 하지 않았습니다.' }

  const bannerClass = {
    ok: 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong',
    warn: 'border-status-warning bg-status-warningSoft text-status-warning',
    danger: 'border-status-danger bg-status-dangerSoft text-status-danger',
    neutral: 'border-border bg-surface-subtle text-ink-secondary',
  }

  const a = result?.found ? result.applicant : null

  return (
    <div className="min-h-screen bg-surface-canvas p-6">
      <div className="mx-auto max-w-6xl">
        <div className="mb-4 flex flex-wrap items-center gap-3">
          <Link to="/" className="text-sm text-ink-muted underline">← 메인</Link>
          <h1 className="text-xl font-bold text-ink-primary">2단계 심층역량평가 입실 확인</h1>
          <span className="rounded-full bg-brand-greenSoft px-3 py-1 text-sm font-semibold text-brand-deepGreenStrong">
            입실 {checkedCount} / {eligible.length}명
          </span>
          <label className="ml-auto flex items-center gap-1.5 text-xs text-ink-muted" title="1단계 사정 전 리허설용 — 2단계 대상이 아니어도 입실 기록">
            <input type="checkbox" checked={rehearsal} onChange={(e) => setRehearsal(e.target.checked)} />
            리허설 모드
          </label>
        </div>

        <form
          onSubmit={(e) => {
            e.preventDefault()
            scan(code)
          }}
          className="mb-4"
        >
          <input
            ref={inputRef}
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="수험표 또는 접수증 바코드를 찍으세요 (직접 입력 후 Enter도 가능)"
            className="w-full rounded-xl border-2 border-brand-deepGreen px-5 py-4 text-2xl font-semibold tracking-widest tabular-nums"
            autoComplete="off"
            spellCheck={false}
          />
        </form>

        <div className="grid gap-4 lg:grid-cols-[1fr_18rem]">
          <section className="rounded-card border border-border bg-surface-card p-6">
            {banner && (
              <div className={`mb-5 rounded-xl border-2 px-5 py-3 ${bannerClass[banner.tone]}`}>
                <p className="text-2xl font-bold">{banner.title}</p>
                <p className="mt-0.5 text-sm">{banner.text}</p>
              </div>
            )}

            {a ? (
              <div className="flex flex-wrap gap-8">
                <div className="flex h-[60mm] w-[46mm] shrink-0 items-center justify-center overflow-hidden rounded-lg border-2 border-ink-primary bg-surface-subtle">
                  {photoUrl ? (
                    <img src={photoUrl} alt="지원자 사진" className="h-full w-full object-cover" />
                  ) : (
                    <span className="px-3 text-center text-sm text-ink-muted">{a.hasPhoto ? '사진 불러오는 중…' : '등록된 사진 없음'}</span>
                  )}
                </div>
                <dl className="grid flex-1 grid-cols-[7rem_1fr] content-start gap-x-4 gap-y-3 text-lg">
                  <dt className="text-ink-muted">수험번호</dt>
                  <dd className="text-3xl font-bold tabular-nums text-ink-primary">{a.examNo || '미부여'}</dd>
                  <dt className="text-ink-muted">성명</dt>
                  <dd className="text-3xl font-bold text-ink-primary">{a.name}</dd>
                  <dt className="text-ink-muted">접수번호</dt>
                  <dd className="tabular-nums">{a.receiptNo}</dd>
                  <dt className="text-ink-muted">생년월일</dt>
                  <dd>{fmtBirth(a.birthDate)}</dd>
                  <dt className="text-ink-muted">성별</dt>
                  <dd>{a.gender || '-'}</dd>
                  <dt className="text-ink-muted">출신 중학교</dt>
                  <dd>{a.school || a.academicStatus}</dd>
                  <dt className="text-ink-muted">지원 전형</dt>
                  <dd className="text-base">{tracksToText(a.tracks)}</dd>
                </dl>
                <div className="flex w-full flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={openForm}
                    disabled={!formDoc?.id || formView?.loading}
                    className="rounded-md border-2 border-brand-deepGreen px-4 py-2 text-sm font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:border-border disabled:text-ink-muted"
                  >
                    {formDoc === null ? '입학원서 확인 중…' : formDoc.missing ? '입학원서 스캔본 없음' : formView?.loading ? '여는 중…' : '입학원서 스캔본 보기'}
                  </button>
                  {formView?.error && <span className="text-sm text-status-danger">{formView.error}</span>}
                </div>
                {(result.recorded || result.alreadyCheckedIn) && (
                  <button
                    type="button"
                    onClick={cancel}
                    className="self-end rounded-md border border-border px-3 py-1.5 text-xs text-ink-secondary hover:bg-surface-subtle"
                  >
                    입실 취소
                  </button>
                )}
              </div>
            ) : (
              !banner && (
                <p className="py-16 text-center text-lg text-ink-muted">
                  바코드를 찍으면 수험생 정보가 여기에 나타납니다.
                </p>
              )
            )}
          </section>

          <aside className="space-y-4">
            <section className="rounded-card border border-border bg-surface-card p-4">
              <h2 className="text-sm font-semibold text-ink-primary">최근 확인</h2>
              <ul className="mt-2 space-y-1 text-sm">
                {recent.length === 0 && <li className="text-ink-muted">—</li>}
                {recent.map((r) => (
                  <li key={r.key} className="flex justify-between gap-2">
                    <span><span className="tabular-nums font-semibold">{r.examNo || ''}</span> {r.name}</span>
                    <span className={r.state === '입실' ? 'text-brand-deepGreenStrong' : 'text-status-warning'}>
                      {r.state} {fmtTime(r.at)}
                    </span>
                  </li>
                ))}
              </ul>
            </section>

            <section className="rounded-card border border-border bg-surface-card p-4">
              <button
                type="button"
                onClick={() => setShowMissing((v) => !v)}
                className="flex w-full justify-between text-sm font-semibold text-ink-primary"
              >
                <span>미입실 {missing.length}명</span>
                <span className="text-xs text-ink-muted">{showMissing ? '접기' : '펼치기'}</span>
              </button>
              {showMissing && (
                <ul className="mt-2 max-h-80 space-y-1 overflow-y-auto text-sm">
                  {missing.map((m) => (
                    <li key={m.applicantId}>
                      <span className="tabular-nums font-semibold">{m.examNo || m.receiptNo}</span> {m.name}
                    </li>
                  ))}
                  {missing.length === 0 && <li className="text-ink-muted">모두 입실했습니다.</li>}
                </ul>
              )}
            </section>
          </aside>
        </div>

        <CheckinRecordManager items={status} onChanged={loadStatus} />
      </div>

      {formView?.url && a && (
        <div className="fixed inset-0 z-50 flex flex-col bg-black/70 p-4" role="dialog" aria-modal="true" aria-label="입학원서 스캔본">
          <div className="mb-2 flex items-center justify-between gap-3 rounded-t-lg bg-white px-4 py-2">
            <p className="text-sm font-semibold text-ink-primary">
              입학원서 — <span className="tabular-nums">{a.examNo || a.receiptNo}</span> {a.name}
              <span className="ml-2 font-normal text-ink-muted">(열람 기록이 남습니다 · Esc로 닫기)</span>
            </p>
            <button type="button" onClick={closeForm} className="rounded-md bg-brand-deepGreen px-4 py-1.5 text-sm font-semibold text-white">
              닫기 (스캔 계속)
            </button>
          </div>
          <div className="min-h-0 w-full flex-1 overflow-hidden rounded-b-lg bg-surface-subtle"><DocumentUrlView url={formView.url} alt="입학원서" /></div>
        </div>
      )}
    </div>
  )
}
