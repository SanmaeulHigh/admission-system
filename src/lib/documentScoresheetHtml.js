// 서류평가 채점표 인쇄 HTML (결재용, 2026-09-28)
//
// 영역별로, 채점위원 한 명당 A4 한 장(넘치면 이어짐)을 만든다. 서명란에는
// 시스템에서 실제로 채점한 위원 + '추가 서명자'(scoresheet_cosigners)를 함께 올린다.
// 출결·학업성실도·공동체는 최고관리자 1명이 채점하지만 내부 규정상 채점위원이
// 2명이어야 하므로, 추가 서명자로 한 명을 더 올려 서명을 받는다.
// 인쇄 → 서명 → 스캔 → K-에듀파인 결재.

import { printFontFaceCss, PRINT_FONT_STACK } from './printFont'
import { roundToText } from './applicantLabels'
import { printStampCss } from './printStamp'

export const DOCUMENT_AREAS = [
  { value: 'attendance', label: '출결', max: 200 },
  { value: 'academic', label: '학업성실도', max: 100 },
  { value: 'community', label: '공동체생활적합성', max: 100 },
  { value: 'essay', label: '자기소개서', max: 100 },
  { value: 'opinion', label: '학부모소견서', max: 25 },
]

const ESSAY_CRITERIA = [
  ['admissionWill', '입학의지'], ['selfUnderstanding', '자기이해'], ['schoolUnderstanding', '학교이해'],
  ['schoolAdaptation', '학교적응'], ['learningWill', '배움의지'], ['serviceWill', '봉사의지'],
  ['communityLife', '공동체생활'], ['careerConnection', '진로연계'],
  ['sincerity', '진지성·구체성'], ['feasibility', '실현가능성'],
]

const OPINION_CRITERIA = [
  ['altEducationUnderstanding', '대안교육이해'], ['schoolUnderstanding', '학교이해'],
  ['childUnderstanding', '자녀이해'], ['childCareerView', '자녀진로관'], ['admissionWillParticipation', '참여의지'],
]

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]))
}

function yn(v) {
  return v ? '예' : ''
}

// 영역별 입력 칸 정의: [머리글, (inputs) => 값, 옵션]
function columnsFor(area) {
  switch (area) {
    case 'attendance':
      return [
        ['미인정결석', (i) => i?.unexcusedAbsences],
        ['지각·조퇴·결과', (i) => i?.tardyEarlyResultCount],
        ['기록 없음', (i) => yn(i?.noRecord)],
      ]
    case 'academic':
      return [
        ['유형', (i) => (i?.inputType === 'ged' ? '검정고시' : i?.inputType === 'regular' ? '학생부' : '')],
        ['반영 학기', (i) => {
          const m = /^([1-3])-([12])$/.exec(String(i?.semesterChoice || ''))
          return m ? `${m[1]}학년 ${m[2]}학기` : ''
        }],
        ['반영 과목 수', (i) => (Array.isArray(i?.subjects) ? i.subjects.length : '')],
        ['자료 없음', (i) => yn(i?.noDocument)],
      ]
    case 'community':
      return [
        ['등급', (i) => i?.grade],
        ['근거 메모', (i) => i?.evidenceMemo, { wide: true }],
      ]
    case 'essay':
      return ESSAY_CRITERIA.map(([k, l]) => [l, (i) => i?.[k]])
    case 'opinion':
      return OPINION_CRITERIA.map(([k, l]) => [l, (i) => i?.[k]])
    default:
      return []
  }
}

// data: get_document_scoresheet 응답
function sectionsFor(data) {
  const area = DOCUMENT_AREAS.find((a) => a.value === data.area)
  const cols = columnsFor(data.area)
  const byEvaluator = new Map()
  for (const s of data.scores || []) {
    if (!byEvaluator.has(s.evaluatorUid)) byEvaluator.set(s.evaluatorUid, { name: s.evaluatorName, rows: new Map() })
    byEvaluator.get(s.evaluatorUid).rows.set(s.applicantId, s)
  }
  const roster = data.roster || []
  const cosigners = data.cosigners || []

  // 채점이 하나도 없으면 빈 채점표 한 장(서명란은 추가 서명자만)
  const evaluators = byEvaluator.size > 0 ? [...byEvaluator.values()] : [{ name: '', rows: new Map() }]

  return evaluators.map((ev) => {
    const scored = roster.filter((r) => ev.rows.has(r.applicantId)).length
    const body = roster.map((r) => {
      const s = ev.rows.get(r.applicantId)
      return `<tr>
        <td class="c">${esc(r.examNo || '')}</td>
        <td>${esc(r.name)}</td>
        ${cols.map(([, get, opt]) => `<td class="${opt?.wide ? 'memo' : 'c'}">${s ? esc(get(s.inputs) ?? '') : ''}</td>`).join('')}
        <td class="c b">${s ? esc(s.score ?? '') : ''}</td>
      </tr>`
    }).join('')

    const signers = [ev.name, ...cosigners].filter(Boolean)
    const signRows = (signers.length ? signers : ['']).map((n) => `
      <div class="signer"><span class="role">채점위원</span><span class="name">${esc(n)}</span><span class="line"></span><span>(서명)</span></div>`).join('')

    return `<section class="page">
      <h1>${esc(data.year)}학년도 신입생 입학전형 서류평가 채점표</h1>
      <div class="meta">
        <span>평가 영역: <b>${esc(area?.label)}</b> (${esc(area?.max)}점 만점)</span>
        <span>${esc(roundToText(data.round))}</span>
        <span>채점 ${scored} / ${roster.length}명</span>
      </div>
      <table>
        <thead><tr>
          <th style="width:18mm">수험번호</th><th style="width:22mm">성명</th>
          ${cols.map(([h]) => `<th>${esc(h)}</th>`).join('')}
          <th style="width:16mm">점수</th>
        </tr></thead>
        <tbody>${body || `<tr><td colspan="${cols.length + 3}" class="c">평가 대상자가 없습니다.</td></tr>`}</tbody>
      </table>
      <div class="confirm">위와 같이 채점하였음을 확인합니다.</div>
      <div class="date">${esc(data.year - 1)}.&nbsp;&nbsp;&nbsp;&nbsp;.&nbsp;&nbsp;&nbsp;&nbsp;.</div>
      <div class="signs">${signRows}</div>
    </section>`
  })
}

export function buildDocumentScoresheetHtml(dataList) {
  const sections = dataList.flatMap(sectionsFor)
  const wide = dataList.some((d) => d.area === 'essay')
  return `<!doctype html><html><head><meta charset="utf-8">
<title>서류평가 채점표</title>
<style>
  ${printFontFaceCss()}
  @page { size: A4 ${wide ? 'landscape' : 'portrait'}; margin: 12mm; }
  ${printStampCss()}
  * { box-sizing: border-box; }
  body { font-family: ${PRINT_FONT_STACK}; color: #111; font-size: 10.5px; margin: 0; background: #eef1f4; }
  .toolbar { position: sticky; top: 0; padding: 10px 16px; background: #111827; color: #fff; font-size: 13px; }
  .page { background: #fff; margin: 12px auto; padding: 10mm; max-width: ${wide ? '273mm' : '186mm'}; }
  .page + .page { break-before: page; page-break-before: always; }
  h1 { font-size: 16px; text-align: center; margin: 0 0 8px; letter-spacing: 1px; }
  .meta { display: flex; gap: 16px; justify-content: space-between; margin-bottom: 6px; font-size: 11px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border: 1px solid #555; padding: 3px 4px; }
  th { background: #f1f3f0; font-weight: 700; font-size: 10px; }
  tr { break-inside: avoid; }
  .c { text-align: center; font-variant-numeric: tabular-nums; }
  .b { font-weight: 700; }
  .memo { font-size: 9px; line-height: 1.35; }
  .confirm { margin-top: 12px; text-align: center; font-size: 12px; }
  .date { margin-top: 6px; text-align: center; font-size: 12px; }
  .signs { margin-top: 10px; display: flex; flex-direction: column; align-items: flex-end; gap: 8px; font-size: 12px; }
  .signer { display: flex; align-items: flex-end; gap: 8px; }
  .signer .role { color: #444; }
  .signer .name { min-width: 22mm; text-align: center; font-weight: 700; }
  .signer .line { display: inline-block; width: 32mm; border-bottom: 1px solid #111; }
  @media print {
    body { background: #fff; }
    .toolbar { display: none; }
    .page { margin: 0; padding: 0; max-width: none; }
  }
</style></head><body>
<div class="toolbar">인쇄 창이 자동으로 열리지 않으면 Ctrl+P를 누르세요. 채점위원별로 한 장씩 나옵니다.</div>
${sections.join('\n')}
<script>window.addEventListener('load', function () { setTimeout(function () { window.print() }, 300) })</script>
</body></html>`
}
