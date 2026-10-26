// 학교장 — 지원자 서류 열람 (2026-10-12)
//
// 교장선생님이 점수 없이 지원자 서류만 보시는 화면. 읽기 전용.
//  - 왼쪽: 지원자 목록(수험번호·접수번호·성명·전형·출신교). 연락처·주소는 싣지 않는다.
//  - 오른쪽: 서류 탭 + 확대·축소 + 이전/다음 지원자
// 서류는 documentAccess.getDocumentViewUrl로만 연다(열람 기록이 남는다).
// 권한: 학교장(principal, 00082), 평가위원·정량평가(00083). 최고관리자도 들어올 수 있다.
// 서류는 각자의 '열람 서류 종류' 설정(사용자 관리)을 그대로 따른다.
// 2026-10-25: PDF를 브라우저 내장 뷰어(iframe) 대신 pdf.js로 그린다 — 일부 PC에서 iframe 안 PDF가
// 흰 화면으로만 나오던 문제(브라우저의 'PDF 바로 내려받기' 설정·프레임 차단 등과 무관하게 보이도록).
// 파일은 한 번 받아 두므로 서명 주소(2분)가 만료돼도 확대·축소가 된다.

import { Suspense, lazy, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { roundToText } from '../../lib/applicantLabels'
import TranscriptionView from '../../components/transcription/TranscriptionView'
import useListPanel from '../../lib/useListPanel'

const TRACK_SHORT = { none: '일반', incheon: '일반+인천추천', social: '일반+사회통합' }
const DOCUMENT_TYPE_LABEL = {
  applicationForm: '입학원서',
  photo: '사진',
  studentRecordSource: '학생부',
  studentRecordAttendanceView: '학생부(출결)',
  studentRecordAcademicView: '학생부(학업)',
  studentRecordCommunityView: '학생부(공동체)',
  essay: '자기소개서',
  opinion: '학부모 소견서',
  portfolio: '포트폴리오',
  writingAnswer: '글쓰기 답안',
  trackEvidence: '전형 자격 증빙',
  consent: '동의서',
}
// 탭 순서: 원서 → 사진 → 학생부 → 자소서 → 소견서 → 나머지
const DOC_ORDER = ['applicationForm', 'photo', 'studentRecordSource', 'essay', 'opinion', 'trackEvidence', 'portfolio', 'writingAnswer', 'consent']
const ZOOM_STEPS = [1, 1.25, 1.5, 2, 3] // 1 = 화면 너비에 맞춤
const PdfCanvasViewer = lazy(() => import('../../components/pdf/PdfCanvasViewer'))

function specialTrack(tracks) {
  const t = tracks || []
  return t.includes('incheon') ? 'incheon' : t.includes('social') ? 'social' : 'none'
}

export default function PrincipalDocumentsPage() {
  const { year, round } = useAdmissionCycle()
  const [applicants, setApplicants] = useState(null)
  const [error, setError] = useState(null)
  const [search, setSearch] = useState('')
  const [selectedId, setSelectedId] = useState(null)
  const [documents, setDocuments] = useState([])
  const [loadingDocs, setLoadingDocs] = useState(false)
  const [docId, setDocId] = useState(null)
  const [loadingView, setLoadingView] = useState(false)
  const [zoom, setZoom] = useState(1)
  const [listOpen, setListOpen] = useListPanel() // 왼쪽 지원자 목록 접기(2026-10-26)
  // 자기소개서·소견서 입력본(00102) 보기 — 채점 화면과 같은 기억값을 쓴다
  const [textMode, setTextModeState] = useState(() => {
    try { return localStorage.getItem('sanmaeul.transcriptionMode') !== '0' } catch { return true }
  })
  const setTextMode = (v) => {
    setTextModeState(v)
    try { localStorage.setItem('sanmaeul.transcriptionMode', v ? '1' : '0') } catch { /* 기억만 못 함 */ }
  }
  const [docData, setDocData] = useState(null) // { kind: 'pdf', bytes } | { kind: 'image', url }
  const openingRef = useRef(null) // 마지막으로 연 서류(그사이 다른 탭을 누르면 늦게 온 결과는 버린다)

  // 지원자 목록 (연락처 없는 기본 정보만)
  useEffect(() => {
    if (!year || !round) return
    let active = true
    // 연락처·가산점·비고 등은 빼고 필요한 열만 돌려주는 함수(00083)
    supabase
      .rpc('list_applicants_basic', { p_year: year, p_round: round })
      .then(({ data, error: err }) => {
        if (!active) return
        if (err) {
          setError(err.message)
          return
        }
        const list = (data || [])
          .filter((a) => !['withdrawn', 'excluded'].includes(a.application_status))
          .sort((x, y) => {
            if (!x.exam_no !== !y.exam_no) return x.exam_no ? -1 : 1
            return (x.exam_no || x.receipt_no).localeCompare(y.exam_no || y.receipt_no, 'ko', { numeric: true })
          })
        setApplicants(list)
      })
    return () => { active = false }
  }, [year, round])

  const visible = useMemo(() => {
    const q = search.trim()
    if (!applicants) return []
    if (!q) return applicants
    return applicants.filter((a) => [a.name, a.exam_no, a.receipt_no, a.school].some((v) => (v || '').includes(q)))
  }, [applicants, search])

  const index = visible.findIndex((a) => a.id === selectedId)
  const current = applicants?.find((a) => a.id === selectedId) || null

  const openDoc = useCallback(async (doc) => {
    setDocId(doc.id)
    openingRef.current = doc.id
    setDocData(null)
    setLoadingView(true)
    setError(null)
    try {
      const { url } = await getDocumentViewUrl(doc.id)
      // 파일을 받아 PDF면 pdf.js로, 아니면 그림으로
      const res = await fetch(url)
      if (!res.ok) throw new Error(`서류를 받지 못했습니다(서버 응답 ${res.status}).`)
      const blob = await res.blob()
      const bytes = new Uint8Array(await blob.arrayBuffer())
      if (openingRef.current !== doc.id) return
      const isPdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 // %PDF
      setDocData(isPdf ? { kind: 'pdf', bytes } : { kind: 'image', url: URL.createObjectURL(blob) })
    } catch (err) {
      if (openingRef.current === doc.id) setError(err.message)
    } finally {
      if (openingRef.current === doc.id) setLoadingView(false)
    }
  }, [])

  // 지원자를 고르면 서류 목록을 불러오고 첫 서류(원서)를 연다
  useEffect(() => {
    if (!selectedId) return
    let active = true
    setDocuments([])
    setDocId(null)
    setDocData(null)
    setLoadingDocs(true)
    supabase
      .from('admission_documents')
      .select('id, document_type, mime_type, uploaded_at')
      .eq('applicant_id', selectedId)
      .eq('active', true)
      .then(({ data, error: err }) => {
        if (!active) return
        setLoadingDocs(false)
        if (err) {
          setError(err.message)
          return
        }
        const sorted = [...(data || [])].sort((a, b) => {
          const ia = DOC_ORDER.indexOf(a.document_type)
          const ib = DOC_ORDER.indexOf(b.document_type)
          return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || (a.uploaded_at || '').localeCompare(b.uploaded_at || '')
        })
        setDocuments(sorted)
        if (sorted[0]) openDoc(sorted[0])
      })
    return () => { active = false }
  }, [selectedId, openDoc])

  // 그림 주소(blob:)는 바뀔 때 풀어 준다
  useEffect(() => () => { if (docData?.kind === 'image') URL.revokeObjectURL(docData.url) }, [docData])

  const zi = ZOOM_STEPS.indexOf(zoom)
  const docType = documents.find((d) => d.id === docId)?.document_type
  const isTextType = docType === 'essay' || docType === 'opinion'
  const showText = isTextType && textMode
  const isPdf = docData?.kind === 'pdf'

  return (
    <div className="flex h-full min-h-[560px]">
      {/* 왼쪽: 지원자 목록 */}
      <aside className={`${listOpen ? 'flex' : 'hidden'} w-64 shrink-0 flex-col border-r border-border bg-surface-card`}>
        <div className="border-b border-border p-3">
          <div className="flex items-center justify-between">
            <h1 className="text-base font-bold text-ink-primary">지원자 서류 열람</h1>
            <button type="button" onClick={() => setListOpen(false)} title="지원자 목록 접기" aria-label="지원자 목록 접기"
              className="rounded-md border border-border px-2 py-1 text-xs text-ink-secondary hover:bg-surface-subtle">◀ 접기</button>
          </div>
          <p className="text-xs text-ink-muted">
            {year}학년도 {roundToText(round)} · {applicants ? `${applicants.length}명` : '불러오는 중…'}
          </p>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="이름·번호·출신교 찾기"
            aria-label="지원자 찾기"
            className="mt-2 w-full rounded-md border border-border px-2 py-1.5 text-sm"
          />
        </div>
        <ul className="min-h-0 flex-1 overflow-y-auto" aria-label="지원자 목록">
          {applicants && visible.length === 0 && (
            <li className="p-4 text-center text-sm text-ink-muted">{applicants.length === 0 ? '접수된 지원자가 없습니다.' : '찾는 지원자가 없습니다.'}</li>
          )}
          {visible.map((a) => {
            const on = a.id === selectedId
            return (
              <li key={a.id}>
                <button
                  type="button"
                  onClick={() => setSelectedId(a.id)}
                  aria-current={on ? 'true' : undefined}
                  className={`flex w-full items-center gap-3 border-b border-border px-3 py-2.5 text-left ${on ? 'bg-brand-greenSoft' : 'hover:bg-surface-subtle'}`}
                >
                  <span className="w-14 shrink-0 font-mono text-xs text-ink-muted">{a.exam_no || a.receipt_no.slice(-3)}</span>
                  <span className="min-w-0">
                    <span className={`block text-sm ${on ? 'font-bold text-brand-deepGreenStrong' : 'font-semibold text-ink-primary'}`}>{a.name}</span>
                    <span className="block truncate text-xs text-ink-muted">
                      {TRACK_SHORT[specialTrack(a.tracks)]} · {a.academic_status === '검정고시' ? '검정고시' : a.school || '—'}
                    </span>
                  </span>
                </button>
              </li>
            )
          })}
        </ul>
      </aside>

      {/* 오른쪽: 서류 */}
      <section className="flex min-w-0 flex-1 flex-col bg-surface-canvas">
        {!listOpen && !current && (
          <div className="border-b border-border bg-surface-card px-4 py-2.5">
            <button type="button" onClick={() => setListOpen(true)} className="rounded-md border border-border px-2.5 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle">▶ 지원자 목록</button>
          </div>
        )}
        {!current ? (
          <div className="flex flex-1 items-center justify-center p-10 text-center">
            <div>
              <p className="text-base font-semibold text-ink-primary">왼쪽에서 지원자를 고르세요</p>
              <p className="mt-1 text-sm text-ink-muted">입학원서·사진·학생부·자기소개서·학부모 소견서를 볼 수 있습니다. 열람 기록은 남습니다.</p>
            </div>
          </div>
        ) : (
          <>
            <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-surface-card px-4 py-2.5">
              <div className="flex min-w-0 items-center gap-3">
                {!listOpen && (
                  <button type="button" onClick={() => setListOpen(true)} title="지원자 목록 펴기" aria-label="지원자 목록 펴기"
                    className="shrink-0 rounded-md border border-border px-2.5 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle">▶ 목록 펴기</button>
                )}
              <div className="min-w-0">
                <h2 className="flex items-center gap-2 text-lg font-bold text-ink-primary">
                  <span className="rounded-md bg-brand-greenSoft px-2 py-0.5 font-mono text-sm text-brand-deepGreenStrong">{current.exam_no || current.receipt_no}</span>
                  {current.name}
                </h2>
                <p className="text-xs text-ink-muted">
                  {current.exam_no ? `수험번호 ${current.exam_no} · ` : ''}접수번호 {current.receipt_no} · {TRACK_SHORT[specialTrack(current.tracks)]} · {current.school || current.academic_status}
                </p>
              </div>
              </div>
              <div className="flex items-center gap-2">
                <button type="button" disabled={index <= 0} onClick={() => setSelectedId(visible[index - 1].id)}
                  className="rounded-lg border border-border px-3 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-30">← 이전</button>
                <span className="text-xs text-ink-muted">{index + 1} / {visible.length}</span>
                <button type="button" disabled={index < 0 || index >= visible.length - 1} onClick={() => setSelectedId(visible[index + 1].id)}
                  className="rounded-lg bg-brand-deepGreen px-3 py-1.5 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-30">다음 →</button>
              </div>
            </header>

            {documents.length > 0 && (
              <div className="flex items-center gap-2 border-b border-border bg-surface-card px-3 py-2">
                <div className="flex min-w-0 flex-1 gap-1 overflow-x-auto" role="tablist" aria-label="서류">
                  {documents.map((d) => (
                    <button key={d.id} type="button" role="tab" aria-selected={d.id === docId} onClick={() => openDoc(d)}
                      className={`shrink-0 rounded-lg px-3 py-1.5 text-sm ${d.id === docId ? 'bg-brand-deepGreen font-semibold text-white' : 'text-ink-secondary hover:bg-surface-subtle'}`}>
                      {DOCUMENT_TYPE_LABEL[d.document_type] || d.document_type}
                    </button>
                  ))}
                </div>
                {isTextType && (
                  <div className="flex shrink-0 rounded-lg border border-border bg-surface-subtle p-0.5" role="group" aria-label="보기 방식">
                    {[[false, '원본'], [true, '입력본']].map(([v, label]) => (
                      <button key={label} type="button" aria-pressed={textMode === v} onClick={() => setTextMode(v)}
                        className={`rounded-md px-2.5 py-1 text-xs font-semibold ${textMode === v ? 'bg-brand-deepGreen text-white' : 'text-ink-secondary'}`}>
                        {label}
                      </button>
                    ))}
                  </div>
                )}
                {isPdf && !showText && (
                  <div className="flex shrink-0 items-center gap-1 border-l border-border pl-2">
                    <button type="button" disabled={zi <= 0} onClick={() => setZoom(ZOOM_STEPS[zi - 1])} aria-label="축소"
                      className="h-8 w-8 rounded-md border border-border font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30">−</button>
                    <button type="button" onClick={() => setZoom(1)} className="min-w-[64px] rounded-md px-2 py-1 text-xs text-ink-secondary hover:bg-surface-subtle">
                      {zoom === 1 ? '너비맞춤' : `${Math.round(zoom * 100)}%`}
                    </button>
                    <button type="button" disabled={zi >= ZOOM_STEPS.length - 1} onClick={() => setZoom(ZOOM_STEPS[zi + 1])} aria-label="확대"
                      className="h-8 w-8 rounded-md border border-border font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30">+</button>
                  </div>
                )}
              </div>
            )}

            <div className="min-h-0 flex-1 bg-surface-subtle">
              {error ? (
                <p className="p-6 text-sm text-status-danger" role="alert">{error}</p>
              ) : showText && current ? (
                <TranscriptionView key={`${current.id}-${docType}`} applicantId={current.id} type={docType} year={year} onShowOriginal={() => setTextMode(false)} />
              ) : loadingDocs || loadingView ? (
                <p className="p-6 text-sm text-ink-muted">불러오는 중…</p>
              ) : documents.length === 0 ? (
                <p className="p-6 text-sm text-ink-muted">이 지원자는 아직 올라온 서류가 없습니다.</p>
              ) : docData?.kind === 'image' ? (
                <div className="flex h-full items-start justify-center overflow-auto p-6">
                  <img src={docData.url} alt={`${current.name} 서류`} className="max-h-full rounded border border-border bg-white shadow-sm" />
                </div>
              ) : isPdf ? (
                <Suspense fallback={<p className="p-6 text-sm text-ink-muted">PDF 보기 준비 중…</p>}>
                  <PdfCanvasViewer key={docId} data={docData.bytes} zoom={zoom} />
                </Suspense>
              ) : null}
            </div>
          </>
        )}
      </section>
    </div>
  )
}
