// 종이 채점 일괄 입력 (2026-09-28)
//
// 배경: 심층역량평가(모둠활동·면접·글쓰기)는 종이 채점표로 운영하고, 평가가
// 끝난 뒤 관리자가 시스템에 옮겨 적기로 했다(2026-09-28 결정 — 본관 네트워크
// 구축 예산 부족). 기존 '관리자 대리 채점 입력'은 한 명씩 버튼을 눌러 입력하는
// 화면이라 인원이 많으면 오래 걸린다. 이 화면은 위원 한 명의 채점표 묶음을
// 표 한 장에 키보드로 쭉 입력한다.
//
// 저장은 기존 admin_submit_group/interview/writing_score(00052)를 그대로 쓴다 —
// 배정 확인·문항 완결성·중복 제출 차단·영역 오픈 여부 검증과 감사 기록이
// 한 명씩 입력할 때와 똑같이 적용된다. 사유는 '평가위원 접속 불가(종이채점 대리입력)'.
//
// 대조 절차(2026-09-28 결정): 입력을 마치면 '입력 확인표'를 위원별로 인쇄해
// 위원이 종이 원본과 대조한 뒤 서명한다.
//
// 입력 중인 값은 이 브라우저에 임시 저장된다(새로고침·실수로 닫아도 유지).
// 저장(제출확정)된 줄은 서버 값이 우선이고 임시값은 지워진다.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { printFontFaceCss, PRINT_FONT_STACK } from '../../lib/printFont'
import ReopenScoreButton from '../../components/actions/ReopenScoreButton'
import {
  DEEP_AREAS as AREAS,
  CONTEXT_RPC,
  buildModel,
  cellValid,
  isBlank,
  planRow,
} from '../../lib/scoreEntry/deepModel'
import { printStampCss } from '../../lib/printStamp'

function rowTotal(columns, values) {
  return columns.reduce((s, c) => s + (isBlank(values?.[c.key]) ? 0 : Number(values[c.key]) || 0), 0)
}

function escapeHtml(v) {
  return String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]))
}

// ------------------------------------------------------------

export default function PaperScoreBulkEntryPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [area, setArea] = useState('group')
  const [evaluators, setEvaluators] = useState([])
  const [evaluatorUid, setEvaluatorUid] = useState('')
  const [ctx, setCtx] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [draft, setDraft] = useState({}) // rowId → { colKey → 문자열 }
  const [segDraft, setSegDraft] = useState({}) // rowId → segmentId[] (모둠활동)
  const [draftKey, setDraftKey] = useState(null) // 지금 draft가 어느 위원 것인지(다른 위원 칸에 잘못 저장 방지)
  const [saving, setSaving] = useState(false)
  const [results, setResults] = useState({}) // rowId → { ok, message }
  const gridRef = useRef(null)

  const storageKey = evaluatorUid && YEAR && ROUND ? `paperEntry:${YEAR}:${ROUND}:${area}:${evaluatorUid}` : null

  // 위원 목록
  useEffect(() => {
    setEvaluatorUid('')
    setCtx(null)
    setError(null)
    supabase.rpc('admin_list_score_entry_evaluators', { p_area: area }).then(({ data, error: err }) => {
      if (err) setError(err.message)
      else setEvaluators(data || [])
    })
  }, [area])

  const loadCtx = useCallback(async () => {
    if (!evaluatorUid || !YEAR || !ROUND) {
      setCtx(null)
      return
    }
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc(CONTEXT_RPC[area], {
      p_year: YEAR,
      p_round: ROUND,
      p_target_evaluator_uid: evaluatorUid,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      setCtx(null)
      return
    }
    setCtx(data)
  }, [area, evaluatorUid, YEAR, ROUND])

  // 위원을 바꾸면 임시 저장값 불러오기
  useEffect(() => {
    setResults({})
    let saved = {}
    let savedSeg = {}
    if (storageKey) {
      try {
        const parsed = JSON.parse(localStorage.getItem(storageKey) || '{}')
        saved = parsed.draft || {}
        savedSeg = parsed.seg || {}
      } catch {
        // 임시값이 깨져 있으면 무시
      }
    }
    setDraft(saved)
    setSegDraft(savedSeg)
    setDraftKey(storageKey)
    loadCtx()
  }, [storageKey, loadCtx])

  // 임시 저장
  useEffect(() => {
    if (!storageKey || draftKey !== storageKey) return
    try {
      localStorage.setItem(storageKey, JSON.stringify({ draft, seg: segDraft }))
    } catch {
      // 저장 공간 문제 등은 무시(입력 자체는 계속 가능)
    }
  }, [storageKey, draftKey, draft, segDraft])

  const { columns, rows } = useMemo(() => buildModel(area, ctx), [area, ctx])

  const plans = useMemo(() => {
    const out = {}
    for (const r of rows) out[r.id] = planRow(area, ctx, columns, r, draft[r.id], segDraft[r.id], evaluatorUid)
    return out
  }, [area, ctx, columns, rows, draft, segDraft, evaluatorUid])

  const counts = useMemo(() => {
    const c = { done: 0, ready: 0, partial: 0, invalid: 0, empty: 0 }
    Object.values(plans).forEach((p) => { c[p.status] += 1 })
    return c
  }, [plans])

  const segmentLabel = useMemo(
    () => Object.fromEntries((ctx?.segments || []).map((s) => [s.segmentId, s.segmentCode])),
    [ctx],
  )

  const setCell = (rowId, colKey, value) => {
    setDraft((cur) => ({ ...cur, [rowId]: { ...(cur[rowId] || {}), [colKey]: value } }))
  }

  const toggleSegment = (row, segId) => {
    setSegDraft((cur) => {
      const base = cur[row.id] ?? row.allowedSegmentIds
      const next = base.includes(segId) ? base.filter((s) => s !== segId) : [...base, segId]
      return { ...cur, [row.id]: next }
    })
  }

  // Enter: 아래 줄 같은 칸으로 이동 (Tab은 브라우저 기본대로 오른쪽 칸)
  const onKeyDown = (event, rowIndex, colIndex) => {
    if (event.key !== 'Enter' && event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
    event.preventDefault()
    const dir = event.key === 'ArrowUp' ? -1 : 1
    for (let r = rowIndex + dir; r >= 0 && r < rows.length; r += dir) {
      const el = gridRef.current?.querySelector(`input[data-r="${r}"][data-c="${colIndex}"]:not([disabled])`)
      if (el) {
        el.focus()
        el.select()
        return
      }
    }
  }

  const saveReady = async () => {
    const targets = rows.filter((r) => plans[r.id]?.calls?.length > 0 && ['ready', 'partial', 'invalid'].includes(plans[r.id].status))
      .filter((r) => plans[r.id].status === 'ready' || area === 'interview')
    const callCount = targets.reduce((s, r) => s + plans[r.id].calls.length, 0)
    if (callCount === 0) return
    if (!window.confirm(`${callCount}건을 제출확정합니다. 제출확정된 점수는 재개방 전에는 고칠 수 없습니다.\n종이 원본과 한 번 더 확인하셨나요?`)) return

    setSaving(true)
    setError(null)
    const next = {}
    for (const r of targets) {
      const msgs = []
      let ok = true
      for (const call of plans[r.id].calls) {
        // eslint-disable-next-line no-await-in-loop
        const { error: err } = await supabase.rpc(call.rpc, call.args)
        if (err) {
          ok = false
          msgs.push(`${call.label}: ${err.message}`)
        } else {
          msgs.push(`${call.label} 저장`)
        }
      }
      next[r.id] = { ok, message: msgs.join(' / ') }
    }
    setResults(next)
    setSaving(false)
    await loadCtx()
  }

  // 서버에 저장된 줄의 임시값은 지운다(서버 값이 기준).
  useEffect(() => {
    if (!rows.length) return
    const doneIds = rows.filter((r) => plans[r.id]?.status === 'done').map((r) => r.id)
    if (doneIds.length === 0) return
    setDraft((cur) => {
      if (!doneIds.some((id) => cur[id])) return cur
      const copy = { ...cur }
      doneIds.forEach((id) => delete copy[id])
      return copy
    })
  }, [rows, plans])

  const evaluatorName = evaluators.find((e) => e.uid === evaluatorUid)?.displayName || ''
  const areaLabel = AREAS.find((a) => a.value === area)?.label

  const printConfirmation = () => {
    const doneRows = rows.filter((r) => r.server)
    const headGroups = []
    columns.forEach((c) => {
      const last = headGroups[headGroups.length - 1]
      if (c.group && last && last.group === c.group) last.span += 1
      else headGroups.push({ group: c.group || '', span: 1 })
    })
    const hasGroups = columns.some((c) => c.group)
    const body = doneRows.map((r) => `
      <tr>
        <td class="mono">${escapeHtml(r.examNo)}</td>
        <td>${escapeHtml(r.name)}${r.sub ? `<div class="sub">${escapeHtml(r.sub)}</div>` : ''}</td>
        ${columns.map((c) => `<td class="num">${isBlank(r.server?.[c.key]) ? '' : escapeHtml(r.server[c.key])}</td>`).join('')}
        <td class="num strong">${escapeHtml(rowTotal(columns, r.server))}</td>
      </tr>`).join('')
    const notDone = rows.length - doneRows.length
    const html = `<!doctype html><html><head><meta charset="utf-8">
<title>${escapeHtml(areaLabel)} 입력 확인표 - ${escapeHtml(evaluatorName)}</title>
<style>
  ${printFontFaceCss()}
  @page { size: A4 ${columns.length > 8 ? 'landscape' : 'portrait'}; margin: 12mm; }
  ${printStampCss()}
  body { font-family: ${PRINT_FONT_STACK}; color: #111; font-size: 11px; margin: 0; }
  h1 { font-size: 17px; margin: 0 0 4px; }
  .meta { color: #444; margin-bottom: 10px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border: 1px solid #999; padding: 4px 5px; }
  th { background: #f1f3f0; font-weight: 700; }
  .num { text-align: center; font-variant-numeric: tabular-nums; }
  .mono { font-variant-numeric: tabular-nums; text-align: center; }
  .strong { font-weight: 700; }
  .sub { color: #666; font-size: 9px; }
  .warn { margin-top: 8px; color: #b56b00; }
  .sign { margin-top: 18px; font-size: 12px; line-height: 2; }
  .sign .line { display: inline-block; min-width: 45mm; border-bottom: 1px solid #111; }
  .toolbar { padding: 10px; background: #111827; color: #fff; }
  @media print { .toolbar { display: none; } }
</style></head><body>
<div class="toolbar">인쇄 창이 자동으로 열리지 않으면 Ctrl+P를 누르세요.</div>
<div style="padding: 6mm 0;">
<h1>${escapeHtml(YEAR)}학년도 심층역량평가 ${escapeHtml(areaLabel)} 채점 입력 확인표</h1>
<div class="meta">평가위원: <b>${escapeHtml(evaluatorName)}</b> · 출력: ${escapeHtml(new Date().toLocaleString('ko-KR'))} · 제출확정 ${doneRows.length}건</div>
<table>
  <thead>
    ${hasGroups ? `<tr><th rowspan="2">수험번호</th><th rowspan="2">성명</th>${headGroups.map((h) => `<th colspan="${h.span}">${escapeHtml(h.group)}</th>`).join('')}<th rowspan="2">합계</th></tr>
    <tr>${columns.map((c) => `<th>${escapeHtml(c.label)}</th>`).join('')}</tr>`
    : `<tr><th>수험번호</th><th>성명</th>${columns.map((c) => `<th>${escapeHtml(c.label)}</th>`).join('')}<th>합계</th></tr>`}
  </thead>
  <tbody>${body || `<tr><td colspan="${columns.length + 3}" class="num">제출확정된 채점이 없습니다.</td></tr>`}</tbody>
</table>
${notDone > 0 ? `<p class="warn">※ 아직 입력되지 않은 지원자 ${notDone}명은 이 표에 없습니다.</p>` : ''}
<div class="sign">
  위 점수가 본인이 작성한 종이 채점표 원본과 일치함을 확인합니다.<br>
  확인일: <span class="line"></span> &nbsp;&nbsp; 평가위원: <b>${escapeHtml(evaluatorName)}</b> <span class="line"></span> (서명)<br>
  입력자: <span class="line"></span> (서명)
</div>
</div>
<script>window.addEventListener('load', function () { setTimeout(function () { window.print() }, 300) })</script>
</body></html>`
    const w = window.open('', '_blank')
    if (!w) {
      alert('팝업이 차단되었습니다. 이 사이트의 팝업을 허용해 주세요.')
      return
    }
    w.document.open()
    w.document.write(html)
    w.document.close()
  }

  const headGroups = useMemo(() => {
    const out = []
    columns.forEach((c) => {
      const last = out[out.length - 1]
      if (c.group && last && last.group === c.group) last.span += 1
      else out.push({ group: c.group || '', span: 1 })
    })
    return out
  }, [columns])
  const hasGroups = columns.some((c) => c.group)
  const saveCount = rows.reduce((s, r) => {
    const p = plans[r.id]
    if (p?.status === 'ready' || area === 'interview') return s + (p?.calls?.length || 0)
    return s
  }, 0)

  return (
    <div className="mx-auto max-w-7xl space-y-4 pb-16">
      <div>
        <Link to="/deep/paper-backup" className="text-xs text-ink-muted underline">종이 채점표 출력 화면</Link>
        <h1 className="mt-1 text-lg font-semibold text-ink-primary">종이 채점 일괄 입력</h1>
        <p className="mt-1 text-xs text-ink-muted">
          위원 한 명의 종이 채점표를 표에 그대로 옮겨 적습니다. Tab은 오른쪽 칸, Enter·↓는 아래 칸으로 이동합니다.
          입력 중인 값은 이 브라우저에 임시 저장되며, &lsquo;제출확정&rsquo;을 눌러야 시스템에 반영됩니다.
          모든 입력은 대리 입력으로 감사 기록에 남습니다.
        </p>
      </div>

      <div className="flex flex-wrap items-end gap-4 rounded-card border border-border bg-surface-card p-4">
        <div>
          <p className="mb-1.5 text-xs font-semibold text-ink-muted">영역</p>
          <div className="flex gap-2">
            {AREAS.map((a) => (
              <button
                key={a.value}
                type="button"
                onClick={() => setArea(a.value)}
                className={`rounded-full border px-4 py-1.5 text-sm font-semibold ${area === a.value ? 'border-brand-deepGreen bg-brand-deepGreenStrong text-white' : 'border-border text-ink-secondary'}`}
              >
                {a.label}
              </button>
            ))}
          </div>
        </div>
        <label className="text-xs font-semibold text-ink-muted">
          평가위원
          <select
            value={evaluatorUid}
            onChange={(e) => setEvaluatorUid(e.target.value)}
            className="mt-1.5 block min-w-[16rem] rounded-lg border-border text-sm text-ink-primary"
          >
            <option value="">— 위원 선택 —</option>
            {evaluators.map((e) => (
              <option key={e.uid} value={e.uid}>{e.displayName} ({e.email})</option>
            ))}
          </select>
        </label>
        {ctx && (
          <div className="ml-auto flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={printConfirmation}
              className="rounded-md border border-brand-deepGreen px-4 py-2 text-sm font-medium text-brand-deepGreenStrong hover:bg-brand-greenSoft"
            >
              입력 확인표 인쇄
            </button>
            <button
              type="button"
              onClick={saveReady}
              disabled={saving || saveCount === 0 || !ctx.areaOpen}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
            >
              {saving ? '저장 중…' : `완성된 ${saveCount}건 제출확정`}
            </button>
          </div>
        )}
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {ctx && !ctx.areaOpen && (
        <p className="rounded-md border border-status-warning bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
          이 영역이 아직 열려 있지 않아 제출확정할 수 없습니다. 입력은 해 두고, 영역을 연 뒤 제출하세요(임시 저장됨).
        </p>
      )}
      {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}

      {ctx && rows.length === 0 && (
        <p className="rounded-md border border-dashed border-border bg-white p-6 text-center text-sm text-ink-muted">
          이 위원에게 배정된 지원자가 없습니다. 평가 계획(조편성·면접조·글쓰기 계획)을 먼저 확인하세요.
        </p>
      )}

      {ctx && rows.length > 0 && (
        <>
          <p className="text-xs text-ink-secondary">
            전체 {rows.length}명 · 제출완료 {counts.done} · 입력 완성 {counts.ready} · 미완성 {counts.partial} · 오류 {counts.invalid} · 미입력 {counts.empty}
            {area === 'writing' && ` · 문항 ${Number(ctx.config?.questionRule?.pick || 2)}개만 채우세요(선택하지 않은 문항은 빈칸)`}
          </p>
          <div ref={gridRef} className="overflow-x-auto rounded-card border border-border bg-surface-card">
            <table className="min-w-full text-sm">
              <thead className="bg-surface-subtle text-xs text-ink-secondary">
                {hasGroups && (
                  <tr>
                    <th colSpan={2} />
                    {headGroups.map((h, i) => (
                      <th key={i} colSpan={h.span} className="border-l border-border px-2 py-1.5 text-center font-semibold">{h.group}</th>
                    ))}
                    <th colSpan={area === 'group' ? 3 : 2} />
                  </tr>
                )}
                <tr>
                  <th className="px-3 py-2 text-left font-semibold">수험번호</th>
                  <th className="px-3 py-2 text-left font-semibold">성명</th>
                  {columns.map((c) => (
                    <th key={c.key} className="border-l border-border px-2 py-2 text-center font-semibold" title={`허용 점수: ${c.values.join(', ')}`}>
                      {c.label}
                      <div className="text-[10px] font-normal text-ink-muted">{c.values[0]}~{c.values[c.values.length - 1]}</div>
                    </th>
                  ))}
                  {area === 'group' && <th className="border-l border-border px-2 py-2 text-center font-semibold">관찰 구간</th>}
                  <th className="border-l border-border px-2 py-2 text-center font-semibold">합계</th>
                  <th className="px-3 py-2 text-left font-semibold">상태</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {rows.map((r, ri) => {
                  const plan = plans[r.id]
                  const values = { ...(draft[r.id] || {}), ...(r.server || {}) }
                  const result = results[r.id]
                  const segs = segDraft[r.id] ?? r.serverSegments ?? r.allowedSegmentIds
                  return (
                    <tr key={r.id} className={plan.status === 'done' ? 'bg-brand-greenSoft/40' : ''}>
                      <td className="px-3 py-1.5 font-semibold tabular-nums text-ink-primary">{r.examNo}</td>
                      <td className="px-3 py-1.5">
                        <span className="font-semibold text-ink-primary">{r.name}</span>
                        {r.sub && <span className="ml-1 text-[11px] text-ink-muted">{r.sub}</span>}
                      </td>
                      {columns.map((c, ci) => {
                        const locked = area === 'interview'
                          ? Boolean(r.lockedSections?.[c.section])
                          : plan.status === 'done'
                        const raw = values[c.key]
                        const bad = !locked && !cellValid(c, raw)
                        return (
                          <td key={c.key} className="border-l border-border px-1 py-1 text-center">
                            <input
                              data-r={ri}
                              data-c={ci}
                              value={isBlank(raw) ? '' : String(raw)}
                              disabled={locked || saving}
                              inputMode="decimal"
                              onChange={(e) => setCell(r.id, c.key, e.target.value)}
                              onKeyDown={(e) => onKeyDown(e, ri, ci)}
                              onFocus={(e) => e.target.select()}
                              className={`w-14 rounded border px-1 py-1 text-center tabular-nums ${bad ? 'border-status-danger bg-status-dangerSoft' : 'border-border'} disabled:border-transparent disabled:bg-transparent disabled:font-semibold disabled:text-ink-primary`}
                            />
                          </td>
                        )
                      })}
                      {area === 'group' && (
                        <td className="border-l border-border px-2 py-1">
                          <div className="flex flex-wrap justify-center gap-1">
                            {r.allowedSegmentIds.map((sid) => {
                              const on = segs?.includes(sid)
                              return (
                                <button
                                  key={sid}
                                  type="button"
                                  tabIndex={-1}
                                  disabled={plan.status === 'done' || saving}
                                  onClick={() => toggleSegment(r, sid)}
                                  className={`rounded-full border px-2 py-0.5 text-[11px] ${on ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border text-ink-muted line-through'}`}
                                  title="실제로 관찰한 구간만 남기세요"
                                >
                                  {segmentLabel[sid] || '구간'}
                                </button>
                              )
                            })}
                          </div>
                        </td>
                      )}
                      <td className="border-l border-border px-2 py-1.5 text-center font-semibold tabular-nums">
                        {rowTotal(columns, values) || ''}
                      </td>
                      <td className="px-3 py-1.5 text-xs">
                        <RowStatus plan={plan} result={result} />
                        {/* 제출확정된 줄은 재개방할 수 있다. 재개방하면 입력했던 값을 칸에 다시 채워 둔다. */}
                        {(area === 'interview'
                          ? ['student', 'parent'].filter((sec) => r.lockedSections?.[sec])
                          : plan.status === 'done' ? [null] : []
                        ).map((sec) => (
                          <ReopenScoreButton
                            key={sec || 'one'}
                            area={area === 'interview' ? `interview_${sec}` : area}
                            applicantId={r.applicantId}
                            evaluatorUid={evaluatorUid}
                            label={sec ? `${sec === 'student' ? '학생' : '학부모'} 재개방` : '재개방'}
                            targetText={`${r.examNo || ''} ${r.name}`}
                            className="ml-2 text-[11px] text-status-warning underline"
                            onDone={async () => {
                              const keep = Object.fromEntries(
                                Object.entries(r.server || {}).filter(([k]) => !sec || k.startsWith(`${sec}:`)),
                              )
                              setDraft((cur) => ({ ...cur, [r.id]: { ...(cur[r.id] || {}), ...keep } }))
                              await loadCtx()
                            }}
                          />
                        ))}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}

function RowStatus({ plan, result }) {
  if (result && !result.ok) return <span className="text-status-danger">{result.message}</span>
  switch (plan.status) {
    case 'done':
      return <span className="font-semibold text-brand-deepGreenStrong">제출완료</span>
    case 'ready':
      return <span className="text-brand-blue">입력 완성</span>
    case 'partial':
      return <span className="text-status-warning">{plan.message || '미완성'}</span>
    case 'invalid':
      return <span className="text-status-danger">{plan.message || '오류'}</span>
    default:
      return <span className="text-ink-muted">—</span>
  }
}
