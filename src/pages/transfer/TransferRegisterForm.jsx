// 전·편입생 선발 전형(공고 2026-40호) 수기접수 폼.
// 요강상 접수는 우편(등기)만 가능해 지원자 본인이 입력하는 창구가 없다 —
// 직원이 도착한 우편물을 확인하며 이 폼으로 등록한다(register_transfer_applicant RPC).
// 신입생 RegisterApplicantForm.jsx과 같은 스타일을 따르되 전편입학 고유
// 지원자격·서류 체크리스트를 반영한다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

const DOCUMENT_ITEMS = [
  { key: 'applicationForm', label: '전(편)입학원서 및 수험표' },
  { key: 'photos', label: '여권사진 2매' },
  { key: 'selfIntroduction', label: '지원자 자필 자기소개서' },
  { key: 'guardianOpinion', label: '보호자 소견서' },
  { key: 'consentForms', label: '개인정보 동의서 · 공동생활 규칙 동의서' },
  { key: 'schoolRecordOrGed', label: '중학교 학생부Ⅱ 사본(또는 검정고시 합격·성적증명서)' },
  { key: 'enrollmentOrWithdrawalCert', label: '고등학교 재학증명서(중퇴자는 제적증명서)' },
  { key: 'other', label: '기타 요청 서류(해외출신자·학교밖 학습경험 등)' },
]

const INITIAL_FORM = {
  name: '',
  eligibilityCategory: 'enrolled',
  currentSchool: '',
  currentGrade: '고1',
  receiptDate: '',
  trackingNo: '',
  staffMemo: '',
  gender: '',
  birthDate: '',
  applicantPhone: '',
  email: '',
  address: '',
  guardianName: '',
  guardianRelation: '',
  guardianPhone: '',
  withdrawalDate: '',
  altSchoolName: '',
  staffNote: '',
}

export default function TransferRegisterForm({ onRegistered, onCancel }) {
  const [form, setForm] = useState(INITIAL_FORM)
  const [checklist, setChecklist] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }))
  const toggleDoc = (key) => setChecklist((c) => ({ ...c, [key]: !c[key] }))

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)

    if (!form.receiptDate) {
      setError('접수일(등기 도착일)을 입력해주세요.')
      return
    }
    setSubmitting(true)

    const { data, error: rpcError } = await supabase.rpc('register_transfer_applicant', {
      p_name: form.name,
      p_eligibility_category: form.eligibilityCategory,
      p_receipt_date: form.receiptDate,
      p_current_school: form.currentSchool || null,
      p_current_grade: form.currentGrade || null,
      p_tracking_no: form.trackingNo || null,
      p_document_checklist: checklist,
      p_staff_memo: form.staffMemo || null,
      p_gender: form.gender || null,
      p_birth_date: form.birthDate || null,
      p_applicant_phone: form.applicantPhone || null,
      p_email: form.email || null,
      p_address: form.address || null,
      p_guardian_name: form.guardianName || null,
      p_guardian_relation: form.guardianRelation || null,
      p_guardian_phone: form.guardianPhone || null,
      p_withdrawal_date: form.withdrawalDate || null,
      p_alt_school_name: form.altSchoolName || null,
      p_staff_note: form.staffNote || null,
    })

    setSubmitting(false)

    if (rpcError) {
      setError(rpcError.message)
      return
    }

    setForm(INITIAL_FORM)
    setChecklist({})
    onRegistered?.(data) // { applicantId, receiptNo }
  }

  const inputCls =
    'w-full rounded-md border border-border px-3 py-2 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500'
  const labelCls = 'mb-1 block text-sm font-medium text-ink-secondary'

  const isWithdrawn = form.eligibilityCategory === 'withdrawn'
  const isAltSchool = form.eligibilityCategory === 'altSchool'

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">지원자 기본 정보</h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>성명 *</label>
            <input required value={form.name} onChange={set('name')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>성별</label>
            <select value={form.gender} onChange={set('gender')} className={inputCls}>
              <option value="">선택</option>
              <option value="남">남</option>
              <option value="여">여</option>
            </select>
          </div>
          <div>
            <label className={labelCls}>생년월일</label>
            <input type="date" value={form.birthDate} onChange={set('birthDate')} className={inputCls} />
          </div>
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">지원자격 (요강 3번)</h3>
        <div className="flex flex-col gap-2">
          {[
            { value: 'enrolled', label: '가. 고등학교 1학년 재학 중인 자' },
            { value: 'withdrawn', label: '나-1. 고1 재학 중 자퇴 — 잔여 수업일수 합산으로 진급 기준 충족 가능' },
            { value: 'altSchool', label: '나-2. 대안학교 등에서 학점 인정받아 전·편입' },
          ].map((opt) => (
            <label key={opt.value} className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="eligibilityCategory"
                value={opt.value}
                checked={form.eligibilityCategory === opt.value}
                onChange={set('eligibilityCategory')}
              />
              {opt.label}
            </label>
          ))}
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">전적교 정보</h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>전적교(현재/최종 재학 학교)</label>
            <input value={form.currentSchool} onChange={set('currentSchool')} className={inputCls} placeholder="○○고등학교" />
          </div>
          <div>
            <label className={labelCls}>학년</label>
            <input value={form.currentGrade} onChange={set('currentGrade')} className={inputCls} placeholder="고1" />
          </div>
          {isWithdrawn && (
            <div>
              <label className={labelCls}>자퇴일자</label>
              <input type="date" value={form.withdrawalDate} onChange={set('withdrawalDate')} className={inputCls} />
            </div>
          )}
          {isAltSchool && (
            <div>
              <label className={labelCls}>대안학교명(전적교와 다를 경우)</label>
              <input value={form.altSchoolName} onChange={set('altSchoolName')} className={inputCls} />
            </div>
          )}
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">접수 정보 (우편·등기 접수만 가능)</h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>접수일(등기 도착일) *</label>
            <input required type="date" value={form.receiptDate} onChange={set('receiptDate')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>등기 송장번호(선택)</label>
            <input value={form.trackingNo} onChange={set('trackingNo')} className={inputCls} />
          </div>
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">제출서류 확인(도착분 체크)</h3>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          {DOCUMENT_ITEMS.map((item) => (
            <label key={item.key} className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={Boolean(checklist[item.key])} onChange={() => toggleDoc(item.key)} />
              {item.label}
            </label>
          ))}
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">연락처</h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>지원자 휴대전화</label>
            <input value={form.applicantPhone} onChange={set('applicantPhone')} className={inputCls} placeholder="010-0000-0000" />
          </div>
          <div>
            <label className={labelCls}>이메일</label>
            <input type="email" value={form.email} onChange={set('email')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>주소</label>
            <input value={form.address} onChange={set('address')} className={inputCls} />
          </div>
        </div>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">보호자</h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>성명</label>
            <input value={form.guardianName} onChange={set('guardianName')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>관계</label>
            <input value={form.guardianRelation} onChange={set('guardianRelation')} className={inputCls} placeholder="모" />
          </div>
          <div>
            <label className={labelCls}>휴대전화</label>
            <input value={form.guardianPhone} onChange={set('guardianPhone')} className={inputCls} />
          </div>
        </div>
      </div>

      <div>
        <label className={labelCls}>직원 메모(전화·이메일 문의 내용 등)</label>
        <textarea
          value={form.staffMemo}
          onChange={set('staffMemo')}
          className={`${inputCls} min-h-[70px]`}
          placeholder="예: 7/11 학부모 전화 문의 — 대안학교 재학 중, 서류 준비 안내함"
        />
      </div>

      {error && (
        <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>
      )}

      <div className="flex justify-end gap-2 border-t pt-4">
        {onCancel && (
          <button
            type="button"
            onClick={onCancel}
            className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle"
          >
            취소
          </button>
        )}
        <button
          type="submit"
          disabled={submitting}
          className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
        >
          {submitting ? '등록 처리 중…' : '접수 등록'}
        </button>
      </div>
    </form>
  )
}
