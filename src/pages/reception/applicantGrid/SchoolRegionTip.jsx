// 출신 중학교 칸: 커서를 잠시 올리면 소재지(시도 시군구) 말풍선 (2026-10-25)
// 표 칸은 overflow:hidden이라 말풍선은 화면 기준(fixed)으로 칸 바로 아래에 띄운다.

import { useEffect, useRef, useState } from 'react'
import { lookupSchoolRegion } from '../../../lib/schoolRegion'

const HOVER_DELAY_MS = 350

export default function SchoolRegionTip({ name, children }) {
  const ref = useRef(null)
  const timer = useRef(null)
  const [tip, setTip] = useState(null) // { x, y, text }

  useEffect(() => () => clearTimeout(timer.current), [])

  const show = () => {
    clearTimeout(timer.current)
    if (!name || name.trim().length < 2) return
    timer.current = setTimeout(async () => {
      const rect = ref.current?.getBoundingClientRect()
      if (!rect) return
      // 칸 위쪽에 띄운다 — 아래쪽은 마우스 커서가 가린다(2026-10-26)
      const pos = { x: rect.left, y: rect.top - 4 }
      setTip({ ...pos, text: '찾는 중…' })
      const res = await lookupSchoolRegion(name)
      let text
      if (res.error) text = `학교 검색 실패 — ${res.error}`
      else if (!res.regions.length) text = res.reason ? `조회 불가 (${res.reason})` : '학교 검색에 없는 이름입니다'
      else if (res.regions.length === 1) text = res.regions[0]
      else text = `같은 이름 ${res.regions.length}곳: ${res.regions.join(' / ')}`
      setTip((cur) => (cur ? { ...pos, text } : cur))
    }, HOVER_DELAY_MS)
  }

  const hide = () => {
    clearTimeout(timer.current)
    setTip(null)
  }

  return (
    // title="": 줄(tr)의 '더블클릭하면…' 브라우저 말풍선이 이 칸에서는 뜨지 않게 해 겹침을 막는다(2026-10-26)
    <span ref={ref} onMouseEnter={show} onMouseLeave={hide} title="" className="block truncate">
      {children}
      {tip && (
        <span
          role="tooltip"
          className="pointer-events-none fixed z-[90] max-w-xs whitespace-normal rounded-md bg-ink-primary px-2.5 py-1.5 text-xs font-medium text-white shadow-lg"
          style={{ left: tip.x, top: tip.y, transform: 'translateY(-100%)' }}
        >
          소재지 · {tip.text}
        </span>
      )}
    </span>
  )
}
