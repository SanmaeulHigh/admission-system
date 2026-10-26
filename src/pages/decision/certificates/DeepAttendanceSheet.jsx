// 심층역량평가 응시 확인서 한 장 (2026-10-21) — 중학교 출석 인정 제출용
// 대상 확인서(DeepConfirmSheet)와 같은 틀. 폭 180mm, 직인 2.4cm.
// 응시일·입실 시각은 당일 바코드 입실 기록(deep_checkins)에서 가져온다.

import schoolLogo from '../../../assets/school-logo.png'
import schoolSeal from '../../../assets/schooi-seal.png'
import { getPrintNotices } from '../../../config/printNotices'

const SHEET_WIDTH_MM = 180
const WEEK = ['일', '월', '화', '수', '목', '금', '토']

function fmtBirth(v) {
  if (!v) return '-'
  const [y, m, d] = String(v).slice(0, 10).split('-')
  return `${y}. ${Number(m)}. ${Number(d)}.`
}

function fmtDay(d) {
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일(${WEEK[d.getDay()]})`
}

function fmtClock(d) {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function fmtIssueDate(v) {
  const d = v ? new Date(v) : new Date()
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일`
}

export default function DeepAttendanceSheet({ item, year, round, issuedAt }) {
  const notices = getPrintNotices(year, round || 'main')
  const place = notices?.certificate?.deep?.place || ''
  const checked = item.checkedInAt ? new Date(item.checkedInAt) : null
  const dayText = checked ? fmtDay(checked) : '-'
  const school = item.school || ''

  return (
    <div className="rounded-lg border-2 border-ink-primary bg-white p-8 print:rounded-none print:border-black" style={{ width: `${SHEET_WIDTH_MM}mm` }}>
      <div className="flex justify-end text-xs text-ink-secondary">
        확인서 번호 <span className="ml-1.5 font-mono font-semibold text-ink-primary">{item.certNo || '(발급 시 부여)'}</span>
      </div>
      <div className="mt-1 flex min-h-[22mm] items-center justify-center gap-3 border-b-2 border-ink-primary pb-4">
        <img src={schoolLogo} alt="" className="h-12 w-auto" />
        <div className="text-center">
          <p className="text-sm text-ink-secondary">{year}학년도 새봄고등학교 신입생 입학전형</p>
          <h1 className="text-2xl font-bold tracking-[0.3em] text-ink-primary">심층역량평가 응시 확인서</h1>
        </div>
      </div>

      <table className="mt-6 w-full text-sm">
        <tbody>
          <Row label="수험번호" value={item.examNo || '-'} strong mono />
          <Row label="성명" value={item.name} strong />
          <Row label="생년월일" value={fmtBirth(item.birthDate)} />
          <Row label="출신 중학교" value={school || '-'} />
        </tbody>
      </table>

      <div className="mt-6 rounded-md border border-border">
        <p className="border-b border-border bg-surface-subtle px-3 py-1.5 text-xs font-bold text-ink-primary">응시 내용</p>
        <table className="w-full text-[13px]">
          <tbody>
            <InfoRow label="전형명" value={`${year}학년도 신입생 입학전형 2단계 심층역량평가`} />
            <InfoRow label="전형일" value={dayText} />
            <InfoRow label="장소" value={`새봄고등학교 ${place}`} />
            <InfoRow label="입실 시각" value={checked ? fmtClock(checked) : '-'} />
          </tbody>
        </table>
      </div>

      <p className="mt-9 text-center text-[15px] leading-8 text-ink-primary">
        위 사람은 {dayText} 본교 {year}학년도 신입생 입학전형
        <br />
        <strong>2단계 심층역량평가에 응시하였음</strong>을 확인합니다.
      </p>

      <p className="mt-10 text-center text-sm text-ink-primary">{fmtIssueDate(issuedAt)}</p>
      <div className="flex items-center justify-center pb-4 pt-5">
        <p className="text-lg font-semibold text-ink-primary">
          산 마 을 고 등 학 교{' '}
          <span className="relative inline-block">
            장
            <img
              src={schoolSeal}
              alt="새봄고등학교장 직인"
              style={{ position: 'absolute', left: 0, top: '50%', transform: 'translateY(-50%)', width: '2.4cm', height: '2.4cm', maxWidth: 'none', pointerEvents: 'none' }}
            />
          </span>
        </p>
      </div>

      <p className="mt-8 text-lg font-semibold text-ink-primary">
        {school ? `${school}장` : '　　　　　　　　학교장'} 귀하
      </p>
      <p className="mt-2 text-xs text-ink-muted">※ 출석 인정 처리를 위한 제출용입니다.</p>
    </div>
  )
}

function Row({ label, value, mono, strong }) {
  return (
    <tr className="border-b border-border last:border-0">
      <th className="w-28 bg-surface-subtle px-3 py-2 text-left text-xs font-medium text-ink-secondary">{label}</th>
      <td className={`px-3 py-2 text-ink-primary ${strong ? 'text-base font-bold' : ''} ${mono ? 'font-mono' : ''}`}>{value}</td>
    </tr>
  )
}

function InfoRow({ label, value }) {
  return (
    <tr className="border-b border-border last:border-0">
      <th className="w-24 px-3 py-1.5 text-left font-medium text-ink-secondary">{label}</th>
      <td className="px-3 py-1.5 text-ink-primary">{value}</td>
    </tr>
  )
}
