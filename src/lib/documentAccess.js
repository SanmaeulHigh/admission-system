// 평가서류 접근 헬퍼 (섹션 6.6, "열람 감사 로그" 요구사항)
//
// 반드시 이 함수를 통해서만 문서에 접근한다. log_document_view RPC로
// 권한 재검증 + 감사 로그 기록을 먼저 하고, 그 응답의 storage_path로
// 서명 URL(단시간)을 발급받는다. createSignedUrl을 직접 호출하는 코드는
// 감사 기록 없이 조용히 열람 가능한 경로가 되므로 만들지 않는다.

import { supabase } from './supabase'

const SIGNED_URL_TTL_SECONDS = 120 // 짧게: 뷰어가 열려있는 동안만 유효하면 충분

export async function getDocumentViewUrl(documentId) {
  const { data: viewData, error: viewError } = await supabase.rpc('log_document_view', {
    p_document_id: documentId,
  })
  if (viewError) throw viewError

  const { data: signedData, error: signedError } = await supabase.storage
    .from('admission-documents')
    .createSignedUrl(viewData.storagePath, SIGNED_URL_TTL_SECONDS)
  if (signedError) throw signedError

  return { url: signedData.signedUrl, documentType: viewData.documentType }
}
