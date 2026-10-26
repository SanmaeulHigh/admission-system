// 수험표 일괄 인쇄 (2026-09-28)
//
// 전형 당일 접수처에서 신분 확인 후 배부할 수험표를 한 번에 뽑는다.
// 수험번호 순으로 A4 한 장에 한 명씩, 실제 크기(폭 180mm, 직인 2.4cm)로 인쇄된다.
//
// 대상: 수험번호가 있고 철회·제외되지 않은 지원자.
// 사진이 없거나 못 불러온 지원자는 인쇄에서 빼고 위쪽에 명단으로 보여준다
// (개별 수험표 화면과 같은 원칙 — 사진 없는 수험표는 발급하지 않는다).
//
// 사진을 모두 받아 둔 뒤에야 인쇄 버튼이 켜진다. 반쯤 받은 상태로 인쇄하면
// 사진 칸이 빈 수험표가 섞이기 때문이다.

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { loadApplicantPhoto } from '../../lib/applicantPhoto'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import ExamTicketSheet from './ExamTicketSheet'

const CONCURRENCY = 4

export default function ExamTicketBulkPrint() {
  const { year, round } = useAdmissionCycle()
  const [applicants, setApplicants] = useState(null)
  const [photos, setPhotos] = useState({}) // id → { url } | { missing } | { error }
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!year || !round) return undefined
    let active = true
    const created = []

    async function load() {
      setError(null)
      const { data, error: err } = await supabase
        .from('applicants')
        .select('id, year, round, receipt_no, name, name_english, nationality, tracks, school, academic_status, exam_no, application_status')
        .eq('year', year)
        .eq('round', round)
        .not('exam_no', 'is', null)
        .order('exam_no')
      if (!active) return
      if (err) {
        setError(err.message)
        return
      }
      const list = (data || []).filter((a) => !['withdrawn', 'excluded'].includes(a.application_status))
      setApplicants(list)

      // 사진을 몇 장씩 나눠 받는다(서버에 한꺼번에 몰리지 않게).
      let next = 0
      async function worker() {
        while (active && next < list.length) {
          const a = list[next]
          next += 1
          // eslint-disable-next-line no-await-in-loop
          const result = await loadApplicantPhoto(a.id)
          if (result.url) created.push(result.url)
          if (active) setPhotos((cur) => ({ ...cur, [a.id]: result }))
        }
      }
      await Promise.all(Array.from({ length: CONCURRENCY }, worker))
    }

    load()
    return () => {
      active = false
      created.forEach((u) => URL.revokeObjectURL(u))
    }
  }, [year, round])

  const { printable, problems, done } = useMemo(() => {
    const list = applicants || []
    const ok = []
    const bad = []
    list.forEach((a) => {
      const p = photos[a.id]
      if (!p) return
      if (p.url) ok.push(a)
      else bad.push({ ...a, reason: p.error || '사진 미등록' })
    })
    return { printable: ok, problems: bad, done: list.length > 0 && ok.length + bad.length === list.length }
  }, [applicants, photos])

  const total = applicants?.length || 0

  return (
    <div className="min-h-screen bg-surface-canvas px-4 py-8 print:min-h-0 print:bg-white print:p-0">
      <div className="mx-auto w-fit">
        <div className="mb-4 print:hidden" style={{ width: '180mm' }}>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Link to="/reception" className="text-sm text-ink-muted underline hover:text-ink-secondary">
              ← 지원자 목록
            </Link>
            <button
              type="button"
              onClick={() => window.print()}
              disabled={!done || printable.length === 0}
              className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
            >
              {done ? `수험표 ${printable.length}장 인쇄` : '사진 불러오는 중…'}
            </button>
          </div>

          <div className="mt-3 rounded-lg border border-border bg-white p-4 text-sm text-ink-secondary">
            <p>
              수험번호 순 · A4 한 장에 한 명 · 대상 {total}명
              {!done && total > 0 && ` · 사진 ${printable.length + problems.length}/${total}`}
            </p>
            <p className="mt-1 text-xs text-ink-muted">
              실제 크기로 뽑으려면 인쇄 창에서 용지 A4, 배율 &lsquo;기본값(100%)&rsquo;으로 두세요
              (&lsquo;페이지에 맞춤&rsquo;은 해제). 대상을 &lsquo;PDF로 저장&rsquo;으로 고르면 전체를 PDF 한 파일로 보관할 수 있습니다.
            </p>
          </div>

          {error && (
            <p className="mt-3 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>
          )}

          {applicants && total === 0 && (
            <p className="mt-3 rounded-md border border-dashed border-border bg-white p-6 text-center text-sm text-ink-muted">
              수험번호가 부여된 지원자가 없습니다. 먼저 &lsquo;수험번호 일괄 부여&rsquo;를 실행하세요.
            </p>
          )}

          {problems.length > 0 && (
            <div className="mt-3 rounded-lg border border-status-warning bg-status-warningSoft p-4 text-sm text-status-warning">
              <p className="font-semibold">사진 문제로 인쇄에서 빠진 지원자 {problems.length}명</p>
              <ul className="mt-2 space-y-0.5">
                {problems.map((a) => (
                  <li key={a.id}>
                    <span className="font-semibold tabular-nums">{a.exam_no}</span> {a.name} — {a.reason}
                  </li>
                ))}
              </ul>
              <p className="mt-2 text-xs">서류 관리에서 사진을 올린 뒤 이 화면을 새로고침하세요.</p>
            </div>
          )}
        </div>

        {/* 인쇄 본문: 한 장에 한 명, 마지막 장 뒤에는 빈 쪽이 생기지 않게 */}
        <div className="space-y-6 print:space-y-0">
          {done && printable.map((a, i) => (
            <div
              key={a.id}
              style={i < printable.length - 1 ? { breakAfter: 'page', pageBreakAfter: 'always' } : undefined}
            >
              <ExamTicketSheet applicant={a} examNo={a.exam_no} photoUrl={photos[a.id]?.url} />
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
