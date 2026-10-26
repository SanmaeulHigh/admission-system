// 관리자 대리 채점 — 엑셀 일괄 입력 (2026-10-01)
//
// 흐름: [양식 내려받기] → 엑셀에 입력 → [엑셀 올리기] → 미리보기(행별 판정) → [제출]
// 판정·저장 요청 조립은 deepModel/documentModel을 그대로 쓴다. 종이 채점 일괄 입력과
// 한 명씩 대리 입력이 쓰는 것과 같은 admin_submit_*_score를 호출하므로 검증·계산·
// 감사 기록이 다른 입력 경로와 똑같다. 이미 제출된 점수는 덮어쓰지 않는다.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { roundToText } from '../../lib/applicantLabels'
import { CONTEXT_RPC, REASON_CODE, buildModel, cellValid, isBlank, planRow } from '../../lib/scoreEntry/deepModel'
import { buildDocumentModel, documentCellValid, planDocumentRow } from '../../lib/scoreEntry/documentModel'
import { buildScoreTemplate, downloadBuffer, parseScoreWorkbook } from '../../lib/scoreEntry/scoreExcel'

const DEEP = ['group', 'interview', 'writing']

const STATUS_VIEW = {
  ready: { label: '저장 가능', cls: 'bg-brand-greenSoft text-brand-deepGreenStrong' },
  partial: { label: '빈칸 있음', cls: 'bg-status-warningSoft text-status-warning' },
  invalid: { label: '잘못된 값', cls: 'bg-status-dangerSoft text-status-danger' },
  empty: { label: '입력 없음', cls: 'bg-surface-subtle text-ink-muted' },
  done: { label: '제출완료', cls: 'bg-surface-subtle text-ink-muted' },
}

export default function ExcelScoreEntry({ area, areaLabel, evaluatorUid, evaluatorName }) {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const isDeep = DEEP.includes(area)
  const [ctx, setCtx] = useState(null)
  const [applicantInfo, setApplicantInfo] = useState({})
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [draft, setDraft] = useState(null) // 올린 파일에서 읽은 값: rowId → { colKey → 문자열 }
  const [fileName, setFileName] = useState('')
  const [parseErrors, setParseErrors] = useState([])
  const [saving, setSaving] = useState(false)
  const [results, setResults] = useState({}) // rowId → { ok, message }
  const fileRef = useRef(null)

  const loadCtx = useCallback(async () => {
    if (!evaluatorUid || !YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: err } = isDeep
      ? await supabase.rpc(CONTEXT_RPC[area], { p_year: YEAR, p_round: ROUND, p_target_evaluator_uid: evaluatorUid })
      : await supabase.rpc('admin_get_document_score_entry_context', {
        p_year: YEAR, p_round: ROUND, p_area: area, p_target_evaluator_uid: evaluatorUid,
      })
    if (!err && area === 'academic') {
      // 학업성실도: 원서 학적(입력 유형)·반영 학기를 양식에 미리 넣는다.
      const { data: apps } = await supabase
        .from('applicants')
        .select('id, academic_status, semester_choice')
        .eq('year', YEAR)
        .eq('round', ROUND)
      setApplicantInfo(Object.fromEntries((apps || []).map((a) => [a.id, { academicStatus: a.academic_status, semesterChoice: a.semester_choice }])))
    }
    setLoading(false)
    if (err) {
      setError(err.message)
      setCtx(null)
      return
    }
    setCtx(data)
  }, [area, evaluatorUid, YEAR, ROUND, isDeep])

  // 영역·위원이 바뀌면 올린 파일 내용은 버린다(다른 위원 칸에 잘못 저장 방지).
  useEffect(() => {
    setDraft(null)
    setFileName('')
    setParseErrors([])
    setResults({})
    setCtx(null)
    loadCtx()
  }, [loadCtx])

  const { columns, rows } = useMemo(
    () => (isDeep ? buildModel(area, ctx) : buildDocumentModel(area, ctx, applicantInfo)),
    [isDeep, area, ctx, applicantInfo],
  )

  const plans = useMemo(() => {
    if (!draft) return {}
    const out = {}
    for (const r of rows) {
      out[r.id] = isDeep
        ? planRow(area, ctx, columns, r, draft[r.id], undefined, evaluatorUid)
        : planDocumentRow(area, columns, r, draft[r.id], evaluatorUid)
    }
    return out
  }, [draft, rows, isDeep, area, ctx, columns, evaluatorUid])

  const counts = useMemo(() => {
    const c = { ready: 0, partial: 0, invalid: 0, empty: 0, done: 0 }
    Object.values(plans).forEach((p) => { c[p.status] += 1 })
    return c
  }, [plans])

  // 면접은 학생·학부모를 따로 저장할 수 있어, 한쪽만 완성된 줄도 그쪽은 저장한다.
  const saveTargets = rows.filter((r) => {
    const p = plans[r.id]
    if (!p || results[r.id]?.ok) return false
    return p.status === 'ready' || (area === 'interview' && p.calls?.length > 0)
  })
  const callCount = saveTargets.reduce((s, r) => s + plans[r.id].calls.length, 0)

  const downloadTemplate = async () => {
    setError(null)
    try {
      const buffer = await buildScoreTemplate(
        { area, areaLabel, evaluatorUid, evaluatorName, year: YEAR, round: ROUND, roundLabel: roundToText(ROUND) },
        columns,
        rows,
      )
      const stamp = new Date().toISOString().slice(0, 10).replaceAll('-', '')
      downloadBuffer(buffer, `${YEAR}_${roundToText(ROUND)}_${areaLabel}_${evaluatorName}_대리입력양식_${stamp}.xlsx`)
    } catch (err) {
      setError(`양식을 만들지 못했습니다: ${err.message}`)
    }
  }

  const onFile = async (event) => {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file) return
    setError(null)
    setResults({})
    try {
      const { draft: parsed, errors } = await parseScoreWorkbook(
        await file.arrayBuffer(),
        { area, evaluatorUid, year: YEAR, round: ROUND },
        columns,
        rows,
      )
      setDraft(parsed)
      setParseErrors(errors)
      setFileName(file.name)
    } catch (err) {
      setDraft(null)
      setFileName('')
      setParseErrors([])
      setError(err.message)
    }
  }

  const save = async () => {
    if (callCount === 0) return
    // eslint-disable-next-line no-alert
    if (!window.confirm(`${saveTargets.length}명(${callCount}건)을 ${evaluatorName} 위원 명의로 제출확정합니다.\n제출확정된 점수는 재개방 전에는 고칠 수 없습니다.\n종이 원본과 한 번 더 확인하셨나요?`)) return
    setSaving(true)
    setError(null)
    const next = { ...results }
    for (const r of saveTargets) {
      const msgs = []
      let ok = true
      for (const c of plans[r.id].calls) {
        // eslint-disable-next-line no-await-in-loop
        const { error: err } = await supabase.rpc(c.rpc, c.args)
        if (err) {
          ok = false
          msgs.push(`${c.label}: ${err.message}`)
        } else {
          msgs.push(`${c.label} 저장`)
        }
      }
      next[r.id] = { ok, message: msgs.join(' · ') }
    }
    setResults(next)
    setSaving(false)
    await loadCtx() // 저장된 줄은 '제출완료'로 바뀐다
  }

  const valid = (col, raw) => (isDeep ? cellValid(col, raw) : documentCellValid(col, raw))

  if (!evaluatorUid) {
    return <div className="rounded-xl border border-dashed bg-white p-6 text-center text-sm text-ink-muted">평가위원을 선택하면 엑셀 양식을 내려받을 수 있습니다.</div>
  }

  return (
    <div className="space-y-4">
      <input ref={fileRef} type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" className="hidden" onChange={onFile} />

      <section className="rounded-xl border bg-white p-4">
        <h2 className="text-sm font-semibold text-ink-primary">{areaLabel} · {evaluatorName} 위원 엑셀 일괄 입력</h2>
        <ol className="mt-2 list-decimal space-y-0.5 pl-5 text-xs text-ink-secondary">
          <li>[양식 내려받기]로 이 위원의 채점 대상(수험번호 순)이 들어 있는 엑셀을 받습니다.</li>
          <li>종이 채점표를 보며 점수를 입력하고 저장합니다. 칸별 허용 값은 &lsquo;작성 안내&rsquo; 시트에 있습니다.</li>
          <li>[엑셀 올리기]로 파일을 올리면 아래에 미리보기가 나옵니다. 확인 후 [제출]을 누르면 저장됩니다.</li>
        </ol>
        <p className="mt-2 text-xs text-ink-muted">사유는 &lsquo;{REASON_CODE}&rsquo;로 기록됩니다. 이미 제출된 점수는 덮어쓰지 않습니다(고치려면 재개방 후 다시 올리세요).</p>
        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" onClick={downloadTemplate} disabled={loading || !ctx} className="rounded-lg border border-border px-4 py-2 text-sm font-semibold text-ink-secondary hover:bg-surface-subtle disabled:opacity-40">
            양식 내려받기
          </button>
          <button type="button" onClick={() => fileRef.current?.click()} disabled={loading || !ctx} className="rounded-lg bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
            엑셀 올리기
          </button>
          {fileName && <span className="self-center text-xs text-ink-muted">올린 파일: {fileName}</span>}
        </div>
      </section>

      {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}
      {error && <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>}
      {ctx && ctx.areaOpen === false && (
        <div className="rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
          현재 이 평가영역이 열려있지 않아 제출이 서버에서 차단됩니다. 양식 작성은 미리 해 둘 수 있습니다.
        </div>
      )}
      {parseErrors.length > 0 && (
        <div className="rounded-lg border border-status-warning bg-status-warningSoft p-3 text-xs text-status-warning">
          <p className="mb-1 font-semibold">읽지 못한 줄이 있습니다</p>
          <ul className="list-disc pl-5">{parseErrors.map((m) => <li key={m}>{m}</li>)}</ul>
        </div>
      )}

      {draft && (
        <section className="rounded-xl border bg-white p-4">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm text-ink-secondary">
              저장 가능 <b className="text-brand-deepGreenStrong">{counts.ready}</b> · 빈칸 있음 <b>{counts.partial}</b> · 잘못된 값 <b className="text-status-danger">{counts.invalid}</b> · 입력 없음 {counts.empty} · 제출완료 {counts.done}
            </p>
            <button
              type="button"
              onClick={save}
              disabled={saving || callCount === 0}
              className="rounded-lg bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
            >
              {saving ? '제출 중…' : `저장 가능한 ${saveTargets.length}명 제출`}
            </button>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full text-left text-xs">
              <thead className="border-b border-border text-ink-muted">
                <tr>
                  <th className="sticky left-0 bg-white px-2 py-2">수험번호</th>
                  <th className="px-2 py-2">성명</th>
                  <th className="px-2 py-2">판정</th>
                  {columns.map((c) => (
                    <th key={c.key} className="whitespace-nowrap px-2 py-2 text-center" title={c.group ? `${c.group} · ${c.label}` : c.label}>
                      {c.group && isDeep ? `${c.group}·` : ''}{c.label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const p = plans[r.id] || { status: 'empty' }
                  const res = results[r.id]
                  const view = STATUS_VIEW[p.status]
                  const cells = { ...(r.prefill || {}), ...(draft[r.id] || {}) }
                  return (
                    <tr key={r.id} className={`border-b border-border ${p.status === 'done' ? 'text-ink-muted' : ''}`}>
                      <td className="sticky left-0 bg-white px-2 py-1.5 font-mono font-semibold">{r.examNo || '-'}</td>
                      <td className="whitespace-nowrap px-2 py-1.5">{r.name}</td>
                      <td className="whitespace-nowrap px-2 py-1.5">
                        <span className={`rounded-full px-2 py-0.5 font-medium ${res ? (res.ok ? STATUS_VIEW.ready.cls : STATUS_VIEW.invalid.cls) : view.cls}`}>
                          {res ? (res.ok ? '저장됨' : '저장 실패') : view.label}
                        </span>
                        {(res?.message || p.message) && <span className="ml-1.5 text-[11px] text-ink-muted">{res?.message || p.message}</span>}
                      </td>
                      {columns.map((c) => {
                        const raw = cells[c.key]
                        const bad = p.status !== 'done' && !valid(c, raw)
                        return (
                          <td key={c.key} className={`whitespace-nowrap px-2 py-1.5 text-center ${bad ? 'bg-status-dangerSoft font-semibold text-status-danger' : ''} ${c.key === 'memo' ? 'max-w-[240px] truncate text-left' : ''}`} title={c.key === 'memo' ? String(raw ?? '') : undefined}>
                            {isBlank(raw) ? '' : String(raw)}
                          </td>
                        )
                      })}
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  )
}
