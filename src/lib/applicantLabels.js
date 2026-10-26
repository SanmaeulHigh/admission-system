// 지원자 관련 공통 라벨 매핑. 여러 화면(접수대장, 접수증, XLSX 내보내기)에서
// 같은 코드값을 다르게 표기하는 걸 막기 위해 한 곳에서만 정의한다.

export const TRACK_LABEL = {
  general: '일반전형',
  incheon: '인천학생추천전형',
  social: '사회통합전형',
}

export const METHOD_LABEL = {
  M: '우편(등기)',
  V: '방문',
}

export const APPLICATION_STATUS_LABEL = {
  received: '접수됨',
  incomplete: '서류미비',
  complete: '접수완료',
  withdrawn: '철회',
  excluded: '제외',
}

export const EVALUATION_STAGE_LABEL = {
  none: '평가전',
  document: '서류평가중',
  documentPassed: '서류합격',
  documentFailed: '서류불합격',
  deep: '심층평가중',
  finalPassed: '최종합격',
  finalFailed: '최종불합격',
}

export const REGISTRATION_STATUS_LABEL = {
  none: '해당없음',
  registered: '등록완료',
  waived: '등록포기',
}

export const ROUND_LABEL = {
  main: '본전형',
  extra1: '추가모집(1차)',
  extra2: '추가모집(2차)',
}

export function roundToText(round) {
  return ROUND_LABEL[round] || round
}

export function tracksToText(tracks) {
  return (tracks || []).map((t) => TRACK_LABEL[t] || t).join(' + ')
}
