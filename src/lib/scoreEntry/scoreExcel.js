// 관리자 대리 채점 — 엑셀 양식 만들기·읽기 (2026-10-01)
//
// 양식은 deepModel/documentModel이 만든 { columns, rows }를 그대로 표로 옮긴다.
//   · '입력' 시트: A열(숨김)=지원자 ID, B=수험번호, C=성명, D=참고, E~=점수 칸, 마지막=상태
//   · '작성 안내' 시트: 칸별 허용 값
//   · '_meta' 시트(숨김): 영역·위원·연도·차수·칸 순서 — 다른 위원/영역 양식을 잘못 올리는 것을 막는다
// 파일은 브라우저 안에서만 만들고 읽는다(서버에 올리지 않는다).

import ExcelJS from 'exceljs/dist/exceljs.min.js'

const META_SHEET = '_meta'
const MARK = 'sanmaeul-score-entry-template'
const VERSION = 1
const HEADER_ROW = 4
const FIRST_DATA_ROW = 5
const FIRST_SCORE_COL = 5 // E

function allowedText(col) {
  if (col.kind === 'flag') return "해당하면 'O', 아니면 빈칸"
  if (col.kind === 'int') return `${col.min}~${col.max} 정수`
  if (col.kind === 'text') return '글자'
  if (col.kind === 'academic') return '성취도 A~E 또는 원점수 0~100'
  return (col.values || []).join(', ')
}

function addValidation(cell, col) {
  if (col.kind === 'text' || col.kind === 'academic') return
  if (col.kind === 'int') {
    cell.dataValidation = {
      type: 'whole', operator: 'between', allowBlank: true, formulae: [col.min, col.max],
      showErrorMessage: true, errorTitle: '입력 오류', error: `${col.min}~${col.max} 사이의 정수만 입력할 수 있습니다.`,
    }
    return
  }
  const values = col.kind === 'flag' ? ['O'] : (col.values || [])
  const list = values.join(',')
  if (list.length > 250) return // 엑셀 목록 길이 제한 — 그 경우 업로드 때 검사한다
  cell.dataValidation = {
    type: 'list', allowBlank: true, formulae: [`"${list}"`],
    showErrorMessage: true, errorTitle: '입력 오류', error: `허용 값: ${list}`,
  }
}

const thin = { style: 'thin', color: { argb: 'FF999999' } }
const border = { top: thin, left: thin, bottom: thin, right: thin }

// meta: { area, areaLabel, evaluatorUid, evaluatorName, year, round, roundLabel }
export async function buildScoreTemplate(meta, columns, rows) {
  const wb = new ExcelJS.Workbook()
  wb.creator = '새봄고 입학전형관리시스템'
  const ws = wb.addWorksheet('입력', { views: [{ state: 'frozen', xSplit: 3, ySplit: HEADER_ROW }] })
  const lastCol = FIRST_SCORE_COL + columns.length // 상태 칸

  ws.getCell(1, 2).value = `${meta.year}학년도 ${meta.roundLabel} · ${meta.areaLabel} 대리 입력 양식`
  ws.getCell(1, 2).font = { bold: true, size: 14 }
  ws.getCell(2, 2).value = `평가위원: ${meta.evaluatorName}  ·  회색 줄(제출완료)은 올려도 반영되지 않습니다  ·  A열·4행 머리글·숨김 시트는 고치지 마세요`
  ws.getCell(2, 2).font = { size: 10, color: { argb: 'FF555555' } }

  // 3행: 묶음 머리글(과목 1, 학생면접 등)
  // 같은 묶음이 이어지면 한 칸으로 합친다(예: '과목 1' 아래 과목명·점수).
  for (let i = 0; i < columns.length;) {
    let j = i
    while (j + 1 < columns.length && columns[j + 1].group && columns[j + 1].group === columns[i].group) j += 1
    if (columns[i].group) {
      const cell = ws.getCell(3, FIRST_SCORE_COL + i)
      cell.value = columns[i].group
      cell.font = { bold: true, size: 10 }
      cell.alignment = { horizontal: 'center' }
      if (j > i) ws.mergeCells(3, FIRST_SCORE_COL + i, 3, FIRST_SCORE_COL + j)
    }
    i = j + 1
  }
  const heads = ['ID', '수험번호', '성명', '참고', ...columns.map((c) => c.label), '상태']
  heads.forEach((h, i) => {
    const cell = ws.getCell(HEADER_ROW, i + 1)
    cell.value = h
    cell.font = { bold: true }
    cell.alignment = { horizontal: 'center', vertical: 'middle', wrapText: true }
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE8EFE6' } }
    cell.border = border
  })
  ws.getRow(HEADER_ROW).height = 34

  rows.forEach((row, r) => {
    const rn = FIRST_DATA_ROW + r
    const done = Boolean(row.server)
    ws.getCell(rn, 1).value = row.applicantId
    ws.getCell(rn, 2).value = row.examNo || ''
    ws.getCell(rn, 3).value = row.name || ''
    ws.getCell(rn, 4).value = row.sub || ''
    columns.forEach((c, i) => {
      const cell = ws.getCell(rn, FIRST_SCORE_COL + i)
      const pre = row.prefill?.[c.key]
      if (pre !== undefined) cell.value = pre
      if (!done) addValidation(cell, c)
      cell.border = border
      cell.alignment = { horizontal: c.kind === 'text' ? 'left' : 'center' }
    })
    ws.getCell(rn, lastCol).value = done ? '제출완료' : ''
    for (let col = 1; col <= lastCol; col += 1) {
      const cell = ws.getCell(rn, col)
      cell.border = border
      if (done) cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFDDDDDD' } }
    }
  })

  ws.getColumn(1).hidden = true
  ws.getColumn(2).width = 11
  ws.getColumn(3).width = 13
  ws.getColumn(4).width = 18
  columns.forEach((c, i) => {
    ws.getColumn(FIRST_SCORE_COL + i).width = c.kind === 'text' ? (c.key === 'memo' ? 40 : 12) : Math.max(8, Math.min(16, c.label.length + 4))
  })
  ws.getColumn(lastCol).width = 10

  // 작성 안내
  const guide = wb.addWorksheet('작성 안내')
  guide.getColumn(1).width = 30
  guide.getColumn(2).width = 40
  guide.getColumn(3).width = 50
  guide.addRow([`${meta.areaLabel} 대리 입력 — 칸별 허용 값`]).font = { bold: true, size: 13 }
  guide.addRow([])
  guide.addRow(['칸', '허용 값', '설명']).font = { bold: true }
  columns.forEach((c) => guide.addRow([c.group ? `${c.group} · ${c.label}` : c.label, allowedText(c), c.hint || '']))
  guide.addRow([])
  guide.addRow(['• 모든 칸을 채운 지원자만 제출됩니다. 일부만 채운 줄은 미리보기에서 "빈칸 있음"으로 표시되고 저장되지 않습니다.'])
  guide.addRow(['• 올린 뒤 화면의 미리보기에서 확인하고 [제출]을 눌러야 저장됩니다. 제출된 점수는 재개방 전에는 고칠 수 없습니다.'])

  // 숨김 메타
  const metaWs = wb.addWorksheet(META_SHEET, { state: 'veryHidden' })
  metaWs.addRow([MARK, VERSION])
  metaWs.addRow(['area', meta.area])
  metaWs.addRow(['evaluatorUid', meta.evaluatorUid])
  metaWs.addRow(['year', String(meta.year)])
  metaWs.addRow(['round', meta.round])
  metaWs.addRow(['columns', JSON.stringify(columns.map((c) => c.key))])

  return wb.xlsx.writeBuffer()
}

export function downloadBuffer(buffer, filename) {
  const blob = new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

// 엑셀 칸 값 → 문자열(빈칸은 '')
function cellText(v) {
  if (v === null || v === undefined) return ''
  if (typeof v === 'object') {
    if (Array.isArray(v.richText)) return v.richText.map((t) => t.text).join('').trim()
    if ('result' in v) return cellText(v.result)
    if ('text' in v) return String(v.text).trim()
    if (v instanceof Date) return ''
    return ''
  }
  if (typeof v === 'boolean') return v ? 'O' : ''
  return String(v).trim()
}

// 반환: { draft: { rowId: { colKey: 문자열 } }, errors: [문자열], matchedCount }
export async function parseScoreWorkbook(arrayBuffer, expected, columns, rows) {
  const wb = new ExcelJS.Workbook()
  try {
    await wb.xlsx.load(arrayBuffer)
  } catch {
    throw new Error('엑셀 파일을 읽을 수 없습니다. 이 화면에서 내려받은 .xlsx 양식인지 확인하세요.')
  }
  const metaWs = wb.getWorksheet(META_SHEET)
  if (!metaWs || cellText(metaWs.getCell(1, 1).value) !== MARK) {
    throw new Error('이 화면에서 내려받은 양식이 아닙니다. [양식 내려받기]로 받은 파일에 입력해 주세요.')
  }
  const meta = {}
  for (let r = 2; r <= 6; r += 1) meta[cellText(metaWs.getCell(r, 1).value)] = cellText(metaWs.getCell(r, 2).value)
  if (meta.area !== expected.area) throw new Error(`다른 영역의 양식입니다(파일: ${meta.area}). 지금 고른 영역의 양식을 올려 주세요.`)
  if (meta.evaluatorUid !== expected.evaluatorUid) throw new Error('다른 평가위원의 양식입니다. 지금 고른 위원의 양식을 올려 주세요.')
  if (meta.year !== String(expected.year) || meta.round !== expected.round) throw new Error('다른 학년도·차수의 양식입니다.')
  let keys
  try {
    keys = JSON.parse(meta.columns)
  } catch {
    throw new Error('양식 정보가 손상되었습니다. 양식을 다시 내려받아 주세요.')
  }
  const expectedKeys = columns.map((c) => c.key)
  if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) {
    throw new Error('채점 항목 구성이 양식을 만들 때와 달라졌습니다. 양식을 다시 내려받아 주세요.')
  }

  const ws = wb.getWorksheet('입력')
  if (!ws) throw new Error("'입력' 시트를 찾을 수 없습니다.")
  const byId = new Map(rows.map((r) => [r.applicantId, r]))
  const draft = {}
  const errors = []
  let matchedCount = 0
  const lastRow = ws.rowCount
  for (let rn = FIRST_DATA_ROW; rn <= lastRow; rn += 1) {
    const id = cellText(ws.getCell(rn, 1).value)
    const examNo = cellText(ws.getCell(rn, 2).value)
    if (!id && !examNo) continue
    const row = byId.get(id)
    if (!row) {
      errors.push(`${rn}행(${examNo || '수험번호 없음'}): 이 위원의 채점 대상이 아닙니다.`)
      continue
    }
    if ((row.examNo || '') !== examNo) {
      errors.push(`${rn}행: 수험번호가 바뀌었습니다(양식 ${row.examNo || '-'} / 파일 ${examNo || '-'}). 줄을 옮기거나 고치지 마세요.`)
      continue
    }
    if (row.server) continue
    const values = {}
    keys.forEach((key, i) => {
      const t = cellText(ws.getCell(rn, FIRST_SCORE_COL + i).value)
      if (t !== '') values[key] = t
    })
    draft[row.id] = values
    matchedCount += 1
  }
  return { draft, errors, matchedCount }
}

