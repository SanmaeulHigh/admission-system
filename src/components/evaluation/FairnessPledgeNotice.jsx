// 공정평가 서약 안내 팝업 (2026-10-16)
//
// 서약서는 이미 종이로 받았다. 이 팝업은 서류평가 위원이 '내 평가' 화면에 들어올 때마다 6대 원칙을
// 상기시킨다(채점을 막지 않는다). '오늘 하루 보지 않기'를 누르면 이 브라우저에서 오늘 자정까지 뜨지 않는다.
// '닫기'는 이번만 닫는다. 화면의 '공정평가 6대 원칙 보기' 링크로 언제든 다시 볼 수 있다.

import { useCallback, useEffect, useState } from 'react'
import { useAuth } from '../../contexts/AuthContext'
import useEscapeKey from '../../lib/useEscapeKey'

const DOCUMENT_AREAS = ['attendance', 'academic', 'community', 'essay', 'opinion']
const AREA_LABEL = { essay: '자기소개서', opinion: '학부모 소견서', attendance: '정량평가', academic: '정량평가', community: '공동체 생활 적합성' }

const PLEDGE_ITEMS = [
  ['공정한 평가', '모집요강과 채점기준표에 따라 제출 서류에 드러난 내용만을 근거로 평가하며, 출신 학교·지역·가정 배경 등에 대한 선입견으로 점수를 정하지 않겠습니다.'],
  ['독립 채점', '다른 위원과 지원자별 점수를 협의하거나 공유하지 않고 독립적으로 채점하겠습니다. 중간 점검 협의는 채점기준의 해석에 한하여 참여하겠습니다.'],
  ['이해충돌 회피', '지원자가 본인의 친족이거나 평가의 공정성을 해칠 만한 관계에 있음을 알게 된 때에는 즉시 입학전형담당교사에게 알리고 해당 지원자의 평가에서 빠지겠습니다.'],
  ['비밀 유지', '평가 과정에서 알게 된 지원자의 개인정보와 평가 내용, 대외비 채점기준 자료를 누설하지 않으며, 평가가 끝난 뒤에도 이를 지키겠습니다.'],
  ['청탁 금지', '평가와 관련한 부정한 청탁이나 금품·향응을 받지 않으며, 이러한 요구를 받은 때에는 즉시 학교에 알리겠습니다.'],
  ['자료와 계정 관리', '지원 서류와 연수 자료를 무단으로 복사·촬영·반출하지 않고, 입학전형관리시스템 계정을 다른 사람과 함께 쓰지 않겠습니다.'],
]

function storageKey(uid) {
  return `sanmaeul.fairnessPledgeHideDate.${uid}`
}

function todayText() {
  const d = new Date()
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`
}

export default function FairnessPledgeNotice({ year }) {
  const { session, userDoc, hasAnyRole } = useAuth()
  const uid = session?.user?.id
  const areas = (userDoc?.assigned_areas || []).filter((a) => DOCUMENT_AREAS.includes(a))
  const isDocumentEvaluator = hasAnyRole(['evaluator', 'quant']) && areas.length > 0
  const [open, setOpen] = useState(false)

  useEffect(() => {
    if (!isDocumentEvaluator || !uid || !year) return
    try {
      if (localStorage.getItem(storageKey(uid)) !== todayText()) setOpen(true)
    } catch {
      setOpen(true)
    }
  }, [isDocumentEvaluator, uid, year])

  const close = useCallback(() => setOpen(false), [])
  const hideToday = () => {
    try {
      localStorage.setItem(storageKey(uid), todayText())
    } catch {
      // 저장 못 하면 다음에 다시 뜰 뿐
    }
    setOpen(false)
  }
  useEscapeKey(open, close)

  if (!isDocumentEvaluator) return null
  const areaText = [...new Set(areas.map((a) => AREA_LABEL[a]))].join(' · ')

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="mb-4 text-xs text-ink-muted underline hover:text-ink-secondary">
        공정평가 6대 원칙 보기
      </button>
      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-labelledby="pledge-title">
          <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-2xl bg-white p-5 shadow-xl">
            <p className="text-xs font-semibold text-brand-deepGreenStrong">{year}학년도 신입생 입학전형 1단계 서류평가</p>
            <h2 id="pledge-title" className="mt-1 text-lg font-bold text-ink-primary">공정평가 6대 원칙</h2>
            <p className="mt-1 text-xs text-ink-muted">맡은 영역: {areaText}</p>

            <ol className="mt-4 space-y-2.5">
              {PLEDGE_ITEMS.map(([title, text], i) => (
                <li key={title} className="flex gap-2.5 text-sm">
                  <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-greenSoft text-[11px] font-bold text-brand-deepGreenStrong">{i + 1}</span>
                  <span>
                    <span className="font-semibold text-ink-primary">{title}</span>
                    <span className="block text-xs leading-relaxed text-ink-secondary">{text}</span>
                  </span>
                </li>
              ))}
            </ol>

            <p className="mt-4 text-xs text-ink-muted">서약하신 내용을 지키며 채점해 주세요.</p>

            <div className="mt-3 flex gap-2">
              <button
                type="button"
                onClick={hideToday}
                className="min-h-11 flex-1 rounded-lg border border-border px-3 py-2.5 text-sm text-ink-secondary hover:bg-surface-subtle"
              >
                오늘 하루 보지 않기
              </button>
              <button
                type="button"
                onClick={close}
                className="min-h-11 flex-1 rounded-lg bg-brand-deepGreen px-3 py-2.5 text-sm font-bold text-white hover:bg-brand-deepGreenStrong"
              >
                닫기
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}
