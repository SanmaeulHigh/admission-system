// 로그인 화면 — 자체 아이디(이메일)/비밀번호 (Supabase Auth, self-hosted GoTrue).
// 마스터 스펙 v1.2 섹션 2.2 참조. 2026-07 로컬 서버 전환에 맞춰 Google OAuth에서 전환.
//
// 2026-10-13: 자체 회원가입을 닫았다(GoTrue DISABLE_SIGNUP). 계정은 최고관리자가 사용자 관리에서
// 만들고, 첫 로그인 때 본인이 새 비밀번호로 바꾼다. 아래는 예전 설계 설명이다.
// 설계: 이메일/비밀번호로 계정을 만들 수 있다(자체 회원가입). 실제 데이터 접근은
// public.users 행 존재 여부와 Postgres RLS가 통제한다 — 로그인/가입 성공이
// 곧 권한 부여를 의미하지 않는다. 미승인 계정은 로그인 후 "계정 승인
// 대기" 화면(RequireAuth)만 보게 된다. (self-hosted 환경은 SMTP 없이도
// 동작하도록 GOTRUE_MAILER_AUTOCONFIRM=true 설정을 전제로 한다 — 이메일
// 인증 없이 바로 세션이 생성되고, 실제 게이트는 관리자 승인이 맡는다.)

import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import WatermarkLogo from '../../components/layout/WatermarkLogo'
import ServerStatusBadge from '../../components/status/ServerStatusBadge'

export default function Login() {
  const { status } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState(null)
  const [submitting, setSubmitting] = useState(false)

  // 이미 로그인된 상태로 /login에 들어오면 바로 넘긴다 (RequireAuth가 승인 대기·교외 인증·
  // 비밀번호 변경·정상 화면 중 무엇을 보일지 이어서 판단).
  if (status === 'unregistered' || status === 'ready' || status === 'mfa') {
    return <Navigate to="/" replace />
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)
    if (!email.trim() || !password) {
      setError('아이디(이메일)와 비밀번호를 입력해 주세요.')
      return
    }
    setSubmitting(true)
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    if (signInError) setError('아이디 또는 비밀번호가 올바르지 않습니다.')
    // 성공 시 onAuthStateChange가 세션을 반영하고, 위 status 체크로 자동 이동.
    setSubmitting(false)
  }

  return (
    <div className="relative flex min-h-screen items-center justify-center bg-brand-greenSoft px-4">
      <div className="w-full max-w-sm rounded-lg bg-white p-8 shadow-sm">
        <h1 className="mb-1 text-xl font-semibold text-ink-primary">입학전형관리시스템</h1>
        <p className="mb-6 text-sm text-ink-muted">
          2027학년도 신입생 입학전형 통합관리시스템
        </p>

        <ServerStatusBadge />

        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="email" className="mb-1 block text-xs font-medium text-ink-secondary">
              아이디(이메일)
            </label>
            <input
              id="email"
              type="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-md border border-border px-3 py-2 text-sm text-ink-primary focus:border-brand-deepGreen focus:outline-none"
              placeholder="ID@ice.go.kr"
            />
          </div>
          <div>
            <label
              htmlFor="password"
              className="mb-1 block text-xs font-medium text-ink-secondary"
            >
              비밀번호
            </label>
            <input
              id="password"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-md border border-border px-3 py-2 text-sm text-ink-primary focus:border-brand-deepGreen focus:outline-none"
            />
          </div>
          <button
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-brand-deepGreen py-2.5 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {submitting ? '로그인 중…' : '로그인'}
          </button>
        </form>

        {error && <p className="mt-3 text-sm text-status-danger">{error}</p>}

        <p className="mt-6 text-xs text-ink-muted">
          전형위원·행정 담당자 전용 화면입니다. 계정은 입학전형 담당자가 만들어 드립니다.
          처음 받은 임시 비밀번호로 로그인하면 새 비밀번호를 정하는 화면이 나옵니다.
          비밀번호를 잊으신 경우 담당자에게 재설정을 요청해 주세요.
        </p>

        <div className="mt-4 flex justify-center">
          <a href="https://supabase.com" target="_blank" rel="noopener noreferrer">
            <img
              width={168}
              height={30}
              src="https://supabase.com/badge-made-with-supabase.svg"
              alt="Made with Supabase"
            />
          </a>
        </div>
      </div>
      <WatermarkLogo />
    </div>
  )
}
