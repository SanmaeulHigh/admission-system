// 대기실 프로젝터 화면 주소 관리 (관리자용, 2026-10-14)
// 주소에 열쇠가 붙어 있어야 명단이 보인다(00087). 주소가 밖으로 새면 '열쇠 바꾸기'로 즉시 막는다.

import { useState } from 'react'
import { useInterviewDisplayKey } from '../../lib/interviewDisplayKey'

export default function InterviewDisplayKeyBox() {
  const { key, url, error, rotate } = useInterviewDisplayKey()
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState(false)
  const fullUrl = key ? `${window.location.origin}${url}` : ''

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(fullUrl)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // 복사 권한이 없으면 사용자가 직접 선택해 복사한다
    }
  }

  const doRotate = async () => {
    // eslint-disable-next-line no-alert
    if (!window.confirm('열쇠를 바꾸면 지금 켜 둔 대기실 화면도 새 주소로 다시 열어야 합니다. 바꿀까요?')) return
    setBusy(true)
    await rotate()
    setBusy(false)
  }

  return (
    <section className="mb-4 rounded-xl border border-border bg-surface-card p-4">
      <h2 className="text-sm font-semibold text-ink-primary">대기실 프로젝터 화면 주소</h2>
      <p className="mt-1 text-xs text-ink-muted">
        로그인 없이 열리는 화면이라 주소에 열쇠가 붙어 있습니다. 프로젝터 PC에서만 여시고, 주소가 밖으로 퍼졌다면 열쇠를 바꾸세요.
      </p>
      {error && <p className="mt-2 text-xs text-status-danger">{error}</p>}
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <input readOnly value={fullUrl} onFocus={(e) => e.target.select()} className="min-w-0 flex-1 rounded-md border border-border bg-surface-subtle px-2 py-1.5 font-mono text-xs" />
        <button type="button" onClick={copy} disabled={!key} className="rounded-md border border-border px-3 py-1.5 text-xs text-ink-secondary hover:bg-surface-subtle disabled:opacity-40">
          {copied ? '복사됨 ✓' : '주소 복사'}
        </button>
        <a href={url} target="_blank" rel="noopener noreferrer" className="rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft">
          화면 열기 ↗
        </a>
        <button type="button" onClick={doRotate} disabled={busy} className="rounded-md border border-status-danger px-3 py-1.5 text-xs text-status-danger hover:bg-status-dangerSoft disabled:opacity-40">
          {busy ? '바꾸는 중…' : '열쇠 바꾸기'}
        </button>
      </div>
    </section>
  )
}
