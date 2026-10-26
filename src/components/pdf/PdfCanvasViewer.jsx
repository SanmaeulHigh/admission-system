// 서류 PDF를 pdf.js로 직접 그리는 뷰어 (2026-10-13)
//
// 왜: 휴대폰·태블릿 브라우저는 <iframe> 안에 PDF를 못 띄우거나(안드로이드 크롬),
// 첫 장만 보여 준다(아이폰·아이패드 사파리). 그래서 터치 기기·좁은 화면에서는
// 이 뷰어로 모든 장을 캔버스에 그려 위아래로 넘겨 보게 한다. 데스크톱은 기존 내장 뷰어 그대로.
//
// - 다운로드·인쇄 버튼이 아예 없다(내장 뷰어보다 억제가 확실하다).
// - 보이는 장 근처만 그리고, 멀어진 장은 캔버스를 비워 메모리를 아낀다(폰에서 수십 장 대비).
// - 보안: pdf.js 3.x 글꼴 취약점(CVE-2024-4367) 때문에 isEvalSupported:false 를 반드시 준다.

import { useEffect, useRef, useState } from 'react'
import * as pdfjsLib from 'pdfjs-dist/legacy/build/pdf'
import workerUrl from 'pdfjs-dist/legacy/build/pdf.worker.min.js?url'

pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl

// 한글 글꼴이 PDF 안에 안 들어 있는 경우를 위한 보조 자료(빌드 때 public/pdfjs 로 복사됨)
const DOC_OPTIONS = {
  isEvalSupported: false,
  cMapUrl: '/pdfjs/cmaps/',
  cMapPacked: true,
  standardFontDataUrl: '/pdfjs/standard_fonts/',
}

const MAX_CANVAS_PIXEL_WIDTH = 2400 // 확대해도 캔버스가 너무 커지지 않게(폰 메모리)
const PAGE_GAP = 12

export default function PdfCanvasViewer({ data, zoom = 1 }) {
  const scrollRef = useRef(null)
  const [pdf, setPdf] = useState(null)
  const [pageSizes, setPageSizes] = useState([]) // [{ w, h }] — 배율 1 기준
  const [containerWidth, setContainerWidth] = useState(0)
  const [error, setError] = useState(null)

  // 문서 열기
  useEffect(() => {
    let cancelled = false
    let doc = null
    setPdf(null)
    setPageSizes([])
    setError(null)
    // 워커로 넘기면 버퍼가 비워지므로 사본을 넘긴다(배율 변경 등으로 다시 열 때 대비)
    const task = pdfjsLib.getDocument({ ...DOC_OPTIONS, data: data.slice() })
    task.promise
      .then(async (loaded) => {
        doc = loaded
        const sizes = []
        for (let i = 1; i <= loaded.numPages; i += 1) {
          const page = await loaded.getPage(i)
          const vp = page.getViewport({ scale: 1 })
          sizes.push({ w: vp.width, h: vp.height })
        }
        if (cancelled) return
        setPdf(loaded)
        setPageSizes(sizes)
      })
      .catch((err) => {
        if (!cancelled) setError(err?.message || 'PDF를 열지 못했습니다.')
      })
    return () => {
      cancelled = true
      task.destroy()
      doc?.destroy()
    }
  }, [data])

  // 화면 폭 따라가기(폰 회전·반반 전환 대응)
  useEffect(() => {
    const el = scrollRef.current
    if (!el) return undefined
    const ro = new ResizeObserver(([entry]) => setContainerWidth(Math.floor(entry.contentRect.width)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  if (error) {
    return <p className="p-6 text-sm text-status-danger">서류를 표시하지 못했습니다: {error}</p>
  }

  const fitWidth = Math.max(0, containerWidth - 16) // 좌우 여백 8px씩
  const pageCssWidth = Math.round(fitWidth * zoom)

  return (
    <div ref={scrollRef} className="h-full w-full overflow-auto overscroll-contain">
      {!pdf ? (
        <p className="p-6 text-sm text-ink-muted">서류 그리는 중…</p>
      ) : (
        <div className="px-2 py-2" style={{ width: pageCssWidth + 16 }}>
          {pageSizes.map((size, i) => (
            <PdfPage
              key={i}
              pdf={pdf}
              pageNumber={i + 1}
              size={size}
              cssWidth={pageCssWidth}
              scrollRoot={scrollRef}
              total={pageSizes.length}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function PdfPage({ pdf, pageNumber, size, cssWidth, scrollRoot, total }) {
  const holderRef = useRef(null)
  const canvasRef = useRef(null)
  const [visible, setVisible] = useState(false)
  const cssHeight = Math.round((cssWidth * size.h) / size.w)

  // 화면 가까이 오면 그린다(위아래로 화면 1장 분량 여유)
  useEffect(() => {
    const el = holderRef.current
    if (!el) return undefined
    const io = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting), {
      root: scrollRoot.current,
      rootMargin: '100% 0px',
    })
    io.observe(el)
    return () => io.disconnect()
  }, [scrollRoot])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return undefined
    if (!visible || cssWidth <= 0) {
      // 멀어진 장은 캔버스를 비워 메모리 반환
      canvas.width = 0
      canvas.height = 0
      return undefined
    }
    let renderTask = null
    let cancelled = false
    pdf.getPage(pageNumber).then((page) => {
      if (cancelled) return
      const dpr = window.devicePixelRatio || 1
      let scale = (cssWidth / size.w) * dpr
      if (size.w * scale > MAX_CANVAS_PIXEL_WIDTH) scale = MAX_CANVAS_PIXEL_WIDTH / size.w
      const viewport = page.getViewport({ scale })
      canvas.width = Math.floor(viewport.width)
      canvas.height = Math.floor(viewport.height)
      renderTask = page.render({ canvasContext: canvas.getContext('2d'), viewport })
      renderTask.promise.catch(() => {}) // 취소(빠른 스크롤·배율 변경)는 정상
    })
    return () => {
      cancelled = true
      renderTask?.cancel()
    }
  }, [visible, cssWidth, pdf, pageNumber, size])

  return (
    <div
      ref={holderRef}
      className="relative bg-white shadow-sm"
      style={{ width: cssWidth, height: cssHeight, marginBottom: PAGE_GAP }}
    >
      <canvas ref={canvasRef} style={{ width: cssWidth, height: cssHeight, display: 'block' }} />
      <span className="pointer-events-none absolute bottom-1 right-2 rounded bg-black/40 px-1.5 text-[11px] text-white">
        {pageNumber} / {total}
      </span>
    </div>
  )
}
