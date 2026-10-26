// 면접 진행표 인쇄 HTML (2026-09-28)
//
// 2026-10-14 기준: 본관에서도 교외 주소(https://ipsi.example.org)로 휴대폰 인증 후 접속해
// 면접위원 화면의 호출·타이머를 쓴다. 학생은 진행 요원이 글쓰기 고사실에서 면접실로 데려간다.
// 이 표는 순서 확인·운영 기록용이며, 통신이 끊겼을 때는 이 표만으로 진행할 수 있게 만든 종이 백업이다.
//
// 면접조 한 개당 A4 가로 한 장. '진행 요원용'과 '면접실용' 2부를 뽑을 수 있다.
// 데이터: get_m5c_interview_plan_admin (면접 조편성·순서·시간).

import { printFontFaceCss, PRINT_FONT_STACK } from './printFont'
import { roundToText } from './applicantLabels'
import { printStampCss } from './printStamp'

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]))
}

const TZ = 'Asia/Seoul'

export function fmtTime(v) {
  if (!v) return ''
  return new Intl.DateTimeFormat('ko-KR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(v))
}

function fmtDate(v) {
  if (!v) return ''
  const d = new Date(v)
  const date = new Intl.DateTimeFormat('ko-KR', { timeZone: TZ, year: 'numeric', month: 'numeric', day: 'numeric' }).format(d)
  const wd = new Intl.DateTimeFormat('ko-KR', { timeZone: TZ, weekday: 'short' }).format(d)
  return `${date}(${wd})`
}

// 앞 지원자 학부모 면접 종료 ~ 다음 지원자 학생 면접 시작 사이가 비어 있으면 쉬는 시간 줄을 넣는다.
function breakRow(slot, next) {
  if (!next || !slot.parentEndsAt || !next.studentStartsAt) return ''
  const minutes = Math.round((new Date(next.studentStartsAt) - new Date(slot.parentEndsAt)) / 60000)
  if (minutes <= 0) return ''
  // 30분 이상 비면 오전·오후 회차 사이(점심)로 표시한다(2부제, 2026-10-14).
  const label = minutes >= 30 ? '점심·회차 사이' : '쉬는 시간'
  return `<tr class="rest"><td colspan="10">${label} ${esc(fmtTime(slot.parentEndsAt))}~${esc(fmtTime(next.studentStartsAt))} (${minutes}분)</td></tr>`
}

// plan: get_m5c_interview_plan_admin 응답, teamIds: 인쇄할 조, copies: ['진행 요원용', '면접실용'] 등
export function buildInterviewRunSheetHtml(plan, { teamIds, copies = ['진행 요원용', '면접실용'] } = {}) {
  const candidates = new Map((plan.candidates || []).map((c) => [c.applicantId, c]))
  const evaluators = new Map((plan.evaluators || []).map((e) => [e.uid, e.displayName]))
  const isFinal = ['final', 'finalized'].includes(plan.validation?.status)

  const teams = (plan.teams || [])
    .filter((t) => !teamIds || teamIds.includes(t.teamId))
    .slice()
    .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || String(a.teamCode).localeCompare(String(b.teamCode), 'ko', { numeric: true }))

  const pages = []
  for (const team of teams) {
    const schedule = (team.schedule || []).slice().sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0)
      || String(a.studentStartsAt).localeCompare(String(b.studentStartsAt)))
    const members = (team.memberUids || []).map((uid) => evaluators.get(uid) || '').filter(Boolean)
    const day = fmtDate(schedule[0]?.studentStartsAt)

    const rows = schedule.map((s, i) => {
      const c = candidates.get(s.applicantId) || {}
      return `<tr>
        <td class="c">${i + 1}</td>
        <td class="c b">${esc(c.examNo || '')}</td>
        <td class="b">${esc(c.displayName || '')}</td>
        <td class="c">${esc(fmtTime(s.studentStartsAt))}~${esc(fmtTime(s.studentEndsAt))}</td>
        <td class="blank"></td>
        <td class="blank"></td>
        <td class="c">${esc(fmtTime(s.parentStartsAt))}~${esc(fmtTime(s.parentEndsAt))}</td>
        <td class="blank"></td>
        <td class="blank"></td>
        <td class="blank note"></td>
      </tr>${breakRow(s, schedule[i + 1])}`
    }).join('')

    for (const copy of copies) {
      pages.push(`<section class="page">
        ${isFinal ? '' : '<div class="draft">확정 전 계획 — 운영용 아님</div>'}
        <div class="head">
          <div>
            <h1>${esc(plan.year)}학년도 신입생 입학전형 ${esc(roundToText(plan.round))} · 2단계 심층역량평가 면접 진행표</h1>
            <div class="meta">
              <span>면접조 <b>${esc(team.teamCode)}</b></span>
              ${team.location ? `<span>장소 <b>${esc(team.location)}</b></span>` : ''}
              ${day ? `<span>일자 <b>${esc(day)}</b></span>` : ''}
              <span>면접위원 <b>${esc(members.join(', ') || '-')}</b></span>
            </div>
          </div>
          <div class="copy">${esc(copy)}</div>
        </div>
        <table>
          <thead>
            <tr>
              <th rowspan="2" style="width:9mm">순서</th>
              <th rowspan="2" style="width:18mm">수험번호</th>
              <th rowspan="2" style="width:24mm">성명</th>
              <th colspan="3">학생 면접</th>
              <th colspan="3">학부모 면접</th>
              <th rowspan="2">비고</th>
            </tr>
            <tr>
              <th style="width:24mm">예정</th><th style="width:17mm">호출</th><th style="width:17mm">완료</th>
              <th style="width:24mm">예정</th><th style="width:17mm">호출</th><th style="width:17mm">완료</th>
            </tr>
          </thead>
          <tbody>${rows || '<tr><td colspan="10" class="c">배정된 지원자가 없습니다.</td></tr>'}</tbody>
        </table>
        <ul class="guide">
          <li>학생 면접이 끝나면 면접실에서 진행 요원에게 알리고, 진행 요원은 다음 순서 학생을 글쓰기 고사실에서 조용히 불러 면접실로 안내합니다.</li>
          <li>호출·완료 칸에는 실제 시각(시:분)을 적습니다. 글쓰기와 면접은 정해진 시간 안에 모두 마칩니다.</li>
          <li>결시·순서 변경 등은 비고란에 적고, 전형 종료 후 채점표와 함께 제출합니다.</li>
        </ul>
        <div class="sign">
          <span>진행 요원 <span class="line"></span> (서명)</span>
          <span>면접위원 확인 <span class="line"></span> (서명)</span>
        </div>
      </section>`)
    }
  }

  return `<!doctype html><html><head><meta charset="utf-8">
<title>면접 진행표</title>
<style>
  ${printFontFaceCss()}
  @page { size: A4 landscape; margin: 10mm; }
  ${printStampCss()}
  * { box-sizing: border-box; }
  body { font-family: ${PRINT_FONT_STACK}; color: #111; font-size: 11px; margin: 0; background: #eef1f4; }
  .toolbar { position: sticky; top: 0; padding: 10px 16px; background: #111827; color: #fff; font-size: 13px; z-index: 5; }
  .page { position: relative; background: #fff; margin: 12px auto; padding: 8mm; max-width: 277mm; }
  .page + .page { break-before: page; page-break-before: always; }
  .draft { position: absolute; top: 3mm; left: 50%; transform: translateX(-50%); color: #c9362b; font-weight: 700; border: 1px solid #c9362b; padding: 1px 8px; }
  .head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 6px; }
  h1 { font-size: 15px; margin: 0 0 4px; }
  .meta { display: flex; flex-wrap: wrap; gap: 14px; font-size: 12px; }
  .copy { border: 2px solid #111; padding: 3px 10px; font-weight: 700; font-size: 13px; white-space: nowrap; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border: 1px solid #555; padding: 0 4px; height: 9.5mm; }
  th { background: #f1f3f0; font-weight: 700; height: 7mm; }
  tr { break-inside: avoid; }
  tr.rest td { height: 6mm; text-align: center; background: #fbf3e6; color: #6b4a12; font-weight: 600; font-size: 10.5px; }
  .c { text-align: center; }
  .b { font-weight: 700; font-size: 12px; }
  .guide { margin: 6px 0 0; padding-left: 16px; color: #333; font-size: 10.5px; line-height: 1.5; }
  .sign { margin-top: 8px; display: flex; justify-content: flex-end; gap: 28px; font-size: 12px; }
  .sign .line { display: inline-block; width: 32mm; border-bottom: 1px solid #111; }
  @media print {
    body { background: #fff; }
    .toolbar { display: none; }
    .page { margin: 0; padding: 0; max-width: none; }
  }
</style></head><body>
<div class="toolbar">인쇄 창이 자동으로 열리지 않으면 Ctrl+P를 누르세요. 용지 A4 가로.</div>
${pages.join('\n') || '<p style="padding:24px">인쇄할 면접조가 없습니다.</p>'}
<script>window.addEventListener('load', function () { setTimeout(function () { window.print() }, 300) })</script>
</body></html>`
}
