// 공통 아이콘 (2026-10-12, UI 다듬기)
//
// 화면 곳곳에 쓰던 글자·이모지 아이콘(☰ ▾ ◂ ▸ ✕ 🔔 🔴 🟠 ℹ️ ⚠️)은 글꼴·OS마다
// 모양과 크기가 달라 흐릿하고 들쭉날쭉했다. 선 굵기가 같은 SVG 하나로 통일한다.
// 경로는 Lucide(ISC 라이선스) 아이콘을 옮긴 것이다 — 아이콘 라이브러리를 따로
// 설치하지 않으려고 쓰는 것만 여기 둔다.
//
// 장식용이면 aria-hidden(기본), 아이콘만 있는 버튼이면 버튼 쪽에 aria-label을 단다.

const PATHS = {
  menu: ['M4 6h16', 'M4 12h16', 'M4 18h16'],
  close: ['M18 6 6 18', 'm6 6 12 12'],
  chevronLeft: ['m15 18-6-6 6-6'],
  chevronRight: ['m9 18 6-6-6-6'],
  chevronDown: ['m6 9 6 6 6-6'],
  externalLink: ['M15 3h6v6', 'M10 14 21 3', 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6'],
  alertCircle: ['M12 8v4', 'M12 16h.01', 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z'],
  alertTriangle: [
    'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3',
    'M12 9v4',
    'M12 17h.01',
  ],
  info: ['M12 16v-4', 'M12 8h.01', 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z'],
  check: ['M20 6 9 17l-5-5'],
  logOut: ['M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4', 'm16 17 5-5-5-5', 'M21 12H9'],
  lock: ['M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Z', 'M7 11V7a5 5 0 0 1 10 0v4'],
}

export default function Icon({ name, size = 18, strokeWidth = 2, className = '', label }) {
  const paths = PATHS[name]
  if (!paths) return null
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={`shrink-0 ${className}`}
      aria-hidden={label ? undefined : 'true'}
      role={label ? 'img' : undefined}
      aria-label={label}
      focusable="false"
    >
      {paths.map((d) => <path key={d} d={d} />)}
    </svg>
  )
}

// 경보 등급 → 아이콘·색 (AlertBanner, BlockingPanel, 대시보드 경보 목록 공용)
export const SEVERITY_ICON_NAME = {
  blocking: 'alertCircle',
  warning: 'alertTriangle',
  info: 'info',
}

export const SEVERITY_ICON_COLOR = {
  blocking: 'text-status-danger',
  warning: 'text-brand-orangeStrong',
  info: 'text-brand-blue',
}

export function SeverityIcon({ severity, size = 16, className = '' }) {
  return (
    <Icon
      name={SEVERITY_ICON_NAME[severity] || 'alertCircle'}
      size={size}
      className={`${SEVERITY_ICON_COLOR[severity] || SEVERITY_ICON_COLOR.blocking} ${className}`}
    />
  )
}
