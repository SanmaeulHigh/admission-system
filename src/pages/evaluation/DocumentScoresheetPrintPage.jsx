// 서류평가 채점표 출력 (결재용, 2026-09-28)
//
// 영역별 채점표를 채점위원 한 명당 한 장씩 인쇄한다. 서명란에는 시스템에서 채점한
// 위원과 함께 '추가 서명자'를 올릴 수 있다 — 출결·학업성실도·공동체는 최고관리자
// 혼자 채점하지만 내부 규정상 채점위원 2명의 서명이 필요하기 때문이다.
// 인쇄 → 서명 → 스캔 → K-에듀파인 결재.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { DOCUMENT_AREAS, buildDocumentScoresheetHtml } from '../../lib/documentScoresheetHtml'

export default function DocumentScoresheetPrintPage() {
  const { year, round } = useAdmissionCycle()
  const [data, setData] = useState({}) // area → 응답
  const [names, setNames] = useState({}) // area → [이름, …] (편집 중)
  const [error, setError] = useState(null)
  const [savingArea, setSavingArea] = useState(null)
  const [notice, setNotice] = useState(null)
  const [printing, setPrinting] = useState(false)

  const load = useCallback(async () => {
    if (!year || !round) return
    setError(null)
    const results = await Promise.all(DOCUMENT_AREAS.map((a) => supabase.rpc('get_document_scoresheet', {
      p_year: year, p_round: round, p_area: a.value,
    })))
    const next = {}
    const nextNames = {}
    for (let i = 0; i < DOCUMENT_AREAS.length; i += 1) {
      const { data: d, error: err } = results[i]
      if (err) {
        setError(err.message)
        return
      }
      next[DOCUMENT_AREAS[i].value] = d
      nextNames[DOCUMENT_AREAS[i].value] = d?.cosigners?.length ? [...d.cosigners] : ['']
    }
    setData(next)
    setNames(nextNames)
  }, [year, round])

  useEffect(() => {
    load()
  }, [load])

  const saveNames = async (area) => {
    setSavingArea(area)
    setError(null)
    setNotice(null)
    const { data: res, error: err } = await supabase.rpc('set_scoresheet_cosigners', {
      p_year: year, p_round: round, p_area: area, p_names: names[area] || [],
    })
    setSavingArea(null)
    if (err) {
      setError(err.message)
      return
    }
    setData((cur) => ({ ...cur, [area]: { ...cur[area], cosigners: res?.names || [] } }))
    setNotice('추가 서명자를 저장했습니다.')
  }

  const openPrint = (areas) => {
    const list = areas.map((a) => data[a]).filter(Boolean)
    if (list.length === 0) return
    // 저장하지 않은 이름 변경도 인쇄에는 반영한다.
    const withNames = list.map((d) => ({ ...d, cosigners: (names[d.area] || []).map((n) => n.trim()).filter(Boolean) }))
    setPrinting(true)
    const w = window.open('', '_blank')
    if (!w) {
      alert('팝업이 차단되었습니다. 이 사이트의 팝업을 허용해 주세요.')
      setPrinting(false)
      return
    }
    w.document.open()
    w.document.write(buildDocumentScoresheetHtml(withNames))
    w.document.close()
    setPrinting(false)
  }

  const setName = (area, idx, value) => {
    setNames((cur) => {
      const arr = [...(cur[area] || [''])]
      arr[idx] = value
      return { ...cur, [area]: arr }
    })
  }
  const addName = (area) => setNames((cur) => ({ ...cur, [area]: [...(cur[area] || []), ''] }))
  const removeName = (area, idx) => setNames((cur) => {
    const arr = (cur[area] || []).filter((_, i) => i !== idx)
    return { ...cur, [area]: arr.length ? arr : [''] }
  })

  return (
    <div className="mx-auto max-w-5xl space-y-4 pb-16">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold text-ink-primary">서류평가 채점표 출력</h1>
          <p className="mt-1 text-sm text-ink-muted">
            영역별 채점표를 채점위원 한 명당 한 장씩 인쇄합니다. 서명을 받아 스캔한 뒤 K-에듀파인으로 결재받으세요.
            &lsquo;추가 서명자&rsquo;는 서명란에만 올라가고 채점 기록에는 영향이 없습니다.
          </p>
        </div>
        <button
          type="button"
          onClick={() => openPrint(DOCUMENT_AREAS.map((a) => a.value).filter((a) => a !== 'essay'))}
          disabled={printing || !Object.keys(data).length}
          className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
          title="자기소개서는 항목이 많아 가로 용지로 따로 인쇄합니다"
        >
          세로형 영역 한꺼번에 인쇄
        </button>
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {notice && <p className="rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">{notice}</p>}

      <div className="grid gap-3 md:grid-cols-2">
        {DOCUMENT_AREAS.map((a) => {
          const d = data[a.value]
          const scorers = [...new Map((d?.scores || []).map((s) => [s.evaluatorUid, s.evaluatorName])).values()]
          const scoredApplicants = new Set((d?.scores || []).map((s) => s.applicantId)).size
          return (
            <section key={a.value} className="rounded-card border border-border bg-surface-card p-4">
              <div className="flex items-center justify-between gap-2">
                <h2 className="text-base font-semibold text-ink-primary">{a.label}</h2>
                <button
                  type="button"
                  onClick={() => openPrint([a.value])}
                  disabled={!d || printing}
                  className="rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-40"
                >
                  인쇄{a.value === 'essay' ? ' (가로)' : ''}
                </button>
              </div>
              <p className="mt-1 text-xs text-ink-secondary">
                대상 {d?.roster?.length ?? '-'}명 · 채점된 지원자 {d ? scoredApplicants : '-'}명
              </p>
              <p className="mt-2 text-xs text-ink-muted">시스템 채점위원</p>
              <p className="text-sm text-ink-primary">{scorers.length ? scorers.join(', ') : '아직 없음'}</p>

              <p className="mt-3 text-xs text-ink-muted">추가 서명자 (서명란에만 표시)</p>
              <div className="mt-1 space-y-1.5">
                {(names[a.value] || ['']).map((n, i) => (
                  <div key={i} className="flex gap-1.5">
                    <input
                      value={n}
                      onChange={(e) => setName(a.value, i, e.target.value)}
                      placeholder="이름"
                      maxLength={30}
                      className="w-full rounded-md border-border text-sm"
                    />
                    <button
                      type="button"
                      onClick={() => removeName(a.value, i)}
                      className="rounded-md border border-border px-2 text-xs text-ink-muted hover:bg-surface-subtle"
                      aria-label="이름 지우기"
                    >
                      ×
                    </button>
                  </div>
                ))}
              </div>
              <div className="mt-2 flex gap-2">
                <button
                  type="button"
                  onClick={() => addName(a.value)}
                  disabled={(names[a.value] || []).length >= 5}
                  className="text-xs text-ink-secondary underline disabled:opacity-40"
                >
                  + 한 명 더
                </button>
                <button
                  type="button"
                  onClick={() => saveNames(a.value)}
                  disabled={savingArea === a.value}
                  className="ml-auto rounded-md bg-surface-subtle px-3 py-1 text-xs font-semibold text-ink-secondary hover:bg-border disabled:opacity-40"
                >
                  {savingArea === a.value ? '저장 중…' : '저장'}
                </button>
              </div>
            </section>
          )
        })}
      </div>
    </div>
  )
}
