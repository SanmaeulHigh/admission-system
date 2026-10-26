// 원서 접수 일보 (2026-10-12)
//
// 접수 기간 동안 매일 한 장씩 올리는 보고서(A4 세로, 결재란 담당·부장·교장).
//  1. 전형별 접수 현황: 전일까지 · 금일 · 누계 · 모집정원 · 경쟁률
//  2. 접수 방법·서류: 방문/우편, 서류 확인 필요(현재), 철회·제외
//  3. 금일 접수자 명단
//  4. 특이사항(손으로 적는 칸)
// 날짜 하나를 골라 뽑거나, 접수 시작일부터 고른 날까지 하루 한 장씩 한꺼번에 뽑는다.
//
// 숫자는 "인쇄하는 시점의 현재 상태"로 센다. 철회·제외된 원서는 접수일과 관계없이
// 지원자 수에서 빼고 따로 적는다(언제 철회됐는지는 세지 않음).
// 인쇄 요소에는 tabular-nums를 쓰지 않는다(PDF 저장 시 숫자가 사라지는 문제).

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { getScheduleForDashboard, formatMonthDay, daysUntil } from '../../config/printNotices'
import schoolLogo from '../../assets/school-logo.png'
import ApprovalBox from '../../components/print/ApprovalBox'

const WEEKDAY = ['일', '월', '화', '수', '목', '금', '토']
const TRACKS = [
  { key: 'none', label: '일반전형만' },
  { key: 'incheon', label: '일반 + 인천학생추천' },
  { key: 'social', label: '일반 + 사회통합' },
]
const DOCS = [
  { type: 'photo', label: '사진' },
  { type: 'studentRecordSource', label: '학생부' },
  { type: 'essay', label: '자소서' },
  { type: 'opinion', label: '소견서' },
]
const OUT = ['withdrawn', 'excluded']

function specialTrack(tracks) {
  const t = tracks || []
  return t.includes('incheon') ? 'incheon' : t.includes('social') ? 'social' : 'none'
}
function kstKey(iso) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso))
}
function keyOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
function dateOfKey(k) {
  const [y, m, d] = k.split('-').map(Number)
  return new Date(y, m - 1, d)
}
function longDate(d) {
  return `${d.getFullYear()}. ${d.getMonth() + 1}. ${d.getDate()}.(${WEEKDAY[d.getDay()]})`
}

// ───────── 하루 한 장 ─────────
function BulletinSheet({ dayKey, year, round, applicants, docs, quota, period }) {
  const day = dateOfKey(dayKey)
  const active = applicants.filter((a) => !OUT.includes(a.application_status))
  const before = active.filter((a) => a.k < dayKey)
  const today = active.filter((a) => a.k === dayKey)
  const upto = active.filter((a) => a.k <= dayKey)
  const count = (list, t) => list.filter((a) => a.track === t).length
  const q = (t) => (t === 'none' ? quota?.general : t === 'incheon' ? quota?.incheon : quota?.social) || 0
  const ratio = (n, cap) => (cap > 0 ? `${(n / cap).toFixed(2)} : 1` : '—')
  const outUpto = applicants.filter((a) => OUT.includes(a.application_status) && a.k <= dayKey).length
  const incompleteUpto = upto.filter((a) => a.application_status === 'incomplete').length
  const dayNo = period ? Math.round((day - period.start) / 86400000) + 1 : null
  const totalDays = period ? Math.round((period.end - period.start) / 86400000) + 1 : null
  const left = period ? daysUntil(period.end, day) : null

  const th = 'border border-black px-1.5 py-1.5 text-center font-semibold bg-[#EFEFEF]'
  const td = 'border border-black px-1.5 py-[5px] text-center'

  return (
    <div className="w-[182mm] bg-white p-6 text-black shadow-sm print:w-auto print:p-0 print:shadow-none" style={{ fontSize: '10pt' }}>
      {/* 머리 */}
      <div className="mb-4 flex items-start justify-between gap-4">
        <div className="flex items-start gap-3 pt-1">
          <img src={schoolLogo} alt="새봄고등학교" style={{ height: '15mm', width: 'auto' }} />
          <div>
            <h1 className="text-[16pt] font-bold leading-snug tracking-tight">원서 접수 일보</h1>
            <p className="text-[10pt]">{year}학년도 신입생 입학전형 · {roundToText(round)}</p>
            <p className="mt-1 text-[11pt] font-bold">{longDate(day)}</p>
            {period && (
              <p className="text-[9pt]">
                접수 기간 {formatMonthDay(period.start)} ~ {formatMonthDay(period.end)}
                {dayNo >= 1 && dayNo <= totalDays && ` · ${totalDays}일 중 ${dayNo}일째`}
                {left > 0 && ` · 마감까지 ${left}일`}
                {left === 0 && ' · 마감일'}
              </p>
            )}
          </div>
        </div>
        <ApprovalBox />
      </div>

      {/* 1. 전형별 */}
      <h2 className="mb-1 text-[10.5pt] font-bold">1. 전형별 접수 현황</h2>
      <table className="mb-4 w-full border-collapse" style={{ tableLayout: 'fixed' }}>
        {/* 지원 전형 칸만 넓게, 숫자 칸 5개는 같은 너비 */}
        <colgroup><col style={{ width: '44mm' }} /><col /><col /><col /><col /><col /></colgroup>
        <thead>
          <tr>
            <th className={th}>지원 전형</th>
            <th className={th}>전일까지</th>
            <th className={th}>금일</th>
            <th className={th}>누계</th>
            <th className={th}>모집정원</th>
            <th className={th}>경쟁률</th>
          </tr>
        </thead>
        <tbody>
          {TRACKS.map((t) => (
            <tr key={t.key}>
              <td className={`${td} text-left`}>{t.label}</td>
              <td className={td}>{count(before, t.key)}</td>
              <td className={`${td} font-bold`}>{count(today, t.key)}</td>
              <td className={td}>{count(upto, t.key)}</td>
              <td className={td}>{t.key === 'none' ? '—' : (q(t.key) || '—')}</td>
              <td className={td}>{t.key === 'none' ? '—' : ratio(count(upto, t.key), q(t.key))}</td>
            </tr>
          ))}
          <tr className="font-bold">
            <td className={`${td} bg-[#F6F6F6]`}>계</td>
            <td className={`${td} bg-[#F6F6F6]`}>{before.length}</td>
            <td className={`${td} bg-[#F6F6F6]`}>{today.length}</td>
            <td className={`${td} bg-[#F6F6F6]`}>{upto.length}</td>
            <td className={`${td} bg-[#F6F6F6]`}>{quota?.total || '—'}</td>
            <td className={`${td} bg-[#F6F6F6]`}>{ratio(upto.length, quota?.total || 0)}</td>
          </tr>
        </tbody>
      </table>

      {/* 2. 방법·서류 */}
      <h2 className="mb-1 text-[10.5pt] font-bold">2. 접수 방법 및 서류</h2>
      <table className="mb-4 w-full border-collapse" style={{ tableLayout: 'fixed' }}>
        {/* 구분 칸만 좁게, 방문·우편·서류·철회 4칸은 같은 너비 */}
        <colgroup><col style={{ width: '22mm' }} /><col /><col /><col /><col /></colgroup>
        <thead>
          <tr>
            <th className={th}>구분</th>
            <th className={th}>방문</th>
            <th className={th}>우편(등기)</th>
            <th className={th}>서류 확인 필요<br /><span className="text-[8pt] font-normal">(누계 중 현재)</span></th>
            <th className={th}>철회·제외<br /><span className="text-[8pt] font-normal">(누계)</span></th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td className={td}>금일</td>
            <td className={td}>{today.filter((a) => a.receipt_method !== 'M').length}</td>
            <td className={td}>{today.filter((a) => a.receipt_method === 'M').length}</td>
            <td className={td} rowSpan={2}>{incompleteUpto}</td>
            <td className={td} rowSpan={2}>{outUpto}</td>
          </tr>
          <tr>
            <td className={td}>누계</td>
            <td className={td}>{upto.filter((a) => a.receipt_method !== 'M').length}</td>
            <td className={td}>{upto.filter((a) => a.receipt_method === 'M').length}</td>
          </tr>
        </tbody>
      </table>

      {/* 3. 금일 접수자 */}
      <h2 className="mb-1 text-[10.5pt] font-bold">3. 금일 접수자 명단 ({today.length}명)</h2>
      <table className="mb-4 w-full border-collapse" style={{ fontSize: '9pt' }}>
        <thead>
          <tr>
            <th className={th} style={{ width: '9mm' }}>연번</th>
            <th className={th} style={{ width: '24mm' }}>접수번호</th>
            <th className={th} style={{ width: '18mm' }}>성명</th>
            <th className={th}>지원 전형</th>
            <th className={th}>출신 중학교</th>
            <th className={th} style={{ width: '13mm' }}>방법</th>
            <th className={th} style={{ width: '26mm' }}>제출 서류</th>
          </tr>
        </thead>
        <tbody>
          {today.length === 0 && (
            <tr><td colSpan={7} className={`${td} py-3`}>금일 접수된 원서가 없습니다.</td></tr>
          )}
          {today.map((a, i) => {
            const has = docs.get(a.id) || new Set()
            const missing = DOCS.filter((d) => !has.has(d.type)).map((d) => d.label)
            return (
              <tr key={a.id}>
                <td className={td}>{i + 1}</td>
                <td className={`${td} font-mono text-[8.5pt]`}>{a.receipt_no}</td>
                <td className={`${td} font-semibold`}>{a.name}</td>
                <td className={td}>{TRACKS.find((t) => t.key === a.track)?.label.replace('전형만', '')}</td>
                <td className={td}>{a.academic_status === '검정고시' ? '(검정고시)' : a.school || ''}</td>
                <td className={td}>{a.receipt_method === 'M' ? '우편' : '방문'}</td>
                <td className={`${td} text-[8.5pt]`}>{missing.length === 0 ? '완비' : `${missing.join('·')} 없음`}</td>
              </tr>
            )
          })}
        </tbody>
      </table>

      {/* 4. 특이사항 */}
      <h2 className="mb-1 text-[10.5pt] font-bold">4. 특이사항</h2>
      <div className="border border-black">
        {[0, 1, 2, 3].map((n) => <div key={n} className={`h-[8mm] ${n < 3 ? 'border-b border-dashed border-[#999]' : ''}`} />)}
      </div>
      <p className="mt-2 text-[8pt]">※ 숫자는 출력 시점 기준이며, 철회·제외된 원서는 지원자 수에서 뺐습니다. 특별전형 지원자는 일반전형에도 함께 지원한 것으로 봅니다.</p>
    </div>
  )
}

// ───────── 화면 ─────────
export default function DailyBulletinPrint() {
  const { year, round } = useAdmissionCycle()
  const [applicants, setApplicants] = useState(null)
  const [docs, setDocs] = useState(new Map())
  const [quota, setQuota] = useState(null)
  const [error, setError] = useState(null)
  const [dayKey, setDayKey] = useState(() => keyOf(new Date()))
  const [mode, setMode] = useState('one') // one | range

  useEffect(() => {
    if (!year || !round) return
    let active = true
    ;(async () => {
      const [appRes, docRes] = await Promise.all([
        supabase
          .from('applicants')
          .select('id, receipt_no, name, tracks, academic_status, school, receipt_method, receipt_date, application_status')
          .eq('year', year)
          .eq('round', round)
          .order('receipt_no'),
        supabase.from('admission_documents').select('applicant_id, document_type').eq('year', year).eq('round', round).eq('active', true),
      ])
      if (!active) return
      if (appRes.error) {
        setError(appRes.error.message)
        return
      }
      const m = new Map()
      ;(docRes.data || []).forEach((d) => {
        if (!m.has(d.applicant_id)) m.set(d.applicant_id, new Set())
        m.get(d.applicant_id).add(d.document_type)
      })
      setDocs(m)
      setApplicants((appRes.data || []).filter((a) => a.receipt_date).map((a) => ({ ...a, k: kstKey(a.receipt_date), track: specialTrack(a.tracks) })))
      try {
        const { data: r } = await supabase.from('admission_rounds').select('config_revision_id').eq('year', year).eq('round', round).maybeSingle()
        if (r?.config_revision_id) {
          const { data: rev } = await supabase.from('config_revisions').select('scoring_params').eq('id', r.config_revision_id).maybeSingle()
          if (active && rev?.scoring_params?.quota) setQuota(rev.scoring_params.quota)
        }
      } catch {
        // 정원을 못 불러와도 일보는 그대로 뽑는다
      }
    })()
    return () => { active = false }
  }, [year, round])

  const period = useMemo(() => getScheduleForDashboard(year, round)?.find((r) => r.label.includes('접수')) || null, [year, round])

  // 고를 수 있는 날짜: 접수 기간 + 실제 접수가 있었던 날
  const dayOptions = useMemo(() => {
    const set = new Set()
    if (period) for (let d = new Date(period.start); d <= period.end; d.setDate(d.getDate() + 1)) set.add(keyOf(d))
    ;(applicants || []).forEach((a) => set.add(a.k))
    set.add(keyOf(new Date()))
    return [...set].sort()
  }, [period, applicants])

  const sheets = useMemo(() => {
    if (mode === 'one') return [dayKey]
    const start = period ? keyOf(period.start) : dayOptions[0]
    return dayOptions.filter((k) => k >= start && k <= dayKey)
  }, [mode, dayKey, period, dayOptions])

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-6 print:min-h-0 print:bg-white print:p-0">
      <style>{`@media print { @page { size: A4 portrait; margin: 14mm 14mm 16mm; } }`}</style>
      <div className="mx-auto w-fit">
        <div className="mb-4 space-y-3 print:hidden" style={{ maxWidth: '182mm' }}>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">← 지원자 목록</Link>
            <button type="button" onClick={() => window.print()} disabled={!applicants}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
              일보 인쇄{sheets.length > 1 ? ` (${sheets.length}장)` : ''}
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-4 rounded-lg border border-border bg-white px-4 py-3 text-sm text-ink-secondary">
            <label className="flex items-center gap-2">
              날짜
              <select value={dayKey} onChange={(e) => setDayKey(e.target.value)} className="rounded-md border border-border px-2 py-1">
                {dayOptions.map((k) => <option key={k} value={k}>{longDate(dateOfKey(k))}</option>)}
              </select>
            </label>
            <label className="flex items-center gap-1.5">
              <input type="radio" checked={mode === 'one'} onChange={() => setMode('one')} /> 그날 한 장
            </label>
            <label className="flex items-center gap-1.5">
              <input type="radio" checked={mode === 'range'} onChange={() => setMode('range')} /> 접수 시작일부터 그날까지 하루 한 장씩
            </label>
          </div>
          {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
        </div>

        {applicants ? (
          <div className="space-y-6 print:space-y-0">
            {sheets.map((k, i) => (
              <div key={k} style={i < sheets.length - 1 ? { breakAfter: 'page', pageBreakAfter: 'always' } : undefined}>
                <BulletinSheet dayKey={k} year={year} round={round} applicants={applicants} docs={docs} quota={quota} period={period} />
              </div>
            ))}
          </div>
        ) : (
          !error && <p className="py-10 text-center text-sm text-ink-muted">불러오는 중…</p>
        )}
      </div>
    </div>
  )
}
