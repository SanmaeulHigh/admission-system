// 평가서류 업로드 (M2, reception/admin/superadmin 전용)
//
// Sprint 2 범위: 지원자 1명씩 수동 선택 업로드. 스펙 1237행의 "정식
// 접수번호 기반 파일명 자동 매칭 일괄 업로드"는 후속 작업으로 남긴다
// (여기서는 신뢰할 수 있는 최소 경로부터 확실히 동작시키는 걸 우선함).
//
// 순서: ① Storage에 파일 업로드 → ② register_admission_document RPC로
// 메타데이터 등록. ①만 성공하고 ②가 실패하면 "메타데이터 없는 고아
// 파일"이 남는데, 그 파일은 admission_documents에 없으므로 storage RLS
// select 정책상 아무도(업로더 본인 포함) 다시 열람할 수 없다 — 안전한
// 실패 모드다. 실패 시 안내 문구로 재시도를 유도한다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

// 전 평가영역 — 사진처럼 특정 채점영역에 매이지 않는 문서는 이 전체를 준다.
const ALL_AREAS = ['attendance', 'academic', 'community', 'essay', 'opinion', 'group', 'interview', 'writing']

const DOCUMENT_TYPE_OPTIONS = [
  { value: 'applicationForm', label: '입학원서', defaultClassification: 'reception' },
  // 사진은 스캔본이라 이미지로 들어온다(다른 서류는 전부 PDF).
  {
    value: 'photo',
    label: '지원자 사진 (증명사진 스캔)',
    defaultClassification: 'evaluation',
    defaultAreas: ALL_AREAS,
    image: true,
  },
  // 2026-09-16: 영역별 발췌본 3종을 만드는 업무 부담이 커서, 학생부를 전체
  // 1건으로 올리고 출결·학업·공동체 채점자가 함께 보도록 바꿨다.
  // 자소서·소견서 담당 위원에게는 주지 않으므로 배정영역을 이 셋으로 한정한다.
  {
    value: 'studentRecordSource',
    label: '학생부 (전체 — 출결·학업·공동체 채점용)',
    defaultClassification: 'evaluation',
    defaultAreas: ['attendance', 'academic', 'community'],
  },
  { value: 'essay', label: '자기소개서', defaultClassification: 'evaluation', defaultAreas: ['essay'] },
  { value: 'opinion', label: '학부모 소견서', defaultClassification: 'evaluation', defaultAreas: ['opinion'] },
  { value: 'portfolio', label: '포트폴리오', defaultClassification: 'evaluation', defaultAreas: ['interview'] },
  { value: 'writingAnswer', label: '글쓰기 답안', defaultClassification: 'evaluation', defaultAreas: ['writing'] },
  { value: 'trackEvidence', label: '전형 자격 증빙', defaultClassification: 'reception' },
  { value: 'consent', label: '동의서', defaultClassification: 'reception' },
]

const AREA_OPTIONS = ['attendance', 'academic', 'community', 'essay', 'opinion', 'group', 'interview', 'writing']

const ACCEPTED_IMAGE_TYPES = ['image/jpeg', 'image/png']

export default function DocumentUploadForm({ applicantId, receiptNo, onUploaded }) {
  const [documentType, setDocumentType] = useState('essay')
  const [classification, setClassification] = useState('evaluation')
  const [accessAreas, setAccessAreas] = useState(['essay'])
  const [file, setFile] = useState(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)
  const [success, setSuccess] = useState(null)

  const isImageType = DOCUMENT_TYPE_OPTIONS.find((o) => o.value === documentType)?.image === true

  const handleTypeChange = (value) => {
    setDocumentType(value)
    const opt = DOCUMENT_TYPE_OPTIONS.find((o) => o.value === value)
    setClassification(opt?.defaultClassification || 'evaluation')
    setAccessAreas(opt?.defaultAreas || [])
  }

  const toggleArea = (area) => {
    setAccessAreas((prev) =>
      prev.includes(area) ? prev.filter((a) => a !== area) : [...prev, area]
    )
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)
    setSuccess(null)

    if (!file) {
      setError('파일을 선택하세요.')
      return
    }
    // 사진만 이미지(JPG/PNG)를 허용한다. 나머지 서류는 기존대로 PDF 전용.
    if (isImageType) {
      if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) {
        setError('사진은 JPG 또는 PNG 파일만 업로드할 수 있습니다.')
        return
      }
    } else if (file.type !== 'application/pdf') {
      setError('PDF 파일만 업로드할 수 있습니다.')
      return
    }
    if (classification === 'evaluation' && accessAreas.length === 0) {
      setError('평가용 문서는 배정영역을 1개 이상 선택해야 합니다.')
      return
    }

    setSubmitting(true)
    try {
      const ext = isImageType ? (file.type === 'image/png' ? 'png' : 'jpg') : 'pdf'
      const storagePath = `${applicantId}/${documentType}_${Date.now()}.${ext}`

      const { error: uploadError } = await supabase.storage
        .from('admission-documents')
        .upload(storagePath, file, { contentType: file.type, upsert: false })
      if (uploadError) throw uploadError

      const { error: rpcError } = await supabase.rpc('register_admission_document', {
        p_applicant_id: applicantId,
        p_document_type: documentType,
        p_storage_path: storagePath,
        p_classification: classification,
        p_access_areas: classification === 'evaluation' ? accessAreas : [],
        p_mime_type: file.type,
        p_file_size: file.size,
      })
      if (rpcError) throw rpcError

      setSuccess(`업로드 완료: ${DOCUMENT_TYPE_OPTIONS.find((o) => o.value === documentType)?.label}`)
      setFile(null)
      onUploaded?.()
    } catch (err) {
      setError(err.message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <p className="text-xs text-ink-muted">
        접수번호 <span className="font-mono">{receiptNo}</span> 지원자에게 서류를 업로드합니다.
      </p>

      <div>
        <label className="mb-1 block text-sm font-medium text-ink-secondary">서류 종류</label>
        <select
          value={documentType}
          onChange={(e) => handleTypeChange(e.target.value)}
          className="w-full rounded-md border border-border px-3 py-2 text-sm"
        >
          {DOCUMENT_TYPE_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium text-ink-secondary">공개 범위</label>
        <select
          value={classification}
          onChange={(e) => setClassification(e.target.value)}
          className="w-full rounded-md border border-border px-3 py-2 text-sm"
        >
          <option value="adminOnly">관리자 전용</option>
          <option value="reception">접수담당 이상</option>
          <option value="evaluation">평가위원(배정영역만)</option>
        </select>
      </div>

      {classification === 'evaluation' && (
        <div>
          <label className="mb-1 block text-sm font-medium text-ink-secondary">배정영역 (해당 영역 위원만 열람)</label>
          <div className="flex flex-wrap gap-2">
            {AREA_OPTIONS.map((area) => (
              <label key={area} className="flex items-center gap-1 text-xs">
                <input
                  type="checkbox"
                  checked={accessAreas.includes(area)}
                  onChange={() => toggleArea(area)}
                />
                {area}
              </label>
            ))}
          </div>
        </div>
      )}

      <div>
        <label className="mb-1 block text-sm font-medium text-ink-secondary">
          {isImageType ? '사진 파일 (JPG · PNG)' : 'PDF 파일'}
        </label>
        <input
          type="file"
          accept={isImageType ? ACCEPTED_IMAGE_TYPES.join(',') : 'application/pdf'}
          onChange={(e) => setFile(e.target.files?.[0] || null)}
          className="w-full text-sm"
        />
        {isImageType && (
          <p className="mt-1 text-xs text-ink-muted">
            여권용 3.5 × 4.5cm 증명사진을 스캔해 올립니다. 수험표 발급에 사용됩니다.
          </p>
        )}
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {success && <p className="rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">{success}</p>}

      <button
        type="submit"
        disabled={submitting}
        className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
      >
        {submitting ? '업로드 중…' : '업로드'}
      </button>
    </form>
  )
}
