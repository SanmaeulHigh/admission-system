// 새 버전 안내 (2026-10-25)
//
// 이 앱은 PWA라 화면 파일을 브라우저에 저장해 두고 쓴다(registerType: 'prompt').
// 그동안 '새 버전이 있다'고 알려 주는 창이 없어서, 서버에 새로 빌드해도 탭을 모두 닫기 전까지
// 예전 화면이 남았다(주소마다 따로 — local은 새 화면, ipsi는 예전 화면 같은 일이 생김).
// 이제 새 버전이 준비되면 화면 아래에 띄우고, [지금 바꾸기]를 누르면 바로 새 화면으로 바뀐다.
// 열어 둔 화면도 10분마다 새 버전이 있는지 확인한다.

import { useRegisterSW } from 'virtual:pwa-register/react'

const CHECK_EVERY_MS = 10 * 60 * 1000

export default function UpdatePrompt() {
  const {
    needRefresh: [needRefresh, setNeedRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return
      setInterval(() => {
        if (navigator.onLine) registration.update().catch(() => {})
      }, CHECK_EVERY_MS)
    },
  })

  if (!needRefresh) return null

  return (
    <div role="status" className="fixed bottom-4 left-1/2 z-[100] flex -translate-x-1/2 items-center gap-3 rounded-xl border border-brand-deepGreen bg-white px-4 py-3 text-sm shadow-xl print:hidden">
      <span className="text-ink-primary">새 버전이 있습니다. 입력 중인 내용을 저장한 뒤 바꿔 주세요.</span>
      <button type="button" onClick={() => updateServiceWorker(true)}
        className="rounded-md bg-brand-deepGreen px-3 py-1.5 font-semibold text-white hover:bg-brand-deepGreenStrong">
        지금 바꾸기
      </button>
      <button type="button" onClick={() => setNeedRefresh(false)} className="text-xs text-ink-muted underline">나중에</button>
    </div>
  )
}
