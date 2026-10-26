// 지원자 목록 (접수대장)
//
// 2026-10-12 재구성 (사용자 피드백 반영 2차):
//  - 표는 엑셀처럼 보고 고르고 복사(Ctrl+C)하는 용도. 칸에 바로 입력하는 방식은 뺐다.
//  - 신규 접수는 종전처럼 "+ 신규 접수" 양식으로 한다.
//  - 수정은 줄을 더블클릭(또는 Enter)해 여는 "지원자 정보" 창에서 한다.
//    창 위쪽에 접수증·수험표·서류 관리·삭제 버튼을 모았다.
//  - 우편 접수 등기번호·비고 열 추가(00081), 접수대장 인쇄(/reception/ledger).

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import RegisterApplicantForm from './RegisterApplicantForm'
import ScanFirstIntake from './ScanFirstIntake'
import DocumentUploadForm from './DocumentUploadForm'
import DocumentListPanel from './DocumentListPanel'
import ExamNoSmsPanel from './ExamNoSmsPanel'
import DestructiveActionDialog from '../../components/actions/DestructiveActionDialog'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import { useAuth } from '../../contexts/AuthContext'
import ChangeReceiptDateDialog from './ChangeReceiptDateDialog'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import ApplicantGrid from './applicantGrid/ApplicantGrid'
import { COLUMNS, STATUS_OPTIONS, displayText, sortValue, toRow } from './applicantGrid/columns'

// 지원 전형 → 접수번호 전형코드(00067). 접수번호 7번째 글자와 다르면 번호를 다시 매겨야 한다.
function trackCodeOf(tracks) {
  const t = tracks || []
  return t.includes('incheon') ? 'I' : t.includes('social') ? 'U' : 'G'
}

const TABS = [
  { key: 'all', label: '전체', match: (s) => s !== 'withdrawn' && s !== 'excluded' },
  { key: 'received', label: '접수 처리 중', match: (s) => s === 'received' },
  { key: 'incomplete', label: '서류 확인 필요', match: (s) => s === 'incomplete' },
  { key: 'complete', label: '접수 완료', match: (s) => s === 'complete' },
  { key: 'out', label: '철회·제외', match: (s) => s === 'withdrawn' || s === 'excluded' },
]

export default function ReceptionPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const { hasAnyRole } = useAuth()
  const canAssignExamNo = hasAnyRole(['superadmin', 'admin'])

  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(null)

  const [tab, setTab] = useState('all')
  const [search, setSearch] = useState('')
  const [filters, setFilters] = useState({})
  const [sort, setSort] = useState({ key: 'exam_no', dir: 'asc' })
  const [selectedIds, setSelectedIds] = useState(() => new Set())
  const [activeInfo, setActiveInfo] = useState(null)
  const [focusRequest, setFocusRequest] = useState(null)
  const [message, setMessage] = useState(null) // { tone: 'error'|'info', text }
  const [bulkBusy, setBulkBusy] = useState(false)

  const [showForm, setShowForm] = useState(false)
  const [lastReceipt, setLastReceipt] = useState(null)
  const [exporting, setExporting] = useState(false)
  const [examDialog, setExamDialog] = useState(null)
  const [examAssigning, setExamAssigning] = useState(false)
  const [examError, setExamError] = useState(null)
  const [examNotice, setExamNotice] = useState(null)
  const [showExamSms, setShowExamSms] = useState(false)
  const [openRow, setOpenRow] = useState(null) // 지원자 정보 창
  const [dateTarget, setDateTarget] = useState(null) // 접수일 바꾸기
  const [renumbering, setRenumbering] = useState(false)

  // 전형을 고친 뒤 접수번호의 전형코드 다시 맞추기(00101)
  const renumberForTracks = async (row) => {
    // eslint-disable-next-line no-alert
    const reason = window.prompt(`${row.name}: 지금 전형에 맞게 접수번호를 다시 매깁니다(같은 접수일, 새 전형의 다음 순번).\n지금 번호 ${row.receipt_no}는 더 쓰지 않습니다.\n\n사유를 적어 주세요.`, '접수 시 전형 체크 누락')
    if (reason == null) return
    setRenumbering(true)
    const { data, error } = await supabase.rpc('renumber_receipt_for_tracks', { p_applicant_id: row.id, p_reason: reason })
    setRenumbering(false)
    if (error) {
      setMessage({ tone: 'error', text: error.message })
      return
    }
    setOpenRow(null)
    setMessage({ tone: 'info', text: `${row.name}: 접수번호 ${data.oldReceiptNo} → ${data.receiptNo}로 바뀌었습니다. 접수증·화일 표지를 다시 출력하세요.` })
    load().then(() => setFocusRequest({ id: row.id, at: Date.now() }))
  }
  const [uploadTarget, setUploadTarget] = useState(null)
  const [documentRefreshKey, setDocumentRefreshKey] = useState(0)
  const [deleteTarget, setDeleteTarget] = useState(null)
  const [deleting, setDeleting] = useState(false)
  const [deleteError, setDeleteError] = useState(null)
  const formRef = useRef(null)

  // ───────── 불러오기 ─────────
  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoadError(null)
    const [appRes, docRes] = await Promise.all([
      supabase
        .from('applicants')
        .select('*, applicants_private(*)')
        .eq('year', YEAR)
        .eq('round', ROUND)
        .order('receipt_no', { ascending: true }),
      supabase
        .from('admission_documents')
        .select('applicant_id, document_type')
        .eq('year', YEAR)
        .eq('round', ROUND)
        .eq('active', true),
    ])
    if (appRes.error) {
      setLoadError(appRes.error.message)
      setLoading(false)
      return
    }
    const docs = new Map()
    ;(docRes.data || []).forEach((d) => {
      if (!docs.has(d.applicant_id)) docs.set(d.applicant_id, new Set())
      docs.get(d.applicant_id).add(d.document_type)
    })
    setRows((appRes.data || []).map((a) => toRow(a, docs.get(a.id))))
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  // ───────── 보이는 줄 ─────────
  const tabCounts = useMemo(() => {
    const counts = {}
    TABS.forEach((t) => { counts[t.key] = rows.filter((r) => t.match(r.application_status)).length })
    return counts
  }, [rows])

  const visibleRows = useMemo(() => {
    const tabDef = TABS.find((t) => t.key === tab) || TABS[0]
    const q = search.trim().toLowerCase()
    const list = rows.filter((r) => {
      if (!tabDef.match(r.application_status)) return false
      for (const [key, set] of Object.entries(filters)) {
        const col = COLUMNS.find((c) => c.key === key)
        if (!set.has(displayText(r, col) || '(빈 칸)')) return false
      }
      if (!q) return true
      return [r.name, r.receipt_no, r.exam_no, r.school, r.guardian_name, r.applicant_phone, r.guardian_phone, r.registered_mail_no, r.reception_note]
        .some((v) => (v || '').toLowerCase().includes(q))
    })
    const col = COLUMNS.find((c) => c.key === sort.key) || COLUMNS[0]
    const sign = sort.dir === 'asc' ? 1 : -1
    return [...list].sort((x, y) => {
      const vx = sortValue(x, col)
      const vy = sortValue(y, col)
      if ((vx === null) !== (vy === null)) return vx === null ? 1 : -1 // 빈 값은 늘 아래
      if (vx !== null) {
        const c = typeof vx === 'number' ? vx - vy : String(vx).localeCompare(String(vy), 'ko', { numeric: true })
        if (c !== 0) return c * sign
      }
      return x.receipt_no.localeCompare(y.receipt_no, 'ko', { numeric: true })
    })
  }, [rows, tab, filters, search, sort])

  const onSort = useCallback((key) => setSort((cur) => (cur.key === key ? { key, dir: cur.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' })), [])
  const onFilterChange = useCallback((key, set) => setFilters((f) => {
    const n = { ...f }
    if (set) n[key] = set
    else delete n[key]
    return n
  }), [])

  // ───────── 선택 ─────────
  const toggleSelect = useCallback((id) => setSelectedIds((s) => {
    const n = new Set(s)
    if (n.has(id)) n.delete(id)
    else n.add(id)
    return n
  }), [])
  const toggleAll = useCallback((on) => setSelectedIds((s) => {
    const n = new Set(s)
    visibleRows.forEach((r) => (on ? n.add(r.id) : n.delete(r.id)))
    return n
  }), [visibleRows])

  const bulkStatus = async (value) => {
    if (!value) return
    const ids = [...selectedIds]
    const label = STATUS_OPTIONS.find((o) => o.value === value)?.label
    // eslint-disable-next-line no-alert
    if (!window.confirm(`선택한 ${ids.length}명의 상태를 '${label}'(으)로 바꿉니다.`)) return
    setBulkBusy(true)
    const failed = []
    for (const id of ids) {
      // eslint-disable-next-line no-await-in-loop
      const { error } = await supabase.rpc('update_application_status', { p_applicant_id: id, p_new_status: value })
      if (error) failed.push(`${rows.find((r) => r.id === id)?.name}: ${error.message}`)
    }
    setBulkBusy(false)
    setMessage(failed.length
      ? { tone: 'error', text: `${ids.length - failed.length}명 변경, ${failed.length}명 실패\n${failed.slice(0, 4).join('\n')}` }
      : { tone: 'info', text: `${ids.length}명의 상태를 '${label}'(으)로 바꿨습니다.` })
    setSelectedIds(new Set())
    load()
  }

  // ───────── 기타 작업 ─────────
  const handleDelete = async (reason) => {
    setDeleteError(null)
    setDeleting(true)
    const { error } = await supabase.rpc('delete_applicant', { p_applicant_id: deleteTarget.id, p_reason: reason })
    setDeleting(false)
    if (error) {
      setDeleteError(error.message)
      return
    }
    setDeleteTarget(null)
    setOpenRow(null)
    load()
  }

  const runAssignExamNumbers = async () => {
    setExamError(null)
    setExamAssigning(true)
    const { data, error } = await supabase.rpc('assign_exam_numbers', { p_year: YEAR, p_round: ROUND, p_reassign: examDialog === 'reassign' })
    setExamAssigning(false)
    if (error) {
      setExamError(error.message)
      return
    }
    setExamDialog(null)
    setExamNotice(
      data?.assigned
        ? `수험번호 ${data.assigned}명 부여 완료 (${data.first} ~ ${data.last}). 지침상 접수 마감 후 3일 이내에 지원자에게 안내해야 합니다.`
        : '부여할 지원자가 없습니다.',
    )
    load()
  }

  const handleExport = async () => {
    setExporting(true)
    try {
      const { exportApplicantsXlsx } = await import('../../lib/exportApplicantsXlsx')
      await exportApplicantsXlsx({ year: YEAR, round: ROUND })
    } catch (err) {
      setMessage({ tone: 'error', text: `내보내기 실패: ${err.message}` })
    } finally {
      setExporting(false)
    }
  }

  const activeCount = tabCounts.all ?? 0
  const hasExamNo = rows.some((r) => r.exam_no)
  const filterCount = Object.keys(filters).length
  const outlineBtn = 'rounded-lg border border-brand-deepGreen bg-surface-card px-3 py-2 text-sm font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-50'
  const plainBtn = 'rounded-lg border border-border bg-surface-card px-3 py-2 text-sm font-semibold text-ink-secondary hover:border-brand-deepGreen disabled:opacity-50'

  // 표가 화면 가로·세로를 꽉 채우도록 이 화면만 넓은 틀(fullBleed)을 쓴다
  return (
    <div className="flex h-full min-h-[640px] flex-col px-4 py-4 sm:px-5">
      {/* 제목 + 작업 버튼 */}
      <div className="mb-3 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-ink-primary">지원자</h1>
          <p className="text-sm text-ink-muted">
            {YEAR}학년도 {roundToText(ROUND)} · 지원자 {activeCount}명
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={handleExport} disabled={exporting || rows.length === 0} className={plainBtn}>
            {exporting ? '만드는 중…' : '엑셀로 내보내기'}
          </button>
          <Link to="/reception/ledger" className={plainBtn}>접수대장 인쇄</Link>
          <Link to="/reception/bulletin" className={plainBtn}>접수 일보</Link>
          <Link to="/reception/daily" className={plainBtn}>일자별 접수 현황</Link>
          {canAssignExamNo && (
            <button type="button" className={outlineBtn} disabled={rows.length === 0}
              onClick={() => { setExamError(null); setExamDialog(hasExamNo ? 'reassign' : 'assign') }}
              title="원서 접수 마감 후 성명 가나다순으로 수험번호를 부여합니다">
              {hasExamNo ? '수험번호 재부여' : '수험번호 일괄 부여'}
            </button>
          )}
          {canAssignExamNo && hasExamNo && (
            <button type="button" className={outlineBtn} onClick={() => setShowExamSms(true)}>수험번호 안내 문자</button>
          )}
          {canAssignExamNo && hasExamNo && (
            <Link to="/reception/exam-tickets" className={outlineBtn}>수험표 일괄 인쇄</Link>
          )}
          <button type="button"
            onClick={() => { setShowForm((v) => !v); setTimeout(() => formRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 50) }}
            className="rounded-lg bg-brand-deepGreen px-3 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong">
            {showForm ? '접수 양식 닫기' : '+ 신규 접수'}
          </button>
        </div>
      </div>

      {examNotice && (
        <div className="mb-3 flex items-center justify-between gap-3 rounded-lg bg-brand-greenSoft px-4 py-2.5 text-sm text-brand-deepGreenStrong">
          <span>{examNotice}</span>
          <button type="button" className="text-xs text-ink-muted underline" onClick={() => setExamNotice(null)}>닫기</button>
        </div>
      )}
      {showExamSms && <ExamNoSmsPanel year={YEAR} round={ROUND} onClose={() => setShowExamSms(false)} />}

      <TypedConfirmDialog
        open={Boolean(examDialog)}
        title={examDialog === 'reassign' ? '수험번호를 다시 매기시겠습니까?' : '수험번호를 부여하시겠습니까?'}
        description={
          examDialog === 'reassign'
            ? '기존 수험번호를 모두 지우고 성명 가나다순으로 다시 매깁니다. 이미 지원자에게 안내한 번호가 있다면 전부 다시 안내해야 합니다. 1단계 사정이 확정된 뒤에는 재부여할 수 없습니다.'
            : '원서 접수 지침에 따라 지원 전형과 상관없이 성명 가나다순으로 부여합니다(동명이인은 접수번호 순). 접수가 모두 마감된 뒤에 실행하세요. 철회·제외된 지원자는 제외됩니다.'
        }
        fields={[
          { label: '대상 회차', value: `${YEAR}학년도 ${roundToText(ROUND)}` },
          { label: '대상 인원', value: `${activeCount}명` },
          { label: '번호 형식', value: `A${ROUND === 'main' ? '1' : ROUND === 'extra1' ? '2' : '3'}001 부터` },
        ]}
        confirmPhrase={examDialog === 'reassign' ? '수험번호 재부여' : '수험번호 부여'}
        confirmLabel={examDialog === 'reassign' ? '재부여' : '부여'}
        onConfirm={runAssignExamNumbers}
        onCancel={() => setExamDialog(null)}
        submitting={examAssigning}
        error={examError}
      />

      {lastReceipt && (
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg bg-brand-greenSoft px-4 py-2.5 text-sm">
          <span>
            접수 완료 — 접수번호 <strong className="font-mono">{lastReceipt.receiptNo}</strong>
            <span className="ml-2 text-xs text-ink-muted">수험번호는 원서 접수 마감 후 일괄 부여됩니다</span>
            {lastReceipt.savedDocCount > 0 && <span className="ml-2 text-xs text-brand-deepGreenStrong">· 스캔 서류 {lastReceipt.savedDocCount}개 저장</span>}
            {lastReceipt.failedDocs?.length > 0 && (
              <span className="mt-1 block text-xs text-status-danger">
                저장하지 못한 서류: {lastReceipt.failedDocs.join(', ')} — 지원자 상세 → 서류 관리에서 다시 올려 주세요.
              </span>
            )}
          </span>
          <div className="flex items-center gap-3">
            <Link to={`/reception/receipt/${lastReceipt.applicantId}`} className="text-xs font-semibold text-brand-deepGreenStrong underline">접수증 출력</Link>
            <Link to={`/reception/folder-cover/${lastReceipt.applicantId}`} className="text-xs font-semibold text-brand-deepGreenStrong underline">화일 표지 출력</Link>
            <button type="button" className="text-xs text-ink-muted underline" onClick={() => setLastReceipt(null)}>닫기</button>
          </div>
        </div>
      )}

      {showForm && (
        <div ref={formRef} className="mb-5 rounded-xl border border-border bg-surface-card p-5">
          <h2 className="mb-1 text-base font-semibold text-ink-primary">신규 접수</h2>
          <p className="mb-4 text-xs text-ink-muted">① 서류를 스캔해 올리고 → ② 스캔한 원서를 보며 입력하면 → ③ 접수번호가 매겨지고 서류가 함께 저장됩니다.</p>
          {/* 2026-10-20: 스캔 먼저 접수(ScanFirstIntake). '스캔 없이 바로 입력'으로 예전처럼 입력만 할 수도 있다. */}
          <ScanFirstIntake
            year={YEAR}
            round={ROUND}
            onRegistered={(result) => {
              setLastReceipt(result)
              setShowForm(false)
              load().then(() => result?.applicantId && setFocusRequest({ id: result.applicantId, at: Date.now() }))
            }}
            onCancel={() => setShowForm(false)}
          />
        </div>
      )}

      {/* 상태 탭 */}
      <div className="mb-2 flex flex-wrap gap-1 border-b border-border" role="tablist" aria-label="접수 상태">
        {TABS.map((t) => {
          const on = tab === t.key
          return (
            <button key={t.key} type="button" role="tab" aria-selected={on} onClick={() => setTab(t.key)}
              className={`-mb-px whitespace-nowrap border-b-2 px-3.5 py-2 text-sm font-semibold ${on ? 'border-brand-deepGreen text-brand-deepGreenStrong' : 'border-transparent text-ink-muted hover:text-ink-primary'}`}>
              {t.label}
              <span className={`ml-1.5 inline-block min-w-[22px] rounded-full px-1.5 text-xs tabular-nums ${on ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-surface-subtle text-ink-secondary'}`}>
                {tabCounts[t.key] ?? 0}
              </span>
            </button>
          )
        })}
      </div>

      {/* 칸 주소·내용 + 찾기 + 선택 작업 */}
      <div className="flex flex-wrap items-center gap-2 rounded-t-xl border border-b-0 border-border bg-surface-card px-2.5 py-2">
        <span className="min-w-[56px] rounded-md border border-border bg-surface-subtle px-2 py-1 text-center font-mono text-xs text-ink-secondary" aria-label="고른 칸">
          {activeInfo?.address || '—'}
        </span>
        <input
          readOnly
          value={activeInfo && activeInfo.col.kind !== 'docs' ? String(displayText(activeInfo.row, activeInfo.col)) : ''}
          placeholder="칸을 고르면 내용이 여기에 보입니다 · 고치려면 줄을 더블클릭"
          aria-label="고른 칸 내용"
          className="min-w-[200px] flex-1 rounded-md border border-border bg-surface-subtle/50 px-2 py-1 text-sm text-ink-primary"
        />
        <span className="h-5 w-px bg-border" aria-hidden="true" />
        <input
          type="search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="이름·번호·학교·연락처·등기번호 찾기"
          aria-label="지원자 찾기"
          className="w-64 rounded-md border border-border px-2 py-1 text-sm"
        />
        {filterCount > 0 && (
          <button type="button" onClick={() => setFilters({})} className="rounded-md bg-brand-deepGreen px-2 py-1 text-xs font-semibold text-white">
            거르기 {filterCount}개 해제
          </button>
        )}
        {selectedIds.size > 0 && (
          <div className="flex items-center gap-1.5 rounded-lg border border-[#CFE6C0] bg-brand-greenSoft px-2 py-1 text-xs font-semibold text-brand-deepGreenStrong">
            {selectedIds.size}명 선택
            <select value="" disabled={bulkBusy} onChange={(e) => bulkStatus(e.target.value)} aria-label="선택한 지원자 상태 바꾸기"
              className="rounded-md border border-border bg-white px-1.5 py-0.5 text-xs text-ink-secondary">
              <option value="">{bulkBusy ? '바꾸는 중…' : '상태 바꾸기…'}</option>
              {STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
            <button type="button" onClick={() => setSelectedIds(new Set())} className="rounded-md border border-border bg-white px-1.5 py-0.5 text-ink-secondary">선택 해제</button>
          </div>
        )}
      </div>

      {message && (
        <div role={message.tone === 'error' ? 'alert' : 'status'}
          className={`flex items-start justify-between gap-3 border border-b-0 border-border px-3 py-2 text-sm ${message.tone === 'error' ? 'bg-status-dangerSoft text-status-danger' : 'bg-brand-blueSoft text-brand-blue'}`}>
          <span className="whitespace-pre-line">{message.text}</span>
          <button type="button" className="shrink-0 text-xs underline opacity-80" onClick={() => setMessage(null)}>닫기</button>
        </div>
      )}

      <div className={`min-h-[420px] flex-1 ${showForm ? 'h-[70vh] flex-none' : ''}`}>
        {loading ? (
          <p className="h-full border border-border bg-surface-card p-6 text-center text-sm text-ink-muted">불러오는 중…</p>
        ) : loadError ? (
          <p className="h-full border border-border bg-surface-card p-6 text-center text-sm text-status-danger">{loadError}</p>
        ) : (
          <ApplicantGrid
            rows={visibleRows}
            allRows={rows}
            sort={sort}
            onSort={onSort}
            filters={filters}
            onFilterChange={onFilterChange}
            selectedIds={selectedIds}
            onToggleSelect={toggleSelect}
            onToggleAll={toggleAll}
            onOpenRow={setOpenRow}
            onActiveChange={setActiveInfo}
            focusRequest={focusRequest}
          />
        )}
      </div>

      {/* 상태줄 */}
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-b-xl border border-t-0 border-border bg-[#F4F6F3] px-3 py-1.5 text-xs text-ink-secondary">
        <span>
          보이는 줄 <b className="text-ink-primary">{visibleRows.length}</b> · 선택 <b className="text-ink-primary">{selectedIds.size}</b> · 서류 확인 필요 <b className="text-ink-primary">{tabCounts.incomplete ?? 0}</b>
        </span>
        <span className="text-ink-muted">
          줄 더블클릭·Enter = 지원자 정보(수정) · Shift+방향키/드래그 = 여러 칸 · Ctrl+C = 엑셀로 복사 · Space = 체크
        </span>
      </div>

      {/* 지원자 정보 창 (수정) */}
      {openRow && (
        <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:p-8" role="dialog" aria-modal="true" aria-labelledby="applicant-info-title">
          <div className="w-full max-w-3xl rounded-xl bg-surface-card shadow-xl">
            <div className="sticky top-0 z-10 rounded-t-xl border-b border-border bg-surface-card px-6 py-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 id="applicant-info-title" className="text-lg font-bold text-ink-primary">{openRow.name}</h2>
                  <p className="font-mono text-xs text-ink-muted">
                    {openRow.receipt_no} · {openRow.exam_no || '수험번호 미부여'}
                  </p>
                </div>
                <button type="button" onClick={() => setOpenRow(null)} className="rounded-lg border border-border px-3 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle">닫기</button>
              </div>
              {!openRow.exam_no && /^\d{6}[GIUMV]\d{3}$/.test(openRow.receipt_no || '')
                && openRow.receipt_no[6] !== trackCodeOf(openRow.raw?.tracks) && (
                <div className="mt-3 flex flex-wrap items-center gap-2 rounded-lg border border-status-warning bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
                  <span>
                    접수번호 전형코드(<b>{openRow.receipt_no[6]}</b>)가 지금 지원 전형(<b>{trackCodeOf(openRow.raw?.tracks)}</b>)과 다릅니다.
                  </span>
                  {hasAnyRole(['superadmin', 'admin']) ? (
                    <button type="button" disabled={renumbering} onClick={() => renumberForTracks(openRow)}
                      className="rounded-md bg-status-warning px-3 py-1 text-xs font-semibold text-white disabled:opacity-50">
                      {renumbering ? '바꾸는 중…' : '접수번호 다시 매기기'}
                    </button>
                  ) : <span className="text-xs">관리자에게 접수번호 재부여를 요청하세요.</span>}
                </div>
              )}
              <div className="mt-3 flex flex-wrap gap-2">
                <Link to={`/reception/receipt/${openRow.id}`} className={plainBtn}>접수증</Link>
                <Link to={`/reception/exam-ticket/${openRow.id}`} className={plainBtn}>수험표</Link>
                <Link to={`/reception/folder-cover/${openRow.id}`} className={plainBtn}>화일 표지</Link>
                <Link to={`/reception/transcriptions/${openRow.id}/essay`} className={plainBtn}>자소서 입력</Link>
                <Link to={`/reception/transcriptions/${openRow.id}/opinion`} className={plainBtn}>소견서 입력</Link>
                {hasAnyRole(['superadmin', 'admin']) && !openRow.exam_no && (
                  <button type="button" className={plainBtn}
                    onClick={() => setDateTarget({ id: openRow.id, name: openRow.name, receiptNo: openRow.receipt_no, receiptDate: openRow.receipt_date })}>
                    접수일 바꾸기
                  </button>
                )}
                <button type="button" className={plainBtn} onClick={() => setUploadTarget({ id: openRow.id, receiptNo: openRow.receipt_no, name: openRow.name })}>
                  서류 관리 (사진·학생부·자소서…)
                </button>
                <button type="button"
                  onClick={() => { setDeleteTarget({ id: openRow.id, receiptNo: openRow.receipt_no, name: openRow.name }); setDeleteError(null) }}
                  className="ml-auto rounded-lg border border-status-danger px-3 py-2 text-sm font-semibold text-status-danger hover:bg-status-dangerSoft">
                  지원자 삭제
                </button>
              </div>
            </div>
            <div className="p-6">
              <RegisterApplicantForm
                key={openRow.id}
                mode="edit"
                applicantId={openRow.id}
                initialData={openRow.raw}
                onCancel={() => setOpenRow(null)}
                onSaved={() => {
                  const id = openRow.id
                  setOpenRow(null)
                  setMessage({ tone: 'info', text: `${openRow.name} 정보를 저장했습니다.` })
                  load().then(() => setFocusRequest({ id, at: Date.now() }))
                }}
              />
            </div>
          </div>
        </div>
      )}

      {uploadTarget && (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/40 p-4">
          <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-xl bg-surface-card p-6">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="text-base font-semibold text-ink-primary">
                서류 관리 — {uploadTarget.name ? `${uploadTarget.name} · ` : ''}{uploadTarget.receiptNo}
              </h3>
              <button type="button" onClick={() => { setUploadTarget(null); load() }} className="text-sm text-ink-muted hover:text-ink-primary">닫기</button>
            </div>
            <div className="mb-5">
              <DocumentListPanel applicantId={uploadTarget.id} refreshKey={documentRefreshKey} />
            </div>
            <div className="border-t border-border pt-4">
              <h4 className="mb-3 text-sm font-semibold text-ink-primary">새 서류 올리기</h4>
              <DocumentUploadForm applicantId={uploadTarget.id} receiptNo={uploadTarget.receiptNo} onUploaded={() => setDocumentRefreshKey((k) => k + 1)} />
            </div>
          </div>
        </div>
      )}

      {dateTarget && (
        <ChangeReceiptDateDialog
          applicant={dateTarget}
          onClose={() => setDateTarget(null)}
          onChanged={(res) => {
            const id = dateTarget.id
            setDateTarget(null)
            setOpenRow(null)
            setMessage({ tone: 'info', text: `${dateTarget.name}: 접수번호 ${res.oldReceiptNo} → ${res.receiptNo}로 바뀌었습니다. 접수증·화일 표지를 다시 출력하세요.` })
            load().then(() => setFocusRequest({ id, at: Date.now() }))
          }}
        />
      )}

      <DestructiveActionDialog
        open={Boolean(deleteTarget)}
        title="지원자 삭제 — 되돌릴 수 없습니다"
        description={deleteTarget && `${deleteTarget.receiptNo} · ${deleteTarget.name}의 접수·서류·채점 데이터가 전부 삭제됩니다. 최종 사정이 끝난 지원자는 삭제할 수 없습니다.`}
        reasonLabel="삭제 사유 (필수, 5자 이상)"
        reasonMinLength={5}
        reasonPlaceholder="예: 테스트로 잘못 등록함 / 지원자 요청으로 접수 취소"
        confirmLabel="삭제 실행"
        submitting={deleting}
        error={deleteError}
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
      />
    </div>
  )
}
