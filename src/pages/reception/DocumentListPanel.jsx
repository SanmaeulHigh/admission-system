// 지원자별 제출서류 목록 (2026-09-16 추가)
//
// 그동안 "서류 관리" 화면에는 업로드 폼만 있고 이미 올린 서류를 보여주는 곳이
// 없었다. 그래서 올리고 나면 제대로 들어갔는지 확인할 방법이 없었고, 같은
// 서류를 중복으로 올리거나 빠뜨려도 알 수 없었다.
//
// 2026-09-16: 잘못 올린 서류를 내리는 기능을 추가했다. 행을 실제로 지우지는
// 않고 active=false로 내린다(deactivate_admission_document RPC) — 입시 서류는
// "언제 무엇이 올라왔고 언제 내려갔는가"가 이의제기·감사의 근거가 되므로
// 흔적을 없애는 대신 감추고 사유를 남긴다. 내려간 문서는 평가위원 열람·수험표
// 조회를 포함한 모든 화면에서 즉시 사라지고 서명 URL도 더는 발급되지 않는다.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { getDocumentViewUrl } from '../../lib/documentAccess'
import DocumentUrlView from '../../components/pdf/DocumentUrlView'

const DOCUMENT_TYPE_LABEL = {
  applicationForm: '입학원서',
  studentRecordSource: '학생부 (전체)',
  studentRecordAttendanceView: '학생부(출결 발췌)',
  studentRecordAcademicView: '학생부(학업 발췌)',
  studentRecordCommunityView: '학생부(공동체 발췌)',
  essay: '자기소개서',
  opinion: '학부모 소견서',
  portfolio: '포트폴리오',
  writingAnswer: '글쓰기 답안',
  trackEvidence: '전형 자격 증빙',
  consent: '동의서',
  photo: '지원자 사진',
}

const CLASSIFICATION_LABEL = {
  adminOnly: '관리자 전용',
  reception: '접수담당 이상',
  evaluation: '평가위원',
}

function formatSize(bytes) {
  if (!bytes) return '-'
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)}KB`
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`
}

function formatDate(iso) {
  return new Date(iso).toLocaleString('ko-KR', {
    month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit',
  })
}

export default function DocumentListPanel({ applicantId, refreshKey }) {
  const [documents, setDocuments] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [openingId, setOpeningId] = useState(null)
  const [viewing, setViewing] = useState(null) // { url, label }
  const [removeTarget, setRemoveTarget] = useState(null) // 내리기 확인 중인 문서
  const [removeReason, setRemoveReason] = useState('')
  const [removing, setRemoving] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase
      .from('admission_documents')
      .select('id, document_type, mime_type, file_size, classification, active, uploaded_at')
      .eq('applicant_id', applicantId)
      .eq('active', true)
      .order('uploaded_at', { ascending: false })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setDocuments(data || [])
  }, [applicantId])

  useEffect(() => {
    load()
  }, [load, refreshKey])

  // 화면 위 창으로 보기 — 서명 URL은 만료가 있으므로 누를 때마다 새로 발급받는다.
  // 2026-10-25: 예전엔 새 탭(window.open)으로 열었는데, 열람 기록 RPC를 기다린 뒤 여는 탓에
  // 브라우저가 팝업으로 막아 PDF·사진 모두 안 열렸다. 같은 화면 위 창 + pdf.js로 바꿨다.
  const openDocument = async (doc) => {
    setOpeningId(doc.id)
    setError(null)
    try {
      const { url } = await getDocumentViewUrl(doc.id)
      setViewing({ url, label: DOCUMENT_TYPE_LABEL[doc.document_type] || doc.document_type })
    } catch (err) {
      setError(err.message)
    } finally {
      setOpeningId(null)
    }
  }

  const confirmRemove = async () => {
    if (!removeTarget) return
    setRemoving(true)
    setError(null)
    const { error: err } = await supabase.rpc('deactivate_admission_document', {
      p_document_id: removeTarget.id,
      p_reason: removeReason.trim(),
    })
    setRemoving(false)
    if (err) {
      setError(err.message)
      return
    }
    setRemoveTarget(null)
    setRemoveReason('')
    await load()
  }

  return (
    <div>
      <div className="mb-2 flex items-center justify-between">
        <h4 className="text-sm font-semibold text-ink-primary">
          올린 서류 {documents.length > 0 && <span className="text-ink-muted">({documents.length}건)</span>}
        </h4>
        <button
          type="button"
          onClick={load}
          className="text-xs text-ink-muted underline hover:text-ink-secondary"
        >
          새로고침
        </button>
      </div>

      {error && (
        <p className="mb-2 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>
      )}

      {loading ? (
        <p className="py-3 text-center text-xs text-ink-muted">불러오는 중…</p>
      ) : documents.length === 0 ? (
        <p className="rounded-md border border-dashed border-border px-3 py-4 text-center text-xs text-ink-muted">
          아직 올린 서류가 없습니다.
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border">
          {documents.map((doc) => (
            <li key={doc.id} className="flex items-center justify-between gap-2 px-3 py-2">
              <div className="min-w-0">
                <p className="truncate text-sm text-ink-primary">
                  {DOCUMENT_TYPE_LABEL[doc.document_type] || doc.document_type}
                  {doc.mime_type?.startsWith('image/') && (
                    <span className="ml-1.5 rounded bg-surface-subtle px-1.5 py-0.5 text-[10px] text-ink-muted">
                      이미지
                    </span>
                  )}
                </p>
                <p className="text-[11px] text-ink-muted">
                  {formatDate(doc.uploaded_at)} · {formatSize(doc.file_size)} ·{' '}
                  {CLASSIFICATION_LABEL[doc.classification] || doc.classification}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-1.5">
                <button
                  type="button"
                  onClick={() => openDocument(doc)}
                  disabled={openingId === doc.id}
                  className="rounded-md border border-border px-2.5 py-1 text-xs text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                >
                  {openingId === doc.id ? '여는 중…' : '보기'}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setRemoveTarget(doc)
                    setRemoveReason('')
                    setError(null)
                  }}
                  className="rounded-md border border-status-danger px-2.5 py-1 text-xs text-status-danger hover:bg-status-dangerSoft"
                >
                  내리기
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {/* 내리기 확인 */}
      {removeTarget && (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-sm rounded-lg border-2 border-status-danger bg-surface-card p-5">
            <h4 className="text-sm font-semibold text-ink-primary">이 서류를 내리시겠습니까?</h4>
            <p className="mt-2 text-xs text-ink-secondary">
              <strong>{DOCUMENT_TYPE_LABEL[removeTarget.document_type] || removeTarget.document_type}</strong>
              {' '}({formatDate(removeTarget.uploaded_at)})
            </p>
            <p className="mt-2 text-xs text-ink-muted">
              내린 서류는 평가위원 열람과 수험표를 포함한 모든 화면에서 즉시 사라집니다.
              다만 기록 자체는 감사 로그에 남습니다 — 나중에 이의제기가 있을 때
              언제 무엇이 올라왔다 내려갔는지 확인할 수 있어야 하기 때문입니다.
            </p>
            <label className="mt-3 block text-xs font-medium text-ink-secondary">
              내리는 사유
              <input
                value={removeReason}
                onChange={(e) => setRemoveReason(e.target.value)}
                placeholder="예: 잘못된 파일 업로드"
                className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                autoFocus
              />
            </label>

            {error && (
              <p className="mt-2 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>
            )}

            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setRemoveTarget(null)}
                className="rounded-md border border-border px-3 py-1.5 text-sm text-ink-secondary hover:bg-surface-subtle"
              >
                취소
              </button>
              <button
                type="button"
                onClick={confirmRemove}
                disabled={removing || removeReason.trim().length < 2}
                className="rounded-md bg-status-danger px-3 py-1.5 text-sm font-semibold text-white hover:opacity-90 disabled:opacity-40"
              >
                {removing ? '처리 중…' : '내리기'}
              </button>
            </div>
          </div>
        </div>
      )}
      {viewing && (
        <div className="fixed inset-0 z-[80] flex flex-col bg-black/70 p-4" role="dialog" aria-modal="true" aria-label={viewing.label}>
          <div className="flex items-center justify-between rounded-t-lg bg-white px-4 py-2">
            <p className="text-sm font-semibold text-ink-primary">{viewing.label} <span className="ml-1 font-normal text-ink-muted">(열람 기록이 남습니다)</span></p>
            <button type="button" onClick={() => setViewing(null)} className="rounded-md bg-brand-deepGreen px-4 py-1.5 text-sm font-semibold text-white">닫기</button>
          </div>
          <div className="min-h-0 w-full flex-1 overflow-hidden rounded-b-lg bg-surface-subtle">
            <DocumentUrlView url={viewing.url} alt={viewing.label} />
          </div>
        </div>
      )}
    </div>
  )
}
