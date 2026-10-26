// 지원자 목록 — 엑셀처럼 보고 긁는 표 (2026-10-12)
//
// 보기·고르기·복사 전용이다. 칸 안에서 바로 고치는 방식은 써 보니 불편해서 뺐고,
// 줄을 더블클릭(또는 Enter)하면 지원자 정보 창이 열려 거기서 고친다.
//
// 칸 고르기: 클릭, 방향키, Tab, Ctrl+방향키(끝까지), Shift+방향키/드래그(여러 칸), Ctrl+A(전체)
// Ctrl+C: 고른 칸을 엑셀에 그대로 붙일 수 있게 복사

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { COLUMNS, DOC_MARKS, displayText } from './columns'
import SchoolRegionTip from './SchoolRegionTip'

const ROWNUM_W = 44
const CHECK_W = 36
const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
const BASE_TOTAL = COLUMNS.reduce((s, c) => s + c.width, 0)
const LAST_FROZEN = COLUMNS.reduce((last, c, i) => (c.frozen ? i : last), -1)

// widths: 화면 폭에 맞춰 늘린 열 너비 배열
function frozenLeft(ci, widths) {
  let left = ROWNUM_W + CHECK_W
  for (let i = 0; i < ci; i += 1) left += widths[i]
  return left
}

function statusTone(v) {
  if (v === 'complete') return 'bg-brand-greenSoft text-brand-deepGreenStrong'
  if (v === 'incomplete') return 'bg-brand-orangeSoft text-brand-orangeStrong'
  if (v === 'withdrawn' || v === 'excluded') return 'bg-surface-subtle text-ink-muted'
  return 'bg-brand-blueSoft text-brand-blue'
}

// ───────────────────────── 열 거르기 팝업 ─────────────────────────
function FilterPopover({ col, allRows, current, onApply, onClose }) {
  const values = useMemo(() => {
    const counts = new Map()
    allRows.forEach((r) => {
      const t = displayText(r, col) || '(빈 칸)'
      counts.set(t, (counts.get(t) || 0) + 1)
    })
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], 'ko'))
  }, [allRows, col])
  const [checked, setChecked] = useState(() => new Set(current ? [...current] : values.map(([v]) => v)))
  const ref = useRef(null)

  useEffect(() => {
    const onDown = (e) => { if (ref.current && !ref.current.contains(e.target)) onClose() }
    const onKey = (e) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('pointerdown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('pointerdown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [onClose])

  const toggle = (v) => setChecked((s) => { const n = new Set(s); if (n.has(v)) n.delete(v); else n.add(v); return n })

  return (
    <div ref={ref} role="dialog" aria-label={`${col.label} 거르기`}
      className="absolute left-0 top-full z-50 mt-1 w-56 rounded-xl border border-border bg-surface-card p-3 text-left text-sm font-normal text-ink-primary shadow-lg">
      <p className="mb-1.5 font-semibold">{col.label} 거르기</p>
      <div className="mb-1 flex gap-2 text-xs">
        <button type="button" className="text-brand-blue hover:underline" onClick={() => setChecked(new Set(values.map(([v]) => v)))}>모두</button>
        <button type="button" className="text-brand-blue hover:underline" onClick={() => setChecked(new Set())}>모두 해제</button>
      </div>
      <div className="max-h-56 overflow-y-auto">
        {values.map(([v, n]) => (
          <label key={v} className="flex cursor-pointer items-center gap-2 rounded px-1 py-1 hover:bg-surface-subtle">
            <input type="checkbox" checked={checked.has(v)} onChange={() => toggle(v)} />
            <span className="flex-1 truncate">{v}</span>
            <span className="text-xs tabular-nums text-ink-muted">{n}</span>
          </label>
        ))}
      </div>
      <div className="mt-2 flex justify-end gap-1.5">
        <button type="button" onClick={() => onApply(null)} className="rounded-md border border-border px-2.5 py-1 text-xs font-semibold text-ink-secondary hover:bg-surface-subtle">거르기 해제</button>
        <button type="button" onClick={() => onApply(checked.size === values.length ? null : checked)}
          className="rounded-md bg-brand-deepGreen px-2.5 py-1 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong">적용</button>
      </div>
    </div>
  )
}

// ───────────────────────── 표 ─────────────────────────
export default function ApplicantGrid({
  rows,
  allRows,
  sort,
  onSort,
  filters,
  onFilterChange,
  selectedIds,
  onToggleSelect,
  onToggleAll,
  onOpenRow,
  onActiveChange,
  focusRequest,
}) {
  const boxRef = useRef(null)
  const [active, setActive] = useState({ r: 0, c: 1 })
  const [anchor, setAnchor] = useState({ r: 0, c: 1 })
  const [openFilter, setOpenFilter] = useState(null)
  const draggingRef = useRef(false)

  // 화면이 넓으면 열을 비율대로 늘려 표가 가로를 꽉 채우게 한다
  const [boxWidth, setBoxWidth] = useState(0)
  useEffect(() => {
    const el = boxRef.current
    if (!el || typeof ResizeObserver === 'undefined') return undefined
    const ro = new ResizeObserver(([entry]) => setBoxWidth(entry.contentRect.width))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  const widths = useMemo(() => {
    const scale = Math.max(1, (boxWidth - ROWNUM_W - CHECK_W - 2) / BASE_TOTAL)
    return COLUMNS.map((c) => Math.floor(c.width * scale))
  }, [boxWidth])

  const rowCount = rows.length
  const clampR = useCallback((r) => Math.max(0, Math.min(rowCount - 1, r)), [rowCount])
  const clampC = (c) => Math.max(0, Math.min(COLUMNS.length - 1, c))

  useEffect(() => {
    if (rowCount === 0) return
    setActive((a) => (a.r > rowCount - 1 ? { ...a, r: rowCount - 1 } : a))
    setAnchor((a) => (a.r > rowCount - 1 ? { ...a, r: rowCount - 1 } : a))
  }, [rowCount])

  // 부모가 특정 지원자 줄로 옮겨 달라고 할 때(방금 등록·수정한 지원자)
  useEffect(() => {
    if (!focusRequest) return
    const r = rows.findIndex((x) => x.id === focusRequest.id)
    if (r < 0) return
    const pos = { r, c: 1 }
    setActive(pos)
    setAnchor(pos)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusRequest])

  const activeRow = rows[active.r]
  const activeCol = COLUMNS[active.c]
  useEffect(() => {
    onActiveChange?.(activeRow ? { row: activeRow, col: activeCol, address: `${LETTERS[active.c]}${active.r + 1}` } : null)
  }, [activeRow, activeCol, active, onActiveChange])

  useEffect(() => {
    const el = boxRef.current?.querySelector(`[data-cell="${active.r}-${active.c}"]`)
    el?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [active])

  useEffect(() => {
    const up = () => { draggingRef.current = false }
    window.addEventListener('mouseup', up)
    return () => window.removeEventListener('mouseup', up)
  }, [])

  const range = useMemo(() => ({
    r1: Math.min(anchor.r, active.r), r2: Math.max(anchor.r, active.r),
    c1: Math.min(anchor.c, active.c), c2: Math.max(anchor.c, active.c),
  }), [anchor, active])
  const isMulti = range.r1 !== range.r2 || range.c1 !== range.c2

  const move = (dr, dc, extend = false) => {
    const next = { r: clampR(active.r + dr), c: clampC(active.c + dc) }
    setActive(next)
    if (!extend) setAnchor(next)
  }

  const onKeyDown = (e) => {
    if (e.target !== boxRef.current) return
    const ctrl = e.ctrlKey || e.metaKey
    const arrows = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }
    if (arrows[e.key]) {
      e.preventDefault()
      const [dr, dc] = arrows[e.key]
      move(ctrl ? dr * 10000 : dr, ctrl ? dc * 10000 : dc, e.shiftKey)
      return
    }
    if (e.key === 'Tab') { e.preventDefault(); move(0, e.shiftKey ? -1 : 1); return }
    if (e.key === 'Home') { e.preventDefault(); move(ctrl ? -10000 : 0, -10000, e.shiftKey); return }
    if (e.key === 'End') { e.preventDefault(); move(ctrl ? 10000 : 0, 10000, e.shiftKey); return }
    if (e.key === 'PageDown') { e.preventDefault(); move(15, 0, e.shiftKey); return }
    if (e.key === 'PageUp') { e.preventDefault(); move(-15, 0, e.shiftKey); return }
    if (e.key === 'Escape') { setAnchor(active); return }
    if (e.key === 'Enter' && activeRow) { e.preventDefault(); onOpenRow(activeRow); return }
    if (e.key === ' ' && activeRow) { e.preventDefault(); onToggleSelect(activeRow.id); return }
    if (ctrl && e.key.toLowerCase() === 'a') {
      e.preventDefault()
      setAnchor({ r: 0, c: 0 })
      setActive({ r: rowCount - 1, c: COLUMNS.length - 1 })
    }
  }

  const onCopy = (e) => {
    if (e.target !== boxRef.current) return
    const lines = []
    for (let r = range.r1; r <= range.r2; r += 1) {
      const row = rows[r]
      if (!row) continue
      const cells = []
      for (let c = range.c1; c <= range.c2; c += 1) cells.push(String(displayText(row, COLUMNS[c])).replace(/[\t\n]/g, ' '))
      lines.push(cells.join('\t'))
    }
    e.clipboardData.setData('text/plain', lines.join('\n'))
    e.preventDefault()
  }

  const allChecked = rows.length > 0 && rows.every((r) => selectedIds.has(r.id))

  const renderCell = (row, col) => {
    if (col.kind === 'docs') {
      return (
        <span className="text-xs tracking-wide" aria-label={DOC_MARKS.map((d) => `${d.label} ${row.docs.has(d.type) ? '있음' : '없음'}`).join(', ')}>
          {DOC_MARKS.map((d) => (
            <span key={d.type} title={d.label} className={`mr-1 ${row.docs.has(d.type) ? 'text-brand-deepGreen' : 'text-[#C8CCC7]'}`}>
              {row.docs.has(d.type) ? '●' : '○'}
            </span>
          ))}
        </span>
      )
    }
    if (col.kind === 'status') {
      return <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-bold ${statusTone(row.application_status)}`}>{displayText(row, col)}</span>
    }
    if (col.key === 'exam_no' && !row.exam_no) return <span className="font-sans text-xs text-ink-muted">미부여</span>
    if (col.key === 'school' && row.school) return <SchoolRegionTip name={row.school}>{displayText(row, col)}</SchoolRegionTip>
    const text = displayText(row, col)
    return <span className={`block truncate ${col.bold ? 'font-bold text-ink-primary' : ''}`} title={text.length > 12 ? text : undefined}>{text}</span>
  }

  return (
    <div
      ref={boxRef}
      tabIndex={0}
      role="grid"
      aria-label="지원자 표 (줄을 더블클릭하거나 Enter를 누르면 지원자 정보 창이 열립니다)"
      aria-rowcount={rows.length}
      onKeyDown={onKeyDown}
      onCopy={onCopy}
      className="h-full overflow-auto border border-border bg-surface-card outline-none focus-visible:ring-2 focus-visible:ring-brand-deepGreen/30"
    >
      <table className="border-separate border-spacing-0 text-sm" style={{ tableLayout: 'fixed', width: ROWNUM_W + CHECK_W + widths.reduce((s, w) => s + w, 0) }}>
        <colgroup>
          <col style={{ width: ROWNUM_W }} />
          <col style={{ width: CHECK_W }} />
          {COLUMNS.map((c, i) => <col key={c.key} style={{ width: widths[i] }} />)}
        </colgroup>
        <thead>
          <tr>
            <th className="sticky left-0 top-0 z-[5] h-5 border-b border-r border-[#E6E9E5] bg-[#FAFBFA]" />
            <th className="sticky top-0 z-[5] h-5 border-b border-r border-[#E6E9E5] bg-[#FAFBFA]" style={{ left: ROWNUM_W }} />
            {COLUMNS.map((col, ci) => (
              <th key={col.key}
                className={`sticky top-0 h-5 border-b border-r border-[#E6E9E5] text-center text-[10.5px] font-medium ${ci >= range.c1 && ci <= range.c2 ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-[#FAFBFA] text-[#9AA19B]'} ${col.frozen ? 'z-[5]' : 'z-[4]'}`}
                style={col.frozen ? { left: frozenLeft(ci, widths) } : undefined}>
                {LETTERS[ci]}
              </th>
            ))}
          </tr>
          <tr>
            <th className="sticky left-0 top-5 z-[5] h-9 border-b border-r border-border bg-[#F4F6F3]" />
            <th className="sticky top-5 z-[5] h-9 border-b border-r border-border bg-[#F4F6F3]" style={{ left: ROWNUM_W }}>
              <input type="checkbox" checked={allChecked} onChange={(e) => onToggleAll(e.target.checked)} aria-label="보이는 지원자 모두 선택" />
            </th>
            {COLUMNS.map((col, ci) => {
              const sorted = sort.key === col.key
              const filtered = Boolean(filters[col.key])
              return (
                <th key={col.key}
                  aria-sort={sorted ? (sort.dir === 'asc' ? 'ascending' : 'descending') : undefined}
                  className={`sticky top-5 h-9 border-b border-r border-border bg-[#F4F6F3] px-2 text-left text-[13px] font-semibold text-ink-secondary ${col.frozen ? 'z-[5]' : 'z-[4]'}`}
                  style={col.frozen ? { left: frozenLeft(ci, widths), boxShadow: ci === LAST_FROZEN ? '2px 0 0 #D5DAD4' : undefined } : undefined}>
                  <div className="relative flex items-center gap-1">
                    {col.sortable ? (
                      <button type="button" tabIndex={-1} onClick={() => onSort(col.key)}
                        className={`truncate text-left hover:text-ink-primary ${sorted ? 'text-brand-deepGreenStrong' : ''}`}
                        title={`${col.label} 기준 정렬`}>
                        {col.label}{sorted ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : ''}
                      </button>
                    ) : (
                      <span className="truncate" title={col.label}>{col.label}</span>
                    )}
                    {col.filter && (
                      <button type="button" tabIndex={-1}
                        onClick={() => setOpenFilter((k) => (k === col.key ? null : col.key))}
                        aria-label={`${col.label} 거르기`}
                        className={`ml-auto shrink-0 rounded border px-1 text-[9px] leading-4 ${filtered ? 'border-brand-deepGreen bg-brand-deepGreen text-white' : 'border-border bg-white text-ink-muted hover:border-brand-deepGreen'}`}>
                        ▼
                      </button>
                    )}
                    {openFilter === col.key && (
                      <FilterPopover col={col} allRows={allRows} current={filters[col.key]}
                        onApply={(set) => { onFilterChange(col.key, set); setOpenFilter(null) }}
                        onClose={() => setOpenFilter(null)} />
                    )}
                  </div>
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 && (
            <tr>
              <td colSpan={COLUMNS.length + 2} className="px-4 py-10 text-center text-sm text-ink-muted">
                {allRows.length === 0 ? '아직 접수된 지원자가 없습니다. 오른쪽 위 ‘+ 신규 접수’로 등록하세요.' : '조건에 맞는 지원자가 없습니다.'}
              </td>
            </tr>
          )}
          {rows.map((row, r) => {
            const checked = selectedIds.has(row.id)
            const rowActive = r >= range.r1 && r <= range.r2
            return (
              <tr key={row.id} className="group" onDoubleClick={() => onOpenRow(row)} title="더블클릭하면 지원자 정보 창이 열립니다">
                <td className={`sticky left-0 z-[2] h-9 border-b border-r border-[#E6E9E5] text-center text-[11.5px] ${rowActive ? 'bg-brand-greenSoft font-semibold text-brand-deepGreenStrong' : 'bg-[#FAFBFA] text-[#9AA19B]'}`}>
                  {r + 1}
                </td>
                <td className={`sticky z-[2] border-b border-r border-[#E6E9E5] text-center ${checked ? 'bg-[#EAF5E2]' : 'bg-white group-hover:bg-[#F8FBF5]'}`} style={{ left: ROWNUM_W }}
                  onDoubleClick={(e) => e.stopPropagation()}>
                  <input type="checkbox" checked={checked} onChange={() => onToggleSelect(row.id)} aria-label={`${row.name} 선택`} />
                </td>
                {COLUMNS.map((col, c) => {
                  const isActive = active.r === r && active.c === c
                  const sel = r >= range.r1 && r <= range.r2 && c >= range.c1 && c <= range.c2
                  let bg = checked ? 'bg-[#EAF5E2]' : 'bg-white group-hover:bg-[#F8FBF5]'
                  if (sel && isMulti) bg = 'bg-[#DDEFD0]'
                  return (
                    <td key={col.key}
                      data-cell={`${r}-${c}`}
                      role="gridcell"
                      aria-selected={sel}
                      onMouseDown={(e) => {
                        if (e.button !== 0) return
                        e.preventDefault()
                        draggingRef.current = true
                        setActive({ r, c })
                        if (!e.shiftKey) setAnchor({ r, c })
                        boxRef.current?.focus({ preventScroll: true })
                      }}
                      onMouseEnter={(e) => { if (draggingRef.current && e.buttons === 1) setActive({ r, c }) }}
                      className={`h-9 cursor-default overflow-hidden whitespace-nowrap border-b border-r border-[#E6E9E5] px-2 ${col.mono ? 'font-mono text-[13.5px]' : ''} ${col.frozen ? 'sticky z-[2]' : ''} ${bg} ${isActive ? 'outline outline-2 -outline-offset-2 outline-brand-deepGreen' : ''}`}
                      style={col.frozen ? { left: frozenLeft(c, widths), boxShadow: c === LAST_FROZEN ? '2px 0 0 #D5DAD4' : undefined } : undefined}
                    >
                      {renderCell(row, col)}
                    </td>
                  )
                })}
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
