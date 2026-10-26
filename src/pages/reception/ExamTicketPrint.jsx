// 수험표 출력 (2026-09-04 추가, 2026-09-28 개정: 본체 분리·PDF 저장)
//
// 발급 시점: 원서 접수 지침에 따라 수험번호는 접수 마감 후 성명 가나다순으로
// 일괄 부여된다(assign_exam_numbers, 00067). 수험표는 전형 당일 접수처에서
// 신분 확인 후 배부한다(2026-09-28 결정 — 문자나라 상품이 이미지 문자를 지원하지
// 않고 서버가 내부망 전용이라 온라인 발송은 하지 않는다).
//
// 사진은 접수 때 스캔해 둔 photo 문서를 그대로 쓴다. 사진이 없으면 발급을
// 막는다(2026-09-04 결정) — 사진 없는 수험표가 섞이면 현장에서 본인 확인이
// 어려워지기 때문이다.
//
// 면접 일시·장소는 넣지 않는다(2026-09-04 결정).
//
// 서식 본체는 ExamTicketSheet — 일괄 인쇄(ExamTicketBulkPrint)와 공유한다.

import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { loadApplicantPhoto } from '../../lib/applicantPhoto'
import { downloadElementAsPdf } from '../../lib/pdfExport'
import ExamTicketSheet from './ExamTicketSheet'

export default function ExamTicketPrint() {
  const { applicantId } = useParams()
  const [applicant, setApplicant] = useState(null)
  const [examNo, setExamNo] = useState(null)
  const [photoUrl, setPhotoUrl] = useState(null)
  const [photoMissing, setPhotoMissing] = useState(false)
  const [photoError, setPhotoError] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [savingPdf, setSavingPdf] = useState(false)
  const sheetRef = useRef(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)

    const [{ data: app, error: appErr }, { data: roster }] = await Promise.all([
      supabase
        .from('applicants')
        .select('id, year, round, receipt_no, name, name_english, nationality, tracks, school, academic_status, exam_no')
        .eq('id', applicantId)
        .maybeSingle(),
      supabase
        .from('evaluation_roster')
        .select('exam_no')
        .eq('applicant_id', applicantId)
        .maybeSingle(),
    ])

    if (appErr || !app) {
      setError(appErr?.message || '지원자를 찾을 수 없습니다.')
      setLoading(false)
      return
    }

    setApplicant(app)
    setExamNo(app.exam_no || roster?.exam_no || null)

    // 사진 문제는 화면 자체를 못 열 사유가 아니므로 안내 패널에만 표시한다.
    const photo = await loadApplicantPhoto(applicantId)
    if (photo.url) setPhotoUrl(photo.url)
    else {
      setPhotoMissing(true)
      if (photo.error) setPhotoError(photo.error)
    }

    setLoading(false)
  }, [applicantId])

  useEffect(() => {
    load()
  }, [load])

  // blob 주소 정리
  useEffect(() => () => {
    if (photoUrl) URL.revokeObjectURL(photoUrl)
  }, [photoUrl])

  async function handlePdf() {
    if (!sheetRef.current) return
    setSavingPdf(true)
    try {
      await downloadElementAsPdf(sheetRef.current, `수험표_${examNo}_${applicant.name}.pdf`)
    } catch (err) {
      alert(`PDF를 만들지 못했습니다.\n${err.message}`)
    } finally {
      setSavingPdf(false)
    }
  }

  if (loading) return <p className="p-10 text-center text-ink-muted">불러오는 중…</p>
  if (error) return <p className="p-10 text-center text-status-danger">{error}</p>
  if (!applicant) return null

  const blocked = !examNo || photoMissing

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-8 print:min-h-0 print:bg-white print:p-0">
      <div className="mx-auto w-fit">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3 print:hidden">
          <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">
            ← 지원자 목록
          </Link>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={handlePdf}
              disabled={blocked || savingPdf}
              className="rounded-md border border-border bg-white px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-40"
            >
              {savingPdf ? 'PDF 만드는 중…' : 'PDF 저장'}
            </button>
            <button
              type="button"
              onClick={() => window.print()}
              disabled={blocked}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
            >
              수험표 인쇄
            </button>
          </div>
        </div>

        {blocked && (
          <div className="mb-4 rounded-lg border border-status-warning bg-status-warningSoft p-4 text-sm text-status-warning print:hidden">
            <p className="font-semibold">아직 수험표를 발급할 수 없습니다.</p>
            <ul className="mt-2 list-inside list-disc space-y-1">
              {!examNo && (
                <li>
                  수험번호가 아직 부여되지 않았습니다. 원서 접수 마감 후 지원자 목록의
                  &lsquo;수험번호 일괄 부여&rsquo;를 실행하면 성명 가나다순으로 부여됩니다.
                </li>
              )}
              {photoMissing && (
                <li>
                  {photoError
                    || '지원자 사진이 등록되지 않았습니다. 지원자 상세 → 서류 관리에서 ‘지원자 사진’을 먼저 업로드하세요.'}
                </li>
              )}
            </ul>
          </div>
        )}

        <div ref={sheetRef} className="w-fit">
          <ExamTicketSheet applicant={applicant} examNo={examNo} photoUrl={photoUrl} />
        </div>

        <p className="mt-3 text-center text-xs text-ink-muted print:hidden">
          실제 크기로 뽑으려면 인쇄 창의 배율을 &lsquo;기본값(100%)&rsquo;으로 두세요(&lsquo;페이지에 맞춤&rsquo; 해제).
        </p>
      </div>
    </div>
  )
}
