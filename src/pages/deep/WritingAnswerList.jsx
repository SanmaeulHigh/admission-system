// 글쓰기 답안 업로드 목록 (2026-10-01)
//
// 예전에는 글쓰기 답안을 지원자 목록 › 서류 관리에서 한 명씩 찾아 올려야 했다.
// 시험 당일 답안을 스캔해 수험번호 순으로 바로 올릴 수 있도록 글쓰기 준비
// 화면 안에 목록을 둔다. 서류 종류·공개 범위·열람 영역은 고정값으로 넣는다.
//
// 교체: 새 답안을 먼저 올린 뒤 이전 답안을 내린다(deactivate_admission_document).
// 순서를 거꾸로 하면 중간에 실패했을 때 답안이 하나도 없는 상태가 될 수 있다.

import { useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { getDocumentViewUrl } from '../../lib/documentAccess'

async function uploadWritingAnswer(applicantId, file) {
  const storagePath = `${applicantId}/writingAnswer_${Date.now()}.pdf`
  const { error: uploadError } = await supabase.storage
    .from('admission-documents')
    .upload(storagePath, file, { contentType: 'application/pdf', upsert: false })
  if (uploadError) throw uploadError
  const { error: rpcError } = await supabase.rpc('register_admission_document', {
    p_applicant_id: applicantId,
    p_document_type: 'writingAnswer',
    p_storage_path: storagePath,
    p_classification: 'evaluation',
    p_access_areas: ['writing'],
    p_mime_type: 'application/pdf',
    p_file_size: file.size,
  })
  if (rpcError) throw rpcError
}

export default function WritingAnswerList({ candidates, finalized, onChanged }) {
  const inputRef = useRef(null)
  const [target, setTarget] = useState(null) // 파일을 고르는 중인 지원자
  const [busyId, setBusyId] = useState(null)
  const [error, setError] = useState(null)
  const [message, setMessage] = useState(null)

  const pickFile = (candidate) => {
    if (candidate.answerDocumentId) {
      const warn = finalized ? '\n글쓰기 계획이 이미 확정되어, 위원이 채점 중일 수 있습니다.' : ''
      // eslint-disable-next-line no-alert
      if (!window.confirm(`${candidate.examNo || ''} ${candidate.displayName}의 답안을 새 파일로 교체할까요?\n이전 답안은 내려가고 기록에 남습니다.${warn}`)) return
    }
    setTarget(candidate)
    setError(null)
    setMessage(null)
    inputRef.current.value = ''
    inputRef.current.click()
  }

  const handleFile = async (event) => {
    const file = event.target.files?.[0]
    const candidate = target
    setTarget(null)
    if (!file || !candidate) return
    if (file.type !== 'application/pdf') {
      setError('글쓰기 답안은 PDF 파일만 올릴 수 있습니다. 스캔할 때 PDF로 저장해 주세요.')
      return
    }
    setBusyId(candidate.applicantId)
    try {
      await uploadWritingAnswer(candidate.applicantId, file)
      if (candidate.answerDocumentId) {
        const { error: deactivateError } = await supabase.rpc('deactivate_admission_document', {
          p_document_id: candidate.answerDocumentId,
          p_reason: '글쓰기 답안 교체(새 파일 업로드)',
        })
        if (deactivateError) {
          throw new Error(`새 답안은 올렸지만 이전 답안을 내리지 못했습니다. 지원자 목록 › 서류 관리에서 이전 답안을 내려 주세요. (${deactivateError.message})`)
        }
      }
      setMessage(`${candidate.examNo || ''} ${candidate.displayName} 답안을 올렸습니다.`)
    } catch (err) {
      setError(err.message)
    } finally {
      setBusyId(null)
      onChanged?.()
    }
  }

  const viewAnswer = async (candidate) => {
    setError(null)
    // 팝업 차단을 피하려고 클릭 시점에 창을 먼저 연다.
    const w = window.open('', '_blank')
    try {
      const { url } = await getDocumentViewUrl(candidate.answerDocumentId)
      if (w) w.location.href = url
      else window.location.href = url
    } catch (err) {
      if (w) w.close()
      setError(err.message)
    }
  }

  const readyCount = candidates.filter((c) => c.answerDocumentId).length

  return (
    <div>
      <input ref={inputRef} type="file" accept="application/pdf" className="hidden" onChange={handleFile} />
      <p className="mb-2 text-xs text-ink-muted">
        스캔한 답안 PDF를 수험번호에 맞춰 올리세요. 올린 답안은 글쓰기 위원에게만 채점용으로 보입니다. ({readyCount} / {candidates.length} 준비)
      </p>
      {error && <p className="mb-3 rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</p>}
      {message && <p className="mb-3 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-3 text-sm text-brand-deepGreenStrong">{message}</p>}
      <div className="divide-y divide-border rounded-xl border border-border bg-surface-card">
        {candidates.map((candidate) => {
          const ready = Boolean(candidate.answerDocumentId)
          const busy = busyId === candidate.applicantId
          return (
            <div key={candidate.applicantId} className="flex items-center justify-between gap-3 px-5 py-3">
              <div className="flex min-w-0 items-center gap-4">
                <span className="w-16 shrink-0 font-mono text-sm font-semibold text-ink-primary">{candidate.examNo || '-'}</span>
                <span className="truncate text-sm font-semibold text-ink-primary">{candidate.displayName}</span>
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${ready ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-status-dangerSoft text-status-danger'}`}>
                  {ready ? '답안 있음' : '답안 없음'}
                </span>
                {ready && (
                  <button type="button" onClick={() => viewAnswer(candidate)} className="rounded-md border border-border px-3 py-1.5 text-xs text-ink-secondary hover:bg-surface-subtle">
                    보기
                  </button>
                )}
                <button
                  type="button"
                  onClick={() => pickFile(candidate)}
                  disabled={Boolean(busyId)}
                  className={`rounded-md px-3 py-1.5 text-xs font-semibold disabled:opacity-40 ${ready ? 'border border-border text-ink-secondary hover:bg-surface-subtle' : 'bg-brand-deepGreen text-white hover:bg-brand-deepGreenStrong'}`}
                >
                  {busy ? '올리는 중…' : ready ? '교체' : '답안 올리기'}
                </button>
              </div>
            </div>
          )
        })}
        {candidates.length === 0 && <p className="px-5 py-6 text-sm text-ink-muted">1단계 서류사정 합격자가 없습니다.</p>}
      </div>
    </div>
  )
}
