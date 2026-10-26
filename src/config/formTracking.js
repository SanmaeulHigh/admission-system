// 온라인 서류작성기(Vercel) 이용 집계 — 구글 시트 + Apps Script 웹 앱.
// 대시보드는 집계 숫자만 받아 온다(방문자별 기록은 받지 않음).
// key 는 Apps Script 의 SUMMARY_KEY 와 같아야 한다.
export const FORM_TRACKING = {
  // 쓰지 않으면 비워 둔다(대시보드 카드에 '설정 안 됨'으로 보인다)
  summaryUrl: import.meta.env.VITE_FORM_TRACKING_URL || '',
  key: import.meta.env.VITE_FORM_TRACKING_KEY || '',
  sheetUrl: '',
}
