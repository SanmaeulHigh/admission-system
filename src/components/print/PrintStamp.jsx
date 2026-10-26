// 앱 화면을 인쇄할 때 모든 쪽 아래 오른쪽 여백에 "인쇄자: 이름 · 시각"을 찍는다.
// 시각은 인쇄 창을 여는 순간(beforeprint)으로 맞춘다. 자세한 내용은 lib/printStamp.js.

import { useEffect, useState } from 'react'
import { flushSync } from 'react-dom'
import { printStampCss } from '../../lib/printStamp'

export default function PrintStamp() {
  const [css, setCss] = useState(() => printStampCss())
  useEffect(() => {
    // 인쇄 화면이 그려지기 전에 바로 반영되도록 동기로 갱신
    const refresh = () => flushSync(() => setCss(printStampCss()))
    window.addEventListener('beforeprint', refresh)
    return () => window.removeEventListener('beforeprint', refresh)
  }, [])
  return <style>{`@media print { ${css} }`}</style>
}
