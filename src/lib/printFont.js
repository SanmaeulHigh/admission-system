// 새 창(window.open + document.write)으로 여는 인쇄용 HTML에 넣는 글꼴 정의.
// 새 창은 앱의 index.css를 읽지 않으므로 @font-face를 따로 넣어야 한다.
// about:blank 창에서는 상대 경로가 기대와 다르게 풀릴 수 있어 절대 주소를 쓴다.

export const PRINT_FONT_STACK =
  "'Pretendard Variable', 'Malgun Gothic', 'Apple SD Gothic Neo', 'Noto Sans CJK KR', sans-serif"

export function printFontFaceCss() {
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  return `
    @font-face { font-family: 'Pretendard Variable'; font-weight: 45 920; font-style: normal; font-display: swap;
      src: url('${origin}/fonts/PretendardVariable.woff2') format('woff2-variations'); }
  `
}
