// L자 화일 표지 (2026-10-21) — 접수한 입학원서 원본을 넣은 L자 화일 겉에 클립으로 고정
//
// 크기: A4 절반(A5 가로, 210×148mm). A4 용지 위쪽 절반에 인쇄되고 가운데 점선을 따라 자른다.
// 화일 겉에 드러나므로 생년월일·연락처는 넣지 않는다(접수번호·성명·전형·출신교·접수일만).
// 서류 칸: '원본'은 손으로 체크, '스캔'은 시스템에 올라간 서류를 자동 표시.

import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { METHOD_LABEL, tracksToText } from '../../lib/applicantLabels'
import schoolLogo from '../../assets/school-logo.png'
import QrCode from '../../components/print/QrCode'

const DOCS = [
  { type: 'applicationForm', label: '입학원서' },
  { type: 'photo', label: '사진' },
  { type: 'studentRecordSource', label: '학교생활기록부' },
  { type: 'essay', label: '자기소개서' },
  { type: 'opinion', label: '학부모 소견서' },
  { type: 'consent', label: '개인정보 동의서' },
  { type: 'trackEvidence', label: '전형 자격 증빙(해당자)' },
]

function fmtDateTime(value) {
  if (!value) return '-'
  const d = new Date(value)
  const opt = { timeZone: 'Asia/Seoul' }
  const date = new Intl.DateTimeFormat('ko-KR', { ...opt, year: 'numeric', month: 'numeric', day: 'numeric' }).format(d)
  const weekday = new Intl.DateTimeFormat('ko-KR', { ...opt, weekday: 'short' }).format(d)
  const time = new Intl.DateTimeFormat('ko-KR', { ...opt, hour: '2-digit', minute: '2-digit', hour12: false }).format(d)
  return `${date}(${weekday}) ${time}`
}

export default function FolderCoverPrint() {
  const { applicantId } = useParams()
  const [applicant, setApplicant] = useState(null)
  const [scanned, setScanned] = useState(null) // Set<document_type> | null(조회 불가)
  const [error, setError] = useState(null)

  useEffect(() => {
    let active = true
    async function load() {
      const { data, error: err } = await supabase
        .from('applicants')
        .select('id, year, round, receipt_no, exam_no, name, tracks, school, academic_status, receipt_date, receipt_method')
        .eq('id', applicantId)
        .maybeSingle()
      if (!active) return
      if (err) { setError(err.message); return }
      if (!data) { setError('지원자를 찾을 수 없습니다.'); return }
      setApplicant(data)
      const { data: docs, error: docErr } = await supabase
        .from('admission_documents')
        .select('document_type')
        .eq('applicant_id', applicantId)
        .eq('active', true)
      if (!active) return
      setScanned(docErr ? null : new Set((docs || []).map((d) => d.document_type)))
    }
    load()
    return () => { active = false }
  }, [applicantId])

  if (error) return <p className="p-10 text-center text-status-danger">{error}</p>
  if (!applicant) return <p className="p-10 text-center text-ink-muted">불러오는 중…</p>

  const printedAt = fmtDateTime(new Date())

  return (
    <div className="min-h-screen bg-surface-canvas p-8 print:min-h-0 print:bg-white print:p-0">
      <style>{'@media print { @page { size: A4 portrait; margin: 0 } html, body { margin: 0 !important; padding: 0 !important; background: #fff !important } }'}</style>

      <div className="mx-auto mb-4 flex max-w-[210mm] flex-wrap items-center justify-between gap-2 print:hidden">
        <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">← 지원자 목록</Link>
        <button type="button" onClick={() => window.print()} className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong">
          표지 인쇄
        </button>
        <p className="w-full text-xs text-ink-muted">
          A4 용지 위쪽 절반에 인쇄됩니다. 인쇄 창에서 용지 A4·세로, 배율 100%, 여백 &lsquo;없음&rsquo;으로 두고 가운데 점선을 따라 자르세요.
        </p>
      </div>

      <FolderCoverSheet applicant={applicant} scanned={scanned} printedAt={printedAt} />
    </div>
  )
}

// A4 한 장(210×297) — 위쪽 절반이 표지, 아래는 비워 둔다
export function FolderCoverSheet({ applicant, scanned, printedAt }) {
  return (
  <div className="mx-auto bg-white shadow print:shadow-none" style={{ width: '210mm', height: '296mm', position: 'relative', overflow: 'hidden' }}>
    <div style={{ position: 'absolute', left: 0, top: 0, width: '210mm', height: '148.5mm', padding: '10mm 12mm' }}>
      <div className="flex h-full flex-col rounded-[3mm] border-[0.6mm] border-ink-primary px-[6mm] py-[5mm] text-ink-primary">
        {/* 머리 */}
        <div className="flex items-center gap-3 border-b-[0.5mm] border-ink-primary pb-[3mm]">
          <img src={schoolLogo} alt="" style={{ height: '11mm' }} />
          <div className="flex-1">
            <p className="text-[9pt] text-ink-secondary">새봄고등학교 {applicant.year}학년도 신입생 입학전형</p>
            <p className="text-[15pt] font-bold tracking-[0.15em]">입학원서 원본 보관 표지</p>
          </div>
          {applicant.receipt_no && <QrCode value={applicant.receipt_no} sizeMm={16} showText={false} />}
        </div>

        <div className="mt-[4mm] flex flex-1 gap-[6mm]">
          {/* 왼쪽: 번호·성명·기본 정보 */}
          <div className="flex flex-[1.35] flex-col">
            <div className="flex gap-[4mm]">
              <div className="flex-1 rounded-[2mm] bg-surface-subtle px-[4mm] py-[2.5mm]">
                <p className="text-[8.5pt] text-ink-secondary">접수번호</p>
                <p className="font-mono text-[24pt] font-bold leading-tight tracking-wide">{applicant.receipt_no}</p>
              </div>
              <div className="w-[38mm] rounded-[2mm] border-[0.4mm] border-dashed border-ink-secondary px-[3mm] py-[2.5mm]">
                <p className="text-[8.5pt] text-ink-secondary">수험번호</p>
                <p className="font-mono text-[18pt] font-bold leading-tight">{applicant.exam_no || ''}</p>
              </div>
            </div>

            <div className="mt-[3mm] flex items-baseline gap-[4mm] px-[1mm]">
              <span className="text-[9pt] text-ink-secondary">성명</span>
              <span className="text-[26pt] font-extrabold tracking-[0.2em]">{applicant.name}</span>
            </div>

            <table className="mt-[2mm] w-full text-[10pt]">
              <tbody>
                <InfoRow label="지원 전형" value={tracksToText(applicant.tracks)} />
                <InfoRow label="출신 중학교" value={applicant.school || applicant.academic_status || '-'} />
                <InfoRow label="접수일" value={fmtDateTime(applicant.receipt_date).replace(/\s\d{2}:\d{2}$/, '')} />
                <InfoRow label="접수방법" value={METHOD_LABEL[applicant.receipt_method] || '-'} />
              </tbody>
            </table>
          </div>

          {/* 오른쪽: 서류 확인 */}
          <div className="flex flex-1 flex-col">
            <table className="w-full border-collapse text-[9pt]">
              <thead>
                <tr className="bg-surface-subtle">
                  <th className="border border-ink-secondary px-[2mm] py-[1mm] text-left font-semibold">제출 서류</th>
                  <th className="w-[11mm] border border-ink-secondary py-[1mm] font-semibold">원본</th>
                  <th className="w-[11mm] border border-ink-secondary py-[1mm] font-semibold">스캔</th>
                </tr>
              </thead>
              <tbody>
                {DOCS.map((d) => (
                  <tr key={d.type}>
                    <td className="border border-ink-secondary px-[2mm] py-[0.9mm]">{d.label}</td>
                    <td className="border border-ink-secondary text-center" />
                    <td className="border border-ink-secondary text-center font-bold">{scanned?.has(d.type) ? '✓' : ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="mt-[2.5mm] flex-1 rounded-[1.5mm] border border-ink-secondary px-[2mm] py-[1mm]">
              <p className="text-[8.5pt] text-ink-secondary">비고 · 확인자</p>
            </div>
          </div>
        </div>

        <div className="mt-[3mm] flex justify-between text-[7.5pt] text-ink-muted">
          <span>개인정보가 담긴 서류입니다 — 잠금 보관, 외부 반출 금지</span>
          <span>출력 {printedAt}</span>
        </div>
      </div>
    </div>

    {/* 자르는 선 */}
    <div style={{ position: 'absolute', left: 0, top: '148.5mm', width: '210mm', borderTop: '0.3mm dashed #9AA39D' }} />
    <p style={{ position: 'absolute', right: '6mm', top: '149.5mm', fontSize: '7pt', color: '#9AA39D' }}>✂ 자르는 선</p>
  </div>
  )
}

function InfoRow({ label, value }) {
  return (
    <tr className="border-b border-border">
      <th className="w-[24mm] py-[1.3mm] text-left font-medium text-ink-secondary">{label}</th>
      <td className="py-[1.3mm]">{value}</td>
    </tr>
  )
}
