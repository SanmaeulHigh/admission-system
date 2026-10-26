// 지원자 사진을 불러와 브라우저 안의 임시 주소(blob:)로 바꿔 준다.
//
// 왜 blob으로 바꾸나:
//  - 서명 URL은 120초 뒤 만료된다. 일괄 인쇄처럼 여러 장을 띄워 두고 한참 뒤
//    인쇄해도 사진이 빠지지 않게 미리 받아 둔다.
//  - Supabase(:8000)와 앱(:3000)은 출처가 달라서, 그대로 두면 PDF 저장
//    (html2canvas)이 사진을 그리지 못한다. blob 주소는 같은 출처로 취급된다.
//
// 열람은 반드시 getDocumentViewUrl을 거친다(권한 재검증 + 열람 감사 로그).

import { supabase } from './supabase'
import { getDocumentViewUrl } from './documentAccess'

// 반환: { url } | { missing: true } | { error: '사유' }
export async function loadApplicantPhoto(applicantId) {
  const { data: photoDoc, error: photoErr } = await supabase
    .from('admission_documents')
    .select('id')
    .eq('applicant_id', applicantId)
    .eq('document_type', 'photo')
    .eq('active', true)
    .order('uploaded_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (photoErr) return { error: `사진을 조회하지 못했습니다: ${photoErr.message}` }
  if (!photoDoc) return { missing: true }

  try {
    const { url } = await getDocumentViewUrl(photoDoc.id)
    const res = await fetch(url)
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const blob = await res.blob()
    return { url: URL.createObjectURL(blob) }
  } catch (err) {
    return { error: `사진을 여는 데 실패했습니다: ${err.message}` }
  }
}
