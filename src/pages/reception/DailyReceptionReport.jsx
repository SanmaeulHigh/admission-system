// 일자별 원서 접수 현황표 (2026-10-12)
//
// 접수 기간 동안 하루하루 원서가 몇 건 들어왔는지 보고용으로 뽑는다(A4 세로, 결재란).
//  - 날짜는 한국 시각 기준 접수일. 접수 기간(요강 일정)의 모든 날을 0건이어도 싣고,
//    기간 밖에 접수된 건이 있으면 그 날도 싣는다.
//  - 철회·제외된 원서는 지원자 수에서 빼고, 아래에 따로 적는다.
//  - 모집정원을 불러올 수 있으면 경쟁률을 함께 적는다.
// 인쇄 요소에는 tabular-nums를 쓰지 않는다(PDF 저장 시 숫자가 사라지는 문제).

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { roundToText } from '../../lib/applicantLabels'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { getScheduleForDashboard, formatMonthDay } from '../../config/printNotices'
import schoolLogo from '../../assets/school-logo.png'
import ApprovalBox from '../../components/print/ApprovalBox'

const WEEKDAY = ['일', '월', '화', '수', '목', '금', '토']

function specialTrack(tracks) {
  const t = tracks || []
  return t.includes('incheon') ? 'incheon' : t.includes('social') ? 'social' : 'none'
}

// 한국 시각 기준 날짜 키 'YYYY-MM-DD'
function kstKey(iso) {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso))
  return p
}
function keyOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
function dateOfKey(k) {
  const [y, m, d] = k.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export default function DailyReceptionReport() {
  const { year, round } = useAdmissionCycle()
  const [applicants, setApplicants] = useState(null)
  const [quota, setQuota] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!year || !round) return
    let active = true
    ;(async () => {
      const { data, error: err } = await supabase
        .from('applicants')
        .select('id, tracks, receipt_method, receipt_date, application_status')
        .eq('year', year)
        .eq('round', round)
      if (!active) return
      if (err) {
        setError(err.message)
        return
      }
      setApplicants(data || [])

      // 모집정원(있으면): admission_rounds → config_revisions.scoring_params.quota
      try {
        const { data: r } = await supabase.from('admission_rounds').select('config_revision_id').eq('year', year).eq('round', round).maybeSingle()
        if (r?.config_revision_id) {
          const { data: rev } = await supabase.from('config_revisions').select('scoring_params').eq('id', r.config_revision_id).maybeSingle()
          if (active && rev?.scoring_params?.quota) setQuota(rev.scoring_params.quota)
        }
      } catch {
        // 정원을 못 불러와도 현황표는 그대로 뽑는다
      }
    })()
    return () => { active = false }
  }, [year, round])

  const period = useMemo(() => getScheduleForDashboard(year, round)?.find((r) => r.label.includes('접수')) || null, [year, round])

  const report = useMemo(() => {
    if (!applicants) return null
    const byDay = new Map()
    const blank = () => ({ none: 0, incheon: 0, social: 0, visit: 0, mail: 0, out: 0 })
    if (period) {
      for (let d = new Date(period.start); d <= period.end; d.setDate(d.getDate() + 1)) byDay.set(keyOf(d), blank())
    }
    applicants.forEach((a) => {
      if (!a.receipt_date) return
      const k = kstKey(a.receipt_date)
      if (!byDay.has(k)) byDay.set(k, blank())
      const row = byDay.get(k)
      if (['withdrawn', 'excluded'].includes(a.application_status)) {
        row.out += 1
        return
      }
      row[specialTrack(a.tracks)] += 1
      if (a.receipt_method === 'M') row.mail += 1
      else row.visit += 1
    })
    let cum = 0
    const rows = [...byDay.keys()].sort().map((k) => {
      const r = byDay.get(k)
      const day = r.none + r.incheon + r.social
      cum += day
      const d = dateOfKey(k)
      return { key: k, date: d, weekday: d.getDay(), ...r, day, cum, inPeriod: !period || (d >= period.start && d <= period.end) }
    })
    const sum = rows.reduce((s, r) => {
      ;['none', 'incheon', 'social', 'visit', 'mail', 'out', 'day'].forEach((f) => { s[f] += r[f] })
      return s
    }, { none: 0, incheon: 0, social: 0, visit: 0, mail: 0, out: 0, day: 0 })
    const maxDay = Math.max(1, ...rows.map((r) => r.day))
    return { rows, sum, maxDay }
  }, [applicants, period])

  const todayKey = keyOf(new Date())
  const th = 'border border-black px-1.5 py-1.5 text-center font-semibold'
  const td = 'border border-black px-1.5 py-[5px] text-center'
  const ratio = (n, q) => (q > 0 ? `${(n / q).toFixed(2)} : 1` : '—')

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-6 print:min-h-0 print:bg-white print:p-0">
      <style>{`@media print { @page { size: A4 portrait; margin: 14mm 14mm 16mm; } }`}</style>
      <div className="mx-auto w-fit">
        <div className="mb-4 space-y-3 print:hidden" style={{ maxWidth: '182mm' }}>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">← 지원자 목록</Link>
            <button type="button" onClick={() => window.print()} disabled={!report}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40">
              현황표 인쇄
            </button>
          </div>
          <p className="rounded-lg border border-border bg-white px-4 py-3 text-xs text-ink-muted">
            접수일(한국 시각) 기준으로 하루씩 셉니다. 철회·제외된 원서는 지원자 수에서 빼고 따로 적습니다. 인쇄할 때마다 그 시점 기준으로 다시 계산됩니다.
          </p>
          {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
        </div>

        {/* ── 인쇄 본문 (A4 세로) ── */}
        <div className="w-[182mm] bg-white p-6 text-black shadow-sm print:w-auto print:p-0 print:shadow-none" style={{ fontSize: '10pt' }}>
          <div className="mb-4 flex items-start justify-between gap-4">
            <div className="flex items-start gap-3 pt-1">
              <img src={schoolLogo} alt="새봄고등학교" style={{ height: '15mm', width: 'auto' }} />
              <div>
                <h1 className="text-[15pt] font-bold leading-snug tracking-tight">
                  {year}학년도 신입생 입학전형<br />일자별 원서 접수 현황
                </h1>
                <p className="mt-1 text-[9.5pt]">
                  {roundToText(round)}
                  {period && ` · 접수 기간 ${formatMonthDay(period.start)} ~ ${formatMonthDay(period.end)}`}
                </p>
                <p className="text-[9pt]">
                  {new Date().toLocaleString('ko-KR', { month: 'long', day: 'numeric', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })} 현재
                </p>
              </div>
            </div>
            <ApprovalBox />
          </div>

          {report && (
            <>
              <table className="w-full border-collapse" style={{ tableLayout: 'fixed' }}>
                <colgroup>
                  <col style={{ width: '24mm' }} />
                  <col style={{ width: '14mm' }} />
                  <col style={{ width: '18mm' }} />
                  <col style={{ width: '18mm' }} />
                  <col style={{ width: '15mm' }} />
                  <col style={{ width: '12mm' }} />
                  <col style={{ width: '12mm' }} />
                  <col style={{ width: '15mm' }} />
                  <col />
                </colgroup>
                <thead>
                  <tr className="bg-[#EFEFEF]">
                    <th rowSpan={2} className={th}>접수일</th>
                    <th colSpan={3} className={th}>지원 전형</th>
                    <th rowSpan={2} className={th}>당일 계</th>
                    <th colSpan={2} className={th}>접수 방법</th>
                    <th rowSpan={2} className={th}>누계</th>
                    <th rowSpan={2} className={th}>당일 접수</th>
                  </tr>
                  <tr className="bg-[#EFEFEF]">
                    <th className={`${th} text-[9pt]`}>일반</th>
                    <th className={`${th} text-[8.5pt]`}>일반+<br />인천추천</th>
                    <th className={`${th} text-[8.5pt]`}>일반+<br />사회통합</th>
                    <th className={`${th} text-[9pt]`}>방문</th>
                    <th className={`${th} text-[9pt]`}>우편</th>
                  </tr>
                </thead>
                <tbody>
                  {report.rows.length === 0 && (
                    <tr><td colSpan={9} className={`${td} py-6`}>접수 기간 일정이 없고, 접수된 원서도 없습니다.</td></tr>
                  )}
                  {report.rows.map((r) => {
                    const weekend = r.weekday === 0 || r.weekday === 6
                    const future = r.key > todayKey
                    return (
                      <tr key={r.key} className={weekend ? 'bg-[#F6F6F6]' : ''}>
                        <td className={`${td} ${r.weekday === 0 ? 'text-[#B00]' : r.weekday === 6 ? 'text-[#1F4FA8]' : ''}`}>
                          {r.date.getMonth() + 1}. {r.date.getDate()}.({WEEKDAY[r.weekday]})
                          {!r.inPeriod && <span className="text-[8pt]"> *</span>}
                        </td>
                        <td className={td}>{future ? '' : r.none}</td>
                        <td className={td}>{future ? '' : r.incheon}</td>
                        <td className={td}>{future ? '' : r.social}</td>
                        <td className={`${td} font-bold`}>{future ? '' : r.day}</td>
                        <td className={td}>{future ? '' : r.visit}</td>
                        <td className={td}>{future ? '' : r.mail}</td>
                        <td className={`${td} font-semibold`}>{future ? '' : r.cum}</td>
                        <td className="border border-black px-1.5">
                          {!future && r.day > 0 && (
                            <div className="h-[3.5mm] bg-[#00873C]" style={{ width: `${(r.day / report.maxDay) * 100}%` }} />
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
                <tfoot>
                  <tr className="bg-[#EFEFEF] font-bold">
                    <td className={td}>합계</td>
                    <td className={td}>{report.sum.none}</td>
                    <td className={td}>{report.sum.incheon}</td>
                    <td className={td}>{report.sum.social}</td>
                    <td className={td}>{report.sum.day}</td>
                    <td className={td}>{report.sum.visit}</td>
                    <td className={td}>{report.sum.mail}</td>
                    <td className={td}>{report.sum.day}</td>
                    <td className={td} />
                  </tr>
                </tfoot>
              </table>

              <div className="mt-3 space-y-0.5 text-[9pt]">
                {quota?.total > 0 && (
                  <p>
                    모집정원 {quota.total}명 · 지원자 {report.sum.day}명 · 경쟁률 {ratio(report.sum.day, quota.total)}
                    {quota.incheon > 0 && ` · 인천학생추천 ${report.sum.incheon}/${quota.incheon}명 (${ratio(report.sum.incheon, quota.incheon)})`}
                    {quota.social > 0 && ` · 사회통합 ${report.sum.social}/${quota.social}명 (${ratio(report.sum.social, quota.social)})`}
                  </p>
                )}
                {report.sum.out > 0 && <p>※ 철회·제외 {report.sum.out}건은 위 숫자에서 뺐습니다.</p>}
                {report.rows.some((r) => !r.inPeriod) && <p>※ * 표시는 접수 기간 밖에 접수된 날입니다.</p>}
                <p>※ 특별전형(인천학생추천·사회통합) 지원자는 일반전형에도 함께 지원한 것으로 봅니다.</p>
              </div>
            </>
          )}
          {!report && !error && <p className="py-10 text-center text-sm text-ink-muted print:hidden">불러오는 중…</p>}
        </div>
      </div>
    </div>
  )
}
