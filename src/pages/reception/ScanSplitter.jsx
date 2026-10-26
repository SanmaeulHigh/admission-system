// 한 번에 스캔한 PDF를 쪽 단위로 서류별로 나누기 (2026-10-20)
//
// 접수 서류 묶음을 통째로 한 PDF로 스캔해 올리면, 쪽 미리보기를 보면서 서류 종류를 정해 준다.
// 스캔은 보통 원서 → 학생부 → 자기소개서 → … 순서이므로, 어떤 쪽을 누르면 "그 쪽부터 다음 경계까지"가
// 고른 서류로 바뀐다(처음엔 전부 입학원서). '한 쪽만' 을 켜면 누른 쪽 하나만 바뀐다. 빈 쪽은 '빼기'.
// 나누기를 마치면 서류별 PDF가 만들어져 스캔 먼저 접수의 각 칸에 들어간다.
// 모든 처리는 이 브라우저 안에서만 한다(원본 묶음 파일은 서버에 올리지 않는다).
// 쪽 미리보기는 pdf.js, 쪽 복사는 pdf-lib — 둘 다 이 화면을 열 때만 불러온다.

import { useEffect, useState } from 'react'
import { TUNNEL_UPLOAD_LIMIT, isTunnelHost, shrinkPdfFileIfNeeded } from '../../lib/pdfCompress'

export const SPLIT_TYPES = [
  { key: 'applicationForm', label: '입학원서', color: 'bg-brand-deepGreen text-white', dot: 'bg-brand-deepGreen' },
  { key: 'studentRecordSource', label: '학교생활기록부', color: 'bg-sky-700 text-white', dot: 'bg-sky-700' },
  { key: 'essay', label: '자기소개서', color: 'bg-violet-700 text-white', dot: 'bg-violet-700' },
  { key: 'opinion', label: '학부모 소견서', color: 'bg-rose-700 text-white', dot: 'bg-rose-700' },
  { key: 'consent', label: '동의서', color: 'bg-amber-700 text-white', dot: 'bg-amber-700' },
  { key: 'trackEvidence', label: '전형 자격 증빙', color: 'bg-teal-700 text-white', dot: 'bg-teal-700' },
  { key: 'skip', label: '빼기(빈 쪽)', color: 'bg-ink-muted text-white', dot: 'bg-ink-muted' },
]
const typeOf = (key) => SPLIT_TYPES.find((t) => t.key === key)

async function loadPdfjs() {
  const pdfjsLib = await import('pdfjs-dist/legacy/build/pdf')
  const { default: workerUrl } = await import('pdfjs-dist/legacy/build/pdf.worker.min.js?url')
  pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl
  return pdfjsLib
}

export default function ScanSplitter({ onDone, onCancel }) {
  const [source, setSource] = useState(null) // { name, bytes }
  const [thumbs, setThumbs] = useState([]) // dataURL per page
  const [assign, setAssign] = useState([]) // type key per page
  const [current, setCurrent] = useState('studentRecordSource')
  const [single, setSingle] = useState(false)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [zoomPage, setZoomPage] = useState(null)

  // 쪽 미리보기 만들기
  useEffect(() => {
    if (!source) return undefined
    let cancelled = false
    ;(async () => {
      setBusy('쪽 미리보기를 만드는 중…')
      setError(null)
      try {
        const pdfjsLib = await loadPdfjs()
        const doc = await pdfjsLib.getDocument({ data: source.bytes.slice(), isEvalSupported: false }).promise
        const out = []
        for (let i = 1; i <= doc.numPages; i += 1) {
          const page = await doc.getPage(i)
          const vp1 = page.getViewport({ scale: 1 })
          const vp = page.getViewport({ scale: 360 / vp1.width })
          const canvas = document.createElement('canvas')
          canvas.width = Math.floor(vp.width)
          canvas.height = Math.floor(vp.height)
          await page.render({ canvasContext: canvas.getContext('2d'), viewport: vp }).promise
          out.push(canvas.toDataURL('image/jpeg', 0.7))
          if (cancelled) return
          setBusy(`쪽 미리보기를 만드는 중… ${i}/${doc.numPages}`)
        }
        doc.destroy()
        if (cancelled) return
        setThumbs(out)
        setAssign(out.map(() => 'applicationForm'))
      } catch (err) {
        if (!cancelled) setError(`PDF를 읽지 못했습니다: ${err.message}`)
      } finally {
        if (!cancelled) setBusy(null)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [source])

  const pickFile = async (file) => {
    if (!file) return
    if (file.type !== 'application/pdf') {
      setError('PDF 파일만 올릴 수 있습니다.')
      return
    }
    setThumbs([])
    setAssign([])
    setSource({ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) })
  }

  // 누른 쪽부터 같은 서류로 이어진 구간 끝까지 바꾼다('한 쪽만'이면 그 쪽만)
  const paint = (idx) => {
    setAssign((a) => {
      const next = [...a]
      const old = a[idx]
      next[idx] = current
      if (!single) {
        for (let j = idx + 1; j < a.length && a[j] === old; j += 1) next[j] = current
      }
      return next
    })
  }

  // 서류별 구간 요약
  const summary = SPLIT_TYPES.filter((t) => t.key !== 'skip')
    .map((t) => ({ ...t, pages: assign.map((k, i) => (k === t.key ? i + 1 : null)).filter(Boolean) }))
    .filter((t) => t.pages.length > 0)

  const finish = async () => {
    setBusy('서류별 PDF를 만드는 중…')
    setError(null)
    try {
      const { PDFDocument } = await import('pdf-lib')
      const src = await PDFDocument.load(source.bytes, { ignoreEncryption: true })
      const files = {}
      for (const t of summary) {
        const out = await PDFDocument.create()
        const copied = await out.copyPages(src, t.pages.map((p) => p - 1))
        copied.forEach((p) => out.addPage(p))
        const bytes = await out.save()
        let file = new File([bytes], `${t.label}.pdf`, { type: 'application/pdf' })
        // 200MB를 넘으면 브라우저 안에서 자동으로 용량을 줄인다(쪽마다 300dpi JPEG로 다시 저장, 색 유지)
        if (file.size > 200 * 1024 * 1024) {
          const before = file.size
          file = await shrinkPdfFileIfNeeded(file, {
            onProgress: (d, n) => setBusy(`${t.label} 용량 줄이는 중… ${d}/${n}쪽`),
          })
          setBusy(`${t.label}: ${(before / 1048576).toFixed(1)}MB → ${(file.size / 1048576).toFixed(1)}MB`)
        }
        if (isTunnelHost() && file.size > TUNNEL_UPLOAD_LIMIT) {
          throw new Error(`${t.label}(${(file.size / 1048576).toFixed(0)}MB)은 교외 주소로는 올릴 수 없습니다(100MB 제한). 서버 PC에서 https://local.example.org 로 접속해 작업해 주세요.`)
        }
        files[t.key] = file
      }
      onDone(files)
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(null)
    }
  }

  return (
    <div>
      {!source && (
        <div className="rounded-lg border-2 border-dashed border-border bg-surface-card p-6 text-center">
          <p className="text-sm font-semibold text-ink-primary">접수 서류 묶음 전체를 한 PDF로 스캔해 올리세요</p>
          <p className="mt-1 text-xs text-ink-muted">원서 → 학생부 → 자기소개서 → 학부모 소견서 → 동의서 → 자격 증빙 순서로 넣어 스캔하면 나누기가 가장 빠릅니다. 사진은 따로 올립니다.</p>
          <input type="file" accept="application/pdf" onChange={(e) => { pickFile(e.target.files?.[0]); e.target.value = '' }} className="mx-auto mt-3 block text-sm" />
        </div>
      )}

      {busy && <p className="my-3 text-sm text-ink-muted">{busy}</p>}
      {error && <p className="my-3 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {thumbs.length > 0 && (
        <>
          {/* 도구 막대: 서류 고르기 → 쪽 누르기 */}
          <div className="sticky top-0 z-10 -mx-1 mb-3 rounded-lg border border-border bg-surface-card/95 p-2 backdrop-blur-sm">
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="mr-1 text-xs text-ink-muted">① 서류 고르기</span>
              {SPLIT_TYPES.map((t) => (
                <button
                  key={t.key}
                  type="button"
                  onClick={() => setCurrent(t.key)}
                  className={`rounded-md px-2.5 py-1.5 text-xs font-semibold ${current === t.key ? `${t.color} ring-2 ring-offset-1 ring-ink-primary` : 'bg-surface-subtle text-ink-secondary hover:bg-border'}`}
                >
                  {t.label}
                </button>
              ))}
            </div>
            <div className="mt-1.5 flex flex-wrap items-center gap-3 text-xs text-ink-muted">
              <span>② 그 서류가 시작되는 쪽을 누르세요 — 다음 서류가 나올 때까지 이어진 쪽이 함께 바뀝니다.</span>
              <label className="flex items-center gap-1">
                <input type="checkbox" checked={single} onChange={(e) => setSingle(e.target.checked)} /> 한 쪽만 바꾸기
              </label>
            </div>
          </div>

          <ol className="grid grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-6 xl:grid-cols-8">
            {thumbs.map((src, i) => {
              const t = typeOf(assign[i])
              const startsBlock = i === 0 || assign[i - 1] !== assign[i]
              return (
                <li key={i} className="relative">
                  <button
                    type="button"
                    onClick={() => paint(i)}
                    onDoubleClick={() => setZoomPage(i)}
                    title="누르면 고른 서류로 바뀝니다 · 두 번 누르면 크게 보기"
                    className={`block w-full overflow-hidden rounded-md border-2 bg-white ${assign[i] === 'skip' ? 'border-ink-muted opacity-40' : 'border-transparent hover:border-ink-primary'}`}
                  >
                    <img src={src} alt={`${i + 1}쪽`} className="block w-full" />
                    <span className={`absolute inset-x-0 bottom-0 px-1 py-0.5 text-center text-[10px] font-semibold ${t.color}`}>
                      {i + 1}쪽 · {t.label}
                    </span>
                    {startsBlock && assign[i] !== 'skip' && (
                      <span className={`absolute left-1 top-1 rounded px-1 text-[10px] font-bold ${t.color}`}>시작</span>
                    )}
                  </button>
                </li>
              )
            })}
          </ol>

          {zoomPage !== null && (
            <button type="button" onClick={() => setZoomPage(null)} className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-6">
              <img src={thumbs[zoomPage]} alt={`${zoomPage + 1}쪽 크게`} className="max-h-full max-w-full bg-white" />
            </button>
          )}

          {/* 결과 요약 */}
          <div className="mt-4 rounded-lg bg-surface-subtle p-3 text-sm">
            <p className="mb-1 font-semibold text-ink-primary">나눌 결과</p>
            <ul className="space-y-0.5 text-xs text-ink-secondary">
              {summary.map((t) => (
                <li key={t.key} className="flex items-center gap-2">
                  <span className={`h-2.5 w-2.5 rounded-full ${t.dot}`} />
                  <span className="w-28 font-medium">{t.label}</span>
                  <span>{t.pages.length}쪽 ({t.pages.join(', ')}쪽)</span>
                </li>
              ))}
              {assign.includes('skip') && <li className="text-ink-muted">빼는 쪽: {assign.map((k, i) => (k === 'skip' ? i + 1 : null)).filter(Boolean).join(', ')}쪽</li>}
            </ul>
            {!summary.some((t) => t.key === 'applicationForm') && <p className="mt-1 text-xs text-status-danger">입학원서 쪽이 없습니다.</p>}
          </div>
        </>
      )}

      <div className="mt-4 flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-3">
          <button type="button" onClick={onCancel} className="text-sm text-ink-muted underline">서류별로 따로 올리기로 돌아가기</button>
          {source && <button type="button" onClick={() => { setSource(null); setThumbs([]); setAssign([]) }} className="text-sm text-ink-muted underline">다른 PDF 고르기</button>}
        </div>
        <button
          type="button"
          disabled={!thumbs.length || Boolean(busy) || !summary.some((t) => t.key === 'applicationForm')}
          onClick={finish}
          className="rounded-lg bg-brand-deepGreen px-5 py-2.5 text-sm font-bold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
        >
          이대로 나누기 →
        </button>
      </div>
    </div>
  )
}
