// UX1 명세서 섹션 5.1(정보구조) + 5.2(기존 화면 매핑)를 반영한 중앙 네비게이션
// 설정. "role-based menu 노출은 navigation.js에 중앙화한다"(23.1)는 원칙에
// 따라 사이드바·모바일 드로어가 전부 이 설정 하나만 보고 렌더링한다.
//
// 아직 페이지가 없는 항목(심층평가 진행 현황, 전형위원·권한 관리)은 넣지
// 않는다 — UX1-A는 기존 route를 새 Shell로 감싸는 단계이지 새 화면을
// 만드는 단계가 아니다. 해당 화면이 생기면 여기에 추가한다.
//
// 2026-07-12 개선(Task #37, 사용자 피드백): 헤더에 신입학/전편입학 전형
// 스위처가 생기면서(AppHeader.jsx, src/lib/admissionMode.js), 신입학
// 파이프라인 전용 섹션과 전편입학(공고 2026-40호) 전용 섹션을 구분해야
// 한다. 각 섹션에 `mode`를 태그해서(null = 두 모드 모두 노출) Sidebar/
// MobileNav가 role 필터에 이어 mode 필터도 적용한다. "전·편입생
// 접수대장"은 기존에 신입학 '지원자' 섹션에 잘못 섞여 있었던 걸 이번에
// 전용 '전편입학' 섹션으로 옮긴다.

export const NAV_SECTIONS = [
  {
    label: null,
    mode: null,
    items: [{ label: '오늘의 업무', path: '/', roles: null }],
  },
  {
    label: '지원자',
    mode: 'new',
    items: [
      { label: '지원자 목록', path: '/reception', roles: ['superadmin', 'admin', 'reception'] },
      { label: '자소서·소견서 입력', path: '/reception/transcriptions', roles: ['superadmin', 'admin', 'reception'] },
      { label: '지원자 서류 열람', path: '/principal/documents', roles: ['principal', 'evaluator', 'quant', 'superadmin'] },
    ],
  },
  {
    label: '전편입학',
    mode: 'transfer',
    items: [
      {
        label: '전·편입생 접수대장',
        path: '/transfer-admission',
        roles: ['superadmin', 'admin', 'reception'],
      },
    ],
  },
  {
    label: '서류평가',
    mode: 'new',
    items: [
      // 평가 준비를 맨 위에 둔다 — 위원 배정이 안 되어 있으면 나머지가 굴러가지 않는다.
      { label: '평가 준비 (위원 배정)', path: '/evaluation/staffing', roles: ['superadmin', 'admin'] },
      { label: '내 평가', path: '/evaluation', roles: ['superadmin', 'admin', 'evaluator', 'quant'] },
      { label: '평가 진행 현황', path: '/evaluation/monitor', roles: ['superadmin', 'admin'] },
      { label: '채점표 출력 (결재용)', path: '/evaluation/scoresheet-print', roles: ['superadmin', 'admin'] },
      { label: '1단계 사정', path: '/decision/document', roles: ['superadmin', 'admin'] },
    ],
  },
  // 2026-09-28 신설: 평가가 정상적으로 안 굴러갈 때 쓰는 대응 수단들을 한곳에 모았다.
  // 전에는 "관리자 대리 채점 입력"과 "현장 종이 백업"이 '결과·자료' 아래 묻혀 있어,
  // 정작 급할 때 찾지 못했다(메뉴 이름에서 용도를 짐작할 수도 없었다).
  {
    label: '평가 운영 · 문제 대응',
    mode: 'new',
    items: [
      { label: '실시간 채점 현황 · 재개방', path: '/evaluation/live-monitor', roles: ['superadmin'] },
      { label: '입실 확인 (바코드)', path: '/deep/checkin', roles: ['superadmin', 'admin'] },
      // 2026-09-28: 심층역량평가는 종이 채점표로 운영하고 관리자가 일괄 입력한다.
      { label: '종이 채점표 출력', path: '/deep/paper-backup', roles: ['superadmin', 'admin'] },
      { label: '면접 진행표 출력', path: '/deep/interview-run-sheet', roles: ['superadmin', 'admin'] },
      { label: '종이 채점 일괄 입력', path: '/deep/paper-entry', roles: ['superadmin', 'admin'] },
      { label: '관리자 대리 채점 입력', path: '/deep/admin-score-entry', roles: ['superadmin', 'admin'] },
    ],
  },
  {
    label: '심층역량평가 · 전형 준비',
    mode: 'new',
    items: [
      { label: '평가 준비 (위원 배정)', path: '/deep/staffing', roles: ['superadmin', 'admin'] },
      { label: '모둠활동', path: '/deep/group-plan', roles: ['superadmin', 'admin'] },
      { label: '면접', path: '/deep/interview-plan', roles: ['superadmin', 'admin'] },
      { label: '글쓰기', path: '/deep/writing-plan', roles: ['superadmin', 'admin'] },
    ],
  },
  {
    label: '심층역량평가 · 내 평가',
    mode: 'new',
    items: [
      { label: '모둠활동', path: '/deep/group-observation', roles: ['evaluator'] },
      { label: '학생·학부모 면접', path: '/deep/interview-score', roles: ['evaluator'] },
      { label: '글쓰기', path: '/deep/writing-score', roles: ['evaluator'] },
    ],
  },
  {
    label: '최종 사정',
    mode: 'new',
    items: [{ label: '사정 결과 검토·확정', path: '/decision/final', roles: ['superadmin', 'admin'] }],
  },
  {
    label: '결과·자료',
    mode: 'new',
    items: [
      { label: '발표 자료', path: '/decision/final/announce', roles: ['superadmin', 'admin'] },
      { label: '전형평가회의 자료', path: '/decision/final/committee-packet', roles: ['superadmin', 'admin'] },
      { label: '확인서·합격증서 출력', path: '/decision/certificates', roles: ['superadmin', 'admin'] },
      {
        label: '면접 대기실 송출 화면',
        path: '/display/interview',
        roles: ['superadmin', 'admin'],
        newTab: true,
      },
    ],
  },
  {
    label: '시스템 관리',
    mode: null,
    items: [
      { label: '감사 기록', path: '/admin/audit-log', roles: ['superadmin', 'admin'] },
      {
        label: '사용자(선생님) 권한 관리',
        path: '/admin/users',
        roles: ['superadmin'],
      },
      {
        label: '년도·전형(회차) 설정',
        path: '/admin/admission-cycle',
        roles: ['superadmin', 'admin'],
        // 2026-10-20: 아직 신입학 회차만 다룬다. 전입생 회차는 엔진 통합 후 전편입학 화면에 따로 둔다.
        mode: 'new',
      },
    ],
  },
]

/** section.mode가 현재 선택된 전형 모드와 맞는지(null = 항상 노출) */
export function isNavSectionVisibleForMode(section, currentMode) {
  return section.mode == null || section.mode === currentMode
}

/** 로그인 사용자의 역할 목록(hasAnyRole 대신 배열 직접 비교용) 기준 노출 여부 */
/** item.mode가 있으면 그 전형 모드에서만 보인다(없으면 두 모드 모두) */
export function isNavItemVisibleForMode(item, currentMode) {
  return item.mode == null || item.mode === currentMode
}

export function isNavItemVisible(item, hasAnyRole) {
  if (!item.roles) return true
  return hasAnyRole(item.roles)
}

/** 현재 pathname과 매칭되는 nav item을 찾는다(breadcrumb·현재 위치 강조용) */
export function findActiveNavItem(pathname) {
  const items = NAV_SECTIONS.flatMap((section) => section.items)
  const path = findActiveNavPath(pathname, items)
  return path ? items.find((item) => item.path === path) ?? null : null
}

/** FieldShell을 써야 하는 route (현장 평가 — 명세서 4.2/24.2) */
export const FIELD_SHELL_ROUTES = ['/deep/group-observation', '/deep/interview-score', '/deep/writing-score']

export function isFieldShellRoute(pathname) {
  return FIELD_SHELL_ROUTES.some((p) => pathname === p || pathname.startsWith(p + '/'))
}

// 현재 주소에 해당하는 메뉴 하나만 고른다 (2026-10-13).
// 예전에는 항목마다 "주소가 이 경로로 시작하나"만 봐서, /evaluation/live-monitor 에서
// '내 평가'(/evaluation)와 '실시간 채점 현황'이 동시에 선택돼 보였다.
// 이제는 보이는 항목 중 가장 길게(구체적으로) 맞는 경로 하나만 활성으로 본다.
export function findActiveNavPath(pathname, items) {
  let best = null
  for (const item of items) {
    if (item.newTab || !item.path) continue
    const p = item.path
    const hit = pathname === p || (p !== '/' && pathname.startsWith(p + '/'))
    if (hit && (!best || p.length > best.length)) best = p
  }
  return best
}
