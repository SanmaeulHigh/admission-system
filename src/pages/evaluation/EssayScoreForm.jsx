// M3d 자기소개서 채점 (evaluator) — 10기준, 기준당 0~10점 정수, 5인 합산 최대 500.
// 자동저장(draft) + 제출확정 흐름. 근거: 2026학년도 서류평가 업무 진행 지침 4.(4).
//
// 2026-07-09 수정: 기존 draft/제출 내역을 불러온다. 이전에는 페이지를
// 나갔다 돌아오면 자동저장된 draft조차 화면에 안 보이던 버그가 있었다.
// 제출확정된 건은 서버가 재제출을 거부하므로 읽기전용으로 바꾼다.

import { useEffect, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { CommonPrinciples, confirmAllSame, isAllSameScore, useRubric } from '../../components/rubric/Rubric'
import RubricScorePicker from '../../components/rubric/RubricScorePicker'

const CRITERIA = [
  { key: 'admissionWill', label: '① 입학의지', hint: '지원 동기, 준비 과정 등' },
  { key: 'selfUnderstanding', label: '② 자기이해', hint: '강점, 약점, 성장전략' },
  { key: 'schoolUnderstanding', label: '③ 학교이해', hint: '교육철학, 생활 방식, 규범' },
  { key: 'schoolAdaptation', label: '④ 학교적응', hint: '생활, 식습관, 심리 대처' },
  { key: 'learningWill', label: '⑤ 배움의지', hint: '학습 계획, 자기주도' },
  { key: 'serviceWill', label: '⑥ 봉사의지', hint: '이타성, 공헌 계획' },
  { key: 'communityLife', label: '⑦ 공동체 생활', hint: '협력, 규범, 갈등해결' },
  { key: 'careerConnection', label: '⑧ 진로 연계', hint: '목표-탐색-학교자원 매칭' },
  { key: 'sincerity', label: '⑨ 글의 진지성·구체성', hint: '사실성, 증거성' },
  { key: 'feasibility', label: '⑩ 실현가능성·잠재력', hint: '계획의 현실성, 성장의 궤적' },
]

// proxy를 넘기면 관리자가 그 평가위원을 대신해 입력하는 모드가 된다.
// 화면·검증은 동일하고 호출 RPC만 admin_* 로 바뀐다(계산은 서버에서 같은 경로).
export default function EssayScoreForm({ applicantId, onSubmitted, proxy }) {
  const { session } = useAuth()
  const evaluatorUid = proxy?.evaluatorUid ?? session?.user?.id
  const [items, setItems] = useState({})
  const [saveStatus, setSaveStatus] = useState('idle') // idle | saving | saved | error
  const [submitting, setSubmitting] = useState(false)
  const [loadingExisting, setLoadingExisting] = useState(true)
  const [alreadySubmitted, setAlreadySubmitted] = useState(false)
  const [error, setError] = useState(null)
  const [result, setResult] = useState(null)
  const saveTimer = useRef(null)
  // 채점기준표(대외비, DB에서 권한 확인 후 받아 옴). 없으면 예전처럼 한 줄 힌트만 보인다.
  const rubric = useRubric('essay')

  const filledCount = CRITERIA.filter((c) => items[c.key] !== undefined && items[c.key] !== '').length

  useEffect(() => {
    if (!evaluatorUid) return
    let active = true
    setLoadingExisting(true)
    setResult(null)
    setAlreadySubmitted(false)
    supabase
      .from('scores_essay')
      .select('items, server_computed, submission_state')
      .eq('applicant_id', applicantId)
      .eq('evaluator_uid', evaluatorUid)
      .maybeSingle()
      .then(({ data }) => {
        if (!active) return
        if (data) {
          setItems(data.items || {})
          setResult(data.server_computed)
          setAlreadySubmitted(data.submission_state === 'submitted')
        }
        setLoadingExisting(false)
      })
    return () => {
      active = false
    }
  }, [applicantId, evaluatorUid])

  const scheduleAutosave = (nextItems) => {
    // 대리 입력 모드에서는 임시저장하지 않는다. save_essay_draft는 호출자
    // 본인(=관리자) 명의로 저장되어 엉뚱한 사람의 초안이 만들어지기 때문이다.
    // 관리자는 종이 채점표를 보고 한 번에 입력해 바로 제출하는 흐름이라
    // 임시저장이 없어도 문제가 없다.
    if (proxy) return
    setSaveStatus('saving')
    if (saveTimer.current) clearTimeout(saveTimer.current)
    saveTimer.current = setTimeout(async () => {
      const numericItems = Object.fromEntries(
        Object.entries(nextItems).filter(([, v]) => v !== '').map(([k, v]) => [k, Number(v)])
      )
      const { error: err } = await supabase.rpc('save_essay_draft', {
        p_applicant_id: applicantId,
        p_items: numericItems,
      })
      setSaveStatus(err ? 'error' : 'saved')
    }, 800)
  }

  const updateItem = (key, value) => {
    const next = { ...items, [key]: value }
    setItems(next)
    scheduleAutosave(next)
  }

  useEffect(() => () => saveTimer.current && clearTimeout(saveTimer.current), [])

  const handleSubmit = async () => {
    setError(null)
    if (filledCount < CRITERIA.length) {
      setError('10개 기준을 모두 입력해야 제출할 수 있습니다.')
      return
    }
    // 모든 기준 같은 점수 확인(대리 입력은 종이 채점표 그대로 옮기므로 묻지 않는다)
    if (!proxy && isAllSameScore(items, CRITERIA.map((c) => c.key))
        && !confirmAllSame(CRITERIA.length, Number(items[CRITERIA[0].key]))) {
      return
    }
    setSubmitting(true)
    const numericItems = Object.fromEntries(Object.entries(items).map(([k, v]) => [k, Number(v)]))
    const { data, error: err } = proxy
      ? await supabase.rpc('admin_submit_essay_score', {
        p_applicant_id: applicantId,
        p_target_evaluator_uid: proxy.evaluatorUid,
        p_items: numericItems,
        p_reason_code: proxy.reasonCode,
        p_reason_text: proxy.reasonText || null,
      })
      : await supabase.rpc('submit_essay_score', {
        p_applicant_id: applicantId,
        p_items: numericItems,
      })
    setSubmitting(false)
    if (err) {
      setError(err.message)
      return
    }
    setResult(data)
    setAlreadySubmitted(true)
    onSubmitted?.()
  }

  if (loadingExisting) {
    return (
      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">자기소개서 채점</h3>
        <p className="text-xs text-ink-muted">기존 제출 내역 확인 중…</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-ink-primary">자기소개서 채점</h3>
        {!alreadySubmitted && (
          <span className="text-xs text-ink-muted">
            {saveStatus === 'saving' && '저장 중…'}
            {saveStatus === 'saved' && '자동저장됨'}
            {saveStatus === 'error' && <span className="text-status-danger">저장 실패</span>}
          </span>
        )}
      </div>

      {alreadySubmitted ? (
        <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">
          이미 제출확정된 채점입니다 — 합계 {result?.total}점. 수정하려면 관리자에게 재개방을 요청하세요.
        </p>
      ) : (
        <p className="mb-3 text-xs text-ink-muted">
          기준마다 해당하는 문장을 눌러 점수를 고르세요. 관련성이 있으면 형식적 서술도 최소 3점입니다.
        </p>
      )}

      <CommonPrinciples />
      <fieldset disabled={alreadySubmitted} className="disabled:opacity-60">
        {/* 기준표 문장이 곧 점수 버튼(기준표가 없으면 숫자 버튼) — 2026-10-16 */}
        <RubricScorePicker
          criteria={CRITERIA}
          rubric={rubric}
          scale="essay"
          items={items}
          disabled={alreadySubmitted}
          onChange={updateItem}
          lowHint={rubric?.footnote}
        />
      </fieldset>

      {error && <p className="mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

      {!alreadySubmitted && (
        <button
          type="button"
          onClick={handleSubmit}
          disabled={submitting}
          className="mt-4 w-full rounded-md bg-brand-deepGreen py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
        >
          {submitting ? '제출 중…' : '제출확정 (되돌릴 수 없음)'}
        </button>
      )}
    </div>
  )
}
