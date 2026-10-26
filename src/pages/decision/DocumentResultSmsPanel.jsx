// 1단계(서류평가) 결과 개별 통보 SMS 발송 패널 (2026-10-13)
//
// 1단계 사정 화면 아래에 붙는다. 최종 결과 문자(FinalAnnouncePage)와 같은 방식:
//   - 확정된 1단계 사정 결과의 합격·불합격자를 불러와 지원자·보호자에게 문자 발송
//   - 문구는 서버(send-document-result-sms)가 확정 결과를 다시 읽어 고른다
//   - 이미 보낸 대상은 "발송완료"로 표시(중복 발송 방지)
// 2단계 심층역량평가 날짜는 요강 일정(config/printNotices.js)에서 읽어 함께 보낸다.

import { useMemo, useState } from 'react'
import { supabase, getEdgeFunctionErrorMessage } from '../../lib/supabase'
import { getScheduleForDashboard, formatMonthDay } from '../../config/printNotices'
import StatusBadge from '../../components/status/StatusBadge'

export default function DocumentResultSmsPanel({ year, round }) {
  const [recipients, setRecipients] = useState(null)
  const [runId, setRunId] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [tab, setTab] = useState('passed')
  const [sendingKey, setSendingKey] = useState(null)
  const [bulkSending, setBulkSending] = useState(null)

  const deepDate = useMemo(() => {
    const row = getScheduleForDashboard(year, round)?.find((r) => r.label.includes('심층'))
    return row ? formatMonthDay(row.start) : ''
  }, [year, round])

  const load = async () => {
    setError(null)
    setLoading(true)
    const { data, error: err } = await supabase.rpc('get_document_result_sms_recipients', { p_year: year, p_round: round })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setRunId(data.runId)
    setRecipients(data.items || [])
  }

  const sendOne = async (applicantId, target) => {
    setSendingKey(`${applicantId}:${target}`)
    setError(null)
    const { data, error: err } = await supabase.functions.invoke('send-document-result-sms', {
      body: { runId, applicantId, targets: [target], deepDate },
    })
    setSendingKey(null)
    if (err) {
      setError(await getEdgeFunctionErrorMessage(err, err.message))
      return false
    }
    const result = data?.results?.[target]
    if (result?.sent) {
      setRecipients((cur) => cur.map((item) => (
        item.applicantId === applicantId ? { ...item, [target === 'applicant' ? 'applicantSent' : 'guardianSent']: true } : item
      )))
      return true
    }
    setError(`${target === 'applicant' ? '지원자' : '보호자'} 발송 실패: ${result?.providerMessage || result?.reason || '알 수 없는 오류'}`)
    return false
  }

  const shown = (recipients || []).filter((item) => item.outcome === tab)
  const outcomeText = tab === 'passed' ? '합격' : '불합격'

  const sendBulk = async (target) => {
    const pending = shown.filter((item) => (target === 'applicant'
      ? !item.applicantSent && item.applicantPhone
      : !item.guardianSent && item.guardianPhone))
    if (pending.length === 0) return
    // eslint-disable-next-line no-alert
    if (!window.confirm(`1단계 ${outcomeText}자 ${pending.length}명의 ${target === 'applicant' ? '지원자' : '보호자'}에게 ${outcomeText} 안내 문자를 보냅니다. 계속할까요?`)) return
    setBulkSending(target)
    for (const item of pending) {
      // eslint-disable-next-line no-await-in-loop
      await sendOne(item.applicantId, target)
    }
    setBulkSending(null)
  }

  const deepLine = deepDate
    ? `2단계 심층역량평가는 ${deepDate}에 실시하며, 입실 시간은 추후 안내드립니다.`
    : '2단계 심층역량평가 일정과 입실 시간은 추후 안내드립니다.'
  const preview = tab === 'passed'
    ? `[새봄고등학교] ○○○ 님, ${year}학년도 새봄고등학교 신입생 입학전형 1단계 서류평가에 합격하셨습니다. 축하드립니다! ${deepLine} 당일 수험표와 신분증을 꼭 지참해 주세요. 자세한 내용은 학교 홈페이지 공지사항을 확인해 주세요. (접수번호 … · 수험번호 …)`
    : `[새봄고등학교] ○○○ 님, ${year}학년도 신입생 입학전형에 보여주신 관심과 정성에 깊이 감사드립니다. 아쉽게도 1단계 서류평가에서 함께하지 못하게 되었음을 알려드립니다. 지원서에 담아 준 고민과 노력은 앞으로의 길에서도 소중한 힘이 될 것입니다. ○○○ 님의 내일을 진심으로 응원합니다. (접수번호 … · 수험번호 …)`

  const sendButton = (item, target) => {
    const sent = target === 'applicant' ? item.applicantSent : item.guardianSent
    const phone = target === 'applicant' ? item.applicantPhone : item.guardianPhone
    const key = `${item.applicantId}:${target}`
    return (
      <div className="flex items-center gap-2">
        <span className="text-xs text-ink-secondary">{phone || '-'}</span>
        {sent ? (
          <StatusBadge label="발송완료" tone="success" />
        ) : (
          <button type="button" disabled={!phone || sendingKey === key || Boolean(bulkSending)} onClick={() => sendOne(item.applicantId, target)}
            className="rounded-md border border-border px-2 py-1 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50">
            {sendingKey === key ? '발송 중…' : '발송'}
          </button>
        )}
      </div>
    )
  }

  return (
    <section className="mt-8 rounded-xl border border-border bg-surface-card p-5" aria-labelledby="doc-sms-title">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id="doc-sms-title" className="text-base font-semibold text-ink-primary">1단계 결과 SMS 발송</h2>
          <p className="mt-0.5 text-xs text-ink-muted">
            확정된 1단계 사정 결과대로 합격·불합격 안내 문자를 보냅니다. 문구는 판정에 맞춰 서버가 고릅니다(지원자용·보호자용 따로).
            {deepDate ? ` 합격 문자에는 2단계 일정 ${deepDate}이 들어갑니다.` : ''}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={load} disabled={loading}
            className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50">
            {loading ? '불러오는 중…' : recipients ? '다시 불러오기' : '대상 불러오기'}
          </button>
          {recipients && shown.length > 0 && (
            <>
              <button type="button" onClick={() => sendBulk('applicant')} disabled={Boolean(bulkSending) || Boolean(sendingKey)}
                className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50">
                {bulkSending === 'applicant' ? '지원자 발송 중…' : `${outcomeText}자 · 지원자 전체 발송`}
              </button>
              <button type="button" onClick={() => sendBulk('guardian')} disabled={Boolean(bulkSending) || Boolean(sendingKey)}
                className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50">
                {bulkSending === 'guardian' ? '보호자 발송 중…' : `${outcomeText}자 · 보호자 전체 발송`}
              </button>
            </>
          )}
        </div>
      </div>

      {error && <p role="alert" className="mb-2 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

      {recipients && (
        <>
          <div className="mb-2 flex flex-wrap items-center gap-2">
            {[['passed', '합격'], ['failed', '불합격']].map(([value, label]) => (
              <button key={value} type="button" onClick={() => setTab(value)} disabled={Boolean(bulkSending)}
                className={`rounded-md border px-3 py-1.5 text-xs font-semibold ${tab === value ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border text-ink-secondary'}`}>
                {label} {recipients.filter((item) => item.outcome === value).length}명
              </button>
            ))}
          </div>
          <p className="mb-2 rounded-md bg-surface-subtle px-3 py-2 text-xs leading-relaxed text-ink-secondary">
            <span className="font-semibold">지원자용 문구 미리보기</span> — {preview}
          </p>
          <div className="overflow-x-auto rounded-lg border border-border">
            <table className="min-w-full text-sm">
              <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
                <tr>
                  <th className="px-3 py-2">수험번호</th>
                  <th className="px-3 py-2">접수번호</th>
                  <th className="px-3 py-2">성명</th>
                  <th className="px-3 py-2">판정</th>
                  <th className="px-3 py-2">지원자 연락처</th>
                  <th className="px-3 py-2">보호자 연락처</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {shown.length === 0 && (
                  <tr><td colSpan={6} className="px-3 py-6 text-center text-xs text-ink-muted">대상이 없습니다.</td></tr>
                )}
                {shown.map((item) => (
                  <tr key={item.applicantId}>
                    <td className="px-3 py-2 font-mono">{item.examNo || '-'}</td>
                    <td className="px-3 py-2 font-mono text-xs text-ink-muted">{item.receiptNo}</td>
                    <td className="px-3 py-2">{item.name}</td>
                    <td className="px-3 py-2">
                      <StatusBadge label={item.outcome === 'passed' ? '합격' : '불합격'} tone={item.outcome === 'passed' ? 'success' : 'neutral'} />
                    </td>
                    <td className="px-3 py-2">{sendButton(item, 'applicant')}</td>
                    <td className="px-3 py-2">{sendButton(item, 'guardian')}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  )
}
