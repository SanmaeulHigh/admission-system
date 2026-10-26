// 스캔 PDF 용량 줄이기 (2026-10-20)
//
// 서류 저장소 한도는 200MB(00095, 2026-10-20 상향 — 25MB는 컬러 스캔에 너무 작았다). 업로드는 서버 PC 교내 주소에서만 한다.
// 그래도 넘는 PDF만 브라우저 안에서 각 쪽을 pdf.js로 다시 그려 JPEG로 바꾼 뒤 pdf-lib로 다시 만든다.
// 판독 화질을 위해 300dpi 미만으로는 절대 내리지 않는다(2026-10-20 결정). 300dpi·품질 0.85로 한 번만 시도한다.
// 색은 그대로 둔다 — 자기소개서 '흑색 볼펜' 여부처럼 색을 확인해야 하는 서류가 있다.

const LIMIT = 200 * 1024 * 1024
// 교외 주소(Cloudflare 터널)는 요청당 100MB 제한 — 그보다 큰 파일은 교내 주소에서 올려야 한다
export const TUNNEL_UPLOAD_LIMIT = 95 * 1024 * 1024
export function isTunnelHost() {
  return typeof window !== 'undefined' && window.location.hostname === (import.meta.env.VITE_TUNNEL_HOST || '__none__')
}

async function loadLibs() {
  const pdfjsLib = await import('pdfjs-dist/legacy/build/pdf')
  const { default: workerUrl } = await import('pdfjs-dist/legacy/build/pdf.worker.min.js?url')
  pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl
  const { PDFDocument } = await import('pdf-lib')
  return { pdfjsLib, PDFDocument }
}

/**
 * @param {Uint8Array} bytes  원본 PDF
 * @param {{ dpi?: number, quality?: number, onProgress?: (done:number,total:number)=>void }} opts
 * @returns {Promise<Uint8Array>}
 */
export async function compressPdfBytes(bytes, { dpi = 300, quality = 0.85, onProgress } = {}) {
  const { pdfjsLib, PDFDocument } = await loadLibs()
  const src = await pdfjsLib.getDocument({ data: bytes.slice(), isEvalSupported: false }).promise
  const out = await PDFDocument.create()
  const canvas = document.createElement('canvas')
  const ctx = canvas.getContext('2d')
  try {
    for (let i = 1; i <= src.numPages; i += 1) {
      const page = await src.getPage(i)
      const base = page.getViewport({ scale: 1 }) // 72dpi 기준 쪽 크기(pt)
      const vp = page.getViewport({ scale: dpi / 72 })
      canvas.width = Math.floor(vp.width)
      canvas.height = Math.floor(vp.height)
      ctx.fillStyle = '#ffffff'
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      await page.render({ canvasContext: ctx, viewport: vp }).promise
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality))
      const jpg = await out.embedJpg(new Uint8Array(await blob.arrayBuffer()))
      const p = out.addPage([base.width, base.height])
      p.drawImage(jpg, { x: 0, y: 0, width: base.width, height: base.height })
      page.cleanup()
      onProgress?.(i, src.numPages)
    }
  } finally {
    src.destroy()
    canvas.width = 0
    canvas.height = 0
  }
  return out.save()
}

/**
 * 200MB를 넘으면 300dpi로 다시 저장해 본다(그 아래로는 내리지 않음). 그래도 크면 서류를 나눠 올리도록 오류를 낸다.
 */
export async function shrinkPdfFileIfNeeded(file, { onProgress } = {}) {
  if (file.size <= LIMIT) return file
  const original = new Uint8Array(await file.arrayBuffer())
  const bytes = await compressPdfBytes(original, { dpi: 300, quality: 0.85, onProgress })
  if (bytes.length <= LIMIT) return new File([bytes], file.name, { type: 'application/pdf' })
  throw new Error(`용량을 줄여도 200MB를 넘습니다. 쪽 수가 많다면 서류를 나눠 올려 주세요(원본 ${(file.size / 1048576).toFixed(1)}MB).`)
}

export const PDF_SIZE_LIMIT = LIMIT
