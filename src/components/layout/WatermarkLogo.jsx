// 화면 하단 우측 워터마크 로고 (2026-07-14 요청)
// 브랜드 존재감을 은은하게 남기되 클릭/터치는 절대 가로채지 않는다
// (pointer-events: none). 로그인 화면·AdminShell·FieldShell 세 곳에서
// 공통으로 쓰도록 분리했다.

import schoolLogo from '../../assets/school-logo.png'

export default function WatermarkLogo() {
  return (
    <img
      src={schoolLogo}
      alt=""
      aria-hidden="true"
      className="pointer-events-none fixed bottom-4 right-4 z-0 h-20 w-auto select-none opacity-10 sm:h-28"
    />
  )
}
