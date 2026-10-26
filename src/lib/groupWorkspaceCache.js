const PREFIX = 'sanmaeul:m5b:workspace:'
const TTL_MS = 24 * 60 * 60 * 1000

function keyFor(userId) {
  return `${PREFIX}${userId}`
}

function minimalWorkspace(workspace) {
  return {
    year: workspace?.year,
    round: workspace?.round,
    planRevision: workspace?.planRevision,
    areaOpen: Boolean(workspace?.areaOpen),
    criteria: workspace?.criteria || [],
    criterionMax: workspace?.criterionMax,
    scoreStep: workspace?.scoreStep,
    perEvaluatorMax: workspace?.perEvaluatorMax,
    segments: (workspace?.segments || []).map((segment) => ({
      segmentId: segment.segmentId,
      segmentCode: segment.segmentCode,
      startsAt: segment.startsAt,
      endsAt: segment.endsAt,
      targetGroupId: segment.targetGroupId,
    })),
    groups: (workspace?.groups || []).map((group) => ({
      groupId: group.groupId,
      groupCode: group.groupCode,
      observerRole: group.observerRole,
      allowedSegmentIds: group.allowedSegmentIds || [],
      members: (group.members || []).map((member) => ({
        applicantId: member.applicantId,
        examNo: member.examNo,
        displayName: member.displayName,
        myScore: member.myScore || null,
      })),
    })),
  }
}

export function saveGroupWorkspaceCache(userId, workspace) {
  if (!userId || !workspace) return
  const now = Date.now()
  try {
    localStorage.setItem(keyFor(userId), JSON.stringify({
      cachedAt: now,
      expiresAt: now + TTL_MS,
      workspace: minimalWorkspace(workspace),
    }))
  } catch {
    // 저장공간/브라우저 정책 문제는 온라인 채점 자체를 막지 않는다.
  }
}

export function getGroupWorkspaceCache(userId) {
  if (!userId) return null
  const key = keyFor(userId)
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || 'null')
    if (!parsed?.workspace || !parsed?.expiresAt || parsed.expiresAt <= Date.now()) {
      localStorage.removeItem(key)
      return null
    }
    return parsed
  } catch {
    localStorage.removeItem(key)
    return null
  }
}

export function clearGroupWorkspaceCache(userId) {
  if (!userId) return
  try {
    localStorage.removeItem(keyFor(userId))
  } catch {
    // 브라우저 저장소 접근이 차단된 경우 정리 실패를 로그아웃 실패로 취급하지 않는다.
  }
}
