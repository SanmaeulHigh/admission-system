// 전편입학 모드에서 '아직 신입학 전용인 화면'을 열었을 때의 안내 (2026-10-20)
// 전입생 전형은 11. 18. 이후 신입학 엔진과 통합한다(docs/전편입학_신입학엔진통합_설계_2026-10.md).
// 그 전까지 회차 설정·권한은 신입학 기준이라, 전편입학 화면에서 착각해 바꾸지 않도록 알린다.

import { ADMISSION_MODES, setAdmissionMode, useAdmissionMode } from '../../lib/admissionMode'

export default function TransferModeNotice({ children }) {
  const mode = useAdmissionMode()
  if (mode !== ADMISSION_MODES.TRANSFER) return null
  return (
    <div className="mb-4 rounded-xl border border-brand-deepGreen bg-brand-greenSoft px-4 py-3 text-sm text-brand-deepGreenStrong">
      <p className="font-semibold">전편입학 화면에서 보고 계십니다</p>
      <p className="mt-1 text-[13px] leading-relaxed">{children}</p>
      <button
        type="button"
        onClick={() => setAdmissionMode(ADMISSION_MODES.NEW)}
        className="mt-2 rounded-md border border-brand-deepGreen bg-white px-3 py-1.5 text-xs font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft"
      >
        신입학 화면으로 전환
      </button>
    </div>
  )
}
