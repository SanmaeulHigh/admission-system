// M7b 내보내기 이력·체크섬 공통 헬퍼.
// 파일을 서버에 저장하지 않으므로(클라이언트 직접 생성·다운로드 구조),
// 생성된 바이트를 SHA-256으로 해시해 "그때 그 데이터로 만든 파일"이라는
// 최소한의 사후 검증 근거만 남긴다. 로그 실패는 다운로드 자체를 막지 않는다
// (감사 기록 실패가 사용자 작업을 막아서는 안 된다는 원칙).

import { supabase } from './supabase'
import { sha256Bytes } from './sha256'

function toBytes(bufferOrString) {
  if (typeof bufferOrString === 'string') return new TextEncoder().encode(bufferOrString)
  if (ArrayBuffer.isView(bufferOrString)) {
    return new Uint8Array(bufferOrString.buffer, bufferOrString.byteOffset, bufferOrString.byteLength)
  }
  return new Uint8Array(bufferOrString)
}

export async function sha256Hex(bufferOrString) {
  const data = toBytes(bufferOrString)
  // crypto.subtle은 보안 컨텍스트에서만 존재 → 교내망 HTTP 접속 시 순수 JS 구현으로 대체
  const digest = globalThis.crypto?.subtle
    ? await crypto.subtle.digest('SHA-256', data)
    : sha256Bytes(data)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * @param {object} params
 * @param {number} params.year
 * @param {string} params.round
 * @param {string} params.exportType - export_type enum 값
 * @param {string} params.fileFormat - 'xlsx' | 'csv' | 'pdf'
 * @param {ArrayBuffer|string} params.content - 체크섬 계산 대상(생성된 파일 바이트 또는 텍스트)
 * @param {string} [params.decisionRunId]
 * @param {string} [params.configRevisionId]
 * @param {number} [params.rowCount]
 * @param {object} [params.metadata]
 */
export async function logExport({
  year,
  round,
  exportType,
  fileFormat,
  content,
  decisionRunId = null,
  configRevisionId = null,
  rowCount = null,
  metadata = {},
}) {
  try {
    const checksum = await sha256Hex(content)
    const { error } = await supabase.rpc('log_export', {
      p_year: year,
      p_round: round,
      p_export_type: exportType,
      p_file_format: fileFormat,
      p_checksum_sha256: checksum,
      p_decision_run_id: decisionRunId,
      p_config_revision_id: configRevisionId,
      p_row_count: rowCount,
      p_metadata: metadata,
    })
    if (error) {
      // eslint-disable-next-line no-console
      console.error('내보내기 이력 기록 실패(다운로드는 정상 진행됨):', error.message)
    }
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('내보내기 이력 기록 실패(다운로드는 정상 진행됨):', e)
  }
}
