// M6e 종합 채점표 XLSX (검토메모 "M6 회의자료 PDF와 종합 채점표 XLSX는 M5e 종이
// 백업과 역할이 다름" 대응)
//
// 2026학년도 실물 워크북(16시트) 구조를 담당 교사 업로드본으로 확인하고 반영했다.
// 서류평가 4영역(출결·학업·공동체·자소서·학부모소견서)은 2026과 2027 위원 수가
// 정확히 일치해(공동체 2인, 자소서 5인, 학부모소견서 4인) 위원별 개별 시트를
// 그대로 재현한다. 심층평가(모둠·면접·글쓰기)는 2026(모둠 10인 합산, 면접 4인조
// 로테이션)과 2027(모둠 2인, 면접 학생·학부모 각 2인 — 승인 요강 문구 그대로
// 이미 구현됨)의 위원 수 자체가 달라 2026의 컬럼 구조를 그대로 못 쓴다.
// "최종 성적" 시트는 전체 철학(수험번호·이름·지원전형·서류점수·모둠·학생면접·
// 학부모면접·글쓰기·합산·순위·사정여부)은 유지하되 2027 실제 위원 수(각 2인)에
// 맞춰 컬럼을 새로 짰다(담당 교사 확인, 2026-07-09).
//
// 서류전형 영역별 breakdown은 확정된 decision_results 스냅샷에 opinion(학부모
// 소견서) 점수가 별도 보존되어 있지 않아(M4 tiebreak_values 미포함) 부득이
// 현재 개별 제출값을 다시 계산해서 보여준다 — 확정 후 재제출이 없었다면
// 스냅샷과 100% 동일하다. 합산점수·순위·사정여부는 항상 확정 스냅샷 값이다.

import ExcelJS from 'exceljs/dist/exceljs.min.js'
import { supabase } from './supabase'
import { tracksToText } from './applicantLabels'
import { logExport } from './exportAudit'

const OUTCOME_LABEL = { passed: '합격', failed: '불합격', excluded: '제외', manualDecisionRequired: '동점(위원회 결정 필요)' }

const ESSAY_CRITERIA = [
  ['admissionWill', '입학의지'], ['selfUnderstanding', '자기이해'], ['schoolUnderstanding', '학교이해'],
  ['schoolAdaptation', '학교적응'], ['learningWill', '배움의지'], ['serviceWill', '봉사의지'],
  ['communityLife', '공동체생활'], ['careerConnection', '진로연계'],
  ['sincerity', '진지성과구체성'], ['feasibility', '실현가능성'],
]
const OPINION_CRITERIA = [
  ['altEducationUnderstanding', '대안교육이해'], ['schoolUnderstanding', '학교이해'],
  ['childUnderstanding', '자녀이해'], ['childCareerView', '자녀진로관'], ['admissionWillParticipation', '참여의지'],
]

function borderAll() {
  const style = { style: 'thin', color: { argb: 'FFCCCCCC' } }
  return { top: style, left: style, bottom: style, right: style }
}

function headerRowStyle(row) {
  row.eachCell((cell) => {
    cell.font = { bold: true }
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE6EDE0' } }
    cell.alignment = { vertical: 'middle', horizontal: 'center', wrapText: true }
    cell.border = borderAll()
  })
}

function addTable(sheet, columns, rows) {
  sheet.columns = columns.map((c) => ({ header: c.header, width: c.width }))
  headerRowStyle(sheet.getRow(1))
  rows.forEach((r) => {
    const row = sheet.addRow(columns.map((c) => c.get(r)))
    row.eachCell((cell) => {
      cell.border = borderAll()
      cell.alignment = { vertical: 'middle', horizontal: 'center' }
    })
  })
  sheet.views = [{ state: 'frozen', ySplit: 1 }]
}

function byApplicant(rows) {
  const m = new Map()
  for (const r of rows) {
    if (!m.has(r.applicantId)) m.set(r.applicantId, [])
    m.get(r.applicantId).push(r)
  }
  return m
}

function groupBy(rows, key) {
  const m = new Map()
  for (const r of rows) {
    const k = r[key]
    if (!m.has(k)) m.set(k, [])
    m.get(k).push(r)
  }
  return m
}

/** roster를 applicantId → {receiptNo, name, tracks} 로 찾기 쉽게 인덱싱 */
function indexRoster(roster) {
  const m = new Map()
  for (const r of roster) m.set(r.applicantId, r)
  return m
}

export async function exportFinalScoresheetXlsx({ year, round }) {
  const { data, error } = await supabase.rpc('get_m6e_scoresheet_data', { p_year: year, p_round: round })
  if (error) throw error
  if (!data.ready) {
    throw new Error(
      data.reason === 'NO_DOCUMENT_FINAL_RUN'
        ? '확정된 1단계 서류사정이 없습니다.'
        : '종합 채점표를 만들 데이터가 없습니다.',
    )
  }

  const roster = data.roster || []
  const rosterIdx = indexRoster(roster)
  const docAgg = data.documentAggregate || []
  const docIndiv = data.documentIndividualScores || []
  const deepIndiv = data.deepIndividualScores || []
  const finalAgg = data.finalAggregate || []

  const workbook = new ExcelJS.Workbook()
  workbook.creator = '새봄 입학'
  workbook.created = new Date()

  // ── 1. 범례 ────────────────────────────────────────────────
  const legend = workbook.addWorksheet('범례')
  legend.addRow(['항목', '값', '비고'])
  headerRowStyle(legend.getRow(1))
  ;[
    ['서류평가 만점', 1000, '출결200+학업100+공동체100+자소서500+학부모소견서100'],
    ['2단계 서류평가 반영(400점 환산)', '서류평가 획득점수 × 0.4', '가산 후 값 기준(요강 (2)-①)'],
    ['모둠활동', 150, '관찰교사 2인'],
    ['학생면접', 150, '위원 2인'],
    ['학부모면접', 100, '위원 2인'],
    ['글쓰기', 200, '위원 2인, 3문항 중 2택'],
    ['인천학생추천 가산점', '1단계 서류평가 획득점수 × 20%', '가산 후 1,000점 초과 불가'],
  ].forEach((r) => legend.addRow(r))
  legend.columns = [{ width: 28 }, { width: 30 }, { width: 40 }]

  // ── 2. 수험번호 부여 ─────────────────────────────────────────
  const rosterSheet = workbook.addWorksheet('수험번호 부여')
  addTable(
    rosterSheet,
    [
      { header: '접수번호', width: 14, get: (r) => r.receiptNo },
      { header: '이름', width: 10, get: (r) => r.name },
      { header: '수험번호', width: 10, get: (r) => r.examNo || '' },
      { header: '가산점 대상 여부', width: 20, get: (r) => r.bonusReason || (r.bonusEligible ? '해당' : '해당없음') },
      { header: '지원전형', width: 18, get: (r) => tracksToText(r.tracks) },
    ],
    roster,
  )

  // ── 3. 서류전형_종합성적(보기전용) ───────────────────────────
  const docSummary = workbook.addWorksheet('서류전형_종합성적(보기전용)')
  addTable(
    docSummary,
    [
      { header: '접수번호', width: 14, get: (r) => rosterIdx.get(r.applicantId)?.receiptNo },
      { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
      { header: '지원전형', width: 18, get: (r) => tracksToText(rosterIdx.get(r.applicantId)?.tracks) },
      { header: '출결 [200]', width: 10, get: (r) => r.breakdown?.attendance ?? '' },
      { header: '학업성실도 [100]', width: 12, get: (r) => r.breakdown?.academic ?? '' },
      { header: '공동체생활적합성 [100]', width: 14, get: (r) => r.breakdown?.community ?? '' },
      { header: '자기소개서 [500]', width: 12, get: (r) => r.breakdown?.essay ?? '' },
      { header: '학부모소견서 [100]', width: 12, get: (r) => r.breakdown?.opinion ?? '' },
      { header: '가산점 적용 전 총점', width: 14, get: (r) => r.breakdown?.rawTotal ?? '' },
      { header: '가산점 적용', width: 10, get: (r) => (r.breakdown?.bonusApplied ? 'O' : 'X') },
      { header: '가산점', width: 10, get: (r) => r.breakdown?.bonusAmount ?? 0 },
      { header: '합산 점수', width: 12, get: (r) => r.totalScore },
      { header: '순위', width: 8, get: (r) => r.rank },
      { header: '사정 여부', width: 24, get: (r) => OUTCOME_LABEL[r.outcome] ?? r.outcome },
    ],
    docAgg,
  )

  // ── 4~15. 서류평가 개별위원 시트 ─────────────────────────────
  const byArea = groupBy(docIndiv, 'area')

  // 학교생활기록부(출결+학업, 위원별)
  const attByEval = groupBy(byArea.get('attendance') || [], 'evaluatorName')
  const acaByEval = groupBy(byArea.get('academic') || [], 'evaluatorName')
  const gijokEvaluators = new Set([...attByEval.keys(), ...acaByEval.keys()])
  for (const evalName of gijokEvaluators) {
    const sheet = workbook.addWorksheet(`(정량평가)학교생활기록부_${evalName}`.slice(0, 31))
    const attRows = indexRoster ? byApplicant(attByEval.get(evalName) || []) : new Map()
    const acaRows = byApplicant(acaByEval.get(evalName) || [])
    const applicantIds = new Set([...attRows.keys(), ...acaRows.keys()])
    const rows = [...applicantIds].map((id) => ({
      applicantId: id,
      att: attRows.get(id)?.[0],
      aca: acaRows.get(id)?.[0],
    }))
    addTable(
      sheet,
      [
        { header: '수험번호', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.examNo || '' },
        { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
        { header: '미인정결 일수', width: 12, get: (r) => r.att?.inputs?.unexcusedAbsences ?? '' },
        { header: '출결 점수 [200]', width: 12, get: (r) => r.att?.score ?? '' },
        { header: '반영 학기', width: 12, get: (r) => r.aca?.inputs?.semesterChoice ?? '' },
        { header: '학업성실도 점수 [100]', width: 14, get: (r) => r.aca?.score ?? '' },
        { header: '계 [300]', width: 10, get: (r) => (Number(r.att?.score) || 0) + (Number(r.aca?.score) || 0) },
      ],
      rows,
    )
  }

  // 공동체 생활 적합성 (위원별)
  for (const [evalName, rows] of groupBy(byArea.get('community') || [], 'evaluatorName')) {
    const sheet = workbook.addWorksheet(`(정성평가)공동체생활적합성_${evalName}`.slice(0, 31))
    addTable(
      sheet,
      [
        { header: '수험번호', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.examNo || '' },
        { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
        { header: '계 [100점]', width: 10, get: (r) => r.score },
      ],
      rows,
    )
  }

  // 자기소개서 (위원별, 10기준)
  for (const [evalName, rows] of groupBy(byArea.get('essay') || [], 'evaluatorName')) {
    const sheet = workbook.addWorksheet(`(정성평가)자기소개서_${evalName}`.slice(0, 31))
    addTable(
      sheet,
      [
        { header: '수험번호', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.examNo || '' },
        { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
        ...ESSAY_CRITERIA.map(([key, label]) => ({
          header: `${label} (10점)`, width: 12, get: (r) => r.inputs?.[key] ?? '',
        })),
        { header: '계 [100점]', width: 10, get: (r) => r.score },
      ],
      rows,
    )
  }

  // 학부모 소견서 (위원별, 5기준)
  for (const [evalName, rows] of groupBy(byArea.get('opinion') || [], 'evaluatorName')) {
    const sheet = workbook.addWorksheet(`(정성평가)학부모소견서_${evalName}`.slice(0, 31))
    addTable(
      sheet,
      [
        { header: '수험번호', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.examNo || '' },
        { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
        ...OPINION_CRITERIA.map(([key, label]) => ({
          header: `${label} (5점)`, width: 12, get: (r) => r.inputs?.[key] ?? '',
        })),
        { header: '계 [25점]', width: 10, get: (r) => r.score },
      ],
      rows,
    )
  }

  // ── 16. 최종 성적 (2027 실제 위원 수에 맞게 재설계) ───────────
  const deepByAreaApplicant = {
    group: byApplicant((deepIndiv || []).filter((r) => r.area === 'group')),
    interviewStudent: byApplicant((deepIndiv || []).filter((r) => r.area === 'interviewStudent')),
    interviewParent: byApplicant((deepIndiv || []).filter((r) => r.area === 'interviewParent')),
    writing: byApplicant((deepIndiv || []).filter((r) => r.area === 'writing')),
  }

  function raterCols(area, applicantId, max) {
    const rows = deepByAreaApplicant[area].get(applicantId) || []
    const names = rows.map((r) => `${r.evaluatorName}:${r.score}`).join(' / ')
    return names || `(제출 없음, ${max}점 만점)`
  }

  const finalSheet = workbook.addWorksheet('최종 성적')
  addTable(
    finalSheet,
    [
      { header: '수험번호', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.examNo || '' },
      { header: '이름', width: 10, get: (r) => rosterIdx.get(r.applicantId)?.name },
      { header: '지원전형', width: 18, get: (r) => tracksToText(rosterIdx.get(r.applicantId)?.tracks) },
      { header: '서류평가 획득점수 [1000]', width: 14, get: (r) => r.documentScore },
      { header: '서류 반영점수 [400]', width: 12, get: (r) => r.documentCarry },
      { header: '모둠활동 위원별 [150]', width: 24, get: (r) => raterCols('group', r.applicantId, 150) },
      { header: '모둠활동 합산', width: 10, get: (r) => r.groupScore },
      { header: '학생면접 위원별 [150]', width: 24, get: (r) => raterCols('interviewStudent', r.applicantId, 150) },
      { header: '학생면접 합산', width: 10, get: (r) => r.interviewStudentScore },
      { header: '학부모면접 위원별 [100]', width: 24, get: (r) => raterCols('interviewParent', r.applicantId, 100) },
      { header: '학부모면접 합산', width: 10, get: (r) => r.interviewParentScore },
      { header: '글쓰기 위원별 [200]', width: 24, get: (r) => raterCols('writing', r.applicantId, 200) },
      { header: '글쓰기 합산', width: 10, get: (r) => r.writingScore },
      { header: '합산 점수 [1000]', width: 12, get: (r) => r.finalTotal },
      { header: '순위', width: 8, get: (r) => r.rank },
      { header: '사정 여부', width: 24, get: (r) => OUTCOME_LABEL[r.outcome] ?? r.outcome },
      {
        header: '비고', width: 20, get: (r) => {
          const tr = r.trackResult || {}
          const parts = []
          if (tr.incheon && tr.incheon !== 'notApplicable') parts.push(`인천:${OUTCOME_LABEL[tr.incheon] ?? tr.incheon}`)
          if (tr.social && tr.social !== 'notApplicable') parts.push(`사회통합:${OUTCOME_LABEL[tr.social] ?? tr.social}`)
          if (tr.general && tr.general !== 'notApplicable') parts.push(`일반:${OUTCOME_LABEL[tr.general] ?? tr.general}`)
          return parts.join(' / ')
        },
      },
    ],
    finalAgg,
  )

  const buffer = await workbook.xlsx.writeBuffer()

  await logExport({
    year,
    round,
    exportType: 'scoreWorkbook',
    fileFormat: 'xlsx',
    content: buffer,
    decisionRunId: data.finalRunId || null,
    rowCount: roster.length,
    metadata: { sheetCount: workbook.worksheets.length },
  })

  const blob = new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  const dateStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  a.href = url
  a.download = `${year}_${round}_종합채점표_${dateStamp}.xlsx`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)

  return { rosterCount: roster.length, finalCount: finalAgg.length }
}
