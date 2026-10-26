// UX1-B — 역할별 "오늘의 업무" Dashboard 라우터.
// 총괄/관리자 · 평가위원 · 정량평가 담당, 3가지 버전 중 하나를 고른다.
// 우선순위: superadmin/admin > evaluator > quant > (역할 없음 안내).
// reception 단독 계정은 별도 spec 섹션이 없어 최소 안내로 대체한다.

import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'
import AdminDashboard from './AdminDashboard'
import EvaluatorDashboard from './EvaluatorDashboard'
import QuantDashboard from './QuantDashboard'

export default function Dashboard() {
  const { roles } = useAuth()

  if (roles.includes('superadmin') || roles.includes('admin')) {
    return <AdminDashboard />
  }
  if (roles.includes('evaluator')) {
    return <EvaluatorDashboard />
  }
  if (roles.includes('quant')) {
    return <QuantDashboard />
  }
  // 학교장: 서류 열람 화면이 곧 첫 화면이다 (00082)
  if (roles.includes('principal')) {
    return <Navigate to="/principal/documents" replace />
  }
  if (roles.includes('reception')) {
    return (
      <div className="space-y-2">
        <h1 className="text-2xl font-bold text-ink-primary">안녕하세요.</h1>
        <p className="text-sm text-ink-secondary">접수 담당 계정입니다.</p>
        <Link
          to="/reception"
          className="mt-2 inline-block rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong"
        >
          지원자 목록으로 이동
        </Link>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-dashed border-border bg-surface-card p-6 text-center">
      <p className="text-sm font-medium text-ink-secondary">아직 배정된 역할이 없습니다.</p>
      <p className="mt-1 text-xs text-ink-muted">관리자에게 역할·배정영역 승인을 요청하세요.</p>
    </div>
  )
}
