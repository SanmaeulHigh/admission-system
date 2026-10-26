// 접수번호·수험번호 QR/바코드 읽기 공용 (2026-10-21)
//
// USB 리더는 키보드처럼 글자를 빠르게 치고 Enter를 누른다.
// 접수번호: YYMMDD + 전형코드(G/I/U, 예전 M/V) + 3자리   예) 261021I003
// 수험번호: A + 회차(1~3) + 3자리                         예) A1001

export const RECEIPT_NO_RE = /^\d{6}[GIUMV]\d{3}$/
export const EXAM_NO_RE = /^A[123]\d{3}$/

export function isApplicantCode(code) {
  return RECEIPT_NO_RE.test(code) || EXAM_NO_RE.test(code)
}

// 키 이벤트 → 글자. 한글 입력 상태여도 물리 키(code) 기준으로 영문·숫자를 얻는다.
export function keyEventToChar(e) {
  const m = /^Key([A-Z])$/.exec(e.code || '')
  if (m) return m[1]
  const d = /^(?:Digit|Numpad)(\d)$/.exec(e.code || '')
  if (d) return d[1]
  if (e.key && e.key.length === 1 && /[0-9A-Za-z]/.test(e.key)) return e.key.toUpperCase()
  return null
}

export function isEditableTarget(el) {
  if (!el) return false
  const tag = el.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable
}

// 한글 입력 상태에서 리더가 입력칸에 친 값 되돌리기: 'ㅁ1001' → 'A1001', '261023ㅑ004' → '261023I004'
const HANGUL_TO_QWERTY = {
  ㅂ: 'Q', ㅈ: 'W', ㄷ: 'E', ㄱ: 'R', ㅅ: 'T', ㅛ: 'Y', ㅕ: 'U', ㅑ: 'I', ㅐ: 'O', ㅔ: 'P',
  ㅁ: 'A', ㄴ: 'S', ㅇ: 'D', ㄹ: 'F', ㅎ: 'G', ㅗ: 'H', ㅓ: 'J', ㅏ: 'K', ㅣ: 'L',
  ㅋ: 'Z', ㅌ: 'X', ㅊ: 'C', ㅍ: 'V', ㅠ: 'B', ㅜ: 'N', ㅡ: 'M',
  ㅃ: 'Q', ㅉ: 'W', ㄸ: 'E', ㄲ: 'R', ㅆ: 'T', ㅒ: 'O', ㅖ: 'P',
}

export function normalizeScanText(raw) {
  return String(raw || '')
    .normalize('NFD') // 혹시 글자가 조합돼 들어와도 자모로 풀기
    .split('')
    .map((ch) => HANGUL_TO_QWERTY[String.fromCharCode(compatJamo(ch.charCodeAt(0)))] || HANGUL_TO_QWERTY[ch] || ch)
    .join('')
    .replace(/\s/g, '')
    .toUpperCase()
}

// 조합형 자모(U+1100대)를 호환 자모(U+3131대)로 — NFD로 풀린 글자를 위 표로 찾기 위해
const CHOSEONG = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ'
const JUNGSEONG = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ'
function compatJamo(code) {
  if (code >= 0x1100 && code <= 0x1112) return CHOSEONG.charCodeAt(code - 0x1100)
  if (code >= 0x1161 && code <= 0x1175) return JUNGSEONG.charCodeAt(code - 0x1161)
  return code
}
