// 출신 중학교 입력 + NEIS 학교 검색 제안 (2026-10-12)
//
// 두 글자 이상 치면 search-school Edge Function으로 중학교를 찾아 아래에
// 제안한다. ↑↓로 고르고 Enter, 또는 마우스로 누르면 학교명이 들어간다.
// 제안은 어디까지나 도움일 뿐이라, 목록에 없는 학교도 그대로 입력할 수 있다
// (신설교·해외학교 등). 검색이 안 되는 상황(인증키 미설정·NEIS 장애)에서도
// 입력 자체는 막히지 않는다.

import { useEffect, useId, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'

export default function SchoolSearchField({ value, onChange, className = '', placeholder = '학교명 두 글자 이상 → 목록에서 선택', autoFocus = false, onKeyDown }) {
  const [suggestions, setSuggestions] = useState([])
  const [open, setOpen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [searched, setSearched] = useState(false)
  const [highlight, setHighlight] = useState(-1)
  const [problem, setProblem] = useState(null)
  const debounceRef = useRef(null)
  const seqRef = useRef(0)
  const listId = useId()

  useEffect(() => () => clearTimeout(debounceRef.current), [])

  const search = (q) => {
    clearTimeout(debounceRef.current)
    if (q.trim().length < 2) {
      setSuggestions([])
      setSearched(false)
      setLoading(false)
      return
    }
    setLoading(true)
    debounceRef.current = setTimeout(async () => {
      const seq = ++seqRef.current
      let schools = []
      let why = null
      try {
        const { data, error } = await supabase.functions.invoke('search-school', { body: { query: q.trim() } })
        if (error) why = `학교 검색 기능에 연결하지 못했습니다 (${error.context?.status ?? error.message})`
        else {
          if (Array.isArray(data?.schools)) schools = data.schools
          why = data?.reason || null
        }
      } catch (err) {
        why = `학교 검색 기능에 연결하지 못했습니다 (${err.message})`
      }
      if (seq !== seqRef.current) return // 더 최근 검색이 있으면 버린다
      setSuggestions(schools)
      setProblem(why)
      setHighlight(schools.length ? 0 : -1)
      setSearched(true)
      setLoading(false)
    }, 300)
  }

  const handleInput = (e) => {
    const v = e.target.value
    onChange(v)
    setOpen(true)
    search(v)
  }

  const choose = (school) => {
    onChange(school.name)
    setSuggestions([])
    setSearched(false)
    setOpen(false)
  }

  const handleKeyDown = (e) => {
    const showing = open && suggestions.length > 0
    if (showing && e.key === 'ArrowDown') {
      e.preventDefault()
      setHighlight((h) => (h + 1) % suggestions.length)
      return
    }
    if (showing && e.key === 'ArrowUp') {
      e.preventDefault()
      setHighlight((h) => (h <= 0 ? suggestions.length - 1 : h - 1))
      return
    }
    if (showing && e.key === 'Enter' && highlight >= 0) {
      e.preventDefault()
      e.stopPropagation()
      choose(suggestions[highlight])
      return
    }
    if (open && e.key === 'Escape' && (suggestions.length || loading)) {
      e.preventDefault()
      e.stopPropagation()
      setOpen(false)
      return
    }
    onKeyDown?.(e)
  }

  const showList = open && (loading || suggestions.length > 0 || (searched && value.trim().length >= 2))

  return (
    <div className="relative">
      <input
        value={value}
        onChange={handleInput}
        onKeyDown={handleKeyDown}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        className={className}
        placeholder={placeholder}
        autoFocus={autoFocus}
        autoComplete="off"
        role="combobox"
        aria-expanded={showList}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={highlight >= 0 && suggestions[highlight] ? `${listId}-${highlight}` : undefined}
      />
      {showList && (
        <ul
          id={listId}
          role="listbox"
          className="absolute left-0 z-40 mt-1 max-h-60 min-w-full w-max max-w-[24rem] overflow-y-auto rounded-lg border border-border bg-surface-card py-1 text-left shadow-lg"
        >
          {loading && <li className="px-3 py-2 text-xs text-ink-muted">찾는 중…</li>}
          {!loading && suggestions.length === 0 && (
            <li className="px-3 py-2 text-xs text-ink-muted">
              {problem ? <span className="block text-status-danger">{problem}</span> : '검색 결과가 없습니다.'}
              학교명을 그대로 입력해도 됩니다.
            </li>
          )}
          {!loading &&
            suggestions.map((s, i) => (
              <li key={s.code} id={`${listId}-${i}`} role="option" aria-selected={i === highlight}>
                <button
                  type="button"
                  tabIndex={-1}
                  onMouseDown={(e) => e.preventDefault()}
                  onMouseEnter={() => setHighlight(i)}
                  onClick={() => choose(s)}
                  className={`block w-full px-3 py-2 text-left text-sm ${i === highlight ? 'bg-brand-greenSoft' : 'hover:bg-surface-subtle'}`}
                >
                  <span className="font-medium text-ink-primary">{s.name}</span>
                  <span className="ml-1.5 text-xs text-ink-muted">
                    {s.region}
                    {s.address ? ` · ${s.address.split(' ').slice(1, 3).join(' ')}` : ''}
                  </span>
                </button>
              </li>
            ))}
        </ul>
      )}
    </div>
  )
}
