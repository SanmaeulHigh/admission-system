// UUID v4 생성 (2026-10-01)
//
// crypto.randomUUID()는 보안 컨텍스트(HTTPS 또는 localhost)에서만 존재한다.
// 예전 교내망 주소(http://192.168.0.10:3000)처럼 https가 아닌 곳에서 열면 undefined가 되어,
// 호출하는 순간 TypeError로 화면 전체가 하얗게 멈췄다(모둠 추가 버튼).
// crypto.getRandomValues()는 비보안 컨텍스트에서도 쓸 수 있어 이걸로 대체한다.

export function newUuid() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80 // variant 10xx
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
