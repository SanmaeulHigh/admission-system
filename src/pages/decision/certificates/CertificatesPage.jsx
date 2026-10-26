// 확인서·합격증서 출력 (2026-10-20)
//
// 심층역량평가 대상 확인서: 1단계 사정 확정 뒤, 그 결과의 합격자만.
// 합격증서           : 최종 사정 확정 뒤, 그 결과의 합격자만.
// 철회·제외된 지원자는 서버에서 빠진다. 관리자(superadmin·admin)만.
//
// '발급·인쇄'를 누르면 서버가 번호를 매기고(처음일 때) 인쇄 횟수를 올린 뒤 인쇄 창을 연다.
// 번호는 한 번 정해지면 바뀌지 않는다. 다시 뽑으면 같은 번호로 다시 나온다(재발급 횟수만 늘어난다).

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../../lib/supabase'
import { useAdmissionCycle } from '../../../contexts/AdmissionCycleContext'
import { getPrintNotices } from '../../../config/printNotices'
import DeepConfirmSheet from './DeepConfirmSheet'
import DeepAttendanceSheet from './DeepAttendanceSheet'
import PassCertificateSheet from './PassCertificateSheet'

const KINDS = [
  { key: 'deep_eligibility', label: '심층역량평가 대상 확인서', paper: 'A4 · 여백 기본' },
  { key: 'deep_attendance', label: '심층역량평가 응시 확인서', paper: 'A4 · 여백 기본' },
  { key: 'final_pass', label: '합격증서', paper: 'A4 · 여백 없음 · 배경 그래픽 켜기' },
]

const KIND_NOTE = {
  deep_eligibility: '1단계 사정을 확정한 결과의 합격자만 나옵니다(철회·제외 제외). 번호: 2027-심층-001',
  deep_attendance: '2단계 당일 입실 확인(바코드)을 한 학생만 나옵니다. 중학교 출석 인정 제출용 — 요청한 학생만 골라 뽑으세요. 번호: 2027-응시-001',
  final_pass: '최종 사정을 확정한 결과의 합격자만 나옵니다(철회·제외 제외). 번호: 2027-A-PASS-001',
}

// '2026. 11. 18.(수)' → '2026년 11월 18일'
function announceText(year, round) {
  const rows = getPrintNotices(year, round || 'main')?.schedule || []
  const row = rows.find(([label]) => label.includes('합격자 발표'))
  const m = row?.[1]?.match(/(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})/)
  if (m) return `${m[1]}년 ${Number(m[2])}월 ${Number(m[3])}일`
  const d = new Date()
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일`
}

function fmtTime(v) {
  if (!v) return ''
  const d = new Date(v)
  return `${d.getMonth() + 1}. ${d.getDate()}. ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

export default function CertificatesPage() {
  const { year, round } = useAdmissionCycle()
  const [kind, setKind] = useState('deep_eligibility')
  const [state, setState] = useState({ loading: true })
  const [selected, setSelected] = useState(() => new Set())
  const [printing, setPrinting] = useState(null) // { kind, issuedAt, items }
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [query, setQuery] = useState('')

  const load = useCallback(async () => {
    if (!year || !round) return
    setState({ loading: true })
    setError(null)
    const { data, error: err } = await supabase.rpc('list_certificate_targets', { p_year: year, p_round: round, p_kind: kind })
    if (err) {
      setState({ loading: false, ready: false, reason: err.message })
      return
    }
    const items = data?.items || []
    setState({ loading: false, ready: !!data?.ready, reason: data?.reason, items })
    // 일괄 배부용(대상 확인서·합격증서)은 아직 안 뽑은 사람을 미리 고르고, 응시 확인서는 요청자만 고르도록 비워 둔다
    setSelected(kind === 'deep_attendance' ? new Set() : new Set(items.filter((i) => !i.certNo).map((i) => i.applicantId)))
    setQuery('')
  }, [year, round, kind])

  useEffect(() => { load() }, [load])

  // 인쇄 데이터가 그려진 뒤 인쇄 창
  useEffect(() => {
    if (!printing) return undefined
    const t = setTimeout(() => window.print(), 300)
    const after = () => { setPrinting(null); load() }
    window.addEventListener('afterprint', after, { once: true })
    return () => { clearTimeout(t); window.removeEventListener('afterprint', after) }
  }, [printing, load])

  const allItems = state.items || []
  const q = query.trim().toUpperCase()
  const items = q ? allItems.filter((i) => (i.name || '').includes(query.trim()) || (i.examNo || '').toUpperCase().includes(q)) : allItems
  const issuedCount = allItems.filter((i) => i.certNo).length
  const allChecked = items.length > 0 && items.every((i) => selected.has(i.applicantId))
  const kindInfo = KINDS.find((k) => k.key === kind)

  function toggle(id) {
    setSelected((cur) => {
      const next = new Set(cur)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function issueAndPrint() {
    const ids = allItems.filter((i) => selected.has(i.applicantId)).map((i) => i.applicantId)
    if (ids.length === 0) return
    const reprint = allItems.filter((i) => selected.has(i.applicantId) && i.certNo).length
    if (reprint > 0 && !window.confirm(`이미 발급한 ${reprint}명이 포함되어 있습니다. 같은 번호로 다시 인쇄하고 재발급 횟수를 기록할까요?`)) return
    setBusy(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('issue_certificates', {
      p_year: year, p_round: round, p_kind: kind, p_applicant_ids: ids,
    })
    setBusy(false)
    if (err) {
      setError(err.message)
      return
    }
    setPrinting({ kind, issuedAt: data.issuedAt, items: data.items || [] })
  }

  const announce = useMemo(() => announceText(year, round), [year, round])
  const printItems = printing?.items || []

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-8 print:min-h-0 print:bg-white print:p-0">
      {/* 합격증서는 A4 전체(여백 0)를 쓴다 */}
      {printing?.kind === 'final_pass' && (
        <style>{'@media print { @page { size: A4; margin: 0 } html, body { margin: 0 !important; padding: 0 !important; background: #fff !important } }'}</style>
      )}
      {printing && printing.kind !== 'final_pass' && <style>{'@page { size: A4; margin: 15mm }'}</style>}

      <div className="mx-auto max-w-4xl print:hidden">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <Link to="/decision/final/announce" className="text-sm text-ink-muted underline hover:text-ink-secondary">← 발표 자료</Link>
          <p className="text-xs text-ink-muted">{year}학년도 · {round === 'main' ? '신입학 본전형' : round}</p>
        </div>
        <h1 className="mt-3 text-xl font-bold text-ink-primary">확인서·합격증서 출력</h1>

        <div className="mt-4 flex flex-wrap gap-2">
          {KINDS.map((k) => (
            <button
              key={k.key}
              type="button"
              onClick={() => setKind(k.key)}
              className={`rounded-md border px-4 py-2 text-sm font-semibold ${kind === k.key ? 'border-brand-deepGreen bg-brand-deepGreen text-white' : 'border-border bg-white text-ink-secondary hover:bg-surface-subtle'}`}
            >
              {k.label}
            </button>
          ))}
        </div>

        <div className="mt-4 rounded-lg border border-border bg-white p-4 text-sm text-ink-secondary">
          <p>
            {KIND_NOTE[kind]} · 처음 발급하는 사람끼리는 수험번호 순으로 번호 부여
          </p>
          <p className="mt-1 text-xs text-ink-muted">
            인쇄 창: 용지 {kindInfo.paper}, 배율 100%(&lsquo;페이지에 맞춤&rsquo; 해제).
            {kind === 'final_pass' && ' 합격증서는 ‘배경 그래픽’을 켜야 바탕 무늬·색이 나옵니다. 두꺼운 상장 용지 권장.'}
          </p>
        </div>

        {error && <p className="mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

        {state.loading && <p className="mt-6 text-center text-sm text-ink-muted">불러오는 중…</p>}

        {!state.loading && !state.ready && (
          <p className="mt-4 rounded-md border border-dashed border-border bg-white p-6 text-center text-sm text-ink-muted">
            {state.reason || '아직 발급할 수 없습니다.'}
          </p>
        )}

        {!state.loading && state.ready && (
          <div className="mt-4 rounded-lg border border-border bg-white">
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-3">
              <p className="text-sm text-ink-secondary">
                대상 <strong className="text-ink-primary">{allItems.length}</strong>명 · 발급 {issuedCount}명 · 선택 {selected.size}명
              </p>
              <button
                type="button"
                onClick={issueAndPrint}
                disabled={busy || selected.size === 0}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
              >
                {busy ? '발급 중…' : `선택 ${selected.size}명 발급·인쇄`}
              </button>
            </div>
            {allItems.length > 0 && (
              <div className="border-b border-border px-4 py-2">
                <input
                  type="search"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="성명 또는 수험번호로 찾기"
                  aria-label="성명 또는 수험번호로 찾기"
                  className="w-full max-w-xs rounded-md border border-border px-3 py-1.5 text-sm"
                />
              </div>
            )}
            {items.length === 0 ? (
              <p className="p-6 text-center text-sm text-ink-muted">대상자가 없습니다.</p>
            ) : (
              <table className="w-full text-sm">
                <thead className="bg-surface-subtle text-xs text-ink-secondary">
                  <tr>
                    <th className="w-10 px-3 py-2">
                      <input
                        type="checkbox"
                        aria-label="모두 선택"
                        checked={allChecked}
                        onChange={() => setSelected((cur) => {
                          const next = new Set(cur)
                          items.forEach((i) => (allChecked ? next.delete(i.applicantId) : next.add(i.applicantId)))
                          return next
                        })}
                      />
                    </th>
                    <th className="px-3 py-2 text-left">수험번호</th>
                    <th className="px-3 py-2 text-left">성명</th>
                    <th className="px-3 py-2 text-left">번호</th>
                    <th className="px-3 py-2 text-left">인쇄</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((i) => (
                    <tr key={i.applicantId} className="border-t border-border">
                      <td className="px-3 py-2 text-center">
                        <input type="checkbox" aria-label={`${i.name} 선택`} checked={selected.has(i.applicantId)} onChange={() => toggle(i.applicantId)} />
                      </td>
                      <td className="px-3 py-2 font-mono tabular-nums">{i.examNo || '-'}</td>
                      <td className="px-3 py-2 font-semibold text-ink-primary">{i.name}</td>
                      <td className="px-3 py-2 font-mono text-xs">{i.certNo || <span className="text-ink-muted">미발급</span>}</td>
                      <td className="px-3 py-2 text-xs text-ink-secondary">
                        {i.printCount > 0 ? `${i.printCount}회 · ${fmtTime(i.lastPrintedAt)}` : '-'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>

      {/* 인쇄 본문 — 화면에서는 숨기고 인쇄 때만 */}
      {printing && (
        <div className="hidden print:block">
          {printItems.map((item, idx) => (
            <div
              key={item.applicantId}
              style={idx < printItems.length - 1 ? { breakAfter: 'page', pageBreakAfter: 'always' } : undefined}
            >
              {printing.kind === 'final_pass' && <PassCertificateSheet item={item} year={year} announceDateText={announce} />}
              {printing.kind === 'deep_eligibility' && <DeepConfirmSheet item={item} year={year} round={round} issuedAt={printing.issuedAt} />}
              {printing.kind === 'deep_attendance' && <DeepAttendanceSheet item={item} year={year} round={round} issuedAt={printing.issuedAt} />}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
