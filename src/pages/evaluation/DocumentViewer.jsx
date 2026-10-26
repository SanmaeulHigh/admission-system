// M2 평가서류 열람 — 좌측 서류 / 우측 채점폼 분할 화면 (스펙 1242행)
//
// pdf.js 뷰어: 별도 라이브러리를 번들에 추가하지 않고 브라우저 내장
// PDF 뷰어(Chrome/Edge/Firefox 모두 pdf.js 기반)를 <iframe>으로 띄운다.
// #toolbar=0&navpanes=0 URL 파라미터로 다운로드·인쇄 버튼을 최대한
// 숨기지만, 이건 UI 수준의 억제일 뿐 완전한 차단은 아니다 — 스펙이
// 요구하는 "다운로드·인쇄 UI 억제"의 현실적 한계로, 완전 차단하려면
// PDF.js를 직접 임베드해 커스텀 렌더러를 만들어야 한다 (후속 검토 대상).
//
// 채점 폼 자리는 M3에서 실제 채점 UI로 교체된다.
//
// 2026-07-09 수정: 한 위원이 여러 영역(예: 공동체+학부모소견서)에 배정된
// 경우 첫 번째로 매칭되는 영역의 폼만 보이고 나머지는 아예 안 보이던 버그를
// 고쳤다 — 매칭되는 영역이 여러 개면 탭으로 선택하게 한다.

// 2026-07-09 UX1-C 추가: 로스터 내 순번(N/전체) 표시 + 이전/다음 지원자로
// 목록에 안 돌아가고 바로 이동. 순번 계산은 evaluation_roster 순서를
// 그대로 쓴다(별도 정렬 규칙 신설 없음).

// 2026-10-13 모바일 재설계: 좁은 화면(폭 1024px 미만)에서는 440px 채점창이 옆에 붙어
// 서류가 거의 안 보였다. 이제 좁은 화면에서는 위아래로 쌓고, 아래 "보기 전환" 막대로
// [서류만 · 반반 · 채점만]을 고른다. 넓은 화면(데스크톱)은 예전 좌우 분할 그대로다.
// 같은 날 추가: 터치 기기·좁은 화면은 PDF를 pdf.js(components/pdf/PdfCanvasViewer)로 그린다.

import { Suspense, lazy, useCallback, useEffect, useMemo, useState } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import AttendanceScoreForm from './AttendanceScoreForm'
import AcademicScoreForm from './AcademicScoreForm'
import CommunityScoreForm from './CommunityScoreForm'
import EssayScoreForm from './EssayScoreForm'
import OpinionScoreForm from './OpinionScoreForm'
import EmptyState from '../../components/feedback/EmptyState'
import TranscriptionView from '../../components/transcription/TranscriptionView'
import useListPanel from '../../lib/useListPanel'

// pdf.js는 무거워서(약 1MB) 터치 기기·좁은 화면에서 서류를 열 때만 불러온다.
const PdfCanvasViewer = lazy(() => import('../../components/pdf/PdfCanvasViewer'))

// PDF는 언제나 pdf.js로 그린다(2026-10-25).
// 처음엔 휴대폰·태블릿·좁은 화면만 pdf.js였는데, 일부 교내 PC에서도 브라우저 내장 PDF 뷰어(iframe)가
// 흰 화면으로만 나와(사진은 정상) PC도 pdf.js로 통일했다. 파일을 한 번 받아 두므로 서명 주소(2분)가
// 만료돼도 확대·축소·탭 전환이 된다.
function useCanvasViewer() {
  return true
}

// pdf.js 뷰어 배율(1 = 화면 너비에 맞춤)
const CANVAS_ZOOM_STEPS = [1, 1.25, 1.5, 2, 3]

const SCORE_FORMS = [
  { key: 'attendance', label: '출결', match: (hasRole, hasArea) => hasRole('quant') && hasArea('attendance'), Form: AttendanceScoreForm },
  { key: 'academic', label: '학업성실도', match: (hasRole, hasArea) => hasRole('quant') && hasArea('academic'), Form: AcademicScoreForm },
  { key: 'community', label: '공동체생활적합성', match: (hasRole, hasArea) => hasRole('evaluator') && hasArea('community'), Form: CommunityScoreForm },
  { key: 'essay', label: '자기소개서', match: (hasRole, hasArea) => hasRole('evaluator') && hasArea('essay'), Form: EssayScoreForm },
  { key: 'opinion', label: '학부모소견서', match: (hasRole, hasArea) => hasRole('evaluator') && hasArea('opinion'), Form: OpinionScoreForm },
]

// 서류를 열면 오른쪽 채점 폼을 그 서류에 맞는 것으로 자동 전환한다.
// 학생부(전체)는 출결·학업·공동체 세 영역에 걸쳐 있어 어느 하나로 정할 수
// 없으므로 전환하지 않고 보던 탭을 유지한다.
const DOC_TYPE_TO_FORM = {
  essay: 'essay',
  opinion: 'opinion',
  studentRecordAttendanceView: 'attendance',
  studentRecordAcademicView: 'academic',
  studentRecordCommunityView: 'community',
}

// 확대·축소 단계. 선생님마다 노트북 해상도가 달라서 고정 배율로는 안 맞는다.
// '너비맞춤'을 기본으로 두고 단계적으로 키우고 줄일 수 있게 한다.
const ZOOM_STEPS = ['page-width', '75', '100', '125', '150', '200', '300']
const ZOOM_LABEL = { 'page-width': '너비맞춤' }

// 좁은 화면 보기 방식 — 고른 것은 브라우저에 기억해 둔다(지원자를 넘길 때마다 다시 고르지 않게).
const MOBILE_PANE_KEY = 'sanmaeul.docViewerPane'
const MOBILE_PANES = [
  { key: 'doc', label: '서류만' },
  { key: 'split', label: '반반' },
  { key: 'score', label: '채점만' },
]

function readMobilePane() {
  try {
    const v = localStorage.getItem(MOBILE_PANE_KEY)
    return MOBILE_PANES.some((p) => p.key === v) ? v : 'split'
  } catch {
    return 'split'
  }
}

const DOCUMENT_TYPE_LABEL = {
  applicationForm: '입학원서',
  studentRecordSource: '학생부 원본',
  studentRecordAttendanceView: '학생부(출결 발췌)',
  studentRecordAcademicView: '학생부(학업 발췌)',
  studentRecordCommunityView: '학생부(공동체 발췌)',
  essay: '자기소개서',
  opinion: '학부모 소견서',
  portfolio: '포트폴리오',
  writingAnswer: '글쓰기 답안',
  trackEvidence: '전형 자격 증빙',
  consent: '동의서',
  photo: '지원자 사진',
}

export default function DocumentViewer() {
  const { applicantId } = useParams()
  const navigate = useNavigate()
  const { hasRole, hasArea } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [documents, setDocuments] = useState([])
  const [applicantName, setApplicantName] = useState('')
  const [selectedDocId, setSelectedDocId] = useState(null)
  // 자기소개서·소견서는 '입력본'(문항별 받아 적은 글, 00102)으로 볼 수 있다. 고른 방식은 기억한다.
  const [textMode, setTextModeState] = useState(() => {
    try { return localStorage.getItem('sanmaeul.transcriptionMode') !== '0' } catch { return true }
  })
  const setTextMode = (v) => {
    setTextModeState(v)
    try { localStorage.setItem('sanmaeul.transcriptionMode', v ? '1' : '0') } catch { /* 기억만 못 함 */ }
  }
  // 서명 URL 원본과 확대배율을 따로 들고 있다가 화면에서 합친다.
  // 배율만 바꿀 때 서명 URL을 다시 발급받지 않기 위해서다(열람 로그도 중복되지 않는다).
  const [viewUrl, setViewUrl] = useState(null)
  const [zoom, setZoom] = useState('page-width')
  const [loadingList, setLoadingList] = useState(true)
  const [loadingDoc, setLoadingDoc] = useState(false)
  const [error, setError] = useState(null)
  const [activeFormKey, setActiveFormKey] = useState(null)
  const [rosterOrder, setRosterOrder] = useState([]) // [{applicant_id, display_name}]
  const [mobilePane, setMobilePane] = useState(readMobilePane)
  const canvasMode = useCanvasViewer()
  // pdf.js 모드: 서명 주소로 받은 파일 내용. 서명 주소는 2분이면 만료되므로 한 번 받아 두고 다시 쓴다.
  const [docBytes, setDocBytes] = useState(null) // { bytes: Uint8Array, kind: 'pdf'|'image', imageUrl? }
  const [canvasZoom, setCanvasZoom] = useState(1)

  const chooseMobilePane = (key) => {
    setMobilePane(key)
    try {
      localStorage.setItem(MOBILE_PANE_KEY, key)
    } catch {
      // 저장 공간을 못 쓰면 기억만 안 한다
    }
  }

  const matchingForms = useMemo(
    () => SCORE_FORMS.filter((f) => f.match(hasRole, hasArea)),
    [hasRole, hasArea],
  )

  useEffect(() => {
    if (matchingForms.length > 0 && !activeFormKey) {
      setActiveFormKey(matchingForms[0].key)
    }
  }, [matchingForms, activeFormKey])

  // 로스터 전체 순서(순번 표시 + 이전/다음 이동용) — 이 화면에 처음 들어올 때 한 번만
  useEffect(() => {
    if (!YEAR || !ROUND) return
    let active = true
    supabase
      .from('evaluation_roster')
      .select('applicant_id, display_name, exam_no, receipt_no')
      .eq('year', YEAR)
      .eq('round', ROUND)
      .eq('evaluation_active', true)
      .order('exam_no', { ascending: true, nullsFirst: false })
      .order('receipt_no', { ascending: true })
      .then(({ data }) => {
        if (active) setRosterOrder(data || [])
      })
    return () => {
      active = false
    }
  }, [YEAR, ROUND])

  const currentIndex = rosterOrder.findIndex((r) => r.applicant_id === applicantId)
  const currentRoster = currentIndex >= 0 ? rosterOrder[currentIndex] : null
  const [listOpen, setListOpen] = useListPanel() // 왼쪽 지원자 목록 접기(2026-10-26, 넓은 화면만)
  const prevApplicant = currentIndex > 0 ? rosterOrder[currentIndex - 1] : null
  const nextApplicant =
    currentIndex >= 0 && currentIndex < rosterOrder.length - 1 ? rosterOrder[currentIndex + 1] : null

  useEffect(() => {
    let active = true
    setSelectedDocId(null)
    setViewUrl(null)
    setLoadingList(true)
    async function load() {
      const [{ data: docs, error: docErr }, { data: roster }] = await Promise.all([
        supabase
          .from('admission_documents')
          .select('*')
          .eq('applicant_id', applicantId)
          .eq('active', true)
          .order('document_type', { ascending: true }),
        supabase
          .from('evaluation_roster')
          .select('display_name')
          .eq('applicant_id', applicantId)
          .maybeSingle(),
      ])
      if (!active) return
      if (docErr) setError(docErr.message)
      else setDocuments(docs || [])
      setApplicantName(roster?.display_name || '')
      setLoadingList(false)
    }
    load()
    return () => {
      active = false
    }
  }, [applicantId])

  const openDocument = useCallback(async (doc) => {
    setSelectedDocId(doc.id)
    setViewUrl(null)
    setError(null)
    setLoadingDoc(true)

    // 이 서류에 대응하는 채점 폼이 있고, 그게 내가 채점할 수 있는 영역이면
    // 오른쪽 채점창을 자동으로 그쪽으로 바꿔준다(자소서를 열면 자소서 채점).
    const targetForm = DOC_TYPE_TO_FORM[doc.document_type]
    if (targetForm && matchingForms.some((f) => f.key === targetForm)) {
      setActiveFormKey(targetForm)
    }

    try {
      const { url } = await getDocumentViewUrl(doc.id)
      setViewUrl(url)
    } catch (err) {
      setError(err.message)
    } finally {
      setLoadingDoc(false)
    }
  }, [matchingForms])

  // 확대배율은 서류를 바꿔도 유지한다(선생님이 자기 화면에 맞춰 한 번 맞추면 끝).
  const selectedDocType = documents.find((d) => d.id === selectedDocId)?.document_type
  const isTextType = selectedDocType === 'essay' || selectedDocType === 'opinion'
  const zoomIndex = ZOOM_STEPS.indexOf(zoom)
  const canZoomOut = zoomIndex > 0
  const canZoomIn = zoomIndex < ZOOM_STEPS.length - 1

  // 브라우저 내장 뷰어의 다운로드·인쇄 버튼은 계속 숨기고(toolbar=0),
  // 배율만 URL 파라미터로 제어한다. iframe은 key를 바꿔 강제로 다시 그린다 —
  // 같은 문서에서 해시만 바뀌면 뷰어가 배율을 다시 적용하지 않기 때문이다.
  const framedUrl = viewUrl && !canvasMode ? `${viewUrl}#toolbar=0&navpanes=0&zoom=${zoom}` : null

  // pdf.js 모드: 서명 주소에서 파일을 한 번 받아 둔다. PDF가 아니면(사진 등) 그림으로 보여 준다.
  const [docFetchError, setDocFetchError] = useState(null)
  useEffect(() => {
    setDocBytes(null)
    setDocFetchError(null)
    if (!canvasMode || !viewUrl) return undefined
    let cancelled = false
    let imageUrl = null
    fetch(viewUrl)
      .then((res) => {
        if (!res.ok) throw new Error(`서버 응답 ${res.status}`)
        return res.blob()
      })
      .then(async (blob) => {
        const bytes = new Uint8Array(await blob.arrayBuffer())
        if (cancelled) return
        const isPdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 // %PDF
        if (isPdf) {
          setDocBytes({ kind: 'pdf', bytes })
        } else {
          imageUrl = URL.createObjectURL(blob)
          setDocBytes({ kind: 'image', imageUrl })
        }
      })
      .catch((err) => {
        if (!cancelled) setDocFetchError(err.message)
      })
    return () => {
      cancelled = true
      if (imageUrl) URL.revokeObjectURL(imageUrl)
    }
  }, [canvasMode, viewUrl])

  const canvasZoomIndex = CANVAS_ZOOM_STEPS.indexOf(canvasZoom)

  // 문서가 하나뿐이면 자동으로 열기
  useEffect(() => {
    if (!loadingList && documents.length === 1 && !selectedDocId) {
      openDocument(documents[0])
    }
  }, [loadingList, documents, selectedDocId, openDocument])

  return (
    <div className="flex h-full flex-col bg-surface-canvas">
      {/* 상단: 지금 누구를 보고 있고 전체 중 몇 번째인지 — 채점은 같은 화면을
          수십 번 반복하는 작업이라 "어디까지 했는지"가 항상 보여야 한다. */}
      <header className="flex shrink-0 items-center justify-between gap-2 border-b border-border bg-surface-card px-3 py-2 lg:gap-3 lg:px-5 lg:py-3">
        <div className="flex min-w-0 items-center gap-2 lg:gap-4">
          <Link
            to="/evaluation"
            className="shrink-0 rounded-md px-2 py-1 text-sm text-ink-muted hover:bg-surface-subtle hover:text-ink-secondary"
          >
            ← 목록
          </Link>
          <button type="button" onClick={() => setListOpen(!listOpen)}
            title={listOpen ? '지원자 목록 접기' : '지원자 목록 펴기'} aria-label={listOpen ? '지원자 목록 접기' : '지원자 목록 펴기'}
            className="hidden shrink-0 rounded-md border border-border px-2.5 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle lg:inline-block">
            {listOpen ? '◀ 접기' : '▶ 목록 펴기'}
          </button>
          <div className="min-w-0">
            <h1 className="flex min-w-0 items-center gap-2 text-base font-bold leading-tight text-ink-primary lg:text-xl">
              {currentRoster && (
                <span className="shrink-0 rounded-md bg-brand-greenSoft px-2 py-0.5 font-mono text-sm text-brand-deepGreenStrong">
                  {currentRoster.exam_no || currentRoster.receipt_no}
                </span>
              )}
              <span className="truncate">{applicantName || '지원자'}</span>
            </h1>
            {currentIndex >= 0 && (
              <div className="mt-1 flex items-center gap-2">
                <div className="hidden h-1.5 w-28 overflow-hidden rounded-full bg-surface-subtle sm:block">
                  <div
                    className="h-full rounded-full bg-brand-deepGreen transition-[width] duration-200"
                    style={{ width: `${((currentIndex + 1) / rosterOrder.length) * 100}%` }}
                  />
                </div>
                <span className="text-xs tabular-nums text-ink-muted">
                  {currentIndex + 1} / {rosterOrder.length}명
                </span>
              </div>
            )}
          </div>
        </div>

        <div className="flex shrink-0 items-center gap-1.5 lg:gap-2">
          <button
            type="button"
            disabled={!prevApplicant}
            onClick={() => prevApplicant && navigate(`/evaluation/documents/${prevApplicant.applicant_id}`)}
            title={prevApplicant ? `이전: ${prevApplicant.display_name}` : '첫 번째 지원자입니다'}
            aria-label="이전 지원자"
            className="min-h-10 rounded-lg border border-border px-3 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-30 lg:px-4"
          >
            ←<span className="hidden sm:inline"> 이전</span>
          </button>
          <button
            type="button"
            disabled={!nextApplicant}
            onClick={() => nextApplicant && navigate(`/evaluation/documents/${nextApplicant.applicant_id}`)}
            title={nextApplicant ? `다음: ${nextApplicant.display_name}` : '마지막 지원자입니다'}
            className="min-h-10 rounded-lg bg-brand-deepGreen px-3 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-30 lg:px-4"
          >
            다음<span className="hidden sm:inline"> 지원자</span> →
          </button>
        </div>
      </header>

      <div className="flex min-h-0 flex-1 flex-col overflow-hidden lg:flex-row">
        {/* 지원자 목록(넓은 화면, 접을 수 있음) */}
        {listOpen && rosterOrder.length > 0 && (
          <nav aria-label="지원자 목록" className="hidden w-52 shrink-0 overflow-y-auto border-r border-border bg-surface-card lg:block">
            <ul>
              {rosterOrder.map((r) => {
                const on = r.applicant_id === applicantId
                return (
                  <li key={r.applicant_id}>
                    <Link to={`/evaluation/documents/${r.applicant_id}`} aria-current={on ? 'page' : undefined}
                      className={`flex items-center gap-2 border-b border-border px-3 py-2 text-sm ${on ? 'bg-brand-greenSoft font-bold text-brand-deepGreenStrong' : 'text-ink-primary hover:bg-surface-subtle'}`}>
                      <span className="w-12 shrink-0 font-mono text-xs text-ink-muted">{r.exam_no || (r.receipt_no || '').slice(-4)}</span>
                      <span className="truncate">{r.display_name}</span>
                    </Link>
                  </li>
                )
              })}
            </ul>
          </nav>
        )}
        {/* ── 좌측: 서류 뷰어 ────────────────────────────────────────
            서류 선택을 세로 버튼 목록에서 가로 탭으로 바꿨다. 예전에는
            서류를 고르기 전까지 화면 대부분이 빈 회색이었고, 고르고 나면
            다른 서류로 넘어가려면 상단 드롭다운을 따로 찾아야 했다.
            탭으로 두면 "무엇이 있는지"와 "지금 무엇을 보는지"가 항상 보인다. */}
        <div
          className={`min-h-0 min-w-0 flex-1 flex-col lg:flex lg:border-r lg:border-border ${
            mobilePane === 'score' ? 'hidden' : 'flex'
          }`}
        >
          {documents.length > 0 && (
            <div className="flex items-center gap-2 border-b border-border bg-surface-card px-3 py-2">
              {/* 서류 탭 — 넘치면 가로 스크롤(접히지 않는다) */}
              <div className="flex min-w-0 flex-1 gap-1 overflow-x-auto">
                {documents.map((d) => {
                  const active = d.id === selectedDocId
                  return (
                    <button
                      key={d.id}
                      type="button"
                      onClick={() => openDocument(d)}
                      className={`shrink-0 rounded-lg px-3 py-2 text-sm transition-colors ${
                        active
                          ? 'bg-brand-deepGreen font-semibold text-white'
                          : 'text-ink-secondary hover:bg-surface-subtle'
                      }`}
                    >
                      {DOCUMENT_TYPE_LABEL[d.document_type] || d.document_type}
                    </button>
                  )
                })}
              </div>

              {/* 자기소개서·소견서: 원본 / 입력본 전환 */}
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

              {/* pdf.js 모드 확대·축소 (휴대폰·태블릿) */}
              {docBytes?.kind === 'pdf' && !(isTextType && textMode) && (
                <div className="flex shrink-0 items-center gap-1 border-l border-border pl-2">
                  <button
                    type="button"
                    disabled={canvasZoomIndex <= 0}
                    onClick={() => setCanvasZoom(CANVAS_ZOOM_STEPS[canvasZoomIndex - 1])}
                    className="h-9 w-9 rounded-md border border-border text-base font-semibold text-ink-secondary disabled:opacity-30"
                    aria-label="축소"
                  >
                    −
                  </button>
                  <button
                    type="button"
                    onClick={() => setCanvasZoom(1)}
                    className="min-w-[52px] rounded-md px-1 py-1 text-xs text-ink-secondary"
                    title="화면 너비에 맞추기"
                  >
                    {canvasZoom === 1 ? '맞춤' : `${Math.round(canvasZoom * 100)}%`}
                  </button>
                  <button
                    type="button"
                    disabled={canvasZoomIndex >= CANVAS_ZOOM_STEPS.length - 1}
                    onClick={() => setCanvasZoom(CANVAS_ZOOM_STEPS[canvasZoomIndex + 1])}
                    className="h-9 w-9 rounded-md border border-border text-base font-semibold text-ink-secondary disabled:opacity-30"
                    aria-label="확대"
                  >
                    +
                  </button>
                </div>
              )}

              {/* 확대·축소 — 기기마다 화면 크기가 달라 고정 배율로는 안 맞는다 (데스크톱 내장 뷰어) */}
              {framedUrl && (
                <div className="flex shrink-0 items-center gap-1 border-l border-border pl-2">
                  <button
                    type="button"
                    disabled={!canZoomOut}
                    onClick={() => setZoom(ZOOM_STEPS[zoomIndex - 1])}
                    className="h-8 w-8 rounded-md border border-border text-base font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30"
                    aria-label="축소"
                  >
                    −
                  </button>
                  <button
                    type="button"
                    onClick={() => setZoom('page-width')}
                    className="min-w-[72px] rounded-md px-2 py-1 text-xs text-ink-secondary hover:bg-surface-subtle"
                    title="화면 너비에 맞추기"
                  >
                    {ZOOM_LABEL[zoom] || `${zoom}%`}
                  </button>
                  <button
                    type="button"
                    disabled={!canZoomIn}
                    onClick={() => setZoom(ZOOM_STEPS[zoomIndex + 1])}
                    className="h-8 w-8 rounded-md border border-border text-base font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-30"
                    aria-label="확대"
                  >
                    +
                  </button>
                </div>
              )}
            </div>
          )}

          <div className="min-h-0 flex-1 bg-surface-subtle">
            {loadingList ? (
              <p className="p-6 text-sm text-ink-muted">불러오는 중…</p>
            ) : error ? (
              <p className="p-6 text-sm text-status-danger">{error}</p>
            ) : documents.length === 0 ? (
              <div className="flex h-full items-center justify-center p-10 text-center">
                <div>
                  <p className="text-base font-semibold text-ink-primary">아직 열람할 서류가 없습니다</p>
                  <p className="mt-2 max-w-sm text-sm text-ink-muted">
                    이 지원자의 서류가 아직 업로드되지 않았거나, 열람이 허용된 서류가 없습니다. 서류가
                    등록되면 이 화면에서 바로 확인할 수 있습니다.
                  </p>
                </div>
              </div>
            ) : isTextType && textMode ? (
              <TranscriptionView key={`${applicantId}-${selectedDocType}`} applicantId={applicantId} type={selectedDocType} year={YEAR} onShowOriginal={() => setTextMode(false)} />
            ) : loadingDoc ? (
              <p className="p-6 text-sm text-ink-muted">서류 불러오는 중…</p>
            ) : canvasMode && viewUrl ? (
              docFetchError ? (
                <p className="p-6 text-sm text-status-danger">서류를 받지 못했습니다: {docFetchError} — 서류 탭을 다시 눌러 주세요.</p>
              ) : !docBytes ? (
                <p className="p-6 text-sm text-ink-muted">서류 받는 중…</p>
              ) : docBytes.kind === 'image' ? (
                <div className="h-full w-full overflow-auto p-2">
                  <img src={docBytes.imageUrl} alt="평가서류" className="mx-auto max-w-full bg-white shadow-sm" />
                </div>
              ) : (
                <Suspense fallback={<p className="p-6 text-sm text-ink-muted">뷰어 준비 중…</p>}>
                  <PdfCanvasViewer key={selectedDocId} data={docBytes.bytes} zoom={canvasZoom} />
                </Suspense>
              )
            ) : framedUrl ? (
              <iframe
                // 배율이 바뀌면 key가 바뀌어 iframe이 새로 그려진다.
                key={`${selectedDocId}-${zoom}`}
                title="평가서류"
                src={framedUrl}
                className="h-full w-full"
              />
            ) : (
              <div className="flex h-full items-center justify-center p-10 text-center">
                <p className="text-sm text-ink-muted">위에서 열람할 서류를 선택하세요.</p>
              </div>
            )}
          </div>
        </div>

        {/* ── 우측: 채점 폼 ──────────────────────────────────────────
            폭을 넓혔다(384 → 440). 자기소개서는 채점 기준이 10개라
            이전 폭에서는 항목마다 줄바꿈이 생겨 읽기 어려웠다. */}
        <aside
          className={`flex min-h-0 flex-col border-t border-border bg-surface-card shadow-[0_-4px_12px_rgba(0,0,0,0.06)] lg:h-auto lg:w-[440px] lg:flex-none lg:shrink-0 lg:border-t-0 lg:shadow-none ${
            mobilePane === 'doc' ? 'shrink-0' : mobilePane === 'split' ? 'h-[52%] shrink-0' : 'flex-1'
          }`}
        >
          {/* 좁은 화면 전용: 보기 전환 막대. '서류만'일 때는 이 막대만 화면 맨 아래에 남는다. */}
          <div
            className="flex shrink-0 items-center gap-2 border-b border-border px-3 py-2 lg:hidden"
            style={mobilePane === 'doc' ? { paddingBottom: 'max(0.5rem, env(safe-area-inset-bottom))' } : undefined}
          >
            <span className="min-w-0 flex-1 truncate text-sm font-semibold text-ink-primary">
              채점{matchingForms.find((f) => f.key === activeFormKey) ? ` · ${matchingForms.find((f) => f.key === activeFormKey).label}` : ''}
            </span>
            <div role="radiogroup" aria-label="화면 보기 방식" className="flex shrink-0 rounded-lg bg-surface-subtle p-0.5">
              {MOBILE_PANES.map((p) => (
                <button
                  key={p.key}
                  type="button"
                  role="radio"
                  aria-checked={mobilePane === p.key}
                  onClick={() => chooseMobilePane(p.key)}
                  className={`min-h-9 rounded-md px-2.5 text-xs font-medium ${
                    mobilePane === p.key ? 'bg-surface-card text-brand-deepGreenStrong shadow-sm' : 'text-ink-muted'
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>
          </div>

          <div className={`min-h-0 flex-1 flex-col lg:flex ${mobilePane === 'doc' ? 'hidden' : 'flex'}`}>
          {matchingForms.length === 0 ? (
            <div className="p-4 lg:p-5">
              <EmptyState
                title="이 화면에서 채점할 서류가 없습니다"
                description="모둠활동·면접·글쓰기 평가는 심층역량평가 메뉴의 각 채점 화면에서 진행합니다. 이 화면은 출결·학업·공동체활동·자기소개서·학부모소견서 서류평가 전용입니다."
              />
            </div>
          ) : (
            <>
              {matchingForms.length > 1 && (
                // 탭이 5개까지 늘어나면 예전 flex-wrap에서는 두 줄로 접혀
                // 채점 영역을 잡아먹었다. 가로 스크롤로 바꿔 한 줄을 유지한다.
                <div className="flex shrink-0 gap-1 overflow-x-auto border-b border-border px-3 pt-3">
                  {matchingForms.map((f) => (
                    <button
                      key={f.key}
                      type="button"
                      onClick={() => setActiveFormKey(f.key)}
                      className={`shrink-0 whitespace-nowrap rounded-t-lg px-3 py-2 text-sm transition-colors ${
                        activeFormKey === f.key
                          ? 'border-b-2 border-brand-deepGreen bg-brand-greenSoft font-semibold text-brand-deepGreenStrong'
                          : 'text-ink-muted hover:bg-surface-subtle'
                      }`}
                    >
                      {f.label}
                    </button>
                  ))}
                </div>
              )}
              <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-4 lg:p-5">
                {matchingForms.map((f) =>
                  f.key === activeFormKey ? <f.Form key={f.key} applicantId={applicantId} /> : null,
                )}
              </div>
            </>
          )}
          </div>
        </aside>
      </div>
    </div>
  )
}
