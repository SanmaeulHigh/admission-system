// M6d 전형평가회의 자료 (마스터 스펙 M6, 검토메모 "M6 회의자료 PDF는 M5e 종이
// 백업과 역할이 다름")
//
// M5e와 동일한 브라우저 인쇄 원칙(window.print(), 시스템 한글 폰트 이용, 서버
// PDF 생성 없음)을 따른다. 익명화는 화면 표시 옵션일 뿐 접근통제가 아니다 —
// 이 화면을 볼 수 있는 사람은 이미 superadmin/admin이라 성명을 볼 권한이 있다.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { exportFinalScoresheetXlsx } from '../../lib/exportFinalScoresheetXlsx'
import { logExport } from '../../lib/exportAudit'
import { roundToText } from '../../lib/applicantLabels'
import PageHeader from '../../components/layout/PageHeader'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { PRINT_FONT_STACK, printFontFaceCss } from '../../lib/printFont'
import { printStampCss } from '../../lib/printStamp'

const TRACK_LABEL = { incheon: '인천학생추천', social: '사회통합', general: '일반' }
const OUTCOME_LABEL = { passed: '합격', failed: '불합격', excluded: '제외', manualDecisionRequired: '동점(위원회 결정 필요)' }

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

function buildPrintHtml(packet, anonymized, YEAR) {
  const rows = (packet.candidates || [])
    .map((c, i) => {
      const label = anonymized ? `익명${i + 1}` : `${escapeHtml(c.receiptNo)} · ${escapeHtml(c.name)}`
      return `<tr>
        <td>${TRACK_LABEL[c.primaryTrack] ?? c.primaryTrack}</td>
        <td>${c.rank ?? '-'}</td>
        <td>${label}</td>
        <td>${c.documentCarry ?? '-'}</td>
        <td>${c.groupScore ?? '-'}</td>
        <td>${c.interviewStudentScore ?? '-'}</td>
        <td>${c.interviewParentScore ?? '-'}</td>
        <td>${c.writingScore ?? '-'}</td>
        <td><strong>${c.finalTotal ?? '-'}</strong></td>
        <td>${OUTCOME_LABEL[c.outcome] ?? c.outcome}</td>
      </tr>`
    })
    .join('')

  const excludedRows = (packet.excludedCandidates || [])
    .map((c, i) => `<tr><td>${anonymized ? `익명제외${i + 1}` : `${escapeHtml(c.receiptNo)} · ${escapeHtml(c.name)}`}</td><td>${escapeHtml(c.adminNote || '-')}</td></tr>`)
    .join('')

  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${YEAR}학년도 전형평가회의 자료</title>
<style>
  @page { size: A4 landscape; margin: 14mm; }
  ${printStampCss()}
  ${printFontFaceCss()}
  body { font-family: ${PRINT_FONT_STACK}; font-size: 11px; color: #111; }
  h1 { font-size: 16px; margin: 0 0 4px; }
  p.meta { color: #555; margin: 0 0 12px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
  th, td { border: 1px solid #ccc; padding: 4px 6px; text-align: center; }
  th { background: #f3f3f3; }
  .toolbar { margin-bottom: 12px; }
  .toolbar button { padding: 6px 14px; }
  @media print { .toolbar { display: none; } }
</style></head>
<body>
  <div class="toolbar"><button type="button" onclick="window.print()">인쇄 / PDF 저장</button></div>
  <h1>${YEAR}학년도 새봄고등학교 신입생 입학전형 — 전형평가회의 자료</h1>
  <p class="meta">
    생성 시각: ${new Date(packet.generatedAt).toLocaleString('ko-KR')} ·
    run 상태: ${packet.runStatus} (${packet.runMode}) ·
    ${anonymized ? '익명화 표시' : '실명 표시'}
  </p>
  <table>
    <thead><tr>
      <th>전형</th><th>순위</th><th>${anonymized ? '익명번호' : '접수번호·성명'}</th>
      <th>서류(400)</th><th>모둠(150)</th><th>학생면접(150)</th><th>학부모면접(100)</th><th>글쓰기(200)</th>
      <th>총점(1000)</th><th>판정</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>
  ${packet.excludedCandidates?.length > 0 ? `
  <h2 style="font-size:13px;">위원회 exclusion 결정 대상</h2>
  <table><thead><tr><th>${anonymized ? '익명번호' : '접수번호·성명'}</th><th>사유</th></tr></thead>
  <tbody>${excludedRows}</tbody></table>` : ''}
</body></html>`
}

export default function CommitteePacketPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [packet, setPacket] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [anonymized, setAnonymized] = useState(false)
  const [xlsxLoading, setXlsxLoading] = useState(false)

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('get_m6_committee_packet', { p_year: YEAR, p_round: ROUND })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setPacket(data)
  }, [YEAR, ROUND])

  useEffect(() => {
    load()
  }, [load])

  const grouped = useMemo(() => {
    const g = { incheon: [], social: [], general: [] }
    for (const c of packet?.candidates || []) g[c.primaryTrack]?.push(c)
    return g
  }, [packet])

  const openPrintPreview = async () => {
    const w = window.open('', '_blank')
    if (!w) {
      setError('새 창이 차단되었습니다. 팝업을 허용한 뒤 다시 시도하세요.')
      return
    }
    const html = buildPrintHtml(packet, anonymized, YEAR)
    await logExport({
      year: YEAR, round: ROUND, exportType: 'committeePacket', fileFormat: 'pdf',
      content: html, decisionRunId: packet.runId,
      rowCount: (packet.candidates || []).length,
      metadata: { anonymized },
    })
    w.document.open()
    w.document.write(html)
    w.document.close()
  }

  const handleDownloadXlsx = async () => {
    setError(null)
    setXlsxLoading(true)
    try {
      await exportFinalScoresheetXlsx({ year: YEAR, round: ROUND })
    } catch (e) {
      setError(e.message)
    } finally {
      setXlsxLoading(false)
    }
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6">
      <PageHeader
        title="전형평가회의 자료"
        description={`${YEAR}학년도 신입생 입학전형 · ${roundToText(ROUND)} · 최근 실행된 최종 사정 결과(시뮬레이션 또는 확정) 기준`}
      />

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}

      {!loading && packet?.reason === 'NO_DOCUMENT_FINAL_RUN' && (
        <p className="rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">확정된 1단계 서류사정이 아직 없습니다.</p>
      )}
      {!loading && packet?.reason === 'NO_FINAL_RUN_YET' && (
        <p className="rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">
          최종 사정을 아직 한 번도 실행하지 않았습니다. `/decision/final`에서 시뮬레이션을 먼저 실행하세요.
        </p>
      )}

      {!loading && packet?.ready && (
        <>
          <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
            <label className="flex items-center gap-2 text-sm text-ink-secondary">
              <input type="checkbox" checked={anonymized} onChange={(e) => setAnonymized(e.target.checked)} />
              익명화 (성명·접수번호 대신 익명번호 표시)
            </label>
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={handleDownloadXlsx}
                disabled={xlsxLoading}
                className="rounded-md border border-border px-4 py-2 text-sm font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
              >
                {xlsxLoading ? '생성 중…' : '종합 채점표 XLSX 다운로드'}
              </button>
              <button
                type="button"
                onClick={openPrintPreview}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong"
              >
                인쇄 / PDF 저장 미리보기
              </button>
            </div>
          </div>

          <div className="mb-6 grid grid-cols-2 gap-3 sm:grid-cols-5">
            {[
              { label: 'run 상태', value: `${packet.runStatus} (${packet.runMode})` },
              { label: '확인 필요 경보', value: packet.blockers.blockingAlertCount, warn: packet.blockers.blockingAlertCount > 0 },
              { label: '심층 미완료', value: packet.blockers.incompleteDeepCount, warn: packet.blockers.incompleteDeepCount > 0 },
              { label: '위원회 결정 대기', value: packet.blockers.reviewPendingCount, warn: packet.blockers.reviewPendingCount > 0 },
              { label: '미해결 동점', value: packet.blockers.unresolvedTieCount, warn: packet.blockers.unresolvedTieCount > 0 },
            ].map((c) => (
              <div key={c.label} className={`rounded-lg border p-3 ${c.warn ? 'border-status-danger bg-status-dangerSoft' : 'border-border bg-white'}`}>
                <p className="text-xs text-ink-muted">{c.label}</p>
                <p className={`text-sm font-semibold ${c.warn ? 'text-status-danger' : 'text-ink-primary'}`}>{c.value}</p>
              </div>
            ))}
          </div>

          {['incheon', 'social', 'general'].map((track) =>
            grouped[track].length > 0 ? (
              <div key={track} className="mb-6">
                <h3 className="mb-2 text-sm font-semibold text-ink-primary">{TRACK_LABEL[track]} ({grouped[track].length}명)</h3>
                <div className="overflow-x-auto rounded-lg border border-border bg-white">
                  <table className="min-w-full text-xs">
                    <thead className="bg-surface-subtle text-left text-ink-muted">
                      <tr>
                        <th className="px-2 py-2">순위</th>
                        <th className="px-2 py-2">{anonymized ? '익명' : '접수번호·성명'}</th>
                        <th className="px-2 py-2">서류(400)</th>
                        <th className="px-2 py-2">모둠(150)</th>
                        <th className="px-2 py-2">학생면접(150)</th>
                        <th className="px-2 py-2">학부모면접(100)</th>
                        <th className="px-2 py-2">글쓰기(200)</th>
                        <th className="px-2 py-2">총점</th>
                        <th className="px-2 py-2">판정</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-100">
                      {grouped[track].map((c, i) => (
                        <tr key={c.applicantId} className={c.outcome === 'manualDecisionRequired' ? 'bg-status-warningSoft' : ''}>
                          <td className="px-2 py-1.5">{c.rank ?? '-'}</td>
                          <td className="px-2 py-1.5 font-mono">{anonymized ? `익명${i + 1}` : `${c.receiptNo} ${c.name}`}</td>
                          <td className="px-2 py-1.5">{c.documentCarry ?? '-'}</td>
                          <td className="px-2 py-1.5">{c.groupScore ?? '-'}</td>
                          <td className="px-2 py-1.5">{c.interviewStudentScore ?? '-'}</td>
                          <td className="px-2 py-1.5">{c.interviewParentScore ?? '-'}</td>
                          <td className="px-2 py-1.5">{c.writingScore ?? '-'}</td>
                          <td className="px-2 py-1.5 font-semibold">{c.finalTotal ?? '-'}</td>
                          <td className="px-2 py-1.5">{OUTCOME_LABEL[c.outcome] ?? c.outcome}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            ) : null,
          )}

          {packet.excludedCandidates?.length > 0 && (
            <div className="mb-6">
              <h3 className="mb-2 text-sm font-semibold text-ink-primary">위원회 exclusion 결정 대상 ({packet.excludedCandidates.length}명)</h3>
              <ul className="rounded-lg border border-border bg-white p-3 text-xs text-ink-secondary">
                {packet.excludedCandidates.map((c, i) => (
                  <li key={c.applicantId}>
                    {anonymized ? `익명제외${i + 1}` : `${c.receiptNo} ${c.name}`} — {c.adminNote || '사유 미기재'}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  )
}
