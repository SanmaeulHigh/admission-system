// 수험표·접수증 하단 안내 문구 (2026-09-28)
//
// 출처: 2027학년도 새봄고등학교 신입생 입학전형 요강(공고 제2026-41호, 2026. 7. 6. 승인)
//   5. 전형 일정 / 4. 전형 방법 (2) / 7. 유의 사항 / 8. 기타 사항 등 문의처
// 수험번호 부여 안내는 원서 접수 업무 진행 지침(붙임 2)을 따른다.
//
// 해마다 요강이 바뀌면 이 파일의 해당 연도 항목만 새로 쓰면 된다.
// 면접 개인별 시각은 넣지 않는다(수험표에 면접 일시를 넣지 않기로 한 2026-09-04 결정과 동일).

const CONTACTS_2027 = [
  '교무실 ☎ 000-000-0000 (08:30~16:30)',
  '누리집 school.example.kr → 입학 → Q&A',
  '이메일 admission@school.example.kr',
]

const NOTICES = {
  2027: {
    schedule: {
      main: [
        ['원서 접수', '2026. 10. 19.(월) 09:00 ~ 11. 2.(월) 17:00', '최종일 17시 도착분까지'],
        ['1단계 서류평가', '2026. 11. 3.(화) ~ 11. 5.(목)', ''],
        ['1단계 결과 및 2단계 대상자 발표', '2026. 11. 6.(금)', '개별 통보(SMS)·홈페이지'],
        ['2단계 심층역량평가', '2026. 11. 14.(토)', '개인별 시간은 별도 안내'],
        ['최종 합격자 발표', '2026. 11. 18.(수)', '개별 통보(SMS)·홈페이지'],
      ],
      extra1: [
        ['원서 접수', '2026. 11. 20.(금) ~ 11. 24.(화)', ''],
        ['심층역량평가', '2026. 11. 27.(금)', '개인별 시간은 별도 안내'],
        ['합격자 발표', '2026. 12. 1.(화)', '개별 통보(SMS)·홈페이지'],
      ],
      extra2: [
        ['원서 접수', '2027. 1. 6.(수) ~ 1. 11.(월)', ''],
        ['심층역량평가', '2027. 1. 12.(화)', '개인별 시간은 별도 안내'],
        ['합격자 발표', '2027. 1. 13.(수)', '개별 통보(SMS)·홈페이지'],
      ],
    },

    // 수험표: 2단계 심층역량평가 응시자 대상
    ticket: {
      deepEvaluation: [
        '모둠 활동(약 80분): 여러 모둠으로 나누어 협력 활동을 하며, 관찰 교사들이 공동체 역량·의사소통 역량·사회성 등을 종합적으로 평가합니다.',
        '학생 면접(약 25분): 제출 서류를 바탕으로 한 개별 면접입니다.',
        '학부모 면접(약 20분): 학부모 대상 개별 면접입니다.',
        '글쓰기: 지문이 있는 글쓰기 문항 3개 중 2개를 골라 답안을 작성합니다.',
        '지원자 자기평가·학부모 설문을 당일 전자적 방법으로 받을 수 있습니다. (합격 시 생활지도에 참고함.)',
      ],
      notes: [
        '전형 당일 수험표와 신분증(학생증, 청소년증, 여권 등)을 반드시 지참하십시오. 여권을 사용하는 경우 ‘여권정보증명서’를 함께 제출해야 합니다.',
        '면접·모둠 활동의 개인별 시간과 장소는 별도로 안내합니다.',
        '심층역량평가에서 허위 사실을 진술한 경우 입학전형위원회 결정에 따라 합격이 취소될 수 있으며, 민·형사상 조치의 대상이 됩니다.',
        '본교에 입학 허가 대상자로 발표된 자는 전·후기 고등학교에 지원할 수 없습니다. (전원 기숙사 생활)',
        '최종 합격자는 학교장이 지정하는 일자까지 등록확인서(학생·학부모 연서)와 주민등록등본을 제출해야 합니다.',
        '수험표를 분실한 경우 본교로 연락하여 재발급받으시기 바랍니다.',
      ],
    },

    // 접수증: 원서 접수자 대상
    receipt: {
      notes: [
        '수험번호는 원서 접수 마감 후 부여되며, 부여 후 3일 이내에 개별 문자로 안내합니다.',
        '제출서류에 허위 사실을 기재하거나 합격 사정에 불리한 사실을 의도적으로 숨긴 경우, 전형 기간 중 또는 최종 합격자 발표 이후라도 합격이 취소될 수 있으며 민·형사상 조치의 대상이 됩니다.',
        '본교에 입학 허가 대상자로 발표된 자는 전·후기 고등학교에 지원할 수 없습니다. (전원 기숙사 생활)',
      ],
    },

    // 심층역량평가 대상 확인서·합격증서 (2026-10-20). 개인별 시각은 넣지 않는다(전원 함께 시작, 모둠 편성은 당일 공개).
    certificate: {
      deep: {
        place: '본관',
        gather: '추후 개별 문자(SMS)로 안내',
        bring: '수험표, 신분증(학생증·청소년증·여권 등)',
        notes: [
          '모둠 편성은 전형 당일 현장에서 공개합니다.',
          '전형 당일 수험표와 신분증을 반드시 지참하십시오.',
          '심층역량평가에서 허위 사실을 진술한 경우 입학전형위원회 결정에 따라 합격이 취소될 수 있습니다.',
        ],
      },
    },

    contacts: CONTACTS_2027,
  },
}

// 해당 연도 문구가 없으면 가장 최근 연도 문구를 쓴다(예: 2099 테스트 차수 → 2027 문구).
// 새 연도 요강이 나오면 그 연도 항목을 추가해야 날짜가 맞게 나온다.
function pickYear(year) {
  if (NOTICES[year]) return NOTICES[year]
  const years = Object.keys(NOTICES).map(Number).sort((a, b) => b - a)
  const older = years.find((y) => y <= year)
  return NOTICES[older ?? years[0]] || null
}

export function getPrintNotices(year, round) {
  const n = pickYear(Number(year))
  if (!n) return null
  return {
    schedule: n.schedule?.[round] || n.schedule?.main || [],
    ticket: n.ticket,
    receipt: n.receipt,
    certificate: n.certificate,
    contacts: n.contacts || [],
  }
}

// ------------------------------------------------------------------
// 대시보드용 전형 일정 (2026-10-12)
// 해당 연도 요강 일정이 있을 때만 돌려준다(테스트 차수 2099 등에서는 null) —
// 다른 연도 날짜로 D-day를 계산하면 엉뚱한 안내가 되기 때문이다.
// 반환: [{ label, when, note, start: Date, end: Date }]
// ------------------------------------------------------------------
function parseScheduleRange(when) {
  // 예: '2026. 10. 19.(월) 09:00 ~ 11. 2.(월) 17:00', '2026. 11. 6.(금)'
  const first = /(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\./.exec(when)
  if (!first) return null
  const year = Number(first[1])
  const start = new Date(year, Number(first[2]) - 1, Number(first[3]))
  let end = new Date(start)
  const tail = when.split('~')[1]
  if (tail) {
    const full = /(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\./.exec(tail)
    const short = /(\d{1,2})\.\s*(\d{1,2})\./.exec(tail)
    if (full) end = new Date(Number(full[1]), Number(full[2]) - 1, Number(full[3]))
    else if (short) {
      end = new Date(year, Number(short[1]) - 1, Number(short[2]))
      if (end < start) end.setFullYear(year + 1) // 연말→연초로 넘어가는 경우
    }
  }
  return { start, end }
}

export function getScheduleForDashboard(year, round) {
  const n = NOTICES[Number(year)]
  if (!n) return null
  const rows = n.schedule?.[round]
  if (!rows?.length) return null
  return rows
    .map(([label, when, note]) => {
      const range = parseScheduleRange(when)
      return range ? { label, when, note, ...range } : null
    })
    .filter(Boolean)
}

// 오늘 기준 남은 날(같은 날 0). 날짜만 비교한다.
export function daysUntil(date, today = new Date()) {
  const a = new Date(today.getFullYear(), today.getMonth(), today.getDate())
  const b = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  return Math.round((b - a) / 86400000)
}

export function formatMonthDay(date) {
  const wd = new Intl.DateTimeFormat('ko-KR', { weekday: 'short' }).format(date)
  return `${date.getMonth() + 1}. ${date.getDate()}.(${wd})`
}
