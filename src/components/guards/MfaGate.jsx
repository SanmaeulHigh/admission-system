// 교외 접속 휴대폰 인증 화면 (2026-10-13, 00085)
//
// 학교 공인 IP가 아닌 곳에서 로그인하면 이 화면이 먼저 뜬다.
// 등록된 휴대폰으로 6자리 인증번호(5분 유효)를 받아 입력하면 그 로그인 동안(최대 12시간) 쓸 수 있다.
// 실제 데이터 차단은 서버 관문(Caddy → mfa_gate)이 하고, 이 화면은 안내·입력만 맡는다.

import { useEffect, useRef, useState } from 'react'
import { supabase, getEdgeFunctionErrorMessage } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import schoolLogo from '../../assets/school-logo.png'

const RESEND_SECONDS = 60

export default function MfaGate() {
  const { access, email, signOut, reloadAuth } = useAuth()
  const [sent, setSent] = useState(false)
  const [sending, setSending] = useState(false)
  const [code, setCode] = useState('')
  const [verifying, setVerifying] = useState(false)
  const [message, setMessage] = useState(null) // { tone, text }
  const [cooldown, setCooldown] = useState(0)
  const inputRef = useRef(null)

  useEffect(() => {
    if (cooldown <= 0) return undefined
    const t = setTimeout(() => setCooldown((c) => c - 1), 1000)
    return () => clearTimeout(t)
  }, [cooldown])

  const sendCode = async () => {
    setSending(true)
    setMessage(null)
    const { error } = await supabase.functions.invoke('send-login-otp', { body: {} })
    setSending(false)
    if (error) {
      setMessage({ tone: 'error', text: await getEdgeFunctionErrorMessage(error, '인증번호를 보내지 못했습니다.') })
      return
    }
    setSent(true)
    setCode('')
    setCooldown(RESEND_SECONDS)
    setMessage({ tone: 'info', text: '인증번호를 보냈습니다. 5분 안에 입력하세요.' })
    setTimeout(() => inputRef.current?.focus(), 50)
  }

  const verify = async (e) => {
    e.preventDefault()
    if (code.length !== 6) return
    setVerifying(true)
    setMessage(null)
    const { data, error } = await supabase.rpc('verify_login_otp', { p_code: code })
    setVerifying(false)
    if (error) {
      setMessage({ tone: 'error', text: error.message })
      return
    }
    if (!data?.ok) {
      setCode('')
      setMessage({
        tone: 'error',
        text: data?.remaining > 0 ? `인증번호가 맞지 않습니다. ${data.remaining}번 더 시도할 수 있습니다.` : '5번 틀렸습니다. 인증번호를 다시 받아 주세요.',
      })
      if (!(data?.remaining > 0)) setSent(false)
      return
    }
    setMessage({ tone: 'info', text: '확인되었습니다.' })
    reloadAuth()
  }

  const hasPhone = access?.hasPhone

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-canvas px-4 py-10">
      <div className="w-full max-w-sm rounded-2xl border border-border bg-surface-card p-7 shadow-sm">
        <div className="mb-5 flex items-center gap-3">
          <img src={schoolLogo} alt="" className="h-11 w-auto" />
          <div>
            <h1 className="text-lg font-bold text-ink-primary">교외 접속 확인</h1>
            <p className="text-xs text-ink-muted">새봄고 입학전형관리시스템</p>
          </div>
        </div>

        <p className="text-sm leading-relaxed text-ink-secondary">
          학교 밖에서 접속하셨습니다. 입학전형 자료 보호를 위해 등록된 휴대폰으로 인증번호를 한 번 더 확인합니다.
        </p>

        {!hasPhone ? (
          <p className="mt-4 rounded-lg bg-status-dangerSoft px-3 py-2.5 text-sm text-status-danger">
            이 계정({email})에는 휴대폰 번호가 등록되어 있지 않아 교외에서 이용할 수 없습니다. 입학전형 담당자에게 번호 등록을 요청하세요.
          </p>
        ) : (
          <>
            <p className="mt-4 rounded-lg bg-surface-subtle px-3 py-2.5 text-sm text-ink-primary">
              받는 번호: <b className="font-mono">{access?.phoneMasked}</b>
            </p>

            <button
              type="button"
              onClick={sendCode}
              disabled={sending || cooldown > 0}
              className={`mt-3 w-full rounded-lg px-4 py-2.5 text-sm font-semibold disabled:opacity-50 ${sent ? 'border border-brand-deepGreen text-brand-deepGreenStrong hover:bg-brand-greenSoft' : 'bg-brand-deepGreen text-white hover:bg-brand-deepGreenStrong'}`}
            >
              {sending ? '보내는 중…' : cooldown > 0 ? `다시 받기 (${cooldown}초 후)` : sent ? '인증번호 다시 받기' : '인증번호 받기'}
            </button>

            {sent && (
              <form onSubmit={verify} className="mt-4">
                <label htmlFor="otp" className="mb-1 block text-xs font-medium text-ink-secondary">인증번호 6자리</label>
                <input
                  id="otp"
                  ref={inputRef}
                  value={code}
                  onChange={(e) => setCode(e.target.value.replace(/[^0-9]/g, '').slice(0, 6))}
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  className="w-full rounded-lg border border-border px-3 py-2.5 text-center font-mono text-xl tracking-[0.4em] focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-brand-deepGreen"
                  aria-describedby="otp-help"
                />
                <p id="otp-help" className="mt-1 text-xs text-ink-muted">5분 안에 입력하세요. 5번 틀리면 다시 받아야 합니다.</p>
                <button
                  type="submit"
                  disabled={verifying || code.length !== 6}
                  className="mt-3 w-full rounded-lg bg-brand-deepGreen px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
                >
                  {verifying ? '확인 중…' : '확인'}
                </button>
              </form>
            )}
          </>
        )}

        {message && (
          <p role={message.tone === 'error' ? 'alert' : 'status'}
            className={`mt-3 rounded-md px-3 py-2 text-xs ${message.tone === 'error' ? 'bg-status-dangerSoft text-status-danger' : 'bg-brand-greenSoft text-brand-deepGreenStrong'}`}>
            {message.text}
          </p>
        )}

        <div className="mt-6 flex items-center justify-between text-xs text-ink-muted">
          <span>{access?.clientIp ? `접속 위치 IP ${access.clientIp}` : ''}</span>
          <button type="button" onClick={signOut} className="underline hover:text-ink-primary">로그아웃</button>
        </div>
      </div>
    </div>
  )
}
