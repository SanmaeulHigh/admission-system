// UX1 명세서 9장 — 서버 경보의 사용자 언어 번역.
// M5a(모둠)/M5c(면접)/M5d(글쓰기) validate_* RPC가 돌려주는 raw code를
// 사용자 문구로 바꾼다. raw code 자체는 감사로그·기술정보에서는 유지하고,
// 기본 화면에는 절대 노출하지 않는다.
//
// 서버가 이미 상당히 읽기 좋은 한국어 message를 주는 경우도 많지만(예:
// "모든 모둠에 주관찰위원 2인을 배정해야 합니다"), title이 따로 없고
// actionLabel(해결 행동)도 없어서 화면에는 code+message를 그대로 붙여
// 보여주고 있었다 — 이 레이어가 그 자리를 대신한다.

export const ALERT_MESSAGES = {
  // ── 공통(M5a/c/d 전부) ──────────────────────────────────────
  PLAN_MISSING: {
    severity: 'info',
    title: '아직 계획을 시작하지 않았습니다',
    description: '저장된 계획이 없습니다. 첫 단계부터 시작하세요.',
  },
  DOCUMENT_SOURCE_STALE: {
    severity: 'blocking',
    title: '1단계 사정 결과가 변경되었습니다',
    description: '이 계획은 이전 1단계 사정 확정본을 기준으로 작성되었습니다. 현재 확정 결과를 기준으로 계획을 다시 확인해 주세요.',
    actionLabel: '변경 내용 확인',
  },
  DOCUMENT_SOURCE_INVALID: {
    severity: 'blocking',
    title: '1단계 사정 기준을 확인할 수 없습니다',
    description: '관리자에게 문의하세요.',
  },
  DOCUMENT_FINAL_MISSING: {
    severity: 'blocking',
    title: '1단계 사정이 아직 확정되지 않았습니다',
    description: '1단계 사정 결과가 확정된 뒤에 계획을 만들 수 있습니다.',
    actionLabel: '1단계 사정으로 이동',
  },
  CONFIG_SOURCE_STALE: {
    severity: 'blocking',
    title: '배점 기준이 변경되었습니다',
    description: '이 계획을 만든 뒤 배점 기준이 바뀌었습니다. 최종확정 전에 계획을 다시 저장하세요.',
  },

  // ── M5a 모둠활동 ─────────────────────────────────────────────
  GROUP_MISSING: {
    severity: 'blocking',
    title: '모둠이 없습니다',
    description: '최소 1개 이상의 모둠을 만들어야 합니다.',
    actionLabel: '모둠 만들기',
  },
  CANDIDATE_UNASSIGNED: {
    severity: 'blocking',
    title: '아직 모둠에 배정되지 않은 지원자가 있습니다',
    actionLabel: '미배정 지원자 확인',
  },
  CANDIDATE_INELIGIBLE: {
    severity: 'blocking',
    title: '대상이 아닌 지원자가 배정되어 있습니다',
    description: '1단계 사정 합격자가 아닌 지원자가 모둠에 포함되어 있습니다.',
  },
  EMPTY_GROUP: {
    severity: 'blocking',
    title: '지원자가 없는 모둠이 있습니다',
    actionLabel: '빈 모둠 확인',
  },
  PRIMARY_OBSERVER_COUNT: {
    severity: 'blocking',
    title: '관찰위원 배정이 완료되지 않았습니다',
    description: '각 모둠에는 주관찰위원 2명이 필요합니다.',
    actionLabel: '미배정 위치 확인',
  },
  PRIMARY_OBSERVER_INVALID: {
    severity: 'blocking',
    title: '관찰위원 자격을 확인할 수 없는 배정이 있습니다',
    description: '해당 위원의 역할·배정영역이 모둠 관찰 조건을 충족하지 않습니다.',
  },
  ROTATION_SEGMENT_MISSING: {
    severity: 'blocking',
    title: '순환 관찰 계획이 없습니다',
    description: '주관찰위원이 다른 모둠을 관찰할 시간을 1회 이상 지정해 주세요.',
    actionLabel: '순환 관찰 계획 만들기',
  },
  ROTATION_SEGMENT_OVERLAP: {
    severity: 'blocking',
    title: '순환 관찰 시간이 겹칩니다',
    description: '같은 위원의 순환 관찰 시간이 서로 겹치지 않게 조정하세요.',
    actionLabel: '겹치는 시간 확인',
  },
  ROTATION_ASSIGNMENT_MISSING: {
    severity: 'blocking',
    title: '순환 관찰 시간에 배정되지 않은 위원이 있습니다',
    description: '모둠 관찰 위원 전원이 각 순환 관찰 시간에 어느 모둠을 볼지 지정되어야 합니다.',
    actionLabel: '미배정 위원 확인',
  },
  PRIMARY_OBSERVER_COVERAGE: {
    severity: 'blocking',
    title: '일부 시간대에 담당 관찰위원이 남아 있지 않습니다',
    description: '순환 관찰 중에도 각 모둠에는 주관찰위원이 최소 1명 남아 있어야 합니다.',
    actionLabel: '문제 시간대 확인',
  },
  ROTATION_TARGET_OUT_OF_SHIFT: {
    severity: 'blocking',
    title: '다른 반 모둠을 관찰 대상으로 잡은 배정이 있습니다',
    description: '오전 구간에는 오전반 모둠만, 오후 구간에는 오후반 모둠만 관찰 대상으로 고를 수 있습니다.',
    actionLabel: '순환 관찰 확인',
  },
  ROVING_OBSERVER_UNUSED: {
    severity: 'warning',
    title: '어느 구간에도 관찰 배정되지 않은 모둠 위원이 있습니다',
    description: null,
    actionLabel: null,
  },

  // ── M5c 면접 ────────────────────────────────────────────────
  TEAM_MISSING: {
    severity: 'blocking',
    title: '면접조가 없습니다',
    description: '최소 1개 이상의 면접조를 만들어야 합니다.',
    actionLabel: '면접조 만들기',
  },
  TEAM_MEMBER_COUNT: {
    severity: 'blocking',
    title: '위원이 정확히 2명이 아닌 면접조가 있습니다',
    description: '각 면접조는 평가위원 2명이 배정되어야 합니다.',
    actionLabel: '면접조 위원 확인',
  },
  INVALID_TEAM_MEMBER: {
    severity: 'blocking',
    title: '면접 자격을 확인할 수 없는 위원이 있습니다',
  },
  NON_CANDIDATE_ASSIGNED: {
    severity: 'blocking',
    title: '대상이 아닌 지원자가 시간표에 포함되어 있습니다',
  },
  DURATION_MISMATCH: {
    severity: 'warning',
    title: '면접 시간이 기준과 다른 항목이 있습니다',
    description: '학생·학부모 면접 배정 시간을 설정 기준에 맞게 조정하세요.',
    actionLabel: '시간표 확인',
  },
  SCHEDULE_OVERLAP: {
    severity: 'blocking',
    title: '같은 면접조의 시간이 겹칩니다',
    description: '학생 면접과 학부모 면접 시간이 겹치지 않게 조정하세요.',
    actionLabel: '겹치는 시간 확인',
  },

  // ── M5d 글쓰기 ──────────────────────────────────────────────
  CANDIDATE_MISSING: {
    severity: 'blocking',
    title: '평가 대상 합격자가 없습니다',
    description: '1단계 사정 합격자가 있어야 글쓰기 계획을 확정할 수 있습니다.',
  },
  WRITING_MEMBER_COUNT: {
    severity: 'blocking',
    title: '평가위원이 정확히 2명이 아닙니다',
    description: '글쓰기 평가위원은 정확히 2명이 배정되어야 합니다.',
    actionLabel: '평가위원 확인',
  },
  INVALID_WRITING_MEMBER: {
    severity: 'blocking',
    title: '글쓰기 평가 자격을 확인할 수 없는 위원이 있습니다',
  },
  WRITING_ANSWER_MISSING: {
    severity: 'blocking',
    title: '아직 준비되지 않은 답안이 있습니다',
    description: '모든 대상 지원자의 글쓰기 답안이 등록되어야 확정할 수 있습니다.',
    actionLabel: '미준비 답안 확인',
  },
}

/**
 * 서버 validate_* 응답의 {code, message} 하나를 화면 표시용으로 번역한다.
 * 매핑이 없는 코드는 서버 message를 그대로 쓰되(이미 한국어 문장인 경우가
 * 대부분) code 자체는 절대 반환하지 않는다.
 */
export function translateAlert({ code, message }) {
  const preset = ALERT_MESSAGES[code]
  if (!preset) {
    return { severity: 'blocking', title: message || '확인이 필요합니다', description: null, actionLabel: null }
  }
  return {
    severity: preset.severity,
    title: preset.title,
    description: preset.description || message || null,
    actionLabel: preset.actionLabel || null,
  }
}
