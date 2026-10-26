// 서류평가 5개 영역(출결·학업성실도·공동체·자기소개서·학부모소견서) 대리 입력용 표 모델 (2026-10-01)
//
// 심층역량평가용 deepModel.js와 같은 모양을 쓴다:
//   buildDocumentModel(area, ctx, applicantInfo) → { columns, rows }
//   planDocumentRow(area, columns, row, draft, evaluatorUid) → { status, calls, message }
// 저장은 기존 admin_submit_*_score(00064)를 그대로 호출한다 — 서버가 대상 위원 명의로
// 원래 submit_*_score를 실행하므로 계산·검증·감사 기록이 한 명씩 입력할 때와 같다.
//
// 열(column) 형식: { key, label, group?, kind, values?, min?, max?, hint? }
//   kind: 'enum'(values 중 하나) | 'int'(min~max 정수) | 'text' | 'flag'('O' 또는 빈칸)
//         | 'academic'(학업성실도 과목 점수: 성취도 A~E 또는 검정고시 원점수 0~100)

import { REASON_CODE, isBlank } from './deepModel'

export const DOCUMENT_AREAS = [
  { value: 'attendance', label: '출결' },
  { value: 'academic', label: '학업성실도' },
  { value: 'community', label: '공동체생활적합성' },
  { value: 'essay', label: '자기소개서' },
  { value: 'opinion', label: '학부모 소견서' },
]

const ESSAY_CRITERIA = [
  ['admissionWill', '① 입학의지'],
  ['selfUnderstanding', '② 자기이해'],
  ['schoolUnderstanding', '③ 학교이해'],
  ['schoolAdaptation', '④ 학교적응'],
  ['learningWill', '⑤ 배움의지'],
  ['serviceWill', '⑥ 봉사의지'],
  ['communityLife', '⑦ 공동체 생활'],
  ['careerConnection', '⑧ 진로 연계'],
  ['sincerity', '⑨ 글의 진지성·구체성'],
  ['feasibility', '⑩ 실현가능성·잠재력'],
]

const OPINION_CRITERIA = [
  ['altEducationUnderstanding', '① 대안교육 이해'],
  ['schoolUnderstanding', '② 학교 이해'],
  ['childUnderstanding', '③ 자녀 이해'],
  ['childCareerView', '④ 자녀 진로관'],
  ['admissionWillParticipation', '⑤ 입학의지 및 참여의지'],
]

export const ACADEMIC_SUBJECT_SLOTS = 8
const ACHIEVEMENTS = ['A', 'B', 'C', 'D', 'E']
export const INPUT_TYPE_LABEL = { regular: '성취도', ged: '원점수' }
const INPUT_TYPE_FROM_LABEL = { 성취도: 'regular', 원점수: 'ged' }

const range = (from, to, step = 1) => {
  const out = []
  for (let v = from; v <= to + 1e-9; v += step) out.push(Number(v.toFixed(2)))
  return out
}

// 원서 학적 → 입력 유형(학업성실도 화면과 같은 규칙). 알 수 없으면 null.
function typeFromStatus(status) {
  if (status === '검정고시') return 'ged'
  if (status === '졸업예정' || status === '졸업') return 'regular'
  return null
}

function semesterLabel(v) {
  const m = /^([1-3])-([12])$/.exec(String(v || ''))
  return m ? `${m[1]}학년 ${m[2]}학기` : v || ''
}

function columnsFor(area) {
  if (area === 'attendance') {
    return [
      { key: 'unexcused', label: '미인정 결석(일)', kind: 'int', min: 0, max: 365 },
      { key: 'tardyEtc', label: '미인정 지각·조퇴·결과 합계(회)', kind: 'int', min: 0, max: 999 },
      { key: 'noRecord', label: '출결 기록 없음', kind: 'flag', hint: '기록이 없으면 O, 나머지 칸은 비움' },
    ]
  }
  if (area === 'academic') {
    const cols = [
      { key: 'inputType', label: '입력 유형', kind: 'enum', values: ['성취도', '원점수'], hint: '원서 학적에서 자동. 졸업(예정)=성취도, 검정고시=원점수' },
    ]
    for (let i = 1; i <= ACADEMIC_SUBJECT_SLOTS; i += 1) {
      cols.push({ key: `s${i}name`, label: `과목${i}`, group: `과목 ${i}`, kind: 'text' })
      cols.push({ key: `s${i}value`, label: `점수${i}`, group: `과목 ${i}`, kind: 'academic', hint: '성취도 A~E 또는 원점수 0~100' })
    }
    cols.push({ key: 'noDocument', label: '서류 없음', kind: 'flag', hint: '성적 서류가 없으면 O, 과목 칸은 비움' })
    return cols
  }
  if (area === 'community') {
    return [
      { key: 'grade', label: '등급(1~5)', kind: 'enum', values: [1, 2, 3, 4, 5], hint: '1등급 100 · 2등급 90 · 3등급 75 · 4등급 60 · 5등급 40' },
      { key: 'memo', label: '근거 메모(10자 이상)', kind: 'text' },
    ]
  }
  if (area === 'essay') {
    return ESSAY_CRITERIA.map(([key, label]) => ({ key, label, kind: 'enum', values: range(0, 10) }))
  }
  // opinion
  return [
    ...OPINION_CRITERIA.map(([key, label]) => ({ key, label, kind: 'enum', values: range(0, 5, 0.5) })),
    { key: 'contradiction', label: '감점: 내용 모순', kind: 'flag' },
    { key: 'omittedSensitiveInfo', label: '감점: 민감정보 누락', kind: 'flag' },
  ]
}

// applicantInfo: applicantId → { academicStatus, semesterChoice } (학업성실도에서만 사용)
export function buildDocumentModel(area, ctx, applicantInfo = {}) {
  if (!ctx) return { columns: [], rows: [] }
  const columns = columnsFor(area)
  const rows = (ctx.items || []).map((item) => {
    const info = applicantInfo[item.applicantId] || {}
    const fixedType = area === 'academic' ? typeFromStatus(info.academicStatus) : null
    const sub = area === 'academic'
      ? [info.academicStatus, info.semesterChoice ? `반영 ${semesterLabel(info.semesterChoice)}` : null].filter(Boolean).join(' · ')
      : ''
    return {
      id: item.applicantId,
      applicantId: item.applicantId,
      examNo: item.examNo,
      name: item.displayName,
      sub,
      fixedType,
      // 양식에 미리 채워 둘 값(학업성실도 입력 유형)
      prefill: fixedType ? { inputType: INPUT_TYPE_LABEL[fixedType] } : {},
      server: item.submissionState === 'submitted' ? (item.serverComputed || {}) : null,
    }
  })
  return { columns, rows }
}

function num(raw) {
  const n = Number(String(raw).trim())
  return Number.isFinite(n) ? n : NaN
}

function isFlag(raw) {
  return ['O', 'o', 'ㅇ', '○', 'Y', 'y', '1', 'TRUE', 'true', '예'].includes(String(raw ?? '').trim())
}

function flagValid(raw) {
  return isBlank(raw) || isFlag(raw)
}

// 칸 하나가 형식에 맞는지(빈칸은 맞는 것으로 본다 — 빈칸 판정은 행 단위에서)
export function documentCellValid(col, raw) {
  if (isBlank(raw)) return true
  if (col.kind === 'flag') return flagValid(raw)
  if (col.kind === 'text') return true
  if (col.kind === 'int') {
    const n = num(raw)
    return Number.isInteger(n) && n >= col.min && n <= col.max
  }
  if (col.kind === 'enum') {
    const s = String(raw).trim()
    return col.values.some((v) => String(v) === s || (typeof v === 'number' && Math.abs(v - num(s)) < 1e-9))
  }
  if (col.kind === 'academic') {
    const s = String(raw).trim().toUpperCase()
    if (ACHIEVEMENTS.includes(s)) return true
    const n = num(s)
    return Number.isFinite(n) && n >= 0 && n <= 100
  }
  return true
}

function call(rpc, label, row, evaluatorUid, args) {
  return {
    rpc,
    label,
    args: {
      p_applicant_id: row.applicantId,
      p_target_evaluator_uid: evaluatorUid,
      ...args,
      p_reason_code: REASON_CODE,
      p_reason_text: null,
    },
  }
}

export function planDocumentRow(area, columns, row, draft, evaluatorUid) {
  if (row.server) return { status: 'done', calls: [] }
  const cells = { ...(row.prefill || {}), ...(draft || {}) }
  // 미리 채운 값(입력 유형)만 있고 나머지가 비었으면 '빈 행'으로 본다.
  const userCols = columns.filter((c) => !(c.key in (row.prefill || {})))
  if (userCols.every((c) => isBlank(cells[c.key]))) return { status: 'empty', calls: [] }
  const bad = columns.find((c) => !documentCellValid(c, cells[c.key]))
  if (bad) return { status: 'invalid', calls: [], message: `${bad.label}: 허용되지 않는 값` }

  if (area === 'attendance') {
    if (isFlag(cells.noRecord)) {
      if (!isBlank(cells.unexcused) || !isBlank(cells.tardyEtc)) {
        return { status: 'invalid', calls: [], message: '기록 없음(O)이면 결석·지각 칸은 비워야 함' }
      }
      return { status: 'ready', calls: [call('admin_submit_attendance_score', '출결', row, evaluatorUid, { p_unexcused_absences: null, p_tardy_early_result_count: null, p_no_record: true })] }
    }
    if (isBlank(cells.unexcused) || isBlank(cells.tardyEtc)) return { status: 'partial', calls: [], message: '결석·지각 두 칸 모두 필요(없으면 0)' }
    return {
      status: 'ready',
      calls: [call('admin_submit_attendance_score', '출결', row, evaluatorUid, {
        p_unexcused_absences: num(cells.unexcused),
        p_tardy_early_result_count: num(cells.tardyEtc),
        p_no_record: false,
      })],
    }
  }

  if (area === 'academic') {
    const type = INPUT_TYPE_FROM_LABEL[String(cells.inputType ?? '').trim()]
    if (!type) return { status: 'partial', calls: [], message: '입력 유형(성취도/원점수) 필요' }
    if (row.fixedType && row.fixedType !== type) {
      return { status: 'invalid', calls: [], message: `원서 학적상 ${INPUT_TYPE_LABEL[row.fixedType]}로 입력해야 함` }
    }
    if (isFlag(cells.noDocument)) {
      return { status: 'ready', calls: [call('admin_submit_academic_score', '학업성실도', row, evaluatorUid, { p_input_type: type, p_subjects: [], p_no_document: true })] }
    }
    const subjects = []
    for (let i = 1; i <= ACADEMIC_SUBJECT_SLOTS; i += 1) {
      const name = String(cells[`s${i}name`] ?? '').trim()
      const value = String(cells[`s${i}value`] ?? '').trim()
      if (!name && !value) continue
      if (!name || !value) return { status: 'partial', calls: [], message: `과목${i}: 과목명과 점수를 함께 입력` }
      if (type === 'regular') {
        const a = value.toUpperCase()
        if (!ACHIEVEMENTS.includes(a)) return { status: 'invalid', calls: [], message: `과목${i}: 성취도는 A~E` }
        subjects.push({ subject: name, achievement: a })
      } else {
        const n = num(value)
        if (!Number.isFinite(n) || n < 0 || n > 100) return { status: 'invalid', calls: [], message: `과목${i}: 원점수는 0~100` }
        subjects.push({ subject: name, rawScore: n })
      }
    }
    if (subjects.length === 0) return { status: 'partial', calls: [], message: '과목 1개 이상 필요' }
    return {
      status: 'ready',
      message: subjects.length < 5 ? `과목 ${subjects.length}개(요강: 상위 5과목)` : undefined,
      calls: [call('admin_submit_academic_score', '학업성실도', row, evaluatorUid, { p_input_type: type, p_subjects: subjects, p_no_document: false })],
    }
  }

  if (area === 'community') {
    if (isBlank(cells.grade)) return { status: 'partial', calls: [], message: '등급 필요' }
    const memo = String(cells.memo ?? '').trim()
    if (memo.length < 10) return { status: 'partial', calls: [], message: '근거 메모 10자 이상 필요' }
    return { status: 'ready', calls: [call('admin_submit_community_score', '공동체', row, evaluatorUid, { p_grade: num(cells.grade), p_evidence_memo: memo })] }
  }

  // essay / opinion — 모든 기준을 채워야 제출 가능
  const scoreCols = columns.filter((c) => c.kind === 'enum')
  const missing = scoreCols.filter((c) => isBlank(cells[c.key]))
  if (missing.length > 0) return { status: 'partial', calls: [], message: `기준 ${missing.length}개 미입력` }
  const items = Object.fromEntries(scoreCols.map((c) => [c.key, num(cells[c.key])]))
  if (area === 'essay') {
    return { status: 'ready', calls: [call('admin_submit_essay_score', '자기소개서', row, evaluatorUid, { p_items: items })] }
  }
  return {
    status: 'ready',
    calls: [call('admin_submit_opinion_score', '학부모 소견서', row, evaluatorUid, {
      p_items: items,
      p_deduction_flags: { contradiction: isFlag(cells.contradiction), omittedSensitiveInfo: isFlag(cells.omittedSensitiveInfo) },
    })],
  }
}
