// 서류평가 정성 영역 채점기준표 표시 (2026-10-16)
//
// 기준표는 대외비라 화면 코드에 문구를 넣지 않는다. DB(evaluation_rubrics, 00091)에서 권한 있는 위원만
// get_evaluation_rubric RPC로 받아 와 보여 준다. 기준표가 아직 등록되지 않았으면 아무것도 표시하지 않는다.
// 표시 영역은 선택·복사·우클릭·인쇄를 막는다(완전한 차단은 아니며, 무단 반출 금지 안내를 함께 둔다).

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

const cache = new Map() // `${year}:${area}` → content (세션 동안만, 메모리)

export function useRubric(area) {
  const { year } = useAdmissionCycle()
  const cacheKey = `${year}:${area}`
  const [content, setContent] = useState(() => cache.get(cacheKey) ?? null)

  useEffect(() => {
    if (!year) return undefined
    if (cache.has(cacheKey)) {
      setContent(cache.get(cacheKey))
      return undefined
    }
    let active = true
    supabase.rpc('get_evaluation_rubric', { p_year: year, p_area: area }).then(({ data, error }) => {
      if (!active || error) return
      cache.set(cacheKey, data ?? null)
      setContent(data ?? null)
    })
    return () => {
      active = false
    }
  }, [year, area, cacheKey])

  return content
}

// 대외비 영역: 선택·복사·우클릭·인쇄 억제
export function Confidential({ children, className = '' }) {
  const block = (e) => e.preventDefault()
  return (
    <div
      className={`select-none print:hidden ${className}`}
      onCopy={block}
      onCut={block}
      onContextMenu={block}
      onDragStart={block}
    >
      {children}
    </div>
  )
}

function Badge() {
  return <span className="rounded bg-status-dangerSoft px-1.5 py-0.5 text-[10px] font-bold text-status-danger">대외비</span>
}

// 공통 채점 원칙(접이식)
export function CommonPrinciples() {
  const content = useRubric('common')
  const [open, setOpen] = useState(false)
  if (!content) return null
  return (
    <Confidential className="mb-3 rounded-lg border border-border bg-surface-subtle">
      <button type="button" onClick={() => setOpen((v) => !v)} className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs font-semibold text-ink-secondary">
        <Badge /> 공통 채점 원칙 {open ? '접기 ▴' : '보기 ▾'}
      </button>
      {open && (
        <div className="space-y-2 border-t border-border px-3 pb-3 pt-2 text-[11px] leading-relaxed text-ink-secondary">
          {(content.sections || []).map((s) => (
            <div key={s.heading}>
              <p className="font-semibold text-ink-primary">{s.heading}</p>
              <ul className="ml-4 list-disc">
                {(s.items || []).map((it) => <li key={it}>{it}</li>)}
              </ul>
            </div>
          ))}
          {content.notice && <p className="text-[10px] text-status-danger">{content.notice}</p>}
        </div>
      )}
    </Confidential>
  )
}

// 기준 하나의 점수별 판단 기준. onPick(score)가 있으면 행을 눌러 점수를 고른다.
export function CriterionGuide({ criterion, levelLabels, current, onPick, disabled }) {
  if (!criterion) return null
  return (
    <Confidential className="mt-1.5 rounded-md border border-border bg-white">
      <p className="flex items-center gap-1.5 border-b border-border px-2 py-1 text-[10px] text-ink-muted">
        <Badge /> 근거 {criterion.sources}{criterion.sources?.startsWith('문항') ? ' (첫 번째가 주 근거)' : ''}
      </p>
      <ul>
        {(criterion.levels || []).map((lv) => {
          const selected = current !== undefined && current !== '' && String(Number(current)) === String(Number(lv.score))
          const clickable = Boolean(onPick) && !disabled
          return (
            <li key={lv.score}>
              <button
                type="button"
                disabled={!clickable}
                onClick={() => onPick?.(Number(lv.score))}
                className={`flex w-full gap-2 px-2 py-1 text-left text-[11px] leading-snug ${
                  selected ? 'bg-brand-greenSoft font-semibold text-brand-deepGreenStrong' : 'text-ink-secondary'
                } ${clickable ? 'hover:bg-surface-subtle' : 'cursor-default'}`}
              >
                <span className="w-16 shrink-0 font-semibold">{levelLabels?.[lv.score] || `${lv.score}점`}</span>
                <span>{lv.text}</span>
              </button>
            </li>
          )
        })}
      </ul>
      {criterion.note && <p className="border-t border-border px-2 py-1 text-[10px] text-brand-orangeStrong">유의 · {criterion.note}</p>}
    </Confidential>
  )
}

// 기준표에서 key로 기준 찾기
export function findCriterion(content, key) {
  return (content?.criteria || []).find((c) => c.key === key) || null
}

// 모든 기준에 같은 점수를 줬는지(2026 채점에서 확인된 문제 — 제출 전 한 번 확인한다)
export function isAllSameScore(items, keys) {
  const values = keys.map((k) => items[k]).filter((v) => v !== undefined && v !== '')
  if (values.length !== keys.length) return false
  return new Set(values.map((v) => Number(v))).size === 1
}

export function confirmAllSame(count, score) {
  // eslint-disable-next-line no-alert
  return window.confirm(
    `${count}개 기준이 모두 ${score}점입니다.\n\n채점기준표는 기준마다 근거 문항을 찾아 따로 판단하도록 안내하고 있습니다.\n그래도 이대로 제출할까요?`,
  )
}
