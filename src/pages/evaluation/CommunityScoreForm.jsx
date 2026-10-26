// M3c 공동체 생활 적합성 채점 (evaluator)
//
// 2026-07-09 수정: 기존 제출 내역 불러오기 + 제출확정 후 읽기전용 처리 추가.
// 2026-09-28 수정: 등급 버튼에 점수와 요강 평가 기준을 함께 보여준다("1이 최상?" 헷갈림 방지).
//   처음에는 아무 등급도 골라져 있지 않다 — 예전에는 3등급이 미리 골라져 있어 안 고르고
//   제출하는 실수가 날 수 있었다.
import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { Confidential, useRubric } from '../../components/rubric/Rubric'
import { LevelRow } from '../../components/rubric/RubricScorePicker'

// proxy를 넘기면 "관리자가 그 평가위원을 대신해" 입력하는 모드가 된다.
// 화면과 검증은 평가위원이 쓰는 것과 완전히 동일하고, 호출하는 RPC만
// admin_* 로 바뀐다(점수 계산은 서버에서 같은 경로를 탄다).
//   proxy = { evaluatorUid, reasonCode, reasonText }
// 2027학년도 요강 '공동체 생활 적합성 영역 등급 및 점수표'. 실제 점수는 서버가 설정값으로
// 계산하므로 여기는 안내용이다(요강이 바뀌면 이 표도 함께 고친다).
const GRADES = [
  { grade: 1, score: 100, text: '공동체 활동에 자발적·주도적으로 참여한 사례가 다수 있으며, 협력적 태도·책임감·배려심이 우수하게 드러남' },
  { grade: 2, score: 90, text: '공동체 활동 참여 경험이 확인되며, 긍정적 관계 형성 및 협력적 태도가 나타남' },
  { grade: 3, score: 75, text: '관련 활동이 일부 확인되나 소극적 태도 혹은 서술의 구체성이 부족함' },
  { grade: 4, score: 60, text: '활동 경험이 부족하거나 공동체성 관련 언급이 미약함' },
  { grade: 5, score: 40, text: '관련 활동이 전무하거나 공동체 생활에 대한 부적절한 태도가 관찰됨' },
]

export default function CommunityScoreForm({ applicantId, onSubmitted, proxy }) {
  const { session } = useAuth()
  const evaluatorUid = proxy?.evaluatorUid ?? session?.user?.id
  const [grade, setGrade] = useState(null)
  const [memo, setMemo] = useState('')
  // 채점기준표(대외비, DB에서 권한 확인 후 받아 옴): 등급별 '기록에서 확인할 판단 신호'
  const rubric = useRubric('community')
  const signalOf = (g) => (rubric?.grades || []).find((x) => x.grade === g)?.signals
  const [submitting, setSubmitting] = useState(false)
  const [loadingExisting, setLoadingExisting] = useState(true)
  const [alreadySubmitted, setAlreadySubmitted] = useState(false)
  const [error, setError] = useState(null)
  const [result, setResult] = useState(null)

  useEffect(() => {
    if (!evaluatorUid) return
    let active = true
    setLoadingExisting(true)
    setResult(null)
    setAlreadySubmitted(false)
    setGrade(null)
    setMemo('')
    supabase
      .from('scores_community')
      .select('inputs, server_computed, submission_state')
      .eq('applicant_id', applicantId)
      .eq('evaluator_uid', evaluatorUid)
      .maybeSingle()
      .then(({ data }) => {
        if (!active) return
        if (data) {
          setGrade(data.inputs?.grade ?? null)
          setMemo(data.inputs?.evidenceMemo ?? '')
          setResult(data.server_computed)
          setAlreadySubmitted(data.submission_state === 'submitted')
        }
        setLoadingExisting(false)
      })
    return () => {
      active = false
    }
  }, [applicantId, evaluatorUid])

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)

    if (!grade) {
      setError('등급을 선택하세요.')
      return
    }
    if (memo.trim().length < 10) {
      setError('근거 메모는 최소 10자 이상 입력해야 합니다.')
      return
    }

    setSubmitting(true)
    const { data, error: err } = proxy
      ? await supabase.rpc('admin_submit_community_score', {
        p_applicant_id: applicantId,
        p_target_evaluator_uid: proxy.evaluatorUid,
        p_grade: Number(grade),
        p_evidence_memo: memo,
        p_reason_code: proxy.reasonCode,
        p_reason_text: proxy.reasonText || null,
      })
      : await supabase.rpc('submit_community_score', {
        p_applicant_id: applicantId,
        p_grade: Number(grade),
        p_evidence_memo: memo,
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

  return (
    <div>
      <h3 className="mb-3 text-sm font-semibold text-ink-primary">공동체 생활 적합성 채점</h3>
      <CommunityGuide rubric={rubric} />
      {loadingExisting ? (
        <p className="text-xs text-ink-muted">기존 제출 내역 확인 중…</p>
      ) : (
        <>
          {alreadySubmitted && (
            <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-xs text-brand-deepGreenStrong">
              이미 제출확정된 채점입니다 — 서버 산정 점수: {result?.score}점. 수정하려면 관리자에게 재개방을
              요청하세요.
            </p>
          )}
          <form onSubmit={handleSubmit} className="space-y-3">
            <fieldset disabled={alreadySubmitted} className="space-y-3 disabled:opacity-60">
              <div>
                <label className="mb-1 block text-xs font-medium text-ink-secondary">등급 선택</label>
                {/* 등급 = 요강 기준 + 기준표 '기록에서 확인할 판단 신호'를 한 버튼으로 (자소서·소견서와 같은 모양) */}
                <Confidential className="space-y-1.5">
                  {GRADES.map((g) => (
                    <LevelRow
                      key={g.grade}
                      head={`${g.grade}등급`}
                      sub={`${g.score}점`}
                      text={<span className="font-medium text-ink-primary">{g.text}</span>}
                      extra={signalOf(g.grade) && (
                        <span className="mt-1 block text-[12px] leading-snug text-ink-muted">판단 신호 · {signalOf(g.grade)}</span>
                      )}
                      selected={grade === g.grade}
                      disabled={alreadySubmitted}
                      onClick={() => setGrade(g.grade)}
                    />
                  ))}
                </Confidential>
              </div>

              <div>
                <label className="mb-1 block text-xs font-medium text-ink-secondary">근거 메모 (필수, 10자 이상)</label>
                <textarea
                  value={memo}
                  onChange={(e) => setMemo(e.target.value)}
                  rows={5}
                  className="w-full rounded-md border border-border px-3 py-2 text-sm"
                  placeholder="학생부 공동체 관련 발췌 자료를 근거로 판단 사유를 기록하세요."
                />
                <p className="mt-1 text-right text-xs text-ink-muted">{memo.length}자</p>
              </div>
            </fieldset>

            {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

            {alreadySubmitted && !proxy && <PeerReviewPanel applicantId={applicantId} />}

            {!alreadySubmitted && (
              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-md bg-brand-deepGreen py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
              >
                {submitting ? '제출 중…' : '채점 제출'}
              </button>
            )}
          </form>
        </>
      )}
    </div>
  )
}

// 판단 순서·경계·주의점(접이식, 대외비)
function CommunityGuide({ rubric }) {
  const [open, setOpen] = useState(false)
  if (!rubric) return null
  const block = (title, groups) => (
    <div>
      <p className="mt-2 font-semibold text-ink-primary">{title}</p>
      {groups.map((g) => (
        <div key={g.heading || g.label} className="mt-1">
          {g.heading && <p className="font-medium">{g.heading}</p>}
          {g.label && <p><span className="font-medium">{g.label}</span> · {g.text}</p>}
          {g.items && <ul className="ml-4 list-disc">{g.items.map((it) => <li key={it}>{it}</li>)}</ul>}
        </div>
      ))}
    </div>
  )
  return (
    <Confidential className="mb-3 rounded-lg border border-border bg-surface-subtle">
      <button type="button" onClick={() => setOpen((v) => !v)} className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs font-semibold text-ink-secondary">
        <span className="rounded bg-status-dangerSoft px-1.5 py-0.5 text-[10px] font-bold text-status-danger">대외비</span>
        평가 자료·판단 순서·주의점 {open ? '접기 ▴' : '보기 ▾'}
      </button>
      {open && (
        <div className="border-t border-border px-3 pb-3 pt-1 text-[11px] leading-relaxed text-ink-secondary">
          {rubric.intro && <p className="mt-1">{rubric.intro}</p>}
          {block('평가 자료', rubric.materials || [])}
          {rubric.materialsNote && <p className="mt-1 text-ink-muted">※ {rubric.materialsNote}</p>}
          {rubric.method && <p className="mt-2"><span className="font-semibold text-ink-primary">채점 방법</span> · {rubric.method}</p>}
          {block('판단 순서', rubric.steps || [])}
          {block('등급 경계 판단', rubric.boundaries || [])}
          {block('판단할 때 주의할 점', rubric.cautions || [])}
        </div>
      )}
    </Confidential>
  )
}

// 상호 검토(관리자가 연 동안만): 같은 지원자에 대한 다른 위원의 등급·근거 메모
function PeerReviewPanel({ applicantId }) {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)
  useEffect(() => {
    let active = true
    supabase.rpc('get_community_peer_review', { p_applicant_id: applicantId }).then(({ data: d, error: err }) => {
      if (!active) return
      if (err) setError(err.message)
      else setData(d)
    })
    return () => {
      active = false
    }
  }, [applicantId])

  if (error) return <p className="text-[11px] text-status-danger">{error}</p>
  if (!data?.open || !data?.eligible) return null
  const items = data.items || []
  const grades = new Set(items.map((i) => i.grade))
  return (
    <section className="rounded-lg border-2 border-brand-orange bg-brand-orangeSoft/40 p-3">
      <p className="text-xs font-bold text-brand-orangeStrong">
        상호 검토 · 위원 {items.length}명 {grades.size > 1 ? '— 등급이 다릅니다' : '— 등급 일치'}
      </p>
      <p className="mt-0.5 text-[11px] text-ink-muted">
        서로의 근거가 등급과 맞는지 확인하는 단계입니다. 등급을 바꿔야 하면 관리자에게 재개방을 요청하세요.
      </p>
      <ul className="mt-2 space-y-2">
        {items.map((it, i) => (
          <li key={i} className="rounded-md bg-white p-2 text-xs">
            <p className="font-semibold text-ink-primary">
              {it.mine ? '나' : it.evaluatorName} · {it.grade}등급{it.score != null ? ` (${it.score}점)` : ''}
            </p>
            <p className="mt-1 whitespace-pre-wrap text-ink-secondary">{it.memo}</p>
          </li>
        ))}
      </ul>
    </section>
  )
}
