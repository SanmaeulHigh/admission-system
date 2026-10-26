// 국적 찾기 (2026-10-13) — 외교부 국가표준코드(config/countries.js)에서 고른다.
// 한글명·영문명·코드 어느 것으로 쳐도 찾고, 고르면 ISO alpha-3 코드(예: USA)가 저장된다.
// ↑↓로 고르고 Enter, 또는 마우스로 누른다.

import { useId, useMemo, useState } from 'react'
import { COUNTRIES, countryLabel } from '../../config/countries'

export default function CountrySearchField({ value, onChange, className = '', excludeKorea = true, required = false }) {
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [highlight, setHighlight] = useState(0)
  const listId = useId()

  const matches = useMemo(() => {
    const q = query.trim().toLowerCase()
    const pool = excludeKorea ? COUNTRIES.filter(([c]) => c !== 'KOR') : COUNTRIES
    if (!q) return pool.slice(0, 30)
    return pool
      .filter(([code, ko, en]) => ko.toLowerCase().includes(q) || en.toLowerCase().includes(q) || code.toLowerCase() === q)
      .sort((a, b) => Number(!a[1].startsWith(query.trim())) - Number(!b[1].startsWith(query.trim())))
      .slice(0, 30)
  }, [query, excludeKorea])

  const choose = (code) => {
    onChange(code)
    setQuery('')
    setOpen(false)
  }

  const onKeyDown = (e) => {
    if (!open || matches.length === 0) return
    if (e.key === 'ArrowDown') { e.preventDefault(); setHighlight((h) => (h + 1) % matches.length) }
    if (e.key === 'ArrowUp') { e.preventDefault(); setHighlight((h) => (h <= 0 ? matches.length - 1 : h - 1)) }
    if (e.key === 'Enter') { e.preventDefault(); choose(matches[highlight][0]) }
    if (e.key === 'Escape') setOpen(false)
  }

  return (
    <div className="relative">
      <input
        value={open ? query : countryLabel(value)}
        onChange={(e) => { setQuery(e.target.value); setOpen(true); setHighlight(0) }}
        onFocus={() => { setQuery(''); setOpen(true); setHighlight(0) }}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        onKeyDown={onKeyDown}
        placeholder="나라 이름(한글·영문) 또는 코드로 찾기"
        autoComplete="off"
        required={required && !value}
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        className={className}
      />
      {open && (
        <ul id={listId} role="listbox" className="absolute left-0 z-40 mt-1 max-h-64 w-full min-w-[16rem] overflow-y-auto rounded-lg border border-border bg-surface-card py-1 shadow-lg">
          {matches.length === 0 && <li className="px-3 py-2 text-xs text-ink-muted">찾는 나라가 없습니다.</li>}
          {matches.map(([code, ko, en], i) => (
            <li key={code} role="option" aria-selected={i === highlight}>
              <button
                type="button"
                tabIndex={-1}
                onMouseDown={(e) => e.preventDefault()}
                onMouseEnter={() => setHighlight(i)}
                onClick={() => choose(code)}
                className={`flex w-full items-baseline justify-between gap-2 px-3 py-1.5 text-left text-sm ${i === highlight ? 'bg-brand-greenSoft' : 'hover:bg-surface-subtle'}`}
              >
                <span><span className="font-medium text-ink-primary">{ko}</span> <span className="text-xs text-ink-muted">{en}</span></span>
                <span className="font-mono text-xs text-ink-secondary">{code}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-1 text-[11px] text-ink-muted">외교부 국가표준코드(ISO) 기준</p>
    </div>
  )
}
