// 심층역량평가 대상 확인서 한 장 (2026-10-20) — 수험표(ExamTicketSheet)와 같은 틀
// 폭 180mm(A4에서 여백 15mm×2를 뺀 폭) — 인쇄 배율 100%로 실제 크기. 직인 2.4cm.
// 개인별 입실 시각·모둠은 넣지 않는다(전원 함께 시작, 모둠 편성은 당일 공개).

import schoolLogo from '../../../assets/school-logo.png'
import schoolSeal from '../../../assets/schooi-seal.png'
import { tracksToText } from '../../../lib/applicantLabels'
import { countryLabel } from '../../../config/countries'
import { NoteList, Contacts } from '../../../components/print/NoticeBlocks'
import { getPrintNotices } from '../../../config/printNotices'

const SHEET_WIDTH_MM = 180

function fmtBirth(v) {
  if (!v) return '-'
  const [y, m, d] = String(v).slice(0, 10).split('-')
  return `${y}. ${Number(m)}. ${Number(d)}.`
}

function fmtIssueDate(v) {
  const d = v ? new Date(v) : new Date()
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일`
}

export default function DeepConfirmSheet({ item, year, round, issuedAt }) {
  const notices = getPrintNotices(year, round || 'main')
  const deep = notices?.certificate?.deep || {}
  const deepRow = (notices?.schedule || []).find(([label]) => label.includes('심층'))
  return (
    <div className="rounded-lg border-2 border-ink-primary bg-white p-8 print:rounded-none print:border-black" style={{ width: `${SHEET_WIDTH_MM}mm` }}>
      <div className="flex justify-end text-xs text-ink-secondary">
        확인서 번호 <span className="ml-1.5 font-mono font-semibold text-ink-primary">{item.certNo || '(발급 시 부여)'}</span>
      </div>
      <div className="mt-1 flex min-h-[22mm] items-center justify-center gap-3 border-b-2 border-ink-primary pb-4">
        <img src={schoolLogo} alt="" className="h-12 w-auto" />
        <div className="text-center">
          <p className="text-sm text-ink-secondary">{year}학년도 새봄고등학교 신입생 입학전형</p>
          <h1 className="text-2xl font-bold tracking-[0.3em] text-ink-primary">심층역량평가 대상 확인서</h1>
        </div>
      </div>

      <table className="mt-6 w-full text-sm">
        <tbody>
          <Row label="수험번호" value={item.examNo || '-'} strong mono />
          <Row label="성명" value={item.name} strong />
          {item.nameEnglish && <Row label="성명(영문)" value={item.nameEnglish} />}
          {item.nationality && item.nationality !== 'KOR' && <Row label="국적" value={countryLabel(item.nationality)} />}
          <Row label="생년월일" value={fmtBirth(item.birthDate)} />
          <Row label="지원 전형" value={tracksToText(item.tracks)} />
          <Row label="출신 중학교" value={item.school || item.academicStatus || '-'} />
        </tbody>
      </table>

      <p className="mt-7 text-center text-[15px] leading-8 text-ink-primary">
        위 사람은 {year}학년도 새봄고등학교 신입생 입학전형 <strong>1단계 서류평가에 합격</strong>하여
        <br />
        <strong>2단계 심층역량평가 대상자</strong>임을 확인합니다.
      </p>

      <div className="mt-6 rounded-md border border-border">
        <p className="border-b border-border bg-surface-subtle px-3 py-1.5 text-xs font-bold text-ink-primary">2단계 심층역량평가 안내</p>
        <table className="w-full text-[12.5px]">
          <tbody>
            <InfoRow label="전형일" value={deepRow ? deepRow[1] : '추후 안내'} />
            <InfoRow label="장소" value={deep.place || '추후 안내'} />
            <InfoRow label="입실 시각" value={deep.gather || '추후 안내'} />
            <InfoRow label="준비물" value={deep.bring || '수험표, 신분증'} />
          </tbody>
        </table>
      </div>

      <div className="mt-4 space-y-3">
        <NoteList title="유의사항" items={deep.notes} />
        <Contacts items={notices?.contacts} />
      </div>

      <p className="mt-8 text-center text-sm text-ink-primary">{fmtIssueDate(issuedAt)}</p>
      <div className="flex items-center justify-center pb-6 pt-5">
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
