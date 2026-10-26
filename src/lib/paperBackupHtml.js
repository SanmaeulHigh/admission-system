import { PRINT_FONT_STACK, printFontFaceCss } from './printFont'
import { printStampCss } from './printStamp'
const AREA_LABEL = {
  group: '모둠활동',
  interview: '학생·학부모 면접',
  writing: '글쓰기',
}

const GROUP_CRITERION_LABEL = {
  contribution: '기여',
  communication: '의사소통',
  logicCreativity: '논리·창의',
}

function asArray(value) {
  return Array.isArray(value) ? value : []
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function chunk(items, size) {
  const result = []
  for (let index = 0; index < items.length; index += size) {
    result.push(items.slice(index, index + size))
  }
  return result
}

function formatDateTime(value) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return new Intl.DateTimeFormat('ko-KR', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(date)
}

function formatTime(value) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return new Intl.DateTimeFormat('ko-KR', {
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(date)
}

function shortId(value) {
  const text = String(value || '')
  return text ? `${text.slice(0, 8)}…${text.slice(-4)}` : '-'
}

function scoreValuesText(criterion, fallbackMax = null, fallbackStep = null) {
  const scoreValues = asArray(criterion?.scoreValues)
  if (scoreValues.length > 0) return scoreValues.join(' · ')
  if (fallbackMax != null && fallbackStep != null) return `0~${fallbackMax} / ${fallbackStep}점 단위`
  return '-'
}

function commonHeader({ title, year, round, generatedAt, draft }) {
  return `
    <div class="sheet-head">
      <div>
        <div class="school">새봄고등학교</div>
        <h1>${escapeHtml(year)}학년도 신입생 입학전형</h1>
        <h2>${escapeHtml(title)}</h2>
      </div>
      <div class="head-meta">
        <div>차수 <strong>${escapeHtml(round)}</strong></div>
        <div>출력 ${escapeHtml(formatDateTime(generatedAt))}</div>
        ${draft ? '<div class="draft-label">운영용 아님</div>' : '<div class="backup-label">종이 채점표</div>'}
      </div>
    </div>
  `
}

function commonFooter(packet, label, pageNo, pageTotal) {
  return `
    <div class="sheet-footer">
      <span>${escapeHtml(label)} · M4 snapshot ${escapeHtml(shortId(packet.documentDecisionRunId))} · plan rev ${escapeHtml(packet.planRevision ?? '-')}</span>
      <span>${pageNo} / ${pageTotal}</span>
    </div>
  `
}

function placeholderPage(packet, area, draft) {
  return `
    <section class="sheet placeholder-sheet">
      ${commonHeader({
        title: `${AREA_LABEL[area]} 평가표`,
        year: packet.year,
        round: packet.round,
        generatedAt: packet.generatedAt,
        draft,
      })}
      <div class="placeholder-box">
        <strong>생성할 평가표가 없습니다.</strong>
        <p>평가계획과 M4 final 합격자 명단을 확인하세요.</p>
      </div>
      ${commonFooter(packet, AREA_LABEL[area], 1, 1)}
    </section>
  `
}

function buildGroupPages(packet, draft) {
  const payload = packet.payload || {}
  const config = payload.config || {}
  const criteria = asArray(config.criteria).map((key) => ({
    key,
    label: GROUP_CRITERION_LABEL[key] || key,
  }))
  const evaluators = asArray(payload.evaluators)
  const pageDrafts = []

  evaluators.forEach((evaluator) => {
    const rows = []
    asArray(evaluator.groups).forEach((group) => {
      const segmentCodes = asArray(group.plannedSegments).map((segment) => segment.segmentCode)
      asArray(group.members).forEach((member) => {
        rows.push({
          ...member,
          groupCode: group.groupCode,
          observerRole: group.observerRole,
          segmentCodes,
        })
      })
    })
    const rowChunks = chunk(rows, 18)
    if (rowChunks.length === 0) rowChunks.push([])
    rowChunks.forEach((pageRows, index) => {
      pageDrafts.push({ evaluator, rows: pageRows, evaluatorPageNo: index + 1, evaluatorPageTotal: rowChunks.length })
    })
  })

  if (pageDrafts.length === 0) return [placeholderPage(packet, 'group', draft)]
  const totalPages = pageDrafts.length

  return pageDrafts.map(({ evaluator, rows, evaluatorPageNo, evaluatorPageTotal }, pageIndex) => `
    <section class="sheet group-sheet">
      ${commonHeader({
        title: '2단계 심층역량평가 모둠활동 평가표',
        year: packet.year,
        round: packet.round,
        generatedAt: packet.generatedAt,
        draft,
      })}
      <div class="meta-grid compact-meta">
        <div><span>전형위원</span><strong>${escapeHtml(evaluator.displayName || '-')}</strong></div>
        <div><span>위원별 페이지</span><strong>${evaluatorPageNo}/${evaluatorPageTotal}</strong></div>
        <div><span>위원별 만점</span><strong>${escapeHtml(config.perEvaluatorMax ?? 15)}점</strong></div>
        <div><span>서명</span><strong class="signature-line">(인)</strong></div>
      </div>
      <div class="instruction-line">
        순환관찰은 충분히 관찰한 지원자만 <strong>관찰확인</strong> 후 채점하고, 채점 후 관리자가 시스템에 입력하고, 입력 확인표로 원본과 대조합니다.
      </div>
      <table class="score-table group-table">
        <thead>
          <tr>
            <th>모둠</th>
            <th>수험번호</th>
            <th>성명</th>
            <th>역할</th>
            <th>계획 segment</th>
            ${criteria.map((criterion) => `<th>${escapeHtml(criterion.label)}<small>0~${escapeHtml(config.criterionMax ?? 5)}</small></th>`).join('')}
            <th>합계<small>/${escapeHtml(config.perEvaluatorMax ?? 15)}</small></th>
            <th>관찰확인</th>
            <th>특이사항</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td>${escapeHtml(row.groupCode)}</td>
              <td class="mono">${escapeHtml(row.examNo || '-')}</td>
              <td class="name-cell">${escapeHtml(row.displayName)}</td>
              <td>${row.observerRole === 'primary' ? '주관찰' : '순환'}</td>
              <td class="segment-cell">${escapeHtml(row.segmentCodes.join(', ') || '-')}</td>
              ${criteria.map(() => '<td class="blank-score"></td>').join('')}
              <td class="blank-score total-cell"></td>
              <td class="check-cell">□</td>
              <td class="remarks-cell"></td>
            </tr>
          `).join('')}
          ${rows.length === 0 ? `<tr><td colspan="${8 + criteria.length}" class="empty-row">배정된 지원자가 없습니다.</td></tr>` : ''}
        </tbody>
      </table>
      <div class="criterion-note">
        ${criteria.map((criterion) => `${escapeHtml(criterion.label)}: 0~${escapeHtml(config.criterionMax ?? 5)}점 (${escapeHtml(config.scoreStep ?? 1)}점 단위)`).join(' · ')}
      </div>
      ${commonFooter(packet, `모둠활동 · ${evaluator.displayName || '-'}`, pageIndex + 1, totalPages)}
    </section>
  `)
}

function rubricRows(criteria) {
  return asArray(criteria).map((criterion) => `
    <tr>
      <td class="criterion-name">${escapeHtml(criterion.label || criterion.key)}</td>
      <td class="allowed-values">${escapeHtml(scoreValuesText(criterion))}</td>
      <td class="blank-score wide-blank"></td>
    </tr>
  `).join('')
}

function buildInterviewPages(packet, draft) {
  const payload = packet.payload || {}
  const student = payload.student || {}
  const parent = payload.parent || {}
  const pageDrafts = []

  asArray(payload.teams).forEach((team) => {
    asArray(team.members).forEach((member) => {
      asArray(team.schedule).forEach((slot) => {
        pageDrafts.push({ team, member, slot })
      })
    })
  })

  if (pageDrafts.length === 0) return [placeholderPage(packet, 'interview', draft)]
  const totalPages = pageDrafts.length

  return pageDrafts.map(({ team, member, slot }, pageIndex) => `
    <section class="sheet interview-sheet">
      ${commonHeader({
        title: '2단계 심층역량평가 학생·학부모 면접 평가표',
        year: packet.year,
        round: packet.round,
        generatedAt: packet.generatedAt,
        draft,
      })}
      <div class="meta-grid interview-meta">
        <div><span>면접조</span><strong>${escapeHtml(team.teamCode)}</strong></div>
        <div><span>장소</span><strong>${escapeHtml(team.location || '-')}</strong></div>
        <div><span>수험번호</span><strong class="mono">${escapeHtml(slot.examNo || '-')}</strong></div>
        <div><span>지원자</span><strong>${escapeHtml(slot.displayName)}</strong></div>
        <div><span>전형위원</span><strong>${escapeHtml(member.displayName || '-')}</strong></div>
        <div><span>학생 / 학부모</span><strong>${escapeHtml(formatTime(slot.studentStartsAt))} / ${escapeHtml(formatTime(slot.parentStartsAt))}</strong></div>
      </div>
      <div class="instruction-line">각 영역의 허용 단계값 중 하나를 기재합니다. 학생면접과 학부모면접은 별도 제출·확정 영역입니다.</div>

      <div class="interview-section">
        <div class="section-title"><strong>학생면접</strong><span>${escapeHtml(student.perEvaluatorMax ?? 150)}점 만점 · 약 ${escapeHtml(student.durationMinutes ?? 25)}분</span></div>
        <table class="score-table rubric-table">
          <thead><tr><th>평가영역</th><th>허용 점수</th><th>점수</th></tr></thead>
          <tbody>${rubricRows(student.criteria)}</tbody>
        </table>
        <div class="subtotal-row"><span>학생면접 합계</span><strong>________ / ${escapeHtml(student.perEvaluatorMax ?? 150)}</strong><span>제출확정 □</span><span>시각 ______ : ______</span></div>
        <div class="memo-box"><span>학생면접 메모</span></div>
      </div>

      <div class="interview-section parent-section">
        <div class="section-title"><strong>학부모면접</strong><span>${escapeHtml(parent.perEvaluatorMax ?? 100)}점 만점 · 약 ${escapeHtml(parent.durationMinutes ?? 20)}분</span></div>
        <table class="score-table rubric-table">
          <thead><tr><th>평가영역</th><th>허용 점수</th><th>점수</th></tr></thead>
          <tbody>${rubricRows(parent.criteria)}</tbody>
        </table>
        <div class="subtotal-row"><span>학부모면접 합계</span><strong>________ / ${escapeHtml(parent.perEvaluatorMax ?? 100)}</strong><span>제출확정 □</span><span>시각 ______ : ______</span></div>
        <div class="memo-box small-memo"><span>학부모면접 메모</span></div>
      </div>

      <div class="signature-footer">전형위원 ${escapeHtml(member.displayName || '')} ____________________ (인)</div>
      ${commonFooter(packet, `${team.teamCode} · ${slot.examNo || '-'} · ${member.displayName || '-'}`, pageIndex + 1, totalPages)}
    </section>
  `)
}

function questionBlock(question) {
  return `
    <div class="question-block">
      <div class="question-title">
        <div><span class="select-box">□</span><strong>${escapeHtml(question.label || question.id)}</strong><span class="question-id">${escapeHtml(question.id)}</span></div>
        <div>문항합계 ______ / 100</div>
      </div>
      <table class="score-table writing-rubric-table">
        <thead><tr><th>평가영역</th><th>허용 점수</th><th>점수</th></tr></thead>
        <tbody>${rubricRows(question.criteria)}</tbody>
      </table>
    </div>
  `
}

function buildWritingPages(packet, draft) {
  const payload = packet.payload || {}
  const config = payload.config || {}
  const members = asArray(payload.members)
  const candidates = asArray(payload.candidates)
  const pageDrafts = []

  members.forEach((member) => {
    candidates.forEach((candidate) => pageDrafts.push({ member, candidate }))
  })

  if (pageDrafts.length === 0) return [placeholderPage(packet, 'writing', draft)]
  const totalPages = pageDrafts.length
  const rule = config.questionRule || {}

  return pageDrafts.map(({ member, candidate }, pageIndex) => `
    <section class="sheet writing-sheet">
      ${commonHeader({
        title: '2단계 심층역량평가 지원자 글쓰기 평가표',
        year: packet.year,
        round: packet.round,
        generatedAt: packet.generatedAt,
        draft,
      })}
      <div class="meta-grid writing-meta">
        <div><span>수험번호</span><strong class="mono">${escapeHtml(candidate.examNo || '-')}</strong></div>
        <div><span>지원자</span><strong>${escapeHtml(candidate.displayName)}</strong></div>
        <div><span>전형위원</span><strong>${escapeHtml(member.displayName || '-')}</strong></div>
        <div><span>위원별 만점</span><strong>${escapeHtml(config.perEvaluatorMax ?? 200)}점</strong></div>
      </div>
      <div class="instruction-line writing-instruction">
        ${escapeHtml(rule.of ?? 3)}문항 중 정확히 <strong>${escapeHtml(rule.pick ?? 2)}문항</strong>을 선택합니다. 선택문항 표시 □ 후 각 4개 평가영역을 모두 채점합니다. 미서술 0점 규칙은 평가 지침에 따릅니다.
      </div>
      <div class="writing-questions">
        ${asArray(config.questions).map(questionBlock).join('')}
      </div>
      <div class="writing-total-row">
        <span>선택 문항: ______ , ______</span>
        <strong>위원별 총점 ________ / ${escapeHtml(config.perEvaluatorMax ?? 200)}</strong>
        <span>제출확정 □</span>
      </div>
      <div class="writing-memo"><span>평가 메모</span></div>
      <div class="signature-footer">전형위원 ${escapeHtml(member.displayName || '')} ____________________ (인)</div>
      ${commonFooter(packet, `글쓰기 · ${candidate.examNo || '-'} · ${member.displayName || '-'}`, pageIndex + 1, totalPages)}
    </section>
  `)
}

function baseStyles(orientation, draft) {
  return `
    ${printFontFaceCss()}
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: #eef1f4; color: #111; }
    body { font-family: ${PRINT_FONT_STACK}; }
    @page { size: A4 ${orientation}; margin: 7mm; }
    ${printStampCss()}
    .screen-toolbar {
      position: sticky; top: 0; z-index: 20; display: flex; justify-content: space-between; align-items: center;
      padding: 10px 16px; background: #111827; color: white; font-size: 13px;
    }
    .screen-toolbar button { border: 0; border-radius: 6px; padding: 8px 14px; font-weight: 700; cursor: pointer; }
    .screen-toolbar .disabled-note { color: #fbbf24; font-weight: 700; }
    .sheet {
      position: relative; width: 100%; height: ${orientation === 'landscape' ? '196mm' : '283mm'}; min-height: ${orientation === 'landscape' ? '196mm' : '283mm'}; margin: 10px auto; background: white; padding: 0;
      page-break-after: always; break-after: page; overflow: hidden;
    }
    .sheet:last-of-type { page-break-after: auto; break-after: auto; }
    .sheet-head { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 2px solid #111; padding-bottom: 3mm; margin-bottom: 3mm; }
    .school { font-size: 8pt; color: #555; }
    h1 { margin: 0.5mm 0 0; font-size: 14pt; line-height: 1.2; }
    h2 { margin: 1mm 0 0; font-size: 12pt; line-height: 1.2; }
    .head-meta { text-align: right; font-size: 7.5pt; line-height: 1.6; }
    .draft-label, .backup-label { display: inline-block; margin-top: 1mm; border: 1px solid #111; padding: 0.5mm 2mm; font-weight: 700; }
    .draft-label { border-color: #9a3412; color: #9a3412; }
    .backup-label { color: #111; }
    .meta-grid { display: grid; gap: 1.5mm; margin-bottom: 2mm; }
    .meta-grid > div { display: flex; align-items: center; min-height: 7mm; border: 1px solid #999; }
    .meta-grid span { width: 25mm; padding: 1.5mm 2mm; color: #555; font-size: 7.5pt; background: #f3f4f6; }
    .meta-grid strong { flex: 1; padding: 1.5mm 2mm; font-size: 9pt; }
    .compact-meta { grid-template-columns: repeat(4, 1fr); }
    .interview-meta { grid-template-columns: repeat(3, 1fr); }
    .writing-meta { grid-template-columns: repeat(4, 1fr); }
    .signature-line { text-align: right; }
    .instruction-line { border: 1px solid #aaa; background: #f7f7f7; padding: 2mm 2.5mm; margin: 2mm 0 2.5mm; font-size: 7.3pt; line-height: 1.45; }
    .score-table { width: 100%; border-collapse: collapse; table-layout: fixed; }
    .score-table th, .score-table td { border: 1px solid #555; text-align: center; vertical-align: middle; }
    .score-table th { background: #eceff1; font-size: 7pt; padding: 1.2mm 0.8mm; }
    .score-table th small { display: block; margin-top: 0.5mm; font-size: 6pt; font-weight: 400; color: #555; }
    .score-table td { font-size: 7pt; padding: 1mm 0.7mm; height: 7mm; }
    .mono { font-family: Consolas, ${PRINT_FONT_STACK}; }
    .name-cell { font-weight: 700; }
    .blank-score { background: white; }
    .total-cell { border-left: 1.5px solid #111 !important; }
    .check-cell { font-size: 11pt !important; }
    .segment-cell { font-size: 6pt !important; line-height: 1.25; }
    .remarks-cell { text-align: left !important; }
    .criterion-note { margin-top: 1.5mm; margin-bottom: 8mm; font-size: 6.5pt; color: #444; }
    .sheet-footer { position: absolute; left: 0; right: 0; bottom: 0; display: flex; justify-content: space-between; border-top: 1px solid #aaa; padding-top: 1.5mm; font-size: 6pt; color: #555; }
    .rubric-table th:nth-child(1), .writing-rubric-table th:nth-child(1) { width: 42%; }
    .rubric-table th:nth-child(2), .writing-rubric-table th:nth-child(2) { width: 42%; }
    .rubric-table th:nth-child(3), .writing-rubric-table th:nth-child(3) { width: 16%; }
    .rubric-table td, .writing-rubric-table td { height: 7mm; font-size: 7.5pt; }
    .criterion-name { text-align: left !important; padding-left: 2mm !important; font-weight: 700; }
    .allowed-values { color: #333; }
    .wide-blank { font-size: 10pt; }
    .section-title, .question-title { display: flex; justify-content: space-between; align-items: center; margin: 2.5mm 0 1.2mm; }
    .section-title strong { font-size: 10pt; }
    .section-title span { font-size: 7pt; color: #555; }
    .subtotal-row { display: flex; justify-content: space-between; align-items: center; border: 1px solid #555; border-top: 0; min-height: 8mm; padding: 1.5mm 2mm; font-size: 7.5pt; }
    .memo-box, .writing-memo { position: relative; height: 18mm; border: 1px solid #777; margin-top: 1.5mm; }
    .memo-box span, .writing-memo span { position: absolute; top: 1mm; left: 1.5mm; font-size: 6.5pt; color: #666; }
    .small-memo { height: 14mm; }
    .signature-footer { margin-top: 2mm; margin-bottom: 8mm; text-align: right; font-size: 8pt; font-weight: 700; }
    .question-block { margin-top: 2.2mm; }
    .question-title { margin-bottom: 1mm; font-size: 8pt; }
    .question-title > div { display: flex; align-items: center; gap: 2mm; }
    .question-title > div:first-child { min-width: 46mm; }
    .question-title strong { white-space: nowrap; }
    .select-box { font-size: 12pt; }
    .question-id { color: #666; font-size: 6.5pt; }
    .writing-rubric-table td { height: 6.2mm; }
    .writing-total-row { display: flex; justify-content: space-between; align-items: center; border: 1.5px solid #111; padding: 2mm; margin-top: 2.5mm; font-size: 8pt; }
    .writing-memo { height: 20mm; }
    .placeholder-sheet { display: flex; flex-direction: column; }
    .placeholder-box { margin: 35mm auto; width: 70%; border: 2px dashed #999; padding: 15mm; text-align: center; }
    .placeholder-box strong { font-size: 16pt; }
    .placeholder-box p { font-size: 10pt; color: #666; }
    ${draft ? `.sheet::after {
      content: "운영용 아님 · 계획 미확정"; position: absolute; inset: 42% auto auto 50%; transform: translate(-50%, -50%) rotate(-24deg);
      font-size: 28pt; font-weight: 800; color: rgba(153, 27, 27, 0.12); white-space: nowrap; pointer-events: none; z-index: 10;
    }` : ''}
    @media screen {
      .sheet { width: ${orientation === 'landscape' ? '297mm' : '210mm'}; min-height: ${orientation === 'landscape' ? '210mm' : '297mm'}; padding: 7mm; box-shadow: 0 2px 12px rgba(0,0,0,.15); }
    }
    @media print {
      html, body { background: white; }
      .screen-toolbar { display: none !important; }
      .sheet { width: auto; height: ${orientation === 'landscape' ? '196mm' : '283mm'}; min-height: ${orientation === 'landscape' ? '196mm' : '283mm'}; margin: 0; padding: 0; box-shadow: none; }
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    }
  `
}

export function buildPaperBackupDocument(packet, { autoPrint = false } = {}) {
  const area = packet?.area
  if (!AREA_LABEL[area]) throw new Error(`지원하지 않는 종이 백업 영역입니다: ${area}`)

  const draft = packet?.ready !== true
  let pages
  let orientation = 'portrait'
  if (area === 'group') {
    pages = buildGroupPages(packet, draft)
    orientation = 'landscape'
  } else if (area === 'interview') {
    pages = buildInterviewPages(packet, draft)
  } else {
    pages = buildWritingPages(packet, draft)
  }

  const pageCount = pages.length
  const title = `${packet.year}학년도 ${AREA_LABEL[area]} 종이 채점표`
  const safeRound = String(packet.round || 'main').replace(/[^a-zA-Z0-9_-]/g, '_')
  const fileName = `${packet.year}_${safeRound}_${area}_paper_backup.pdf`
  const toolbar = packet.ready === true
    ? `<div><strong>${escapeHtml(title)}</strong> · ${pageCount}쪽</div><button type="button" onclick="window.print()">인쇄 / PDF 저장</button>`
    : `<div><strong>${escapeHtml(title)}</strong> · ${pageCount}쪽</div><div class="disabled-note">계획 미확정 · 초안 미리보기</div>`

  const html = `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  <style>${baseStyles(orientation, draft)}</style>
</head>
<body>
  <div class="screen-toolbar">${toolbar}</div>
  ${pages.join('\n')}
  <script>
    window.__M5E_PAGE_COUNT__ = ${pageCount};
    window.__M5E_FILE_NAME__ = ${JSON.stringify(fileName)};
    ${autoPrint && packet.ready === true ? `window.addEventListener('load', async () => { try { if (document.fonts && document.fonts.ready) await document.fonts.ready; } catch (_) {} setTimeout(() => window.print(), 120); });` : ''}
  </script>
</body>
</html>`

  return { html, pageCount, fileName, title, orientation }
}
