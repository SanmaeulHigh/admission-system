// 모든 출력물 하단의 "인쇄자" 표시 (2026-10-12)
//
// 누가 언제 뽑았는지 종이에 남긴다. 쓰는 곳 세 갈래:
//  1) 앱 화면을 그대로 인쇄(접수증·수험표·접수대장 등)
//       → App에 붙은 <PrintStamp />가 @page 아래 여백(오른쪽)에 찍는다.
//  2) 새 창에 HTML을 써서 인쇄(채점표·면접 진행표·확인표 등)
//       → 각 HTML의 <style>에 printStampCss()를 넣는다.
//  3) PDF 저장(html2canvas) → pdfExport가 서식 아래에 글자로 붙인다.
//
// 이름은 로그인할 때 AuthContext가 setPrintIdentity로 넣어 둔다.
// @page 여백 상자(@bottom-right)는 Chrome·Edge 131 이상에서 찍힌다.

let identity = ''

export function setPrintIdentity(name) {
  identity = name || ''
}

export function printStampText(now = new Date()) {
  const when = now.toLocaleString('ko-KR', {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
  })
  return `인쇄자: ${identity || '(이름 없음)'} · ${when}`
}

function cssString(text) {
  return `"${String(text).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

// @page 아래 오른쪽 여백에 인쇄자 표시 — 본문을 가리지 않는다
export function printStampCss(now = new Date()) {
  return `@page { @bottom-right { content: ${cssString(printStampText(now))}; font-size: 7.5pt; color: #555; font-family: Pretendard, 'Malgun Gothic', sans-serif; } }`
}
