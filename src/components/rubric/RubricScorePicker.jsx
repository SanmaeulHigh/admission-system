// 기준표 = 점수 버튼 (2026-10-16)
//
// 채점기준표의 '점수별 판단 기준' 문장을 그대로 점수 버튼으로 쓴다. 위원이 문장을 읽고 해당하는 줄을
// 누르면 그 점수가 매겨진다. 기준표가 없거나(미등록·권한 없음) '설명 숨기기'를 켜면 숫자 버튼만 보인다.
//
//  - 맨 아래 줄('6점 이하', '3점 이하')을 누르면 세부 점수 버튼이 펼쳐진다.
//  - 한 기준을 고르면 아직 안 고른 다음 기준으로 화면이 내려간다.
//  - 좁은 화면(휴대폰 세로, 채점 패널 440px)에서도 한 줄 = 점수 + 문장 2열로 읽히게 했다.
//  - 기준표 문구는 대외비라 Confidential(선택·복사·우클릭·인쇄 억제) 안에서만 그린다.

import { useEffect, useRef, useState } from 'react'
import { Confidential } from './Rubric'

const COMPACT_KEY = 'sanmaeul.rubricPickerCompact'

// scale별 숫자 범위와 '이하' 묶음
export const SCALES = {
  essay: {
    top: ['10', '9', '8', '7'],
    lowAnchor: '6',
    low: ['6', '5', '4', '3', '2', '1', '0'],
    all: ['10', '9', '8', '7', '6', '5', '4', '3', '2', '1', '0'],
    defaultLabels: { 10: '10점', 9: '9점', 8: '8점 보통', 7: '7점', 6: '6점 이하' },
  },
  opinion: {
    top: ['5', '4.5', '4', '3.5'],
    lowAnchor: '3',
    low: ['3', '2.5', '2', '1.5', '1', '0.5', '0'],
    all: ['5', '4.5', '4', '3.5', '3', '2.5', '2', '1.5', '1', '0.5', '0'],
    defaultLabels: { 5: '5점', 4.5: '4.5점', 4: '4점 보통', 3.5: '3.5점', 3: '3점 이하' },
  },
}

function readCompact() {
  try {
    return localStorage.getItem(COMPACT_KEY) === '1'
  } catch {
    return false
  }
}

function same(a, b) {
  return a !== undefined && a !== null && a !== '' && Number(a) === Number(b)
}

// 점수 + 문장 한 줄짜리 버튼 (공동체 등급에서도 같이 쓴다)
export function LevelRow({ head, sub, text, extra, selected, disabled, onClick }) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      aria-pressed={selected}
      className={`flex min-h-11 w-full items-start gap-2.5 rounded-lg border px-2.5 py-2 text-left transition-colors active:scale-[0.99] disabled:cursor-default ${
        selected
          ? 'border-brand-deepGreen bg-brand-greenSoft'
          : 'border-border bg-white hover:border-brand-deepGreen/60'
      }`}
    >
      <span className="w-12 shrink-0">
        <span className={`block text-[15px] font-bold leading-tight ${selected ? 'text-brand-deepGreenStrong' : 'text-ink-primary'}`}>{head}</span>
        {sub && <span className={`block text-[10px] leading-tight ${selected ? 'text-brand-deepGreenStrong' : 'text-ink-muted'}`}>{sub}</span>}
      </span>
      <span className={`min-w-0 flex-1 text-[13px] leading-snug ${selected ? 'text-brand-deepGreenStrong' : 'text-ink-secondary'}`}>
        {text}
        {extra}
      </span>
    </button>
  )
}

function Chips({ values, current, disabled, onPick }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {values.map((v) => (
        <button
          key={v}
          type="button"
          disabled={disabled}
          onClick={() => onPick(v)}
          aria-pressed={same(current, v)}
          className={`h-10 min-w-10 rounded-md border px-2 text-sm font-semibold disabled:cursor-default ${
            same(current, v)
              ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong'
              : 'border-border bg-white text-ink-secondary hover:border-brand-deepGreen/60'
          }`}
        >
          {v}
        </button>
      ))}
    </div>
  )
}

/**
 * criteria: [{ key, label, hint }]  — 화면 고정 이름(기준표가 없을 때도 보임)
 * rubric:   get_evaluation_rubric 결과(없으면 null)
 * scale:    'essay' | 'opinion'
 * items:    { key: '8', ... }  onChange(key, valueString)
 */
export default function RubricScorePicker({ criteria, rubric, scale, items, onChange, disabled, lowHint }) {
  const conf = SCALES[scale]
  const [compactPref, setCompactPref] = useState(readCompact)
  const [lowOpen, setLowOpen] = useState({})
  const cardRefs = useRef({})
  const compact = compactPref || !rubric

  const filled = criteria.filter((c) => items[c.key] !== undefined && items[c.key] !== '').length
  const total = criteria.reduce((s, c) => s + (Number(items[c.key]) || 0), 0)

  const toggleCompact = () => {
    const next = !compactPref
    setCompactPref(next)
    try {
      localStorage.setItem(COMPACT_KEY, next ? '1' : '0')
    } catch {
      // 기억만 못 할 뿐
    }
  }

  const pick = (key, value) => {
    onChange(key, String(value))
    // 아직 안 고른 다음 기준으로 내려가기
    const idx = criteria.findIndex((c) => c.key === key)
    const next = criteria.slice(idx + 1).find((c) => items[c.key] === undefined || items[c.key] === '')
    if (next) {
      setTimeout(() => cardRefs.current[next.key]?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 120)
    }
  }

  const jumpTo = (key) => cardRefs.current[key]?.scrollIntoView({ behavior: 'smooth', block: 'start' })

  return (
    <div>
      {/* 진행 상태 + 바로가기 */}
      <div className="sticky top-0 z-10 -mx-1 mb-2 bg-surface-card/95 px-1 pb-2 pt-1 backdrop-blur-sm">
        <div className="flex items-center justify-between gap-2">
          <p className="text-xs text-ink-secondary">
            <strong className="text-ink-primary">{filled}</strong>/{criteria.length} 기준 · 합계{' '}
            <strong className="text-ink-primary">{Number.isInteger(total) ? total : total.toFixed(1)}</strong>점
          </p>
          {rubric && (
            <button type="button" onClick={toggleCompact} className="shrink-0 rounded border border-border px-2 py-1 text-[11px] text-ink-muted hover:bg-surface-subtle">
              {compactPref ? '설명 보이기' : '설명 숨기기'}
            </button>
          )}
        </div>
        <div className="mt-1.5 flex flex-wrap gap-1">
          {criteria.map((c) => {
            const done = items[c.key] !== undefined && items[c.key] !== ''
            return (
              <button
                key={c.key}
                type="button"
                onClick={() => jumpTo(c.key)}
                title={c.label}
                className={`flex h-6 min-w-6 items-center justify-center rounded-full px-1 text-[11px] font-semibold ${
                  done ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-surface-subtle text-ink-muted'
                }`}
              >
                {c.label.slice(0, 1)}
              </button>
            )
          })}
        </div>
      </div>

      <div className="space-y-3">
        {criteria.map((c) => {
          const guide = (rubric?.criteria || []).find((x) => x.key === c.key)
          const current = items[c.key]
          const isLow = current !== undefined && current !== '' && Number(current) <= Number(conf.lowAnchor)
          const labels = rubric?.levelLabels || conf.defaultLabels
          return (
            <section
              key={c.key}
              ref={(el) => { cardRefs.current[c.key] = el }}
              className="scroll-mt-20 rounded-xl border border-border bg-surface-card p-2.5"
            >
              <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-2">
                <h4 className="text-sm font-semibold text-ink-primary">{c.label}</h4>
                <span className="text-[11px] text-ink-muted">{guide ? `근거 ${guide.sources}` : c.hint}</span>
              </div>

              {compact || !guide ? (
                <Chips values={conf.all} current={current} disabled={disabled} onPick={(v) => pick(c.key, v)} />
              ) : (
                <Confidential className="space-y-1.5">
                  {(guide.levels || []).map((lv) => {
                    const anchorIsLow = String(Number(lv.score)) === String(Number(conf.lowAnchor))
                    const label = labels[lv.score] || `${lv.score}점`
                    const sub = label.replace(/^[^\s(]+/, '').replace(/[()]/g, '').trim() || null
                    if (!anchorIsLow) {
                      return (
                        <LevelRow
                          key={lv.score}
                          head={lv.score}
                          sub={sub}
                          text={lv.text}
                          selected={same(current, lv.score)}
                          disabled={disabled}
                          onClick={() => pick(c.key, lv.score)}
                        />
                      )
                    }
                    const open = lowOpen[c.key] || isLow
                    return (
                      <div key={lv.score}>
                        <LevelRow
                          head={isLow ? current : `${lv.score}↓`}
                          sub={isLow ? '' : '이하'}
                          text={lv.text}
                          selected={isLow}
                          disabled={disabled}
                          onClick={() => setLowOpen((o) => ({ ...o, [c.key]: !o[c.key] }))}
                        />
                        {open && (
                          <div className="mt-1.5 pl-[3.6rem]">
                            <Chips values={conf.low} current={current} disabled={disabled} onPick={(v) => pick(c.key, v)} />
                            {lowHint && <p className="mt-1 text-[11px] text-ink-muted">{lowHint}</p>}
                          </div>
                        )}
                      </div>
                    )
                  })}
                  {guide.note && <p className="pt-0.5 text-[11px] text-brand-orangeStrong">유의 · {guide.note}</p>}
                </Confidential>
              )}
            </section>
          )
        })}
      </div>
    </div>
  )
}
