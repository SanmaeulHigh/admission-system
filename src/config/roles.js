// 역할 이름을 화면에 보여줄 때 쓰는 한글 표기 (2026-10-12)
// 헤더 사용자 메뉴에 'superadmin, quant'처럼 영문 코드가 그대로 보이던 것을 바꾼다.

export const ROLE_LABEL = {
  superadmin: '최고관리자',
  admin: '관리자',
  reception: '접수',
  quant: '정량평가',
  evaluator: '평가위원',
  viewer: '열람 전용',
  principal: '학교장',
}

export function rolesToText(roles) {
  if (!roles || roles.length === 0) return '역할 없음'
  return roles.map((r) => ROLE_LABEL[r] || r).join(' · ')
}
