// UX1-G(27장) — 전역 상태 라벨 사전.
//
// 지원자 업무 상태(application_status/evaluation_stage/track/round 등)는
// 이미 src/lib/applicantLabels.js가 한 곳에서 관리하고 있어 그대로 둔다.
// 이 파일은 그 외 화면 전반에서 반복되는 "작업 상태"(제출/확정/재개방 등
// draft·submitted·finalized류)와 "경보 심각도"(blocking/warning/info) 라벨을
// 담당한다. 이전에는 StatusBadge.jsx와 AlertBanner.jsx, AdminDashboard.jsx가
// 각자 자기만의 STATUS_MAP/SEVERITY_ICON을 갖고 있었다(23.1 "page마다 제각각
// badge CSS를 만들지 않는다" 위반) — 이 파일로 통합한다.
//
// 22.1 금지 표현표의 raw 용어(draft/final/finalized/blocking/segment 등)는
// 이 파일을 거치지 않고 화면에 절대 직접 노출하지 않는다.

export const WORK_STATUS_LABEL = {
  draft: { label: '작성 중', tone: 'neutral' },
  saved: { label: '저장됨', tone: 'info' },
  submitted: { label: '제출 완료', tone: 'success' },
  finalized: { label: '확정 완료', tone: 'success' },
  reopened: { label: '수정 재개방', tone: 'warning' },
  pending: { label: '대기', tone: 'neutral' },
  blocked: { label: '진행 불가', tone: 'danger' },
  stale: { label: '기준 변경 확인 필요', tone: 'warning' },
}

export function workStatusText(status) {
  return WORK_STATUS_LABEL[status]?.label || status
}

// 경보 심각도(server의 severity: blocking/warning/info) — 22.1에 따라 화면에는
// "blocking"이라는 단어 자체를 절대 노출하지 않는다.
export const SEVERITY_LABEL = {
  blocking: '확인 필요',
  warning: '주의',
  info: '안내',
}

export const SEVERITY_ICON = {
  blocking: '🔴',
  warning: '🟠',
  info: 'ℹ️',
}

export const SEVERITY_TONE = {
  blocking: 'danger',
  warning: 'warning',
  info: 'info',
}

export function severityText(severity) {
  return SEVERITY_LABEL[severity] || severity
}

// StatusBadge/AlertBanner의 tone → 색상 토큰 클래스. 여기서만 정의해서
// 페이지별로 같은 의미에 다른 색을 쓰지 않게 한다(28장 "색상 의미 일관성").
export const TONE_CLASS = {
  success: 'bg-brand-greenSoft text-brand-deepGreenStrong',
  info: 'bg-brand-blueSoft text-brand-blue',
  warning: 'bg-brand-orangeSoft text-brand-orangeStrong',
  danger: 'bg-status-dangerSoft text-status-danger',
  neutral: 'bg-surface-subtle text-ink-secondary',
}
