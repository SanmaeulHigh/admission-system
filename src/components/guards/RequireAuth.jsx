import { useEffect, useState } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import MfaGate from './MfaGate'
import ChangePasswordForm from '../auth/ChangePasswordForm'
import schoolLogo from '../../assets/school-logo.png'

export default function RequireAuth({ children }) {
  const { status, email, signOut, session } = useAuth()
  const location = useLocation()

  if (status === 'loading') return <AuthLoading />

  if (status === 'signedOut') {
    return <Navigate to="/login" state={{ from: location }} replace />
  }

  // 교외 접속: 휴대폰 인증을 마쳐야 들어간다(00085)
  if (status === 'mfa') {
    return <MfaGate />
  }

  if (status === 'unregistered') {
    // 섹션 2.2: 로그인 성공이 곧 권한 부여를 의미하지 않는다.
    // superadmin이 권한을 부여하면 Realtime 구독으로 자동 전환된다.
    return (
      <div className="flex h-screen flex-col items-center justify-center gap-4 px-6 text-center">
        <p className="text-lg font-medium text-ink-primary">계정 승인 대기 중입니다.</p>
        <p className="max-w-sm text-sm text-ink-muted">
          아래 이메일 주소를 입학전형 시스템 관리자에게 전달해 권한을 요청하세요.
          승인되면 이 화면이 자동으로 넘어갑니다.
        </p>
        <p className="rounded-md bg-surface-subtle px-4 py-2 font-mono text-sm text-ink-primary">
          {email}
        </p>
        <button
          type="button"
          onClick={signOut}
          className="text-sm text-ink-muted underline hover:text-ink-primary"
        >
          로그아웃
        </button>
      </div>
    )
  }

  // 최고관리자가 만든 계정·재설정한 비밀번호는 첫 로그인 때 본인이 새 비밀번호로 바꾼다
  if (status === 'ready' && session?.user?.user_metadata?.must_change_password) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-surface-canvas px-4 py-10">
        <div className="w-full max-w-sm rounded-2xl border border-border bg-surface-card p-7 shadow-sm">
          <div className="mb-5 flex items-center gap-3">
            <img src={schoolLogo} alt="" className="h-11 w-auto" />
            <div>
              <h1 className="text-lg font-bold text-ink-primary">새 비밀번호 정하기</h1>
              <p className="text-xs text-ink-muted">{email}</p>
            </div>
          </div>
          <p className="mb-4 text-sm leading-relaxed text-ink-secondary">
            관리자가 정해 준 임시 비밀번호로 들어오셨습니다. 본인만 아는 새 비밀번호로 바꾼 뒤 이용해 주세요.
          </p>
          <ChangePasswordForm submitLabel="바꾸고 시작하기" />
          <button type="button" onClick={signOut} className="mt-4 w-full text-center text-xs text-ink-muted underline hover:text-ink-primary">로그아웃</button>
        </div>
      </div>
    )
  }

  return children
}

// 로그인 확인이 오래 걸리면(서버 지연·저장된 로그인 정보 꼬임) 빠져나갈 길을 보여 준다(2026-10-26)
function AuthLoading() {
  const [slow, setSlow] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setSlow(true), 12000)
    return () => clearTimeout(t)
  }, [])
  const relogin = async () => {
    try { await supabase.auth.signOut({ scope: 'local' }) } catch { /* 어차피 아래에서 지운다 */ }
    try {
      Object.keys(localStorage).filter((k) => k.startsWith('sb-')).forEach((k) => localStorage.removeItem(k))
    } catch { /* 저장소를 못 쓰는 환경 */ }
    window.location.assign('/login')
  }
  return (
    <div className="flex h-screen flex-col items-center justify-center gap-3 text-ink-muted">
      <p>불러오는 중…</p>
      {slow && (
        <div className="text-center text-sm">
          <p>로그인 확인이 오래 걸리고 있습니다.</p>
          <div className="mt-2 flex justify-center gap-2">
            <button type="button" onClick={() => window.location.reload()} className="rounded-md border border-border px-3 py-1.5 text-ink-secondary">새로고침</button>
            <button type="button" onClick={relogin} className="rounded-md bg-brand-deepGreen px-3 py-1.5 font-semibold text-white">다시 로그인</button>
          </div>
        </div>
      )}
    </div>
  )
}
