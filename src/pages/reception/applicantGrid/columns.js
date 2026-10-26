// 지원자 목록(엑셀형 표)의 열 정의 (2026-10-12)
//
// 표는 보기·고르기·복사 전용이다. 수정은 줄을 더블클릭해 여는 지원자 정보 창에서
// 한다(사용자 피드백: 칸에 바로 입력하는 방식은 불편, 데이터 긁기는 유용).

import { APPLICATION_STATUS_LABEL, METHOD_LABEL } from '../../../lib/applicantLabels'

const TRACK_LABEL = { none: '일반', incheon: '일반+인천추천', social: '일반+사회통합' }

export const STATUS_OPTIONS = ['received', 'incomplete', 'complete', 'withdrawn', 'excluded'].map((v) => ({
  value: v,
  label: APPLICATION_STATUS_LABEL[v],
}))

// 서류 칸에 보여줄 4종(사진·학생부·자소서·소견서)
export const DOC_MARKS = [
  { type: 'photo', label: '사진' },
  { type: 'studentRecordSource', label: '학생부' },
  { type: 'essay', label: '자소서' },
  { type: 'opinion', label: '소견서' },
]

export function formatReceiptDate(v) {
  return v ? new Date(v).toLocaleDateString('ko-KR', { month: 'numeric', day: 'numeric' }) : ''
}

// kind: text | docs | status
export const COLUMNS = [
  { key: 'exam_no', label: '수험번호', mono: true, width: 100, sortable: true, frozen: true },
  { key: 'name', label: '성명', width: 110, sortable: true, frozen: true, bold: true },
  { key: 'receipt_no', label: '접수번호', mono: true, width: 120, sortable: true },
  { key: 'special_track', label: '지원 전형', width: 136, filter: true, sortable: true, get: (r) => TRACK_LABEL[r.special_track] },
  { key: 'academic_status', label: '학적', width: 92, filter: true, sortable: true },
  { key: 'receipt_method', label: '접수 방법', width: 104, filter: true, get: (r) => METHOD_LABEL[r.receipt_method] || r.receipt_method },
  { key: 'registered_mail_no', label: '등기번호', mono: true, width: 150 },
  { key: 'gender', label: '성별', width: 70, filter: true },
  { key: 'birth_date', label: '생년월일', mono: true, width: 112, sortable: true },
  { key: 'school', label: '출신 중학교', width: 150, filter: true, sortable: true },
  { key: 'grade_class_no', label: '학년-반-번호', mono: true, width: 104 },
  { key: 'applicant_phone', label: '학생 휴대전화', mono: true, width: 136 },
  { key: 'guardian_name', label: '보호자', width: 88 },
  { key: 'guardian_relation', label: '관계', width: 66 },
  { key: 'guardian_phone', label: '보호자 휴대전화', mono: true, width: 136 },
  { key: 'docs', label: '서류 (사진·학생부·자소서·소견서)', kind: 'docs', width: 124 },
  { key: 'receipt_date', label: '접수일', width: 88, sortable: true, get: (r) => formatReceiptDate(r.receipt_date) },
  { key: 'application_status', label: '상태', kind: 'status', width: 100, filter: true, sortable: true, get: (r) => APPLICATION_STATUS_LABEL[r.application_status] },
  { key: 'reception_note', label: '비고', width: 200 },
]

// 화면·복사용 글자
export function displayText(row, col) {
  if (col.kind === 'docs') return DOC_MARKS.filter((d) => row.docs?.has(d.type)).map((d) => d.label).join(',')
  if (col.get) return col.get(row) ?? ''
  return row[col.key] ?? ''
}

// 정렬 기준값
export function sortValue(row, col) {
  if (col.key === 'receipt_date') return row.receipt_date ? new Date(row.receipt_date).getTime() : null
  const t = displayText(row, col)
  return t === '' ? null : t
}

// DB에서 읽은 지원자 1명 → 표의 한 줄
export function toRow(applicant, docTypes) {
  const p = Array.isArray(applicant.applicants_private) ? applicant.applicants_private[0] : applicant.applicants_private
  const tracks = applicant.tracks || ['general']
  return {
    id: applicant.id,
    exam_no: applicant.exam_no,
    name: applicant.name,
    receipt_no: applicant.receipt_no,
    special_track: tracks.includes('incheon') ? 'incheon' : tracks.includes('social') ? 'social' : 'none',
    academic_status: applicant.academic_status,
    receipt_method: applicant.receipt_method,
    registered_mail_no: applicant.registered_mail_no ?? null,
    gender: p?.gender ?? '',
    birth_date: p?.birth_date ?? null,
    school: applicant.school,
    grade_class_no: applicant.grade_class_no,
    applicant_phone: p?.applicant_phone ?? null,
    guardian_name: p?.guardian_name ?? null,
    guardian_relation: p?.guardian_relation ?? null,
    guardian_phone: p?.guardian_phone ?? null,
    docs: docTypes || new Set(),
    receipt_date: applicant.receipt_date,
    application_status: applicant.application_status,
    reception_note: applicant.reception_note ?? null,
    raw: applicant,
  }
}
