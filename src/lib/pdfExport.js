// 화면의 서식(수험표·접수증)을 A4 PDF 파일로 저장한다.
//
// 방식: html2canvas로 서식을 고해상도 그림으로 뜬 뒤 jsPDF로 A4 한 장에 붙인다.
// 서식 폭은 180mm로 고정돼 있으므로(ExamTicketSheet, ReceiptPrint) PDF에서도
// 여백 15mm 안쪽에 폭 180mm로 붙이면 실제 크기가 된다 — 직인 2.4cm도 그대로.
// 서식이 A4 높이를 넘으면(거의 없음) 비율을 유지한 채 한 장에 맞춰 줄인다.
//
// 글자는 그림으로 들어간다(PDF 안에서 글자 선택·검색은 안 됨). 대신 한글 글꼴을
// PDF에 따로 넣을 필요가 없고, 화면과 똑같이 나온다.

import { printStampText } from './printStamp'

const A4_W = 210
const A4_H = 297
const MARGIN = 15

export async function downloadElementAsPdf(element, filename) {
  const pdf = await renderElementToPdf(element)
  pdf.save(filename)
}

// 메일 첨부 등: PDF를 Blob으로 받는다(2026-10-25). scale 2면 첨부 용량이 작아진다.
export async function elementToPdfBlob(element, { scale = 2 } = {}) {
  const pdf = await renderElementToPdf(element, { scale })
  return pdf.output('blob')
}

async function renderElementToPdf(element, { scale = 3 } = {}) {
  const [{ default: html2canvas }, { jsPDF }] = await Promise.all([
    import('html2canvas'),
    import('jspdf'),
  ])

  if (document.fonts?.ready) await document.fonts.ready

  // 인쇄자 표시(2026-10-12): 캡처하는 동안만 서식 아래에 한 줄 붙였다가 뗀다
  const stamp = document.createElement('div')
  stamp.textContent = printStampText()
  stamp.style.cssText = 'margin-top:4mm;text-align:right;font-size:7.5pt;color:#555;'
  element.appendChild(stamp)
  let canvas
  try {
    canvas = await html2canvas(element, {
      scale, // 3이면 인쇄 품질(약 250dpi 이상)
      backgroundColor: '#ffffff',
      useCORS: true,
    })
  } finally {
    stamp.remove()
  }

  const maxW = A4_W - MARGIN * 2
  const maxH = A4_H - MARGIN * 2
  let w = maxW
  let h = (canvas.height / canvas.width) * w
  if (h > maxH) {
    h = maxH
    w = (canvas.width / canvas.height) * h
  }
  const x = (A4_W - w) / 2

  const pdf = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' })
  pdf.addImage(canvas.toDataURL('image/jpeg', 0.92), 'JPEG', x, MARGIN, w, h)
  return pdf
}
