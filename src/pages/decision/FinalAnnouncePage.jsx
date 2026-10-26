// M6c 최종 발표 산출물 (마스터 스펙 5.5, 요강 승인본 "5. 전형 일정 — 최종 합격자
// 발표: 개별 통보(SMS) 및 홈페이지")
//
// get_final_pass_list가 용도별로 필드를 서버에서 이미 최소화해서 내려준다.
// 이 화면은 그 결과를 미리보기·CSV 다운로드만 한다 — 실제 SMS 발송·홈페이지
// 게시는 이 화면 밖(학교 문자발송 도구, 홈페이지 관리자)에서 이 CSV를 가지고
// 진행한다.
//
// 2026-07-14 추가: 합격자 개별 통보 SMS는 CSV로 뽑아 수동 발송하는 대신
// 시스템에서 바로 보낼 수 있도록 send-final-result-sms Edge Function을
// 연동한다(접수증 SMS와 동일한 문자나라 연동 재사용). 확정된 최종 사정
// 결과 중 합격자에게만, 서버에서 재검증한 뒤 발송한다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import { logExport } from '../../lib/exportAudit'
import { roundToText } from '../../lib/applicantLabels'
import PageHeader from '../../components/layout/PageHeader'
import StatusBadge from '../../components/status/StatusBadge'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

function toCsv(rows, columns) {
  const escape = (v) => {
    const s = v === null || v === undefined ? '' : String(v)
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  const header = columns.map((c) => c.label).join(',')
  const body = rows.map((r) => columns.map((c) => escape(r[c.key])).join(',')).join('\n')
  return '﻿' + header + '\n' + body
}

async function downloadCsv(filename, rows, columns, exportMeta) {
  const csv = toCsv(rows, columns)
  if (exportMeta) {
    await logExport({ ...exportMeta, fileFormat: 'csv', content: csv, rowCount: rows.length })
  }
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

const SMS_COLUMNS = [
  { key: 'receiptNo', label: '접수번호' },
  { key: 'name', label: '성명' },
  { key: 'applicantPhone', label: '지원자 연락처' },
  { key: 'guardianName', label: '보호자 성명' },
  { key: 'guardianPhone', label: '보호자 연락처' },
  { key: 'trackLabel', label: '전형' },
  { key: 'outcomeLabel', label: '판정' },
]

const WEBSITE_COLUMNS = [
  { key: 'receiptNo', label: '접수번호' },
  { key: 'outcomeLabel', label: '판정' },
]

export default function FinalAnnouncePage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [smsItems, setSmsItems] = useState(null)
  const [websiteItems, setWebsiteItems] = useState(null)
  const [runId, setRunId] = useState(null)
  const [loading, setLoading] = useState(null)
  const [error, setError] = useState(null)

  const [recipients, setRecipients] = useState(null)
  const [resultSmsRunId, setResultSmsRunId] = useState(null)
  const [recipientsLoading, setRecipientsLoading] = useState(false)
  const [recipientsError, setRecipientsError] = useState(null)
  const [sendingKey, setSendingKey] = useState(null)
  const [bulkSending, setBulkSending] = useState(null)
  // 2026-10-01: 불합격자도 시스템에서 통보한다. 문구는 서버가 확정된 판정으로 고른다.
  const [outcomeTab, setOutcomeTab] = useState('passed')

  const load = async (purpose) => {
    setError(null)
    setLoading(purpose)
    const { data, error: err } = await supabase.rpc('get_final_pass_list', {
      p_year: YEAR,
      p_round: ROUND,
      p_purpose: purpose,
    })
    setLoading(null)
    if (err) {
      setError(err.message)
      return
    }
    setRunId(data.runId)
    if (purpose === 'sms') setSmsItems(data.items)
    else setWebsiteItems(data.items)
  }

  const loadRecipients = async () => {
    setRecipientsError(null)
    setRecipientsLoading(true)
    const { data, error: err } = await supabase.rpc('get_final_result_sms_recipients', {
      p_year: YEAR,
      p_round: ROUND,
    })
    setRecipientsLoading(false)
    if (err) {
      setRecipientsError(err.message)
      return
    }
    setResultSmsRunId(data.runId)
    setRecipients(data.items || [])
  }

  const sendOne = async (applicantId, target) => {
    const key = `${applicantId}:${target}`
    setSendingKey(key)
    setRecipientsError(null)
    const { data, error: err } = await supabase.functions.invoke('send-final-result-sms', {
      body: { runId: resultSmsRunId, applicantId, targets: [target] },
    })
    setSendingKey(null)
    if (err) {
      setRecipientsError(err.message)
      return
    }
    const result = data?.results?.[target]
    if (result?.sent) {
      setRecipients((current) => current.map((item) => (
        item.applicantId === applicantId
          ? { ...item, [target === 'applicant' ? 'applicantSent' : 'guardianSent']: true }
          : item
      )))
    } else {
      setRecipientsError(
        `${target === 'applicant' ? '지원자' : '보호자'} 발송 실패: ${result?.providerMessage || result?.reason || '알 수 없는 오류'}`,
      )
    }
  }

  const shownRecipients = (recipients || []).filter((item) => item.outcome === outcomeTab)
  const outcomeText = outcomeTab === 'passed' ? '합격' : '불합격'

  const sendBulk = async (target) => {
    if (!recipients) return
    const pending = shownRecipients.filter((item) => (
      target === 'applicant' ? !item.applicantSent && item.applicantPhone : !item.guardianSent && item.guardianPhone
    ))
    if (pending.length === 0) return
    // eslint-disable-next-line no-alert
    if (!window.confirm(`${outcomeText}자 ${pending.length}명의 ${target === 'applicant' ? '지원자' : '보호자'}에게 ${outcomeText} 안내 문자를 보냅니다. 계속할까요?`)) return
    setBulkSending(target)
    setRecipientsError(null)
    for (const item of pending) {
      // eslint-disable-next-line no-await-in-loop
      await sendOne(item.applicantId, target)
    }
    setBulkSending(null)
  }

  return (
    <div className="mx-auto max-w-4xl px-4 py-6 sm:px-6">
      <PageHeader
        title="최종 발표 산출물"
        description={`${YEAR}학년도 신입생 입학전형 · ${roundToText(ROUND)} · 확정된 최종 사정 결과만 사용합니다. 여기서 만든 CSV로 실제 문자 발송·홈페이지 게시는 이 화면 밖에서 진행합니다.`}
      />

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}

      {/* 합격자 개별 통보 SMS 발송 */}
      <div className="mb-6 rounded-lg border border-border bg-white p-4">
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 className="text-sm font-semibold text-ink-primary">최종 결과 SMS 발송</h3>
            <p className="text-xs text-ink-muted">확정된 최종 사정 결과대로 합격·불합격 안내 문자를 시스템에서 바로 보냅니다. 문구는 판정에 맞춰 서버가 고르며(지원자용·보호자용 따로), 이미 발송된 대상은 "발송완료"로 표시됩니다.</p>
          </div>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={loadRecipients}
              disabled={recipientsLoading}
              className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
            >
              {recipientsLoading ? '불러오는 중…' : '대상 불러오기'}
            </button>
            {recipients && recipients.length > 0 && (
              <>
                <button
                  type="button"
                  onClick={() => sendBulk('applicant')}
                  disabled={Boolean(bulkSending) || Boolean(sendingKey)}
                  className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
                >
                  {bulkSending === 'applicant' ? '지원자 발송 중…' : `${outcomeText}자 · 지원자 전체 발송`}
                </button>
                <button
                  type="button"
                  onClick={() => sendBulk('guardian')}
                  disabled={Boolean(bulkSending) || Boolean(sendingKey)}
                  className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
                >
                  {bulkSending === 'guardian' ? '보호자 발송 중…' : `${outcomeText}자 · 보호자 전체 발송`}
                </button>
              </>
            )}
          </div>
        </div>

        {recipientsError && <p className="mb-2 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{recipientsError}</p>}

        {recipients && (
          <>
            <div className="mb-2 flex items-center gap-2">
              {[['passed', '합격'], ['failed', '불합격']].map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  onClick={() => setOutcomeTab(value)}
                  disabled={Boolean(bulkSending)}
                  className={`rounded-md border px-3 py-1.5 text-xs font-semibold ${outcomeTab === value ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border text-ink-secondary'}`}
                >
                  {label} {recipients.filter((item) => item.outcome === value).length}명
                </button>
              ))}
              <span className="text-xs text-ink-muted">
                {outcomeTab === 'passed' ? '축하 문구로 발송됩니다.' : '감사와 응원을 담은 안내 문구로 발송됩니다.'}
              </span>
            </div>
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
                <tbody className="divide-y divide-gray-100">
                  {shownRecipients.map((item) => (
                    <tr key={item.applicantId}>
                      <td className="px-3 py-2 font-mono">{item.examNo || '-'}</td>
                      <td className="px-3 py-2 font-mono text-xs text-ink-muted">{item.receiptNo}</td>
                      <td className="px-3 py-2">{item.name}</td>
                      <td className="px-3 py-2">
                        <StatusBadge label={item.outcome === 'passed' ? '합격' : '불합격'} tone={item.outcome === 'passed' ? 'success' : 'neutral'} />
                      </td>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-2">
                          <span className="text-xs text-ink-secondary">{item.applicantPhone || '-'}</span>
                          {item.applicantSent ? (
                            <StatusBadge label="발송완료" tone="success" />
                          ) : (
                            <button
                              type="button"
                              disabled={!item.applicantPhone || sendingKey === `${item.applicantId}:applicant` || Boolean(bulkSending)}
                              onClick={() => sendOne(item.applicantId, 'applicant')}
                              className="rounded-md border border-border px-2 py-1 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                            >
                              {sendingKey === `${item.applicantId}:applicant` ? '발송 중…' : '발송'}
                            </button>
                          )}
                        </div>
                      </td>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-2">
                          <span className="text-xs text-ink-secondary">{item.guardianPhone || '-'}</span>
                          {item.guardianSent ? (
                            <StatusBadge label="발송완료" tone="success" />
                          ) : (
                            <button
                              type="button"
                              disabled={!item.guardianPhone || sendingKey === `${item.applicantId}:guardian` || Boolean(bulkSending)}
                              onClick={() => sendOne(item.applicantId, 'guardian')}
                              className="rounded-md border border-border px-2 py-1 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                            >
                              {sendingKey === `${item.applicantId}:guardian` ? '발송 중…' : '발송'}
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>

      {/* SMS */}
      <div className="mb-6 rounded-lg border border-border bg-white p-4">
        <div className="mb-2 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-semibold text-ink-primary">개별 통보(SMS)용</h3>
            <p className="text-xs text-ink-muted">합격·불합격 전원 · 지원자/보호자 연락처 포함</p>
          </div>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => load('sms')}
              disabled={loading === 'sms'}
              className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
            >
              {loading === 'sms' ? '불러오는 중…' : '불러오기'}
            </button>
            {smsItems && smsItems.length > 0 && (
              <button
                type="button"
                onClick={() =>
                  downloadCsv(`${YEAR}_최종발표_SMS.csv`, smsItems, SMS_COLUMNS, {
                    year: YEAR, round: ROUND, exportType: 'finalResultSms', decisionRunId: runId,
                  })
                }
                className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong"
              >
                CSV 다운로드
              </button>
            )}
          </div>
        </div>
        {smsItems && (
          <p className="text-xs text-ink-muted">{smsItems.length}명 (합격 {smsItems.filter((i) => i.outcomeLabel === '합격').length}명)</p>
        )}
      </div>

      {/* 홈페이지 */}
      <div className="mb-6 rounded-lg border border-border bg-white p-4">
        <div className="mb-2 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-semibold text-ink-primary">홈페이지 게시용</h3>
            <p className="text-xs text-ink-muted">합격자만 · 접수번호 외 개인정보 없음</p>
          </div>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => load('website')}
              disabled={loading === 'website'}
              className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
            >
              {loading === 'website' ? '불러오는 중…' : '불러오기'}
            </button>
            {websiteItems && websiteItems.length > 0 && (
              <button
                type="button"
                onClick={() =>
                  downloadCsv(`${YEAR}_최종발표_홈페이지.csv`, websiteItems, WEBSITE_COLUMNS, {
                    year: YEAR, round: ROUND, exportType: 'finalResultWebsite', decisionRunId: runId,
                  })
                }
                className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong"
              >
                CSV 다운로드
              </button>
            )}
          </div>
        </div>
        {websiteItems && <p className="text-xs text-ink-muted">합격자 {websiteItems.length}명</p>}

        {websiteItems && websiteItems.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-2">
            {websiteItems.map((i) => (
              <span key={i.receiptNo} className="rounded-full bg-brand-greenSoft px-2 py-0.5 font-mono text-xs text-brand-deepGreenStrong">
                {i.receiptNo}
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
