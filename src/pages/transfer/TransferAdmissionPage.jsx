// 전·편입생 선발 전형(공고 2026-40호) 접수대장.
// 신입생 ReceptionPage.jsx와 같은 UX 패턴(현황 카드=필터, 검색, 등록 폼
// 토글, 목록, 상세 drawer)을 따르되, 이 전형 전용 테이블(transfer_applicants)
// 만 사용한다 — 신입생 데이터와는 물리적으로 완전히 분리되어 있다.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import TransferRegisterForm from './TransferRegisterForm'
import TransferScorePanel from './TransferScorePanel'
import Drawer from '../../components/layout/Drawer'
import StatusBadge from '../../components/status/StatusBadge'

const ROUND_LABEL = '2026-07'

const STATUS_LABEL = {
  received: '접수 처리 중',
  incomplete: '서류 미비',
  complete: '접수 완료',
  withdrawn: '지원 철회',
  excluded: '제외',
}

const ELIGIBILITY_LABEL = {
  enrolled: '가. 고1 재학중',
  withdrawn: '나-1. 고1 자퇴',
  altSchool: '나-2. 대안학교 전편입',
}

const FILTER_CARDS = [
  { key: 'all', label: '전체' },
  { key: 'received', label: '접수 처리 중' },
  { key: 'incomplete', label: '서류 미비' },
  { key: 'complete', label: '접수 완료' },
]

export default function TransferAdmissionPage() {
  const [applicants, setApplicants] = useState([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(null)
  const [showForm, setShowForm] = useState(false)
  const [lastReceipt, setLastReceipt] = useState(null)
  const [search, setSearch] = useState('')
  const [activeFilter, setActiveFilter] = useState('all')
  const [detailApplicant, setDetailApplicant] = useState(null)
  const [detailScores, setDetailScores] = useState(null)
  const [detailLoading, setDetailLoading] = useState(false)

  const load = useCallback(async () => {
    setLoadError(null)
    const { data, error } = await supabase
      .from('transfer_applicants')
      .select('*')
      .eq('round_label', ROUND_LABEL)
      .order('exam_no', { ascending: true, nullsFirst: false })
      .order('receipt_no', { ascending: true })

    if (error) {
      setLoadError(error.message)
    } else {
      setApplicants(data || [])
    }
    setLoading(false)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const activeApplicants = useMemo(
    () => applicants.filter((a) => a.application_status !== 'withdrawn' && a.application_status !== 'excluded'),
    [applicants],
  )

  const filterCounts = useMemo(() => {
    const counts = { all: activeApplicants.length, received: 0, incomplete: 0, complete: 0 }
    for (const a of activeApplicants) {
      if (a.application_status === 'received') counts.received += 1
      if (a.application_status === 'incomplete') counts.incomplete += 1
      if (a.application_status === 'complete') counts.complete += 1
    }
    return counts
  }, [activeApplicants])

  const visibleRows = useMemo(() => {
    const q = search.trim().toLowerCase()
    return activeApplicants.filter((a) => {
      if (activeFilter !== 'all' && a.application_status !== activeFilter) return false
      if (!q) return true
      return a.name.toLowerCase().includes(q) || a.receipt_no.toLowerCase().includes(q)
    })
  }, [activeApplicants, activeFilter, search])

  const handleRegistered = (result) => {
    setLastReceipt(result)
    setShowForm(false)
    load()
  }

  const openDetail = async (applicant) => {
    setDetailApplicant(applicant)
    setDetailLoading(true)
    const { data, error } = await supabase
      .from('transfer_document_scores')
      .select('*')
      .eq('applicant_id', applicant.id)
      .maybeSingle()
    setDetailLoading(false)
    if (!error) setDetailScores(data)
  }

  const refreshDetail = async () => {
    if (!detailApplicant) return
    const { data } = await supabase
      .from('transfer_document_scores')
      .select('*')
      .eq('applicant_id', detailApplicant.id)
      .maybeSingle()
    setDetailScores(data)
    load()
  }

  const handleStatusChange = async (applicantId, newStatus) => {
    const { error } = await supabase.rpc('update_transfer_application_status', {
      p_applicant_id: applicantId,
      p_new_status: newStatus,
    })
    if (error) {
      alert(`상태 변경 실패: ${error.message}`)
      return
    }
    load()
    setDetailApplicant((prev) => (prev ? { ...prev, application_status: newStatus } : prev))
  }

  const handleChecklistToggle = async (applicant, key) => {
    const nextValue = !(applicant.document_checklist || {})[key]
    const { error } = await supabase.rpc('update_transfer_document_checklist', {
      p_applicant_id: applicant.id,
      p_checklist: { [key]: nextValue },
    })
    if (error) {
      alert(`서류 체크 실패: ${error.message}`)
      return
    }
    await load()
    setDetailApplicant((prev) =>
      prev && prev.id === applicant.id
        ? { ...prev, document_checklist: { ...prev.document_checklist, [key]: nextValue } }
        : prev,
    )
  }

  const DOCUMENT_ITEMS = [
    { key: 'applicationForm', label: '원서·수험표' },
    { key: 'photos', label: '사진 2매' },
    { key: 'selfIntroduction', label: '자기소개서' },
    { key: 'guardianOpinion', label: '보호자소견서' },
    { key: 'consentForms', label: '동의서 2종' },
    { key: 'schoolRecordOrGed', label: '학생부/검정고시' },
    { key: 'enrollmentOrWithdrawalCert', label: '재학/제적증명서' },
    { key: 'other', label: '기타서류' },
  ]

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-ink-primary">전·편입생 선발 전형 접수대장</h2>
          <p className="text-sm text-ink-secondary">
            우편(등기) 접수만 · 지원자{' '}
            {activeApplicants.length}명
          </p>
        </div>
        <button
          type="button"
          onClick={() => setShowForm((v) => !v)}
          className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong"
        >
          {showForm ? '폼 닫기' : '+ 우편 도착분 등록'}
        </button>
      </div>

      {lastReceipt && (
        <div className="mb-4 flex items-center justify-between rounded-md bg-brand-greenSoft px-4 py-3 text-sm">
          <span>
            등록 완료 — 접수번호 <strong className="font-mono">{lastReceipt.receiptNo}</strong>
          </span>
          <button type="button" className="text-xs text-ink-muted underline" onClick={() => setLastReceipt(null)}>
            닫기
          </button>
        </div>
      )}

      <div className="mb-4 flex flex-wrap gap-2">
        {FILTER_CARDS.map((card) => {
          const count = filterCounts[card.key] ?? 0
          const active = activeFilter === card.key
          return (
            <button
              key={card.key}
              type="button"
              onClick={() => setActiveFilter(card.key)}
              className={`rounded-lg border px-4 py-2 text-left transition-colors ${
                active ? 'border-brand-deepGreen bg-brand-greenSoft' : 'border-border bg-surface-card hover:border-brand-deepGreen'
              }`}
            >
              <p className="text-xs text-ink-muted">{card.label}</p>
              <p className={`text-lg font-semibold ${active ? 'text-brand-deepGreenStrong' : 'text-ink-primary'}`}>{count}</p>
            </button>
          )
        })}
      </div>

      <div className="mb-4">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 이름 또는 접수번호 검색"
          className="w-full max-w-sm rounded-md border border-border px-3 py-2 text-sm sm:w-72"
        />
      </div>

      {showForm && (
        <div className="mb-6 rounded-lg border border-border bg-surface-card p-5">
          <h3 className="mb-4 text-base font-semibold text-ink-primary">우편 도착분 등록</h3>
          <TransferRegisterForm onRegistered={handleRegistered} onCancel={() => setShowForm(false)} />
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border border-border bg-surface-card">
        {loading ? (
          <p className="p-6 text-center text-sm text-ink-muted">불러오는 중…</p>
        ) : loadError ? (
          <p className="p-6 text-center text-sm text-status-danger">{loadError}</p>
        ) : visibleRows.length === 0 ? (
          <p className="p-6 text-center text-sm text-ink-muted">
            {search || activeFilter !== 'all' ? '조건에 맞는 지원자가 없습니다.' : '아직 등록된 전편입학 지원자가 없습니다.'}
          </p>
        ) : (
          <table className="min-w-full text-sm">
            <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
              <tr>
                <th className="px-4 py-2 font-medium">접수번호</th>
                <th className="px-4 py-2 font-medium">지원자</th>
                <th className="px-4 py-2 font-medium">지원자격</th>
                <th className="px-4 py-2 font-medium">전적교</th>
                <th className="px-4 py-2 font-medium">접수일</th>
                <th className="px-4 py-2 font-medium">상태</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {visibleRows.map((a) => (
                <tr key={a.id} onClick={() => openDetail(a)} className="cursor-pointer hover:bg-surface-subtle">
                  <td className="px-4 py-2 font-mono">{a.receipt_no}</td>
                  <td className="px-4 py-2 font-medium text-ink-primary">{a.name}</td>
                  <td className="px-4 py-2">{ELIGIBILITY_LABEL[a.eligibility_category]}</td>
                  <td className="px-4 py-2">{a.current_school || '—'}</td>
                  <td className="px-4 py-2">{a.receipt_date}</td>
                  <td className="px-4 py-2">
                    <StatusBadge
                      label={STATUS_LABEL[a.application_status]}
                      tone={a.application_status === 'complete' ? 'success' : a.application_status === 'incomplete' ? 'warning' : 'info'}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <Drawer
        open={Boolean(detailApplicant)}
        onClose={() => {
          setDetailApplicant(null)
          setDetailScores(null)
        }}
        title={detailApplicant?.name}
        subtitle={detailApplicant?.receipt_no}
        widthClassName="max-w-lg"
      >
        {detailApplicant && (
          <>
            <dl className="mb-5 space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-ink-muted">지원자격</dt>
                <dd className="text-ink-primary">{ELIGIBILITY_LABEL[detailApplicant.eligibility_category]}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-ink-muted">전적교</dt>
                <dd className="text-ink-primary">
                  {detailApplicant.current_school || '—'} ({detailApplicant.current_grade || '—'})
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-ink-muted">접수일 / 송장번호</dt>
                <dd className="text-ink-primary">
                  {detailApplicant.receipt_date} {detailApplicant.tracking_no ? `/ ${detailApplicant.tracking_no}` : ''}
                </dd>
              </div>
              {detailApplicant.staff_memo && (
                <div>
                  <dt className="text-ink-muted">직원 메모</dt>
                  <dd className="mt-1 text-ink-primary">{detailApplicant.staff_memo}</dd>
                </div>
              )}
            </dl>

            <label className="mb-1 block text-xs font-medium text-ink-secondary">접수 상태 변경</label>
            <select
              value={detailApplicant.application_status}
              onChange={(e) => handleStatusChange(detailApplicant.id, e.target.value)}
              className="mb-5 w-full rounded-md border border-border px-3 py-2 text-sm"
            >
              {Object.entries(STATUS_LABEL).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>

            <div className="mb-5">
              <h4 className="mb-2 text-sm font-semibold text-ink-primary">제출서류 체크리스트</h4>
              <div className="grid grid-cols-2 gap-2">
                {DOCUMENT_ITEMS.map((item) => (
                  <label key={item.key} className="flex items-center gap-2 text-xs">
                    <input
                      type="checkbox"
                      checked={Boolean((detailApplicant.document_checklist || {})[item.key])}
                      onChange={() => handleChecklistToggle(detailApplicant, item.key)}
                    />
                    {item.label}
                  </label>
                ))}
              </div>
            </div>

            <div className="border-t border-border pt-4">
              <h4 className="mb-3 text-sm font-semibold text-ink-primary">1단계 서류전형 채점</h4>
              {detailLoading ? (
                <p className="text-xs text-ink-muted">불러오는 중…</p>
              ) : (
                <TransferScorePanel applicantId={detailApplicant.id} scores={detailScores} onUpdated={refreshDetail} />
              )}
            </div>
          </>
        )}
      </Drawer>
    </div>
  )
}
