// 심층역량평가(모둠활동·면접·글쓰기) 관리자 대리 입력용 표 모델 (2026-10-01 분리)
//
// 원래 PaperScoreBulkEntryPage.jsx(종이 채점 일괄 입력) 안에 있던 코드다.
// 엑셀 일괄 입력도 같은 검증·저장 요청 조립을 써야 해서 그대로 옮겨 공유한다
// (로직을 두 벌로 두면 한쪽만 고쳐져 입력 경로마다 판정이 달라질 수 있다).
//
// buildModel(area, ctx) → { columns, rows }
// planRow(area, ctx, columns, row, draft, segDraft, evaluatorUid) → { status, calls, message }
//   status: 'empty' | 'partial' | 'invalid' | 'ready' | 'done'

export const REASON_CODE = '평가위원 접속 불가(종이채점 대리입력)'

export const DEEP_AREAS = [
  { value: 'group', label: '모둠활동' },
  { value: 'interview', label: '면접' },
  { value: 'writing', label: '글쓰기' },
]

export const CONTEXT_RPC = {
  group: 'admin_get_group_score_entry_context',
  interview: 'admin_get_interview_score_entry_context',
  writing: 'admin_get_writing_score_entry_context',
}

const GROUP_CRITERION_LABELS = {
  contribution: '기여도',
  communication: '소통',
  logicCreativity: '논리·창의',
}

// ------------------------------------------------------------
// 영역별로 "행(지원자)"과 "열(입력 칸)"을 만든다.
// 열: { key, label, section?, values:[허용 점수], group?: 머리글 묶음 }
// ------------------------------------------------------------
export function buildModel(area, ctx) {
  if (!ctx) return { columns: [], rows: [] }

  if (area === 'group') {
    const max = Number(ctx.criterionMax || 5)
    const step = Number(ctx.scoreStep || 1)
    const values = []
    for (let v = 0; v <= max + 1e-9; v += step) values.push(Number(v.toFixed(2)))
    const columns = (ctx.criteria || []).map((key) => ({
      key,
      label: GROUP_CRITERION_LABELS[key] || key,
      values,
    }))
    const rows = []
    for (const g of ctx.groups || []) {
      for (const m of g.members || []) {
        const submitted = m.myScore?.submissionState === 'submitted'
        rows.push({
          id: m.applicantId,
          applicantId: m.applicantId,
          examNo: m.examNo,
          name: m.displayName,
          sub: `${g.groupCode}조 · ${g.observerRole === 'primary' ? '전담' : '순환'}`,
          observerRole: g.observerRole,
          allowedSegmentIds: g.allowedSegmentIds || [],
          server: submitted ? { ...(m.myScore.items || {}) } : null,
          serverSegments: m.myScore?.observedSegmentIds || null,
        })
      }
    }
    return { columns, rows }
  }

  if (area === 'interview') {
    const cols = []
    for (const section of ['student', 'parent']) {
      for (const c of ctx[section]?.criteria || []) {
        cols.push({
          key: `${section}:${c.key}`,
          criterionKey: c.key,
          section,
          group: section === 'student' ? '학생면접' : '학부모면접',
          label: c.label,
          values: (c.scoreValues || []).map(Number),
        })
      }
    }
    const rows = (ctx.schedule || []).map((s) => {
      const server = {}
      const locked = {}
      for (const section of ['student', 'parent']) {
        const sc = s.myScore?.[section]
        if (sc?.submissionState === 'submitted') {
          locked[section] = true
          for (const [k, v] of Object.entries(sc.items || {})) server[`${section}:${k}`] = v
        }
      }
      return {
        id: s.applicantId,
        applicantId: s.applicantId,
        examNo: s.examNo,
        name: s.displayName,
        sub: s.sortOrder ? `${s.sortOrder}번째` : '',
        server: Object.keys(server).length ? server : null,
        lockedSections: locked,
      }
    })
    return { columns: cols, rows }
  }

  // writing
  const questions = ctx.config?.questions || []
  const columns = []
  for (const q of questions) {
    for (const c of q.criteria || []) {
      columns.push({
        key: `${q.id}:${c.key}`,
        questionId: q.id,
        criterionKey: c.key,
        group: q.label,
        label: c.label,
        values: (c.scoreValues || []).map(Number),
      })
    }
  }
  const rows = (ctx.candidates || []).map((c) => {
    const submitted = c.myScore?.submissionState === 'submitted'
    const server = {}
    if (submitted) {
      for (const r of c.myScore.responses || []) {
        for (const [k, v] of Object.entries(r.items || {})) server[`${r.questionId}:${k}`] = v
      }
    }
    return {
      id: c.applicantId,
      applicantId: c.applicantId,
      examNo: c.examNo,
      name: c.displayName,
      sub: '',
      server: submitted ? server : null,
    }
  })
  return { columns, rows }
}

export function isBlank(v) {
  return v === undefined || v === null || String(v).trim() === ''
}

export function cellValid(col, raw) {
  if (isBlank(raw)) return true
  const n = Number(String(raw).trim())
  if (!Number.isFinite(n)) return false
  return col.values.some((v) => Math.abs(v - n) < 1e-9)
}

// 한 행을 저장 가능한 요청(들)으로 바꾼다. 반환: { status, calls:[{rpc,args,label}], message }
// status: 'empty' | 'partial' | 'invalid' | 'ready' | 'done'
export function planRow(area, ctx, columns, row, draft, segDraft, evaluatorUid) {
  const cells = draft || {}

  if (area === 'group') {
    if (row.server) return { status: 'done', calls: [] }
    const filled = columns.filter((c) => !isBlank(cells[c.key]))
    if (filled.length === 0) return { status: 'empty', calls: [] }
    if (columns.some((c) => !cellValid(c, cells[c.key]))) return { status: 'invalid', calls: [], message: '허용되지 않는 점수' }
    if (filled.length < columns.length) return { status: 'partial', calls: [], message: '기준 미입력' }
    const segments = segDraft ?? row.allowedSegmentIds
    if (!segments || segments.length === 0) return { status: 'invalid', calls: [], message: '관찰 구간 없음' }
    const items = Object.fromEntries(columns.map((c) => [c.key, Number(cells[c.key])]))
    return {
      status: 'ready',
      calls: [{
        rpc: 'admin_submit_group_score',
        label: '모둠활동',
        args: {
          p_applicant_id: row.applicantId,
          p_target_evaluator_uid: evaluatorUid,
          // 종이에 점수를 적었다는 것 자체가 "충분히 관찰했다"는 판단이다(순환관찰 포함).
          p_observation_confirmed: true,
          p_observed_segment_ids: segments,
          p_items: items,
          p_reason_code: REASON_CODE,
          p_reason_text: null,
        },
      }],
    }
  }

  if (area === 'interview') {
    const calls = []
    let anyPartial = false
    let anyInvalid = false
    let anyFilled = false
    for (const section of ['student', 'parent']) {
      const cols = columns.filter((c) => c.section === section)
      if (cols.length === 0) continue
      if (row.lockedSections?.[section]) continue
      const filled = cols.filter((c) => !isBlank(cells[c.key]))
      if (filled.length === 0) continue
      anyFilled = true
      if (cols.some((c) => !cellValid(c, cells[c.key]))) { anyInvalid = true; continue }
      if (filled.length < cols.length) { anyPartial = true; continue }
      calls.push({
        rpc: 'admin_submit_interview_score',
        label: section === 'student' ? '학생면접' : '학부모면접',
        args: {
          p_applicant_id: row.applicantId,
          p_section: section,
          p_target_evaluator_uid: evaluatorUid,
          p_items: Object.fromEntries(cols.map((c) => [c.criterionKey, Number(cells[c.key])])),
          p_memo: null,
          p_reason_code: REASON_CODE,
          p_reason_text: null,
        },
      })
    }
    const allLocked = ['student', 'parent'].every((s) => row.lockedSections?.[s] || !columns.some((c) => c.section === s))
    if (allLocked) return { status: 'done', calls: [] }
    if (anyInvalid) return { status: 'invalid', calls, message: '허용되지 않는 점수' }
    if (anyPartial) return { status: 'partial', calls, message: '기준 미입력' }
    if (!anyFilled) return { status: 'empty', calls: [] }
    return { status: 'ready', calls }
  }

  // writing
  if (row.server) return { status: 'done', calls: [] }
  const pick = Number(ctx?.config?.questionRule?.pick || 2)
  const byQuestion = new Map()
  for (const c of columns) {
    if (!byQuestion.has(c.questionId)) byQuestion.set(c.questionId, [])
    byQuestion.get(c.questionId).push(c)
  }
  const responses = []
  let anyFilled = false
  for (const [qid, cols] of byQuestion) {
    const filled = cols.filter((c) => !isBlank(cells[c.key]))
    if (filled.length === 0) continue
    anyFilled = true
    if (cols.some((c) => !cellValid(c, cells[c.key]))) return { status: 'invalid', calls: [], message: '허용되지 않는 점수' }
    if (filled.length < cols.length) return { status: 'partial', calls: [], message: '기준 미입력' }
    responses.push({ questionId: qid, items: Object.fromEntries(cols.map((c) => [c.criterionKey, Number(cells[c.key])])) })
  }
  if (!anyFilled) return { status: 'empty', calls: [] }
  if (responses.length !== pick) {
    return { status: 'partial', calls: [], message: `${pick}문항을 채워야 함(현재 ${responses.length})` }
  }
  return {
    status: 'ready',
    calls: [{
      rpc: 'admin_submit_writing_score',
      label: '글쓰기',
      args: {
        p_applicant_id: row.applicantId,
        p_target_evaluator_uid: evaluatorUid,
        p_responses: responses,
        p_memo: null,
        p_reason_code: REASON_CODE,
        p_reason_text: null,
      },
    }],
  }
}
