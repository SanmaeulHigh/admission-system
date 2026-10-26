// 수험표 한 장 (개별 출력·일괄 인쇄·PDF가 함께 쓰는 본체)
//
// 실제 크기 원칙: 폭을 180mm로 고정한다. A4(210mm)에서 인쇄 여백 15mm × 2를 뺀
// 폭과 같아서, 인쇄 배율 100%(기본값)로 뽑으면 화면 배치 그대로 종이에 나온다.
// 직인(2.4cm)과 사진 칸(3.5 × 4.5cm)도 mm·cm 단위라 실제 크기로 찍힌다.
// PDF 저장(pdfExport)도 이 폭을 180mm로 옮겨 붙이므로 같은 크기가 된다.

import schoolLogo from '../../assets/school-logo.png'
import schoolSeal from '../../assets/schooi-seal.png'
import { tracksToText } from '../../lib/applicantLabels'
import { countryLabel } from '../../config/countries'
import QrCode from '../../components/print/QrCode'
import { ScheduleTable, NoteList, Contacts } from '../../components/print/NoticeBlocks'
import { getPrintNotices } from '../../config/printNotices'

export const SHEET_WIDTH_MM = 180

export default function ExamTicketSheet({ applicant, examNo, photoUrl }) {
  // 하단 안내(요강 발췌) — 연도·차수별 문구는 src/config/printNotices.js
  const notices = getPrintNotices(applicant.year, applicant.round || 'main')
  return (
    <div
      className="rounded-lg border-2 border-ink-primary bg-white p-8 print:rounded-none print:border-black"
      style={{ width: `${SHEET_WIDTH_MM}mm` }}
    >
      {/* 머리: 가운데 로고·제목, 오른쪽 끝에 수험번호 QR 코드 */}
      <div className="relative flex min-h-[24mm] items-center justify-center gap-3 border-b-2 border-ink-primary pb-4">
        <img src={schoolLogo} alt="" className="h-12 w-auto" />
        <div className="text-center">
          <p className="text-sm text-ink-secondary">{applicant.year || 2027}학년도 새봄고등학교 신입생 입학전형</p>
          <h1 className="text-2xl font-bold tracking-widest text-ink-primary">수 험 표</h1>
        </div>
        {examNo && (
          <div className="absolute right-0 top-1/2 -translate-y-1/2">
            <QrCode value={examNo} sizeMm={20} showText={false} />
          </div>
        )}
      </div>

      <div className="mt-6 flex gap-6">
        <div className="shrink-0">
          <div className="flex h-[45mm] w-[35mm] items-center justify-center overflow-hidden border border-ink-primary bg-surface-subtle">
            {photoUrl ? (
              <img src={photoUrl} alt="지원자 사진" className="h-full w-full object-cover" />
            ) : (
              <span className="px-2 text-center text-xs text-ink-muted">사진 없음</span>
            )}
          </div>
        </div>

        <div className="flex-1">
          <table className="w-full text-sm">
            <tbody>
              <Row label="수험번호" value={examNo || '미부여'} mono strong />
              <Row label="성명" value={applicant.name} strong />
              {applicant.name_english && <Row label="성명(영문)" value={applicant.name_english} />}
              {applicant.nationality && applicant.nationality !== 'KOR' && (
                <Row label="국적" value={countryLabel(applicant.nationality)} />
              )}
              <Row label="접수번호" value={applicant.receipt_no} mono />
              <Row label="지원 전형" value={tracksToText(applicant.tracks)} />
              <Row label="출신 중학교" value={applicant.school || applicant.academic_status} />
            </tbody>
          </table>
        </div>
      </div>

      <div className="mt-5 space-y-3 border-t border-border pt-4">
        {notices ? (
          <>
            <ScheduleTable rows={notices.schedule} />
            <NoteList title="2단계 심층역량평가 안내" items={notices.ticket?.deepEvaluation} />
            <NoteList title="유의사항" items={notices.ticket?.notes} />
            <Contacts items={notices.contacts} />
          </>
        ) : (
          <NoteList
            title="유의사항"
            items={[
              '전형 당일 수험표와 신분증(학생증, 청소년증, 여권 등)을 반드시 지참하십시오. 여권을 사용하는 경우 ‘여권정보증명서’를 함께 제출해야 합니다.',
              '면접 일시와 장소는 별도로 안내됩니다.',
              '수험표를 분실한 경우 본교로 연락하여 재발급받으시기 바랍니다.',
            ]}
          />
        )}
      </div>

      <div className="mt-4 flex items-center justify-center pb-6 pt-6">
        {/* 마지막 글자 "장"을 기준점으로 직인 왼쪽 끝을 맞추고 세로 가운데로 걸친다.
            규격은 초·중·고등학교장 직인 2.4cm × 2.4cm(접수증과 동일). */}
        <p className="text-lg font-semibold text-ink-primary">
          산 마 을 고 등 학 교{' '}
          <span className="relative inline-block">
            장
            <img
              src={schoolSeal}
              alt="새봄고등학교장 직인"
              style={{
                position: 'absolute',
                left: 0,
                top: '50%',
                transform: 'translateY(-50%)',
                width: '2.4cm',
                height: '2.4cm',
                maxWidth: 'none',
                pointerEvents: 'none',
              }}
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
      <th className="w-28 bg-surface-subtle px-3 py-2 text-left text-xs font-medium text-ink-secondary">
        {label}
      </th>
      <td
        className={`px-3 py-2 text-ink-primary '' ${
          strong ? 'text-base font-bold' : ''
        }`}
      >
        {value}
      </td>
    </tr>
  )
}
