// 접수증 (스펙 1229행 "접수번호 자동 채번 + 접수증 PDF" 대응)
//
// 구현 방식: 별도 인쇄 전용 라우트에서 A4 서식만 렌더링 → 브라우저
// 인쇄(Ctrl+P) → "PDF로 저장"으로 PDF 산출물을 얻는다. Cloud Function
// 기반 PDF 생성이나 한글 폰트 임베딩 없이도 실제 결재·보관용 PDF를
// 만들 수 있어, Blaze 없는 이 프로젝트 제약과도 잘 맞는다.
//
// 스타일 원칙: 화면 미리보기와 인쇄 결과가 같아야 하므로 @media print에서
// 버튼류만 숨기고 본문은 그대로 유지한다.

import { useEffect, useRef, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { supabase, getEdgeFunctionErrorMessage } from '../../lib/supabase'
import { METHOD_LABEL, tracksToText } from '../../lib/applicantLabels'
import schoolSeal from '../../assets/schooi-seal.png'
import { downloadElementAsPdf, elementToPdfBlob } from '../../lib/pdfExport'
import QrCode from '../../components/print/QrCode'
import { ScheduleTable, NoteList, Contacts } from '../../components/print/NoticeBlocks'
import { getPrintNotices } from '../../config/printNotices'

export default function ReceiptPrint() {
  const { applicantId } = useParams()
  const [applicant, setApplicant] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [downloading, setDownloading] = useState(false)
  const [savingPdf, setSavingPdf] = useState(false)
  const [sendingSms, setSendingSms] = useState(false)
  const [sendingEmail, setSendingEmail] = useState(false)
  const [hideContacts, setHideContacts] = useState(false) // 메일용 판: 연락처 줄을 뺀다
  const receiptRef = useRef(null)

  async function handleDownloadPng() {
    if (!receiptRef.current) return
    setDownloading(true)
    try {
      const { default: html2canvas } = await import('html2canvas')
      const canvas = await html2canvas(receiptRef.current, {
        scale: 2, // 인쇄 품질에 준하는 고해상도로 캡처
        backgroundColor: '#ffffff',
        useCORS: true,
      })
      const dataUrl = canvas.toDataURL('image/png')
      const link = document.createElement('a')
      link.href = dataUrl
      link.download = `접수증_${applicant?.receipt_no ?? applicantId}.png`
      link.click()
    } finally {
      setDownloading(false)
    }
  }

  // PDF 저장 — 서식 폭이 180mm로 고정돼 있어 A4에 실제 크기로 들어간다(직인 2.4cm 유지).
  async function handleDownloadPdf() {
    if (!receiptRef.current) return
    setSavingPdf(true)
    try {
      await downloadElementAsPdf(receiptRef.current, `접수증_${applicant?.receipt_no ?? applicantId}.pdf`)
    } catch (err) {
      alert(`PDF를 만들지 못했습니다.\n${err.message}`)
    } finally {
      setSavingPdf(false)
    }
  }

  // 문자나라 웹연동 API는 텍스트(SMS/LMS)만 지원한다("그림문자 지원X" 확인됨,
  // 2026-07-14) — 접수증 이미지는 함께 보낼 수 없고, 접수 완료 사실만 안내한다.
  async function handleSendSms(targets) {
    setSendingSms(true)
    try {
      const { data, error: invokeErr } = await supabase.functions.invoke('send-receipt-sms', {
        body: { applicantId, targets },
      })
      if (invokeErr) {
        // 서버가 돌려준 실제 사유(권한·지원자 없음 등)를 보여 준다. 함수가 아예 없으면 상태 코드로.
        const status = invokeErr.context?.status
        const detail = await getEdgeFunctionErrorMessage(invokeErr, invokeErr.message)
        alert(`문자 발송 요청에 실패했습니다.${status ? ` (응답 ${status})` : ''}\n${detail}`)
        return
      }
      const results = data?.results ?? {}
      const reasonLabel = {
        not_configured: '문자 발송이 아직 설정되지 않았습니다(관리자 문의).',
        invalid_phone: '연락처가 없거나 형식이 올바르지 않습니다.',
      }
      const lines = targets.map((t) => {
        const label = t === 'applicant' ? '지원자' : '보호자'
        const r = results[t]
        if (!r) return `${label}: 대상 없음`
        if (r.sent) return `${label}: 발송 성공`
        return `${label}: ${reasonLabel[r.reason] ?? r.providerMessage ?? '발송 실패'}`
      })
      alert(lines.join('\n'))
    } finally {
      setSendingSms(false)
    }
  }

  // 접수증 PDF를 지원자 이메일로 보낸다(2026-10-25). 메일용 판은 지원자·보호자 연락처를 뺀다.
  async function handleSendEmail(toEmail) {
    if (!receiptRef.current) return
    if (!window.confirm(`접수증 PDF(연락처 제외)를 아래 주소로 보낼까요?\n\n${toEmail}\n\n주소가 틀리면 [취소]하고 지원자 정보에서 고친 뒤 보내세요.`)) return
    setSendingEmail(true)
    try {
      setHideContacts(true)
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
      const blob = await elementToPdfBlob(receiptRef.current)
      setHideContacts(false)
      const buf = new Uint8Array(await blob.arrayBuffer())
      let bin = ''
      for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000))
      const { data, error: invokeErr } = await supabase.functions.invoke('send-receipt-email', {
        body: { applicantId, pdfBase64: btoa(bin) },
      })
      if (invokeErr) {
        const detail = await getEdgeFunctionErrorMessage(invokeErr, invokeErr.message)
        alert(`메일 발송 요청에 실패했습니다.${invokeErr.context?.status ? ` (응답 ${invokeErr.context.status})` : ''}\n${detail}`)
        return
      }
      const r = data?.result || {}
      const reasonLabel = {
        not_configured: '메일 발송 계정이 아직 설정되지 않았습니다(관리자 문의).',
        invalid_email: '지원자 이메일 주소가 없거나 형식이 올바르지 않습니다.',
        smtp_error: `메일 서버 오류: ${r.message || ''}`,
      }
      alert(r.sent ? `메일을 보냈습니다 (${r.to}).\n스팸함도 확인하도록 안내해 주세요.` : (reasonLabel[r.reason] || '발송 실패'))
    } catch (err) {
      alert(`메일을 보내지 못했습니다.\n${err.message}`)
    } finally {
      setHideContacts(false)
      setSendingEmail(false)
    }
  }

  useEffect(() => {
    let active = true
    async function load() {
      const { data, error: err } = await supabase
        .from('applicants')
        .select('*, applicants_private(applicant_phone, guardian_name, guardian_phone, email)')
        .eq('id', applicantId)
        .maybeSingle()

      if (!active) return
      if (err) setError(err.message)
      else if (!data) setError('지원자를 찾을 수 없습니다.')
      else setApplicant(data)
      setLoading(false)
    }
    load()
    return () => {
      active = false
    }
  }, [applicantId])

  if (loading) return <p className="p-10 text-center text-ink-muted">불러오는 중…</p>
  if (error) return <p className="p-10 text-center text-status-danger">{error}</p>
  if (!applicant) return null

  const private_ = Array.isArray(applicant.applicants_private)
    ? applicant.applicants_private[0]
    : applicant.applicants_private

  const trackText = tracksToText(applicant.tracks)
  // 하단 안내(요강 발췌) — 연도·차수별 문구는 src/config/printNotices.js
  const notices = getPrintNotices(applicant.year, applicant.round)
  const issuedAt = new Date().toLocaleDateString('ko-KR', {
    year: 'numeric', month: 'long', day: 'numeric',
  })

  return (
    <div className="mx-auto w-fit bg-white p-10 print:p-0">
      <div className="mb-6 flex justify-end gap-2 print:hidden">
        <Link
          to="/reception"
          className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle"
        >
          목록으로
        </Link>
        <button
          type="button"
          onClick={handleDownloadPng}
          disabled={downloading}
          className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {downloading ? '이미지 생성 중…' : 'PNG로 저장'}
        </button>
        <button
          type="button"
          onClick={handleDownloadPdf}
          disabled={savingPdf}
          className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {savingPdf ? 'PDF 만드는 중…' : 'PDF 저장'}
        </button>
        <button
          type="button"
          onClick={() => {
            const targets = []
            if (private_?.applicant_phone) targets.push('applicant')
            if (private_?.guardian_phone) targets.push('guardian')
            if (targets.length === 0) {
              alert('전송 가능한 연락처가 없습니다.')
              return
            }
            const labels = targets.map((t) => (t === 'applicant' ? '지원자' : '보호자')).join(', ')
            if (!window.confirm(`${labels} 번호로 접수 완료 안내 문자를 보낼까요?\n(이미지는 첨부되지 않고 텍스트로만 발송됩니다)`)) return
            handleSendSms(targets)
          }}
          disabled={sendingSms}
          className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {sendingSms ? '전송 중…' : '문자로 안내 전송'}
        </button>
        <button
          type="button"
          onClick={() => handleSendEmail(private_.email)}
          disabled={sendingEmail || !private_?.email}
          title={private_?.email ? `${private_.email}로 보내기` : '지원자 이메일 주소가 없습니다'}
          className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {sendingEmail ? '메일 보내는 중…' : '이메일로 보내기'}
        </button>
        <button
          type="button"
          onClick={() => window.print()}
          className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-medium text-white hover:bg-brand-deepGreenStrong"
        >
          인쇄
        </button>
      </div>

      {/* 인쇄되는 실제 접수증 본문 */}
      {/* 폭 180mm 고정 = A4(210mm) − 인쇄 여백 15mm × 2. 배율 100%로 인쇄하면 실제 크기. */}
      <div ref={receiptRef} className="border-2 border-ink-primary bg-white p-8" style={{ width: '180mm' }}>
        {/* 머리: 가운데 제목, 오른쪽 끝에 접수번호 QR 코드(정사각형이라 제목 줄에 함께 들어간다). */}
        <div className="relative mb-6 text-center">
          <p className="text-sm text-ink-muted">새봄고등학교</p>
          <h1 className="mt-1 text-2xl font-bold text-ink-primary">
            {applicant.year}학년도 신입생 입학전형 접수증
          </h1>
          {applicant.receipt_no && (
            <div className="absolute right-0 top-1/2 -translate-y-1/2">
              <QrCode value={applicant.receipt_no} sizeMm={18} showText={false} />
            </div>
          )}
        </div>

        <table className="w-full border-collapse text-sm">
          <tbody>
            {/* 수험번호는 원서 접수 마감 후 성명 가나다순으로 일괄 부여된다(원서 접수 지침).
                접수 시점에는 없으므로 지침 붙임2 문구대로 안내한다. */}
            <Row
              label="수험번호"
              value={applicant.exam_no || '원서 접수 종료 후 부여 예정'}
              mono={Boolean(applicant.exam_no)}
            />
            <Row label="접수번호" value={applicant.receipt_no} mono />
            <Row label="성명" value={applicant.name} />
            <Row label="지원 전형" value={trackText} />
            <Row label="학적상태" value={applicant.academic_status} />
            {applicant.school && <Row label="출신 중학교" value={applicant.school} />}
            <Row
              label="접수일"
              value={formatReceiptDate(applicant.receipt_date)}
            />
            <Row label="접수방법" value={METHOD_LABEL[applicant.receipt_method]} />
            {!hideContacts && private_?.applicant_phone && (
              <Row label="지원자 연락처" value={private_.applicant_phone} />
            )}
            {!hideContacts && private_?.guardian_name && (
              <Row
                label="보호자"
                value={`${private_.guardian_name}${private_.guardian_phone ? ` (${private_.guardian_phone})` : ''}`}
              />
            )}
          </tbody>
        </table>

        <p className="mt-5 text-center text-sm leading-relaxed text-ink-secondary">
          위와 같이 {applicant.year}학년도 신입생 입학전형 원서를 접수하였음을 증명합니다.
          <br />
          1단계 서류평가 결과는 아래 전형 일정에 따라 개별 통지됩니다.
        </p>

        {/* 증명서 형식: 발급일을 가운데 두고, 그 아래에 학교장 + 직인.
            직인(2.4cm)이 위아래로 걸치므로 발급일과 겹치지 않게 간격을 둔다. */}
        <p className="mt-5 text-center text-sm text-ink-secondary">{issuedAt}</p>

        <div className="mt-6 flex items-center justify-center">
          <p className="text-lg font-semibold text-ink-primary">
            산 마 을 고 등 학 교{' '}
            <span className="relative inline-block">
              장
              {/* 직인: 학교법인 및 사립학교 직인규칙 별표 기준 초·중·고등학교장 직인 규격
                  2.4cm × 2.4cm를 인쇄 시 그대로 재현한다(cm는 화면 100%/인쇄 "실제 크기"
                  기준에서 물리적 단위로 정확히 변환됨). 마지막 글자 "장"의 정중앙에
                  직인 중심이 오도록 절대배치하여, 폰트/자간이 바뀌어도 항상 "장" 한
                  글자에만 걸치도록 한다(margin 수치를 눈대중으로 맞추는 대신 이 글자
                  span을 기준점으로 삼음). */}
              <img
                src={schoolSeal}
                alt="새봄고등학교장 직인"
                style={{
                  position: 'absolute',
                  left: '0%', // "장" 글자의 왼쪽 끝 = 직인의 왼쪽 끝선(글자가 직인 왼쪽 끝선에서 "시작")
                  top: '50%',
                  transform: 'translate(0%, -50%)', // X축 이동 없음, Y축만 세로 중앙 정렬
                  width: '2.4cm',
                  height: '2.4cm',
                  maxWidth: 'none',
                  pointerEvents: 'none',
                }}
              />
            </span>
          </p>
        </div>

        {/* 하단 안내: 전형 일정·유의사항·문의처(요강 발췌). 직인이 아래로 걸치므로 여백을 둔다. */}
        {notices && (
          <div className="mt-10 space-y-3 border-t border-border pt-4">
            <ScheduleTable rows={notices.schedule} />
            <NoteList title="유의사항" items={notices.receipt?.notes} />
            <Contacts items={notices.contacts} />
          </div>
        )}
      </div>

      <p className="mt-4 text-center text-xs text-ink-muted print:hidden">
        실제 크기로 뽑으려면 인쇄 창의 배율을 &lsquo;기본값(100%)&rsquo;으로 두세요(&lsquo;페이지에 맞춤&rsquo; 해제).
      </p>
    </div>
  )
}

function Row({ label, value, mono }) {
  return (
    <tr className="border-b border-border">
      <th className="w-32 bg-surface-subtle px-3 py-1.5 text-left font-medium text-ink-secondary">
        {label}
      </th>
      <td className={`px-3 py-1.5 text-ink-primary ''`}>{value}</td>
    </tr>
  )
}

// 접수일: 2026. 9. 16.(수) — 시각은 넣지 않는다(2026-10-25).
// 시각은 입력한 때일 뿐이고, 우편 접수·접수일 소급(00100)에서는 실제 도착 시각과 달라 오해를 부른다.
function formatReceiptDate(value) {
  if (!value) return '-'
  const d = new Date(value)
  const date = new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', year: 'numeric', month: 'numeric', day: 'numeric' }).format(d)
  const weekday = new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', weekday: 'short' }).format(d)
  return `${date}(${weekday})`
}
