// 수험번호 안내 문자 발송 패널 (2026-09-28)
//
// 원서 접수 지침 4-(2): 원서 접수 마감 이후 3일 이내 개인별 연락처로 수험번호 안내.
// 문구는 지침 붙임 3을 따르며 서버(Edge Function send-exam-no-sms)에서 만든다.
// 합격자 통보 문자(FinalAnnouncePage)와 같은 방식이다 — 대상 불러오기 →
// 개별 또는 전체 발송 → 발송완료 표시. 재발송은 막지 않는다.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import StatusBadge from '../../components/status/StatusBadge'

export default function ExamNoSmsPanel({ year, round, onClose }) {
  const [items, setItems] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [sendingKey, setSendingKey] = useState(null)
  const [bulk, setBulk] = useState(null) // null | 'applicant' | 'guardian'
  const [progress, setProgress] = useState(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('get_exam_no_sms_recipients', {
      p_year: year,
      p_round: round,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setItems(data?.items || [])
  }, [year, round])

  useEffect(() => {
    load()
  }, [load])

  // 한 명·한 대상에게 보낸다. 실패 사유를 문자열로 돌려준다(성공이면 null).
  const sendOne = async (applicantId, target) => {
    const { data, error: err } = await supabase.functions.invoke('send-exam-no-sms', {
      body: { applicantId, targets: [target] },
    })
    if (err) return err.message
    const r = data?.results?.[target]
    if (!r?.sent) return r?.providerMessage || r?.reason || '발송 실패'
    setItems((cur) => cur.map((it) => (
      it.applicantId === applicantId
        ? { ...it, [target === 'applicant' ? 'applicantSent' : 'guardianSent']: true }
        : it
    )))
    return null
  }

  const handleOne = async (applicantId, target) => {
    setSendingKey(`${applicantId}:${target}`)
    setError(null)
    const fail = await sendOne(applicantId, target)
    setSendingKey(null)
    if (fail) setError(`${target === 'applicant' ? '지원자' : '보호자'} 발송 실패: ${fail}`)
  }

  const handleBulk = async (target) => {
    const phoneKey = target === 'applicant' ? 'applicantPhone' : 'guardianPhone'
    const sentKey = target === 'applicant' ? 'applicantSent' : 'guardianSent'
    const pending = (items || []).filter((it) => !it[sentKey] && it[phoneKey])
    if (pending.length === 0) return
    setBulk(target)
    setError(null)
    const failures = []
    for (let i = 0; i < pending.length; i += 1) {
      setProgress(`${i + 1} / ${pending.length}`)
      // eslint-disable-next-line no-await-in-loop
      const fail = await sendOne(pending[i].applicantId, target)
      if (fail) failures.push(`${pending[i].examNo} ${pending[i].name}: ${fail}`)
    }
    setBulk(null)
    setProgress(null)
    if (failures.length) setError(`실패 ${failures.length}건 — ${failures.join(' / ')}`)
  }

  const count = items?.length || 0
  const applicantDone = (items || []).filter((i) => i.applicantSent).length
  const guardianDone = (items || []).filter((i) => i.guardianSent).length
  const busy = Boolean(bulk) || Boolean(sendingKey)

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="flex max-h-[90vh] w-full max-w-3xl flex-col rounded-lg bg-surface-card">
        <div className="flex items-start justify-between gap-3 border-b border-border p-5">
          <div>
            <h3 className="text-base font-semibold text-ink-primary">수험번호 안내 문자</h3>
            <p className="mt-1 text-xs text-ink-muted">
              원서 접수 지침상 접수 마감 후 3일 이내에 보내야 합니다. 문구는 지침 붙임 3과 같고,
              접수번호·접수일자·성명·생년월일/성별·수험번호가 들어가 장문으로 발송됩니다.
            </p>
          </div>
          <button type="button" onClick={onClose} disabled={busy} className="text-sm text-ink-muted hover:text-ink-primary disabled:opacity-40">
            닫기
          </button>
        </div>

        <div className="flex flex-wrap items-center gap-2 border-b border-border px-5 py-3">
          <span className="mr-auto text-sm text-ink-secondary">
            대상 {count}명 · 지원자 {applicantDone}명 · 보호자 {guardianDone}명 발송완료
            {progress && <span className="ml-2 font-semibold text-brand-deepGreenStrong">발송 중 {progress}</span>}
          </span>
          <button
            type="button"
            onClick={() => handleBulk('applicant')}
            disabled={busy || count === 0}
            className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {bulk === 'applicant' ? '지원자 발송 중…' : '지원자 미발송분 전체 발송'}
          </button>
          <button
            type="button"
            onClick={() => handleBulk('guardian')}
            disabled={busy || count === 0}
            className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {bulk === 'guardian' ? '보호자 발송 중…' : '보호자 미발송분 전체 발송'}
          </button>
        </div>

        {error && (
          <p className="mx-5 mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>
        )}

        <div className="min-h-0 flex-1 overflow-y-auto p-5">
          {loading ? (
            <p className="text-sm text-ink-muted">불러오는 중…</p>
          ) : count === 0 ? (
            <p className="rounded-md border border-dashed border-border p-6 text-center text-sm text-ink-muted">
              수험번호가 부여된 지원자가 없습니다. 먼저 &lsquo;수험번호 일괄 부여&rsquo;를 실행하세요.
            </p>
          ) : (
            <table className="min-w-full text-sm">
              <thead className="border-b border-border text-left text-xs text-ink-secondary">
                <tr>
                  <th className="px-2 py-2 font-semibold">수험번호</th>
                  <th className="px-2 py-2 font-semibold">성명</th>
                  <th className="px-2 py-2 font-semibold">지원자</th>
                  <th className="px-2 py-2 font-semibold">보호자</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {items.map((it) => (
                  <tr key={it.applicantId}>
                    <td className="px-2 py-2 font-mono font-semibold">{it.examNo}</td>
                    <td className="px-2 py-2">{it.name}</td>
                    {['applicant', 'guardian'].map((target) => {
                      const phone = target === 'applicant' ? it.applicantPhone : it.guardianPhone
                      const sent = target === 'applicant' ? it.applicantSent : it.guardianSent
                      const key = `${it.applicantId}:${target}`
                      return (
                        <td key={target} className="px-2 py-2">
                          <div className="flex items-center gap-2">
                            <span className="text-xs text-ink-secondary">{phone || '연락처 없음'}</span>
                            {sent && <StatusBadge label="발송완료" tone="success" />}
                            {phone && (
                              <button
                                type="button"
                                disabled={busy}
                                onClick={() => handleOne(it.applicantId, target)}
                                className="rounded-md border border-border px-2 py-0.5 text-xs text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                              >
                                {sendingKey === key ? '발송 중…' : sent ? '재발송' : '발송'}
                              </button>
                            )}
                          </div>
                        </td>
                      )
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  )
}
