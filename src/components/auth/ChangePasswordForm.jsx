// 비밀번호 바꾸기 (2026-10-13)
// - 첫 로그인(임시 비밀번호) 때 RequireAuth 가 이 화면을 먼저 띄운다(must_change_password).
// - 머리글 사용자 메뉴의 "비밀번호 변경"에서도 쓴다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

export default function ChangePasswordForm({ onDone, onCancel, submitLabel = '비밀번호 바꾸기' }) {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const submit = async (e) => {
    e.preventDefault()
    setError(null)
    if (password.length < 8) {
      setError('비밀번호는 8자 이상으로 정해 주세요.')
      return
    }
    if (password !== confirm) {
      setError('두 칸의 비밀번호가 서로 다릅니다.')
      return
    }
    setBusy(true)
    const { error: err } = await supabase.auth.updateUser({ password, data: { must_change_password: false } })
    setBusy(false)
    if (err) {
      setError(/same|different/i.test(err.message) ? '지금 비밀번호와 다른 비밀번호로 정해 주세요.' : `바꾸지 못했습니다: ${err.message}`)
      return
    }
    onDone?.()
  }

  const inputCls = 'w-full rounded-lg border border-border px-3 py-2 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-brand-deepGreen'

  return (
    <form onSubmit={submit} className="space-y-3">
      <div>
        <label htmlFor="new-password" className="mb-1 block text-xs font-medium text-ink-secondary">새 비밀번호 (8자 이상)</label>
        <input id="new-password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} className={inputCls} autoFocus />
      </div>
      <div>
        <label htmlFor="new-password-confirm" className="mb-1 block text-xs font-medium text-ink-secondary">새 비밀번호 확인</label>
        <input id="new-password-confirm" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} className={inputCls} />
      </div>
      {error && <p role="alert" className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="flex-1 rounded-lg bg-brand-deepGreen px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50">
          {busy ? '바꾸는 중…' : submitLabel}
        </button>
        {onCancel && (
          <button type="button" onClick={onCancel} className="rounded-lg border border-border px-4 py-2.5 text-sm text-ink-secondary hover:bg-surface-subtle">취소</button>
        )}
      </div>
    </form>
  )
}
