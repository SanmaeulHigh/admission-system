// M1 신규 수기접수 폼 (스펙 1226행 등록 폼 요구사항)
//
// 2026-07-14: 접수 담당자의 입력 실수를 고칠 수단이 없어서, 같은 폼을
// "수정 모드"로도 쓸 수 있게 확장했다(mode="edit" + applicantId +
// initialData 전달 시 update_applicant RPC를 호출). 필드 구성은 등록과
// 완전히 동일하므로 폼을 통째로 새로 만들지 않고 이 컴포넌트를 재사용한다.
//
// 2026-09-04: 2027학년도 전형 양식 최종본(서식 1 입학원서)이 확정되어,
// 화면 구성을 종이 원서와 같은 순서·같은 번호로 맞췄다.
//   ① 지원 전형  ② 지원자 인적사항  ③ 중학교 학적사항  ④ 보호자
// 접수 담당자가 종이 원서를 왼쪽에 놓고 위에서부터 순서대로 옮겨 적을 수
// 있게 하려는 것이다(칸 순서가 다르면 빠뜨리거나 잘못 옮기기 쉽다).
// "접수 방법"만 양식에 없는 시스템 고유 항목이라 맨 아래에 따로 뒀다.
//
// 주민등록번호는 받지 않는다 — 마스터스펙의 "주민번호 원본 비저장, 성별·
// 생년월일만 파생 저장" 원칙에 따른 것이다. 종이 원서에는 있지만 시스템에는
// 옮겨 적지 않는다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'
import AddressSearchField from '../../components/form/AddressSearchField'
import SchoolSearchField from '../../components/form/SchoolSearchField'
import CountrySearchField from '../../components/form/CountrySearchField'
import { findCountry } from '../../config/countries'

// 사진은 접수 창구에서 원서와 함께 받으므로, 별도 "서류 관리" 화면으로
// 다시 들어가지 않고 이 폼에서 바로 올린다. 지원자 id는 등록이 끝나야
// 생기므로 저장 성공 후에 이어서 업로드한다(아래 uploadPhoto 참고).
const PHOTO_AREAS = ['attendance', 'academic', 'community', 'essay', 'opinion', 'group', 'interview', 'writing']
const ACCEPTED_PHOTO_TYPES = ['image/jpeg', 'image/png']

// 가산점 사유는 배점 설정(config scoring_params.bonus.eligibleReasons)의
// 문자열과 정확히 일치해야 한다. 다르면 사정 엔진이 가산점을 적용하지 않는다.
const BONUS_REASONS = [
  { value: '농어민자녀', label: '농·어민 자녀' },
  { value: '강화군소재중학교졸업', label: '강화군 소재 중학교 졸업' },
]

const BLANK_FORM = {
  // ① 지원 전형
  specialTrack: 'none', // 'none' | 'incheon' | 'social' — 일반은 항상 포함
  bonusEligible: '', // '' = 미확인 | 'yes' | 'no'
  bonusReason: '',
  // ② 지원자 인적사항
  // nationalityType은 화면 전용 상태다(대한민국/외국 라디오). 실제 저장값은
  // nationality(ISO Alpha-3) 하나뿐이라, 둘을 분리하지 않으면 코드를 입력하는
  // 순간 "외국 국적" 선택이 풀려 입력란이 사라진다.
  nationalityType: 'KOR', // 'KOR' | 'FOREIGN'
  nationality: 'KOR',
  name: '',
  nameEnglish: '',
  gender: '',
  birthDate: '',
  applicantLandline: '',
  applicantPhone: '',
  email: '',
  address: '',
  // ③ 중학교 학적사항
  academicStatus: '졸업예정',
  school: '',
  gradeClassNo: '',
  semesterChoice: '3-1',
  // ④ 보호자
  guardianName: '',
  guardianRelation: '',
  guardianPhone: '',
  guardianAddress: '',
  // 시스템 고유
  receiptMethod: 'V',
  registeredMailNo: '', // 우편(등기) 접수 시 등기번호 (2026-10-12)
  receptionNote: '', // 접수대장 비고
}

// 수정 모드 진입 시: applicants + applicants_private 조인 데이터를
// 폼 상태 모양으로 변환한다.
function toFormState(initialData) {
  const private_ = Array.isArray(initialData.applicants_private)
    ? initialData.applicants_private[0]
    : initialData.applicants_private
  const tracks = initialData.tracks || ['general']
  const specialTrack = tracks.includes('incheon') ? 'incheon' : tracks.includes('social') ? 'social' : 'none'

  return {
    specialTrack,
    bonusEligible:
      initialData.bonus_eligible === true ? 'yes' : initialData.bonus_eligible === false ? 'no' : '',
    bonusReason: initialData.bonus_reason ?? '',
    nationalityType: (initialData.nationality ?? 'KOR') === 'KOR' ? 'KOR' : 'FOREIGN',
    nationality: initialData.nationality ?? 'KOR',
    name: initialData.name ?? '',
    nameEnglish: initialData.name_english ?? '',
    gender: private_?.gender ?? '',
    birthDate: private_?.birth_date ?? '',
    applicantLandline: private_?.applicant_landline ?? '',
    applicantPhone: private_?.applicant_phone ?? '',
    email: private_?.email ?? '',
    address: private_?.address ?? '',
    academicStatus: initialData.academic_status ?? '졸업예정',
    school: initialData.school ?? '',
    gradeClassNo: initialData.grade_class_no ?? '',
    semesterChoice: initialData.semester_choice ?? '3-1',
    guardianName: private_?.guardian_name ?? '',
    guardianRelation: private_?.guardian_relation ?? '',
    guardianPhone: private_?.guardian_phone ?? '',
    guardianAddress: private_?.guardian_address ?? '',
    receiptMethod: initialData.receipt_method ?? 'V',
    registeredMailNo: initialData.registered_mail_no ?? '',
    receptionNote: initialData.reception_note ?? '',
  }
}

export default function RegisterApplicantForm({
  year,
  round,
  onRegistered,
  onCancel,
  mode = 'create', // 'create' | 'edit'
  applicantId,
  initialData,
  onSaved,
  // 2026-10-20 스캔 먼저 접수: 미리 올려 둔 스캔 파일들. 등록(접수번호 채번)이 끝나면 이어서 저장한다.
  //   [{ key, documentType, label, file, classification, areas }]
  pendingDocuments = [],
  // 스캔 접수 화면에서는 사진도 1단계에서 받으므로 이 폼의 사진 칸을 숨긴다.
  hidePhotoInput = false,
}) {
  const isEdit = mode === 'edit'
  const [form, setForm] = useState(() => (isEdit && initialData ? toFormState(initialData) : BLANK_FORM))
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)
  const [photoFile, setPhotoFile] = useState(null)
  // 지원자 등록은 됐는데 사진 업로드만 실패한 경우를 알리기 위한 경고.
  // 이때 등록 자체를 되돌리지는 않는다 — 사진은 나중에 서류 관리에서 다시 올릴 수 있다.
  const [photoWarning, setPhotoWarning] = useState(null)

  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }))

  const isGed = form.academicStatus === '검정고시'
  const isIncheon = form.specialTrack === 'incheon'
  const isForeign = form.nationalityType === 'FOREIGN'

  // 사진 업로드 — 지원자 id가 확정된 뒤에 호출한다.
  // 실패해도 예외를 던지지 않고 사유 문자열을 돌려준다(등록 자체는 살린다).
  const uploadPhoto = async (targetApplicantId) => {
    if (!photoFile) return null
    try {
      const ext = photoFile.type === 'image/png' ? 'png' : 'jpg'
      const storagePath = `${targetApplicantId}/photo_${Date.now()}.${ext}`

      const { error: uploadError } = await supabase.storage
        .from('admission-documents')
        .upload(storagePath, photoFile, { contentType: photoFile.type, upsert: false })
      if (uploadError) return uploadError.message

      const { error: rpcError } = await supabase.rpc('register_admission_document', {
        p_applicant_id: targetApplicantId,
        p_document_type: 'photo',
        p_storage_path: storagePath,
        p_classification: 'evaluation',
        p_access_areas: PHOTO_AREAS,
        p_mime_type: photoFile.type,
        p_file_size: photoFile.size,
      })
      if (rpcError) return rpcError.message

      return null
    } catch (err) {
      return err.message
    }
  }

  // 미리 올려 둔 스캔 파일 저장 — 지원자 id가 확정된 뒤 하나씩. 실패한 서류 이름을 돌려준다.
  const uploadPendingDocuments = async (targetApplicantId) => {
    const failed = []
    for (const doc of pendingDocuments) {
      try {
        const isImage = doc.file.type.startsWith('image/')
        const ext = isImage ? (doc.file.type === 'image/png' ? 'png' : 'jpg') : 'pdf'
        const storagePath = `${targetApplicantId}/${doc.documentType}_${Date.now()}.${ext}`
        const { error: uploadError } = await supabase.storage
          .from('admission-documents')
          .upload(storagePath, doc.file, { contentType: doc.file.type, upsert: false })
        if (uploadError) throw uploadError
        const { error: rpcError } = await supabase.rpc('register_admission_document', {
          p_applicant_id: targetApplicantId,
          p_document_type: doc.documentType,
          p_storage_path: storagePath,
          p_classification: doc.classification,
          p_access_areas: doc.classification === 'evaluation' ? doc.areas : [],
          p_mime_type: doc.file.type,
          p_file_size: doc.file.size,
        })
        if (rpcError) throw rpcError
      } catch (err) {
        failed.push(`${doc.label}(${err.message})`)
      }
    }
    return failed
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)
    setPhotoWarning(null)

    // 가산점은 인천학생추천전형 지원자에게만 적용된다(사정 엔진 00008 조건).
    if (!isIncheon && form.bonusEligible === 'yes') {
      setError('가산점은 인천학생추천전형 지원자에게만 적용됩니다. 지원 전형을 확인해 주세요.')
      return
    }
    if (form.bonusEligible === 'yes' && !form.bonusReason) {
      setError('가산점 대상으로 표시하려면 사유를 선택해야 합니다.')
      return
    }
    if (isForeign && (!/^[A-Z]{3}$/.test(form.nationality) || !findCountry(form.nationality))) {
      setError('외국 국적이면 국적 칸에서 나라를 찾아 골라 주세요.')
      return
    }
    if (photoFile && !ACCEPTED_PHOTO_TYPES.includes(photoFile.type)) {
      setError('사진은 JPG 또는 PNG 파일만 올릴 수 있습니다.')
      return
    }

    setSubmitting(true)

    const tracks =
      form.specialTrack === 'none' ? ['general'] : ['general', form.specialTrack]

    const commonFields = {
      p_name: form.name,
      p_tracks: tracks,
      p_academic_status: form.academicStatus,
      p_receipt_method: form.receiptMethod,
      p_school: isGed ? null : form.school || null,
      p_grade_class_no: isGed ? null : form.gradeClassNo || null,
      p_semester_choice: form.semesterChoice || null,
      p_gender: form.gender || null,
      p_birth_date: form.birthDate || null,
      p_applicant_phone: form.applicantPhone || null,
      p_email: form.email || null,
      p_address: form.address || null,
      p_guardian_name: form.guardianName || null,
      p_guardian_relation: form.guardianRelation || null,
      p_guardian_phone: form.guardianPhone || null,
      p_guardian_address: form.guardianAddress || null,
      p_nationality: form.nationality || 'KOR',
      p_name_english: form.nameEnglish || null,
      p_applicant_landline: form.applicantLandline || null,
      p_bonus_eligible:
        form.bonusEligible === 'yes' ? true : form.bonusEligible === 'no' ? false : null,
      p_bonus_reason: form.bonusEligible === 'yes' ? form.bonusReason || null : null,
    }

    const { data, error: rpcError } = isEdit
      ? await supabase.rpc('update_applicant', { p_applicant_id: applicantId, ...commonFields })
      : await supabase.rpc('register_applicant', { p_year: year, p_round: round, ...commonFields })

    if (rpcError) {
      setSubmitting(false)
      setError(rpcError.message)
      return
    }

    // 등록·수정이 끝난 뒤 사진을 올린다(신규 등록은 이때야 지원자 id가 생긴다).
    const targetId = isEdit ? applicantId : data?.applicantId

    // 등기번호·비고는 별도 RPC로 저장한다(00081). 방문 접수면 등기번호는 비운다.
    if (targetId) {
      const { error: extraError } = await supabase.rpc('set_applicant_reception_extra', {
        p_applicant_id: targetId,
        p_registered_mail_no: form.receiptMethod === 'M' ? form.registeredMailNo : null,
        p_reception_note: form.receptionNote,
      })
      if (extraError) {
        setSubmitting(false)
        setError(
          `${isEdit ? '정보는 저장됐지만' : '지원자 등록은 완료됐지만'} 등기번호·비고 저장에 실패했습니다 (${extraError.message}). ` +
          '목록에서 해당 지원자를 더블클릭해 다시 저장해 주세요.',
        )
        if (!isEdit) onRegistered?.(data)
        return
      }
    }
    const photoError = targetId ? await uploadPhoto(targetId) : null
    const failedDocs = !isEdit && targetId && pendingDocuments.length > 0 ? await uploadPendingDocuments(targetId) : []

    setSubmitting(false)

    if (photoError) {
      // 등록은 성공했으므로 되돌리지 않고, 사진만 다시 올리도록 안내한다.
      setPhotoWarning(
        `지원자 등록은 완료되었지만 사진 업로드에 실패했습니다 (${photoError}). ` +
        '지원자 상세 → 서류 관리에서 사진만 다시 올려 주세요.',
      )
      setPhotoFile(null)
      if (isEdit) onSaved?.()
      return
    }

    if (isEdit) {
      onSaved?.()
    } else {
      setForm(BLANK_FORM)
      setPhotoFile(null)
      // failedDocs: 스캔 서류 중 저장에 실패한 것(지원자 상세 → 서류 관리에서 다시 올린다)
      onRegistered?.({ ...data, savedDocCount: pendingDocuments.length - failedDocs.length, failedDocs }) // { applicantId, receiptNo, ... }
    }
  }

  const inputCls =
    'w-full rounded-md border border-border px-3 py-2 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500'
  const labelCls = 'mb-1 block text-sm font-medium text-ink-secondary'
  const sectionCls = 'rounded-lg border border-border bg-surface-card p-4'

  const SectionTitle = ({ no, children, hint }) => (
    <div className="mb-3">
      <h3 className="flex items-center gap-2 text-sm font-semibold text-ink-primary">
        <span className="flex h-5 w-5 items-center justify-center rounded bg-brand-deepGreen text-xs font-bold text-white">
          {no}
        </span>
        {children}
      </h3>
      {hint && <p className="mt-1 text-xs text-ink-muted">{hint}</p>}
    </div>
  )

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <p className="rounded-md bg-surface-subtle px-3 py-2 text-xs text-ink-muted">
        종이 원서(서식 1 · 입학원서)와 같은 순서로 배치되어 있습니다. 원서 위에서부터 차례대로 옮겨 적으세요.
        주민등록번호는 시스템에 저장하지 않으므로 입력란이 없습니다 — 성별과 생년월일만 옮겨 적습니다.
      </p>

      {/* ── ① 지원 전형 ─────────────────────────────── */}
      <section className={sectionCls}>
        <SectionTitle no="1" hint="모든 지원자는 일반전형에 필수 지원하며, 자격 해당자는 특별전형 1개를 추가 선택합니다.">
          지원 전형
        </SectionTitle>
        <div className="flex flex-wrap gap-4">
          {[
            { value: 'none', label: '일반전형만' },
            { value: 'incheon', label: '일반 + 인천학생추천' },
            { value: 'social', label: '일반 + 사회통합' },
          ].map((opt) => (
            <label key={opt.value} className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="specialTrack"
                value={opt.value}
                checked={form.specialTrack === opt.value}
                onChange={set('specialTrack')}
              />
              {opt.label}
            </label>
          ))}
        </div>

        {form.specialTrack === 'social' && (
          <p className="mt-3 rounded-md bg-status-warningSoft px-3 py-2 text-xs text-status-warning">
            사회통합전형은 대상자 확인서(서식 6-1)와 학부모 서약서(서식 6-2), 증빙서류가 함께 제출되어야 합니다.
          </p>
        )}

        {/* 가산점 — 양식에서도 인천학생추천전형 칸 아래에 있고,
            사정 엔진도 인천전형 지원자에게만 적용한다. */}
        {isIncheon && (
          <div className="mt-4 rounded-md border border-border bg-surface-subtle p-3">
            <label className={labelCls}>가산점 (인천학생추천전형 한정)</label>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <select value={form.bonusEligible} onChange={set('bonusEligible')} className={inputCls}>
                <option value="">미확인 (증빙 확인 전)</option>
                <option value="yes">해당 — 증빙서류 확인함</option>
                <option value="no">해당 없음</option>
              </select>
              {form.bonusEligible === 'yes' && (
                <select value={form.bonusReason} onChange={set('bonusReason')} className={inputCls}>
                  <option value="">사유 선택</option>
                  {BONUS_REASONS.map((r) => (
                    <option key={r.value} value={r.value}>{r.label}</option>
                  ))}
                </select>
              )}
            </div>
            <p className="mt-2 text-xs text-ink-muted">
              증빙서류(농·어민 자녀 또는 강화군 소재 중학교 졸업)를 확인한 뒤 &lsquo;해당&rsquo;으로 표시하세요.
              미확인 상태로 두면 사정 시 가산점이 적용되지 않습니다.
            </p>
          </div>
        )}
      </section>

      {/* ── ② 지원자 인적사항 ────────────────────────── */}
      <section className={sectionCls}>
        <SectionTitle no="2">지원자 인적사항</SectionTitle>

        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>국적</label>
            <select
              value={form.nationalityType}
              onChange={(e) =>
                setForm((f) => ({
                  ...f,
                  nationalityType: e.target.value,
                  // 대한민국으로 되돌리면 코드도 KOR로 함께 맞춘다.
                  nationality: e.target.value === 'KOR' ? 'KOR' : f.nationality === 'KOR' ? '' : f.nationality,
                }))
              }
              className={inputCls}
            >
              <option value="KOR">대한민국 (KOR)</option>
              <option value="FOREIGN">외국 국적</option>
            </select>
          </div>
          {form.nationalityType === 'FOREIGN' && (
            <div>
              <label className={labelCls}>국적 (나라 찾기) *</label>
              {/* 2026-10-13: 외교부 국가표준코드에서 골라 ISO alpha-3 코드로 저장 */}
              <CountrySearchField
                value={form.nationality}
                onChange={(code) => setForm((f) => ({ ...f, nationality: code }))}
                className={inputCls}
                required
              />
            </div>
          )}
          <div>
            <label className={labelCls}>성명 (한글) *</label>
            <input required value={form.name} onChange={set('name')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>
              성명 (영문){isForeign && ' *'}
            </label>
            <input
              value={form.nameEnglish}
              onChange={set('nameEnglish')}
              className={inputCls}
              placeholder="HONG / GILDONG"
            />
          </div>
        </div>

        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
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

        {/* 사진 — 양식에서도 인적사항 우측에 부착란이 있다.
            원서와 함께 받은 증명사진을 스캔해 이 자리에서 바로 올린다. (스캔 먼저 접수에서는 1단계에서 받는다) */}
        <div className={`mt-3 rounded-md border border-border bg-surface-subtle p-3 ${hidePhotoInput ? 'hidden' : ''}`}>
          <label className={labelCls}>지원자 사진 (증명사진 스캔)</label>
          <div className="flex flex-wrap items-center gap-3">
            <input
              type="file"
              accept={ACCEPTED_PHOTO_TYPES.join(',')}
              onChange={(e) => setPhotoFile(e.target.files?.[0] || null)}
              className="text-sm"
            />
            {photoFile && (
              <button
                type="button"
                onClick={() => setPhotoFile(null)}
                className="text-xs text-ink-muted underline hover:text-ink-secondary"
              >
                선택 취소
              </button>
            )}
          </div>
          <p className="mt-1 text-xs text-ink-muted">
            여권용 3.5 × 4.5cm · JPG 또는 PNG · 수험표 발급에 사용됩니다.
            {isEdit && ' 새로 올리면 가장 최근 사진이 수험표에 쓰입니다.'}
            {' '}지금 올리지 않아도 나중에 지원자 상세 → 서류 관리에서 추가할 수 있습니다.
          </p>
        </div>

        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>전형기간 중 연락처 (유선)</label>
            <input
              value={form.applicantLandline}
              onChange={set('applicantLandline')}
              className={inputCls}
              placeholder="032-000-0000"
            />
          </div>
          <div>
            <label className={labelCls}>휴대전화 (지원자 본인)</label>
            <input
              value={form.applicantPhone}
              onChange={set('applicantPhone')}
              className={inputCls}
              placeholder="010-0000-0000"
            />
          </div>
          <div>
            <label className={labelCls}>E-mail</label>
            <input type="email" value={form.email} onChange={set('email')} className={inputCls} />
          </div>
        </div>
      </section>

      {/* ── ③ 중학교 학적사항 ────────────────────────── */}
      <section className={sectionCls}>
        <SectionTitle no="3" hint="해당하는 하나에만 기재합니다.">중학교 학적사항</SectionTitle>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-4">
          <div>
            <label className={labelCls}>학적상태 *</label>
            <select required value={form.academicStatus} onChange={set('academicStatus')} className={inputCls}>
              <option value="졸업예정">졸업예정</option>
              <option value="졸업">졸업</option>
              <option value="검정고시">검정고시</option>
              <option value="기타">기타</option>
            </select>
          </div>
          {!isGed && (
            <>
              <div>
                <label className={labelCls}>출신 중학교</label>
                {/* 2026-10-12: NEIS 학교 검색 제안(목록에 없으면 직접 입력) */}
                <SchoolSearchField
                  value={form.school}
                  onChange={(v) => setForm((f) => ({ ...f, school: v }))}
                  className={inputCls}
                />
              </div>
              <div>
                <label className={labelCls}>학년-반-번호</label>
                <input value={form.gradeClassNo} onChange={set('gradeClassNo')} className={inputCls} placeholder="3-2-15" />
              </div>
            </>
          )}
          <div>
            <label className={labelCls}>학업성실도 반영 희망 학기</label>
            {/* 원서에 적힌 학기를 고른다. 학업성실도 채점 화면에 그대로 표시된다. */}
            <select value={form.semesterChoice} onChange={set('semesterChoice')} className={inputCls}>
              <option value="">미기재</option>
              {['1-1', '1-2', '2-1', '2-2', '3-1', '3-2'].map((v) => (
                <option key={v} value={v}>{`${v[0]}학년 ${v[2]}학기`}</option>
              ))}
            </select>
          </div>
        </div>
        {isGed && (
          <p className="mt-3 text-xs text-ink-muted">
            검정고시 출신자는 담임교사 확인·중학교장 직인이 필요하지 않습니다. 합격증명서 제출 여부를 확인하세요.
          </p>
        )}
        {form.academicStatus === '졸업' && (
          <p className="mt-3 text-xs text-ink-muted">
            이미 졸업한 지원자는 담임교사 확인·중학교장 직인 대신 중학교 졸업증명서를 제출합니다.
          </p>
        )}
      </section>

      {/* ── ④ 보호자 ─────────────────────────────────── */}
      <section className={sectionCls}>
        <SectionTitle no="4">보호자</SectionTitle>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className={labelCls}>성명</label>
            <input value={form.guardianName} onChange={set('guardianName')} className={inputCls} />
          </div>
          <div>
            <label className={labelCls}>지원자와의 관계</label>
            <input value={form.guardianRelation} onChange={set('guardianRelation')} className={inputCls} placeholder="모" />
          </div>
          <div>
            <label className={labelCls}>휴대전화 (보호자)</label>
            <input value={form.guardianPhone} onChange={set('guardianPhone')} className={inputCls} />
          </div>
        </div>
        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
          <AddressSearchField
            label="주민등록상 주소 (우편번호 포함)"
            value={form.guardianAddress}
            onChange={(v) => setForm((f) => ({ ...f, guardianAddress: v }))}
            inputClassName={inputCls}
            labelClassName={labelCls}
            placeholder="주소 검색 후 상세주소를 이어서 입력"
          />
          <AddressSearchField
            label="지원자 주소 (보호자와 다를 경우)"
            value={form.address}
            onChange={(v) => setForm((f) => ({ ...f, address: v }))}
            inputClassName={inputCls}
            labelClassName={labelCls}
            placeholder="같으면 비워 두세요"
          />
        </div>
      </section>

      {/* ── 접수 방법 (양식에 없는 시스템 고유 항목) ──── */}
      <section className={sectionCls}>
        <h3 className="mb-3 text-sm font-semibold text-ink-primary">접수 방법</h3>
        <div className="flex gap-4">
          {[
            { value: 'V', label: '방문 (V)' },
            { value: 'M', label: '우편 (M)' },
          ].map((opt) => (
            <label key={opt.value} className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="receiptMethod"
                value={opt.value}
                checked={form.receiptMethod === opt.value}
                onChange={set('receiptMethod')}
              />
              {opt.label}
            </label>
          ))}
        </div>
        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
          {form.receiptMethod === 'M' && (
            <div>
              <label className={labelCls}>등기번호</label>
              <input
                value={form.registeredMailNo}
                onChange={set('registeredMailNo')}
                className={`${inputCls} font-mono`}
                placeholder="예: 1234567890123"
                inputMode="numeric"
              />
            </div>
          )}
          <div className={form.receiptMethod === 'M' ? 'sm:col-span-2' : 'sm:col-span-3'}>
            <label className={labelCls}>비고 (접수대장에 인쇄됩니다)</label>
            <input
              value={form.receptionNote}
              onChange={set('receptionNote')}
              className={inputCls}
              placeholder="예: 소견서 추후 제출 예정"
            />
          </div>
        </div>
      </section>

      {error && (
        <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>
      )}
      {photoWarning && (
        <p className="rounded-md bg-status-warningSoft px-3 py-2 text-sm text-status-warning">{photoWarning}</p>
      )}

      {/* 폼이 5개 구역으로 길어져서, 저장하려면 매번 맨 아래까지 스크롤해야 했다.
          화면 하단에 붙여 어디서든 바로 저장할 수 있게 한다. */}
      <div className="sticky bottom-0 -mx-1 flex items-center justify-between gap-3 border-t border-border bg-surface-card/95 px-1 py-3 backdrop-blur">
        <p className="text-xs text-ink-muted">
          {isEdit ? '고친 내용을 저장합니다.' : '저장하면 접수번호가 자동으로 부여됩니다.'}
        </p>
        <div className="flex shrink-0 gap-2">
          {onCancel && (
            <button
              type="button"
              onClick={onCancel}
              className="rounded-lg border border-border px-4 py-2.5 text-sm text-ink-secondary hover:bg-surface-subtle"
            >
              취소
            </button>
          )}
          <button
            type="submit"
            disabled={submitting}
            className="rounded-lg bg-brand-deepGreen px-6 py-2.5 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
          >
            {submitting ? '저장 중…' : isEdit ? '수정 저장' : '접수 등록'}
          </button>
        </div>
      </div>
    </form>
  )
}
