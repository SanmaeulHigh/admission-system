// 모둠활동 모둠표 인쇄 HTML (2026-10-01)
//
// 예전에는 모둠 편성 화면에서 window.print()로 앱 화면을 그대로 인쇄해서
// 상단바·왼쪽 메뉴·배경 로고까지 찍히고, 좁아진 칸에 이름이 두 줄로 잘렸다.
// 면접 진행표(interviewRunSheetHtml.js)처럼 인쇄 전용 문서를 새 창에 만든다.
//
// 모둠표는 관찰위원·진행 요원이 보는 문서라 서류 점수·1단계 순위는 넣지 않는다
// (관찰 평가에 선입견을 주지 않기 위해). 수험번호 순으로 적는다.

import { printFontFaceCss, PRINT_FONT_STACK } from './printFont'
import { roundToText } from './applicantLabels'
import { printStampCss } from './printStamp'

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]))
}

const byExamNo = (a, b) =>
  String(a.examNo || '￿').localeCompare(String(b.examNo || '￿'), 'ko', { numeric: true })

// groups: [{ groupCode, members: [applicantId], primaryObservers: [uid] }]
// candidateMap: applicantId → { examNo, displayName }, evaluatorMap: uid → { displayName }
export function buildGroupSheetHtml({ year, round, groups, candidateMap, evaluatorMap, finalized }) {
  const totalMembers = groups.reduce((sum, g) => sum + g.members.length, 0)

  const blocks = groups.map((group) => {
    const members = group.members.map((id) => candidateMap[id]).filter(Boolean).sort(byExamNo)
    const observers = group.primaryObservers.filter(Boolean).map((uid) => evaluatorMap[uid]?.displayName || '').filter(Boolean)
    const rows = members.map((c, i) => `<tr>
        <td class="c">${i + 1}</td>
        <td class="c b">${esc(c.examNo || '미발급')}</td>
        <td class="b">${esc(c.displayName)}</td>
        <td></td>
      </tr>`).join('')
    return `<section class="group">
      <div class="ghead">
        <span class="code">${esc(group.groupCode)} 모둠</span>
        <span class="count">${members.length}명</span>
        <span class="obs">주관찰위원 <b>${esc(observers.join(' · ') || '미배정')}</b></span>
      </div>
      <table>
        <thead><tr><th style="width:12mm">번호</th><th style="width:30mm">수험번호</th><th style="width:40mm">성명</th><th>비고</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="4" class="c">배정된 지원자가 없습니다.</td></tr>'}</tbody>
      </table>
    </section>`
  }).join('\n')

  return `<!doctype html><html><head><meta charset="utf-8">
<title>모둠표</title>
<style>
  ${printFontFaceCss()}
  @page { size: A4 portrait; margin: 14mm; }
  ${printStampCss()}
  * { box-sizing: border-box; }
  body { font-family: ${PRINT_FONT_STACK}; color: #111; font-size: 12px; margin: 0; background: #eef1f4; }
  .toolbar { position: sticky; top: 0; padding: 10px 16px; background: #111827; color: #fff; font-size: 13px; z-index: 5; }
  .page { position: relative; background: #fff; margin: 12px auto; padding: 12mm; max-width: 210mm; }
  .draft { color: #c9362b; font-weight: 700; border: 1px solid #c9362b; padding: 1px 8px; display: inline-block; margin-bottom: 6px; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  .meta { font-size: 12px; color: #444; margin-bottom: 10px; padding-bottom: 8px; border-bottom: 2px solid #111; }
  .group { margin-top: 12px; break-inside: avoid; page-break-inside: avoid; }
  .ghead { display: flex; align-items: baseline; gap: 12px; margin-bottom: 4px; }
  .code { font-size: 15px; font-weight: 800; }
  .count { color: #555; }
  .obs { margin-left: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border: 1px solid #555; padding: 0 6px; height: 8.5mm; }
  th { background: #f1f3f0; font-weight: 700; height: 7mm; }
  .c { text-align: center; }
  .b { font-weight: 700; font-size: 13px; }
  @media print {
    body { background: #fff; }
    .toolbar { display: none; }
    .page { margin: 0; padding: 0; max-width: none; }
  }
</style></head><body>
<div class="toolbar">인쇄 창이 자동으로 열리지 않으면 Ctrl+P를 누르세요. 용지 A4 세로.</div>
<div class="page">
  ${finalized ? '' : '<div class="draft">확정 전 계획 — 운영용 아님</div>'}
  <h1>새봄고등학교 ${esc(year)}학년도 신입생 입학전형 · 심층역량평가 모둠표</h1>
  <div class="meta">${esc(roundToText(round))} · 모둠 ${groups.length}개 · 지원자 ${totalMembers}명 · 1단계 서류사정 확정본 기준</div>
  ${blocks || '<p>편성된 모둠이 없습니다.</p>'}
</div>
<script>window.addEventListener('load', function () { setTimeout(function () { window.print() }, 300) })</script>
</body></html>`
}
