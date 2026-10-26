// 역할 기반 화면 가드.
// 주의: 이 가드는 UX 편의(메뉴/화면 숨김)일 뿐이며 실제 데이터 접근 통제는
// 아니다. "Security Rules 없이 UI 숨김만으로 권한 통제"는 섹션 9.2에서
// 명시적으로 금지된 패턴이다 — 이 컴포넌트는 절대 그 대체물이 될 수 없다.

import { Navigate } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'

export default function RequireRole({ roles, area, children }) {
  const { hasAnyRole, hasArea } = useAuth()

  if (roles && !hasAnyRole(roles)) {
    return <Navigate to="/" replace />
  }

  if (area && !hasArea(area)) {
    return <Navigate to="/" replace />
  }

  return children
}
