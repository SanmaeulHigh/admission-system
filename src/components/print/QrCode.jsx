// 인쇄용 QR 코드 (SVG, 2026-09-28 — 1차원 바코드 대신)
//
// 내용은 번호 문자열 그대로다(수험번호 A1003, 접수번호 260916G001). 2D 리더기로 찍으면
// 키보드처럼 그 번호가 입력되므로 입실 확인 화면(CheckinPage)에서 바로 쓸 수 있다.
// 크기를 mm로 지정해 인쇄해도 그대로 나온다. 짧은 번호라 21×21 칸(버전 1)이면 충분하다.

import QRCode from 'qrcode'

const MARGIN = 2 // 여백(칸 수). 표준 권장은 4지만 흰 종이 위라 2로도 잘 읽힌다.

export default function QrCode({ value, sizeMm = 20, showText = true, className = '' }) {
  if (!value) return null
  let qr
  try {
    qr = QRCode.create(String(value), { errorCorrectionLevel: 'M' })
  } catch {
    return null
  }
  const n = qr.modules.size
  const total = n + MARGIN * 2
  const cells = []
  for (let r = 0; r < n; r += 1) {
    for (let c = 0; c < n; c += 1) {
      if (qr.modules.get(r, c)) cells.push(`M${c + MARGIN} ${r + MARGIN}h1v1h-1z`)
    }
  }

  return (
    <div className={`inline-flex flex-col items-center ${className}`}>
      <svg
        width={`${sizeMm}mm`}
        height={`${sizeMm}mm`}
        viewBox={`0 0 ${total} ${total}`}
        role="img"
        aria-label={`QR 코드 ${value}`}
        shapeRendering="crispEdges"
      >
        <rect x="0" y="0" width={total} height={total} fill="#ffffff" />
        <path d={cells.join('')} fill="#000000" />
      </svg>
      {showText && (
        <span className="mt-0.5 text-[10px] tracking-[0.15em] text-ink-primary">{value}</span>
      )}
    </div>
  )
}
