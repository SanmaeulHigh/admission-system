// 결재용 접수대장 XLSX 내보내기 (스펙 1230행 "결재용 접수대장 XLSX/PDF:
// 기존 27컬럼 구조 재현" 대응)
//
// 실제 기존 종이/엑셀 접수대장 원본을 아직 확보하지 못해, 스펙과 데이터
// 모델(3.5/3.6)을 기준으로 28개 컬럼을 구성했다. 기존 서식과 다르면
// 이 파일의 COLUMNS 배열만 조정하면 된다 — 구조를 다른 곳과 결합하지
// 않아 컬럼 추가/삭제/순서변경이 국소적으로 끝난다.
//
// Cloud Function 없이 브라우저에서 직접 워크북을 만들어 다운로드한다
// (접수증 PDF와 동일한 원칙 — Blaze 없는 이 프로젝트 제약과 맞음).

import ExcelJS from 'exceljs/dist/exceljs.min.js'
import { supabase } from './supabase'
import { logExport } from './exportAudit'
import {
  tracksToText,
  METHOD_LABEL,
  APPLICATION_STATUS_LABEL,
  EVALUATION_STAGE_LABEL,
  REGISTRATION_STATUS_LABEL,
} from './applicantLabels'

// 28개 컬럼 정의. header: 표시명, width: 열 너비, get: 행 데이터 → 셀 값.
const COLUMNS = [
  { header: '연번', width: 6, get: (_, i) => i + 1 },
  { header: '접수번호', width: 14, get: (a) => a.receipt_no },
  { header: '성명', width: 10, get: (a) => a.name },
  { header: '성별', width: 6, get: (a) => a.private?.gender || '' },
  { header: '생년월일', width: 12, get: (a) => a.private?.birth_date || '' },
  { header: '지원전형', width: 20, get: (a) => tracksToText(a.tracks) },
  { header: '가산대상', width: 8, get: (a) => (a.bonus_eligible === true ? 'O' : a.bonus_eligible === false ? 'X' : '미확인') },
  { header: '가산사유', width: 16, get: (a) => a.bonus_reason || '' },
  { header: '학적상태', width: 10, get: (a) => a.academic_status },
  { header: '출신중학교', width: 16, get: (a) => a.school || '' },
  { header: '학년반번호', width: 12, get: (a) => a.grade_class_no || '' },
  { header: '반영학기', width: 10, get: (a) => a.semester_choice || '' },
  { header: '접수방법', width: 10, get: (a) => METHOD_LABEL[a.receipt_method] || a.receipt_method },
  { header: '등기번호', width: 18, get: (a) => a.registered_mail_no || '' },
  { header: '접수일자', width: 12, get: (a) => new Date(a.receipt_date).toLocaleDateString('ko-KR') },
  { header: '접수시각', width: 10, get: (a) => new Date(a.receipt_date).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' }) },
  { header: '지원자휴대전화', width: 16, get: (a) => a.private?.applicant_phone || '' },
  { header: '지원자자택전화', width: 16, get: (a) => a.private?.applicant_landline || '' },
  { header: '지원자이메일', width: 20, get: (a) => a.private?.email || '' },
  { header: '지원자주소', width: 28, get: (a) => a.private?.address || '' },
  { header: '보호자성명', width: 10, get: (a) => a.private?.guardian_name || '' },
  { header: '보호자관계', width: 8, get: (a) => a.private?.guardian_relation || '' },
  { header: '보호자휴대전화', width: 16, get: (a) => a.private?.guardian_phone || '' },
  { header: '보호자주소', width: 28, get: (a) => a.private?.guardian_address || '' },
  { header: '접수상태', width: 10, get: (a) => APPLICATION_STATUS_LABEL[a.application_status] || a.application_status },
  { header: '서류평가단계', width: 12, get: (a) => EVALUATION_STAGE_LABEL[a.evaluation_stage] || a.evaluation_stage },
  { header: '등록상태', width: 10, get: (a) => REGISTRATION_STATUS_LABEL[a.registration_status] || a.registration_status },
  { header: '비고', width: 24, get: (a) => a.reception_note || '' },
]

/**
 * 접수대장 XLSX를 조회해 만든 뒤 브라우저 다운로드를 트리거한다.
 * @param {{year:number, round:string}} params
 */
export async function exportApplicantsXlsx({ year, round }) {
  const { data: applicants, error } = await supabase
    .from('applicants')
    .select('*, applicants_private(*)')
    .eq('year', year)
    .eq('round', round)
    .order('receipt_no', { ascending: true })

  if (error) throw error
  if (!applicants || applicants.length === 0) {
    throw new Error('내보낼 접수 데이터가 없습니다.')
  }

  // applicants_private(*)는 Supabase가 1:1 관계여도 배열로 반환할 수 있어 평탄화
  const rows = applicants.map((a) => ({
    ...a,
    private: Array.isArray(a.applicants_private) ? a.applicants_private[0] : a.applicants_private,
  }))

  const workbook = new ExcelJS.Workbook()
  workbook.creator = '새봄 입학'
  workbook.created = new Date()

  const sheet = workbook.addWorksheet(`${year}_${round}_접수대장`, {
    views: [{ state: 'frozen', ySplit: 1 }], // 헤더 행 고정
    pageSetup: { orientation: 'landscape', fitToPage: true, fitToWidth: 1 },
  })

  sheet.columns = COLUMNS.map((c) => ({ header: c.header, width: c.width }))

  const headerRow = sheet.getRow(1)
  headerRow.eachCell((cell) => {
    cell.font = { bold: true }
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE6EDE0' } }
    cell.alignment = { vertical: 'middle', horizontal: 'center' }
    cell.border = borderAll()
  })

  rows.forEach((a, i) => {
    const values = COLUMNS.map((c) => c.get(a, i))
    const row = sheet.addRow(values)
    row.eachCell((cell) => {
      cell.border = borderAll()
      cell.alignment = { vertical: 'middle' }
    })
  })

  const buffer = await workbook.xlsx.writeBuffer()

  await logExport({
    year,
    round,
    exportType: 'receiptLedger',
    fileFormat: 'xlsx',
    content: buffer,
    rowCount: rows.length,
  })

  const blob = new Blob([buffer], {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  const dateStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  a.href = url
  a.download = `${year}_${round}_접수대장_${dateStamp}.xlsx`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)

  return rows.length
}

function borderAll() {
  const style = { style: 'thin', color: { argb: 'FFCCCCCC' } }
  return { top: style, left: style, bottom: style, right: style }
}
