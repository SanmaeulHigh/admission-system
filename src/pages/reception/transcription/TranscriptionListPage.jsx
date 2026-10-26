// 자기소개서·학부모 소견서 입력 현황 (2026-10-25, 00102)
// 지원자별로 스캔본이 있는지, 몇 문항을 입력했는지, '입력 끝'인지를 보고 바로 입력 화면으로 간다.

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../../lib/supabase'
import { useAdmissionCycle } from '../../../contexts/AdmissionCycleContext'
import { getTranscriptionForm } from '../../../config/transcriptionForms'

function Cell({ applicantId, type, hasScan, status, total }) {
  const filled = status?.filled || 0
  let tone = 'bg-surface-subtle text-ink-muted'
  let text = hasScan ? '미입력' : '스캔 없음'
  if (status?.completed) { tone = 'bg-brand-greenSoft text-brand-deepGreenStrong'; text = `입력 끝 ${filled}/${total}` }
  else if (filled > 0) { tone = 'bg-status-warningSoft text-status-warning'; text = `입력 중 ${filled}/${total}` }
  return (
    <Link to={`/reception/transcriptions/${applicantId}/${type}`}
      className={`inline-block min-w-[96px] rounded-full px-2.5 py-1 text-center text-xs font-semibold hover:ring-2 hover:ring-brand-deepGreen/30 ${tone}`}>
      {text}
    </Link>
  )
}

export default function TranscriptionListPage() {
  const { year, round } = useAdmissionCycle()
  const [rows, setRows] = useState(null)
  const [error, setError] = useState(null)
  const [query, setQuery] = useState('')
  const [onlyTodo, setOnlyTodo] = useState(false)

  useEffect(() => {
    if (!year || !round) return
    supabase.rpc('list_transcription_status', { p_year: year, p_round: round }).then(({ data, error: err }) => {
      if (err) setError(err.message)
      else setRows(data || [])
    })
  }, [year, round])

  const essayTotal = getTranscriptionForm(year, 'essay').questions.length
  const opinionTotal = getTranscriptionForm(year, 'opinion').questions.length

  const visible = useMemo(() => {
    const q = query.trim()
    return (rows || []).filter((r) => {
      if (q && ![r.name, r.receiptNo, r.examNo].some((v) => (v || '').includes(q))) return false
      if (onlyTodo && r.essay?.completed && r.opinion?.completed) return false
      return true
    })
  }, [rows, query, onlyTodo])

  const done = (rows || []).filter((r) => r.essay?.completed && r.opinion?.completed).length

  return (
    <div>
      <h1 className="text-xl font-bold text-ink-primary">자기소개서·소견서 입력</h1>
      <p className="mt-1 text-sm text-ink-secondary">
        손글씨 서류를 문항별로 받아 적어 두면 위원 열람·채점 화면에 '입력본'으로 보입니다. 원문 그대로, 읽을 수 없는 글자는 [판독불가].
      </p>

      <div className="mt-4 flex flex-wrap items-center gap-3">
        <input type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="성명·접수번호·수험번호"
          aria-label="지원자 찾기" className="w-60 rounded-md border border-border px-3 py-1.5 text-sm" />
        <label className="flex items-center gap-1.5 text-sm text-ink-secondary">
          <input type="checkbox" checked={onlyTodo} onChange={(e) => setOnlyTodo(e.target.checked)} /> 남은 것만
        </label>
        {rows && <span className="ml-auto text-sm text-ink-secondary">둘 다 입력 끝 <b className="text-ink-primary">{done}</b> / {rows.length}명</span>}
      </div>

      {error && <p className="mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      <div className="mt-3 overflow-hidden rounded-lg border border-border bg-white">
        <table className="w-full text-sm">
          <thead className="bg-surface-subtle text-xs text-ink-secondary">
            <tr>
              <th className="px-3 py-2 text-left">접수번호</th>
              <th className="px-3 py-2 text-left">수험번호</th>
              <th className="px-3 py-2 text-left">성명</th>
              <th className="px-3 py-2 text-left">자기소개서 ({essayTotal}문항)</th>
              <th className="px-3 py-2 text-left">학부모 소견서 ({opinionTotal}문항)</th>
            </tr>
          </thead>
          <tbody>
            {!rows && !error && <tr><td colSpan={5} className="p-6 text-center text-ink-muted">불러오는 중…</td></tr>}
            {rows && visible.length === 0 && <tr><td colSpan={5} className="p-6 text-center text-ink-muted">해당하는 지원자가 없습니다.</td></tr>}
            {visible.map((r) => (
              <tr key={r.applicantId} className="border-t border-border">
                <td className="px-3 py-2 font-mono text-xs">{r.receiptNo}</td>
                <td className="px-3 py-2 font-mono text-xs">{r.examNo || '-'}</td>
                <td className="px-3 py-2 font-semibold text-ink-primary">{r.name}</td>
                <td className="px-3 py-2"><Cell applicantId={r.applicantId} type="essay" hasScan={r.hasEssay} status={r.essay} total={essayTotal} /></td>
                <td className="px-3 py-2"><Cell applicantId={r.applicantId} type="opinion" hasScan={r.hasOpinion} status={r.opinion} total={opinionTotal} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
