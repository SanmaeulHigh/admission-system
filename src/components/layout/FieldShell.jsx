// UX1 명세서 4.2 — FieldShell.
// 모둠활동 관찰채점·면접채점·글쓰기채점 전용 레이아웃. 사이드바 없음,
// 감사로그·접수대장·최종사정 메뉴는 이 Shell에 애초에 존재하지 않는다.
// 한 손 조작을 고려해 주요 터치 타깃 44px 이상, iOS safe area 반영.

import { Link } from 'react-router-dom'
import { useAuth } from '../../contexts/AuthContext'
import SaveStatus from '../feedback/SaveStatus'
import schoolLogo from '../../assets/school-logo.png'
import WatermarkLogo from './WatermarkLogo'

export default function FieldShell({ title, contextLine, saveState, children, bottomBar }) {
  const { email } = useAuth()

  return (
    <div
      className="flex h-screen flex-col bg-surface-canvas"
      style={{ paddingTop: 'env(safe-area-inset-top)', paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <header className="shrink-0 border-b border-border bg-surface-card px-4 pt-3">
        <div className="mb-2 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <img src={schoolLogo} alt="새봄고등학교 로고" width={24} height={24} />
            <span className="text-sm font-bold text-ink-primary">입학전형관리시스템</span>
          </div>
          <div className="flex items-center gap-3">
            <span className="hidden max-w-[100px] truncate text-xs text-ink-muted sm:inline">{email}</span>
            <Link to="/" className="text-xs font-medium text-ink-muted underline">
              나가기
            </Link>
          </div>
        </div>
        <h1 className="pb-3 text-lg font-bold text-ink-primary">{title}</h1>
      </header>

      {(contextLine || saveState) && (
        <div className="flex shrink-0 items-center justify-between border-b border-border bg-surface-subtle px-4 py-2">
          <span className="text-sm text-ink-secondary">{contextLine}</span>
          {saveState && <SaveStatus state={saveState} />}
        </div>
      )}

      <main className="min-h-0 flex-1 overflow-y-auto px-4 py-4">{children}</main>

      {bottomBar && (
        <div className="shrink-0 border-t border-border bg-surface-card px-4 py-3">{bottomBar}</div>
      )}
      <WatermarkLogo />
    </div>
  )
}
