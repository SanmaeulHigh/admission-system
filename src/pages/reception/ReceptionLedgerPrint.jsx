// 원서 접수대장 인쇄 (2026-10-12)
//
// 예전 엑셀 접수대장을 대신하는 결재용 출력물. A4 가로, 표 머리는 쪽마다 반복된다.
// 오른쪽 위 결재란: 담당 · 부장 · 교장.
// 연락처·주소 같은 개인정보는 넣지 않는다(결재·보관용이라 필요 최소한만).
// 인쇄 요소에는 tabular-nums를 쓰지 않는다(PDF 저장 시 숫자가 사라지는 문제).

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { APPLICATION_STATUS_LABEL, METHOD_LABEL, roundToText } from '../../lib/applicantLabels'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { getScheduleForDashboard, formatMonthDay } from '../../config/printNotices'
import schoolLogo from '../../assets/school-logo.png'
import ApprovalBox from '../../components/print/ApprovalBox'

const TRACK_SHORT = { none: '일반', incheon: '일반+인천추천', social: '일반+사회통합' }
const DOCS = [
  { type: 'photo', label: '사진' },
  { type: 'studentRecordSource', label: '학생부' },
  { type: 'essay', label: '자소서' },
  { type: 'opinion', label: '소견서' },
]

function specialTrack(tracks) {
  const t = tracks || []
  return t.includes('incheon') ? 'incheon' : t.includes('social') ? 'social' : 'none'
}

function fmtDate(v) {
  if (!v) return ''
  const d = new Date(v)
  return `${d.getMonth() + 1}. ${d.getDate()}.`
}

export default function ReceptionLedgerPrint() {
  const { year, round } = useAdmissionCycle()
  const [applicants, setApplicants] = useState(null)
  const [docs, setDocs] = useState(new Map())
  const [error, setError] = useState(null)
  const [includeOut, setIncludeOut] = useState(true)
  const [order, setOrder] = useState('receipt') // receipt | exam

  useEffect(() => {
    if (!year || !round) return
    let active = true
    ;(async () => {
      const [appRes, docRes] = await Promise.all([
        supabase
          .from('applicants')
          .select('id, receipt_no, exam_no, name, tracks, academic_status, school, receipt_method, registered_mail_no, reception_note, receipt_date, application_status, applicants_private(gender, birth_date)')
          .eq('year', year)
          .eq('round', round)
          .order('receipt_no'),
        supabase
          .from('admission_documents')
          .select('applicant_id, document_type')
          .eq('year', year)
          .eq('round', round)
          .eq('active', true),
      ])
      if (!active) return
      if (appRes.error) {
        setError(appRes.error.message)
        return
      }
      const m = new Map()
      ;(docRes.data || []).forEach((d) => {
        if (!m.has(d.applicant_id)) m.set(d.applicant_id, new Set())
        m.get(d.applicant_id).add(d.document_type)
      })
      setDocs(m)
      setApplicants(appRes.data || [])
    })()
    return () => { active = false }
  }, [year, round])

  const list = useMemo(() => {
    const base = (applicants || []).filter((a) => includeOut || !['withdrawn', 'excluded'].includes(a.application_status))
    if (order === 'exam') {
      return [...base].sort((x, y) => {
        if (!x.exam_no !== !y.exam_no) return x.exam_no ? -1 : 1
        return (x.exam_no || x.receipt_no).localeCompare(y.exam_no || y.receipt_no, 'ko', { numeric: true })
      })
    }
    return base
  }, [applicants, includeOut, order])

  const summary = useMemo(() => {
    const active = (applicants || []).filter((a) => !['withdrawn', 'excluded'].includes(a.application_status))
    const count = (k) => active.filter((a) => specialTrack(a.tracks) === k).length
    return {
      total: active.length,
      none: count('none'),
      incheon: count('incheon'),
      social: count('social'),
      out: (applicants || []).length - active.length,
      visit: active.filter((a) => a.receipt_method === 'V').length,
      mail: active.filter((a) => a.receipt_method === 'M').length,
    }
  }, [applicants])

  const receiptPeriod = useMemo(() => {
    const row = getScheduleForDashboard(year, round)?.find((r) => r.label.includes('접수'))
    return row ? `${formatMonthDay(row.start)} ~ ${formatMonthDay(row.end)}` : null
  }, [year, round])


  const th = 'border border-black px-1 py-1 text-center font-semibold'
  const td = 'border border-black px-1 py-[3px] text-center whitespace-nowrap overflow-hidden'

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-6 print:min-h-0 print:bg-white print:p-0">
      {/* 이 화면만 A4 가로, 쪽 번호 */}
      <style>{`
        @media print {
          @page { size: A4 landscape; margin: 10mm 10mm 12mm; @bottom-center { content: counter(page) " / " counter(pages); font-size: 8pt; } }
          .ledger-table thead { display: table-header-group; }
          .ledger-table tr { break-inside: avoid; }
        }
      `}</style>

      <div className="mx-auto w-fit">
        <div className="mb-4 space-y-3 print:hidden" style={{ maxWidth: '277mm' }}>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">← 지원자 목록</Link>
            <button type="button" onClick={() => window.print()} disabled={!applicants}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
              접수대장 인쇄
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-4 rounded-lg border border-border bg-white px-4 py-3 text-sm text-ink-secondary">
            <label className="flex items-center gap-2">
              정렬
              <select value={order} onChange={(e) => setOrder(e.target.value)} className="rounded-md border border-border px-2 py-1">
                <option value="receipt">접수번호 순</option>
                <option value="exam">수험번호 순</option>
              </select>
            </label>
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={includeOut} onChange={(e) => setIncludeOut(e.target.checked)} />
              철회·제외 지원자도 싣기 (상태 칸에 표시)
            </label>
            <span className="text-xs text-ink-muted">A4 가로로 인쇄됩니다. 인쇄 창에서 배율은 ‘기본값’으로 두세요.</span>
          </div>
          {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
        </div>

        {/* ── 인쇄 본문 ── */}
        <div className="min-w-[277mm] bg-white p-6 text-black shadow-sm print:min-w-0 print:p-0 print:shadow-none" style={{ fontSize: '9pt' }}>
          <div className="mb-3 flex items-start justify-between gap-6">
            <div className="flex items-start gap-3 pt-2">
              <img src={schoolLogo} alt="새봄고등학교" style={{ height: '16mm', width: 'auto' }} />
              <div>
              <h1 className="text-[16pt] font-bold tracking-tight">
                {year}학년도 새봄고등학교 신입생 입학전형 원서 접수대장
              </h1>
              <p className="mt-1 text-[10pt]">
                {roundToText(round)}
                {receiptPeriod && ` · 원서 접수 기간 ${receiptPeriod}`}
              </p>
              <p className="mt-1 text-[9pt]">
                지원자 {summary.total}명 (일반 {summary.none} · 일반+인천추천 {summary.incheon} · 일반+사회통합 {summary.social})
                {' · '}방문 {summary.visit} · 우편 {summary.mail}
                {summary.out > 0 && ` · 철회·제외 ${summary.out}명 별도`}
              </p>
              </div>
            </div>
            {/* 결재란 */}
            <ApprovalBox />
          </div>

          <table className="ledger-table w-full border-collapse" style={{ tableLayout: 'fixed' }}>
            <colgroup>
              <col style={{ width: '8mm' }} />
              <col style={{ width: '21mm' }} />
              <col style={{ width: '15mm' }} />
              <col style={{ width: '16mm' }} />
              <col style={{ width: '8mm' }} />
              <col style={{ width: '18mm' }} />
              <col style={{ width: '23mm' }} />
              <col style={{ width: '24mm' }} />
              <col style={{ width: '14mm' }} />
              <col style={{ width: '10mm' }} />
              <col style={{ width: '26mm' }} />
              <col style={{ width: '12mm' }} />
              {DOCS.map((d) => <col key={d.type} style={{ width: '13mm' }} />)}
              <col style={{ width: '13mm' }} />
              <col />
            </colgroup>
            <thead>
              <tr className="bg-[#EFEFEF]">
                <th rowSpan={2} className={th}>연번</th>
                <th rowSpan={2} className={th}>접수번호</th>
                <th rowSpan={2} className={th}>수험번호</th>
                <th rowSpan={2} className={th}>성명</th>
                <th rowSpan={2} className={th}>성별</th>
                <th rowSpan={2} className={th}>생년월일</th>
                <th rowSpan={2} className={th}>지원 전형</th>
                <th rowSpan={2} className={th}>출신 중학교</th>
                <th rowSpan={2} className={th}>학적</th>
                <th rowSpan={2} className={th}>접수<br />방법</th>
                <th rowSpan={2} className={th}>등기번호</th>
                <th rowSpan={2} className={th}>접수일</th>
                <th colSpan={DOCS.length} className={th}>제출 서류</th>
                <th rowSpan={2} className={th}>상태</th>
                <th rowSpan={2} className={th}>비고</th>
              </tr>
              <tr className="bg-[#EFEFEF]">
                {DOCS.map((d) => <th key={d.type} className={`${th} whitespace-nowrap text-[8pt]`}>{d.label}</th>)}
              </tr>
            </thead>
            <tbody>
              {applicants && list.length === 0 && (
                <tr><td colSpan={14 + DOCS.length} className={`${td} py-6`}>접수된 지원자가 없습니다.</td></tr>
              )}
              {list.map((a, i) => {
                const p = Array.isArray(a.applicants_private) ? a.applicants_private[0] : a.applicants_private
                const has = docs.get(a.id) || new Set()
                const out = ['withdrawn', 'excluded'].includes(a.application_status)
                return (
                  <tr key={a.id} className={out ? 'text-[#666]' : ''}>
                    <td className={td}>{i + 1}</td>
                    <td className={`${td} font-mono text-[8.5pt]`}>{a.receipt_no}</td>
                    <td className={`${td} font-mono`}>{a.exam_no || ''}</td>
                    <td className={`${td} font-semibold ${out ? 'line-through' : ''}`}>{a.name}</td>
                    <td className={td}>{p?.gender || ''}</td>
                    <td className={`${td} font-mono text-[8.5pt]`}>{p?.birth_date || ''}</td>
                    <td className={td}>{TRACK_SHORT[specialTrack(a.tracks)]}</td>
                    <td className={`${td} truncate`}>{a.academic_status === '검정고시' ? '(검정고시)' : (a.school || '')}</td>
                    <td className={td}>{a.academic_status}</td>
                    <td className={td}>{a.receipt_method === 'M' ? '우편' : METHOD_LABEL[a.receipt_method] || ''}</td>
                    <td className={`${td} font-mono text-[8.5pt]`}>{a.receipt_method === 'M' ? (a.registered_mail_no || '') : ''}</td>
                    <td className={td}>{fmtDate(a.receipt_date)}</td>
                    {DOCS.map((d) => <td key={d.type} className={td}>{has.has(d.type) ? '○' : ''}</td>)}
                    <td className={td}>{APPLICATION_STATUS_LABEL[a.application_status] || ''}</td>
                    <td className={`${td} whitespace-normal text-left`}>{a.reception_note || ''}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
          {/* 인쇄자·시각은 모든 쪽 아래 오른쪽 여백에 찍힌다(PrintStamp) */}
        </div>
      </div>
    </div>
  )
}
