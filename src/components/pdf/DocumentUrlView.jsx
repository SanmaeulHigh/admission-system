// 서명 주소(URL)의 서류를 받아 PDF는 pdf.js로, 그 밖(사진 등)은 그림으로 보여 준다 (2026-10-25)
// 브라우저 내장 PDF 뷰어(iframe)가 일부 PC에서 흰 화면으로만 나와서 iframe 대신 쓴다.
// 주소는 getDocumentViewUrl로 받은 것만 넘긴다(열람 감사 기록).

import { Suspense, lazy, useEffect, useState } from 'react'

const PdfCanvasViewer = lazy(() => import('./PdfCanvasViewer'))
const ZOOMS = [1, 1.25, 1.5, 2, 3]

export default function DocumentUrlView({ url, alt = '서류' }) {
  const [doc, setDoc] = useState(null) // { kind:'pdf', bytes } | { kind:'image', src }
  const [error, setError] = useState(null)
  const [zoom, setZoom] = useState(1)

  useEffect(() => {
    let cancelled = false
    let src = null
    setDoc(null)
    setError(null)
    fetch(url)
      .then((res) => {
        if (!res.ok) throw new Error(`서버 응답 ${res.status}`)
        return res.blob()
      })
      .then(async (blob) => {
        const bytes = new Uint8Array(await blob.arrayBuffer())
        if (cancelled) return
        const isPdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 // %PDF
        if (isPdf) setDoc({ kind: 'pdf', bytes })
        else {
          src = URL.createObjectURL(blob)
          setDoc({ kind: 'image', src })
        }
      })
      .catch((err) => { if (!cancelled) setError(err.message) })
    return () => {
      cancelled = true
      if (src) URL.revokeObjectURL(src)
    }
  }, [url])

  if (error) return <p className="p-6 text-sm text-status-danger">서류를 받지 못했습니다: {error}</p>
  if (!doc) return <p className="p-6 text-sm text-ink-muted">서류 받는 중…</p>
  if (doc.kind === 'image') {
    return (
      <div className="h-full w-full overflow-auto p-2">
        <img src={doc.src} alt={alt} className="mx-auto max-w-full bg-white shadow-sm" />
      </div>
    )
  }
  const zi = ZOOMS.indexOf(zoom)
  return (
    <div className="relative flex h-full min-h-0 flex-col">
      <div className="absolute right-3 top-3 z-10 flex items-center gap-1 rounded-lg border border-border bg-white/95 p-1 shadow-sm">
        <button type="button" aria-label="축소" disabled={zi <= 0} onClick={() => setZoom(ZOOMS[zi - 1])}
          className="h-8 w-8 rounded-md border border-border font-semibold text-ink-secondary disabled:opacity-30">−</button>
        <button type="button" onClick={() => setZoom(1)} className="min-w-[56px] px-1 text-xs text-ink-secondary">
          {zoom === 1 ? '너비맞춤' : `${Math.round(zoom * 100)}%`}
        </button>
        <button type="button" aria-label="확대" disabled={zi >= ZOOMS.length - 1} onClick={() => setZoom(ZOOMS[zi + 1])}
          className="h-8 w-8 rounded-md border border-border font-semibold text-ink-secondary disabled:opacity-30">+</button>
      </div>
      <Suspense fallback={<p className="p-6 text-sm text-ink-muted">뷰어 준비 중…</p>}>
        <PdfCanvasViewer data={doc.bytes} zoom={zoom} />
      </Suspense>
    </div>
  )
}
