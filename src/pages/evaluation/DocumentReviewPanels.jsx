// 서류평가 중간 점검 · 공동체 상호 검토 (관리자, 2026-10-16)
// 평가 진행률·경보 모니터 화면 아래에 붙는다.
//  - 채점 품질 집계(00093): 위원별 '모든 기준 같은 점수' 건수, 기준별 위원 간 차이가 큰 지원자 수
//  - 공동체 상호 검토(00092): 열기/닫기 + 등급이 갈린 지원자 목록(근거 메모 포함)

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'

const CRITERION_LABEL = {
  essay: {
    admissionWill: '① 입학의지', selfUnderstanding: '② 자기이해', schoolUnderstanding: '③ 학교이해',
    schoolAdaptation: '④ 학교적응', learningWill: '⑤ 배움의지', serviceWill: '⑥ 봉사의지',
    communityLife: '⑦ 공동체 생활', careerConnection: '⑧ 진로 연계', sincerity: '⑨ 진지성·구체성',
    feasibility: '⑩ 실현가능성·잠재력',
  },
  opinion: {
    altEducationUnderstanding: '① 대안교육 이해', schoolUnderstanding: '② 학교 이해', childUnderstanding: '③ 자녀 이해',
    childCareerView: '④ 자녀 진로관', admissionWillParticipation: '⑤ 입학·참여의지',
  },
}
const AREA_NAME = { essay: '자기소개서', opinion: '학부모 소견서' }

export function ScoringQualityPanel({ year, round }) {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!year || !round) return
    const { data: d, error: err } = await supabase.rpc('get_document_scoring_quality', { p_year: year, p_round: round })
    if (err) setError(err.message)
    else {
      setError(null)
      setData(d)
    }
  }, [year, round])

  useEffect(() => {
    load()
  }, [load])

  return (
    <section className="mt-8">
      <div className="mb-2 flex items-center justify-between">
        <div>
          <h2 className="text-base font-bold text-ink-primary">중간 점검 · 채점 품질</h2>
          <p className="text-xs text-ink-muted">제출확정된 채점만 집계합니다. 지원자 이름은 나오지 않습니다(기준 해석 협의용).</p>
        </div>
        <button type="button" onClick={load} className="rounded-md border border-border px-3 py-1.5 text-xs text-ink-secondary hover:bg-surface-subtle">새로고침</button>
      </div>
      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
      {data && (
        <div className="grid gap-4 lg:grid-cols-2">
          {['essay', 'opinion'].map((area) => {
            const a = data[area] || {}
            return (
              <div key={area} className="rounded-lg border border-border bg-white p-4">
                <h3 className="text-sm font-semibold text-ink-primary">{AREA_NAME[area]}</h3>

                <p className="mt-3 text-xs font-medium text-ink-secondary">위원별 · 모든 기준 같은 점수</p>
                <table className="mt-1 w-full text-xs">
                  <tbody className="divide-y divide-border">
                    {(a.evaluators || []).map((e) => (
                      <tr key={e.evaluatorName}>
                        <td className="py-1">{e.evaluatorName}</td>
                        <td className="py-1 text-right text-ink-muted">제출 {e.submitted}건</td>
                        <td className={`py-1 text-right font-semibold ${e.allSame > 0 ? 'text-status-danger' : 'text-ink-muted'}`}>
                          같은 점수 {e.allSame}건
                        </td>
                      </tr>
                    ))}
                    {(a.evaluators || []).length === 0 && <tr><td className="py-2 text-ink-muted">아직 제출된 채점이 없습니다.</td></tr>}
                  </tbody>
                </table>

                <p className="mt-4 text-xs font-medium text-ink-secondary">
                  기준별 · 위원 간 {a.gapThreshold}점 이상 차이 난 지원자
                </p>
                <table className="mt-1 w-full text-xs">
                  <tbody className="divide-y divide-border">
                    {(a.criteria || []).map((c) => (
                      <tr key={c.key}>
                        <td className="py-1">{CRITERION_LABEL[area][c.key] || c.key}</td>
                        <td className="py-1 text-right text-ink-muted">평균 {c.avg}</td>
                        <td className={`py-1 text-right font-semibold ${c.wideGapCount > 0 ? 'text-brand-orangeStrong' : 'text-ink-muted'}`}>
                          {c.wideGapCount}/{c.applicantCount}명
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

export function CommunityReviewPanel({ year, round }) {
  const [board, setBoard] = useState(null)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const [onlyMismatch, setOnlyMismatch] = useState(true)

  const load = useCallback(async () => {
    if (!year || !round) return
    const { data, error: err } = await supabase.rpc('get_community_review_board', { p_year: year, p_round: round })
    if (err) setError(err.message)
    else {
      setError(null)
      setBoard(data)
    }
  }, [year, round])

  useEffect(() => {
    load()
  }, [load])

  const toggle = async () => {
    const next = !board?.open
    // eslint-disable-next-line no-alert
    if (!window.confirm(next
      ? '상호 검토를 열면 공동체 위원이 자기가 제출한 지원자에 대해 다른 위원의 등급과 근거 메모를 볼 수 있습니다. 열까요?'
      : '상호 검토를 닫으면 위원들은 다시 다른 위원의 등급·메모를 볼 수 없습니다. 닫을까요?')) return
    setBusy(true)
    const { error: err } = await supabase.rpc('set_community_peer_review', { p_year: year, p_round: round, p_open: next })
    setBusy(false)
    if (err) setError(err.message)
    else load()
  }

  const items = (board?.items || []).filter((i) => !onlyMismatch || i.mismatch)
  const mismatchCount = (board?.items || []).filter((i) => i.mismatch).length

  return (
    <section className="mt-8">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-bold text-ink-primary">공동체 생활 적합성 · 상호 검토</h2>
          <p className="text-xs text-ink-muted">
            평소에는 독립 채점입니다. 상호 검토를 연 동안에만 위원들이 서로의 등급·근거 메모를 봅니다.
            등급 수정이 필요하면 해당 채점을 재개방하세요.
          </p>
        </div>
        <button
          type="button"
          disabled={busy || !board}
          onClick={toggle}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold disabled:opacity-40 ${
            board?.open ? 'border border-status-danger text-status-danger hover:bg-status-dangerSoft' : 'bg-brand-deepGreen text-white hover:bg-brand-deepGreenStrong'
          }`}
        >
          {board?.open ? '상호 검토 닫기' : '상호 검토 열기'}
        </button>
      </div>
      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}
      {board && (
        <>
          <p className="mb-2 text-xs">
            <span className={`rounded-full px-2 py-0.5 font-semibold ${board.open ? 'bg-brand-orangeSoft text-brand-orangeStrong' : 'bg-surface-subtle text-ink-muted'}`}>
              {board.open ? '상호 검토 열림' : '상호 검토 닫힘'}
            </span>
            <span className="ml-2 text-ink-secondary">채점된 지원자 {(board.items || []).length}명 중 등급이 갈린 지원자 {mismatchCount}명</span>
            <label className="ml-3 inline-flex items-center gap-1 text-ink-secondary">
              <input type="checkbox" checked={onlyMismatch} onChange={(e) => setOnlyMismatch(e.target.checked)} /> 갈린 지원자만
            </label>
          </p>
          <ul className="space-y-2">
            {items.map((it) => (
              <li key={it.applicantId} className={`rounded-lg border p-3 ${it.mismatch ? 'border-brand-orange bg-brand-orangeSoft/30' : 'border-border bg-white'}`}>
                <p className="text-sm font-semibold text-ink-primary">
                  {it.displayName} <span className="font-mono text-xs font-normal text-ink-muted">{it.examNo || '-'}</span>
                  {it.mismatch && <span className="ml-2 text-xs text-brand-orangeStrong">{it.gradeGap}등급 차이</span>}
                </p>
                <div className="mt-1 grid gap-2 sm:grid-cols-2">
                  {(it.submissions || []).map((s, i) => (
                    <div key={i} className="rounded-md bg-white p-2 text-xs">
                      <p className="font-semibold">{s.evaluatorName} · {s.grade}등급</p>
                      <p className="mt-0.5 whitespace-pre-wrap text-ink-secondary">{s.memo}</p>
                    </div>
                  ))}
                </div>
              </li>
            ))}
            {items.length === 0 && <li className="rounded-lg border border-dashed border-border p-4 text-center text-xs text-ink-muted">표시할 지원자가 없습니다.</li>}
          </ul>
        </>
      )}
    </section>
  )
}
