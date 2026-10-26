// 주소 입력 필드 + 다음(카카오) 우편번호 검색 (2026-09-04 추가)
//
// 양식(서식 1 입학원서)의 "주민등록상 주소 (우편번호 포함)" 칸에 대응한다.
// 접수 담당자가 주소를 손으로 옮겨 적으면 오타·표기 불일치가 잦아서, 검색으로
// 도로명주소와 우편번호를 정확히 채우고 상세주소만 덧붙이게 한다.
//
// 저장 형태: DB에 주소 컬럼이 하나뿐이므로(applicants_private.address /
// guardian_address) "(우편번호) 도로명주소 상세주소" 한 줄로 합쳐 넣는다.
// 별도 postal_code 컬럼을 새로 만들지 않은 이유는, 양식 자체가 "우편번호 포함"
// 한 칸이고 이 값을 우편 발송 라벨 외에 구조적으로 쓸 데가 없어서다.
//
// 개인정보: 다음 우편번호 API는 브라우저에서 스크립트를 실행해 주소를 고르는
// 방식이라 입력값이 카카오 서버로 전송·저장되지 않는다(개인정보처리방침 제6조
// 참고 문구와 동일한 근거). 지원자 정보를 외부로 보내지 않는다.
//
// 네트워크: 스크립트를 외부 CDN에서 내려받으므로 인터넷이 막히면 검색이 안 된다.
// 이 경우에도 접수를 못 하면 안 되므로, 입력란은 항상 직접 타이핑할 수 있게
// 열어두고 검색 실패는 안내 문구로만 알린다.

import { useState } from 'react'

const POSTCODE_SCRIPT_SRC = 'https://t1.daumcdn.net/mapjsapi/bundle/postcode/prod/postcode.v2.js'

function loadPostcodeScript() {
  if (window.daum?.Postcode) return Promise.resolve()

  const existing = document.querySelector(`script[src="${POSTCODE_SCRIPT_SRC}"]`)
  if (existing) {
    return new Promise((resolve, reject) => {
      existing.addEventListener('load', resolve, { once: true })
      existing.addEventListener('error', reject, { once: true })
    })
  }

  return new Promise((resolve, reject) => {
    const script = document.createElement('script')
    script.src = POSTCODE_SCRIPT_SRC
    script.async = true
    script.onload = resolve
    script.onerror = () => reject(new Error('주소 검색 스크립트를 불러오지 못했습니다.'))
    document.head.appendChild(script)
  })
}

export default function AddressSearchField({
  label,
  value,
  onChange,
  inputClassName,
  labelClassName,
  placeholder,
}) {
  const [loading, setLoading] = useState(false)
  const [scriptError, setScriptError] = useState(null)

  const openSearch = async () => {
    setScriptError(null)
    setLoading(true)
    try {
      await loadPostcodeScript()
      new window.daum.Postcode({
        oncomplete: (data) => {
          // 도로명주소를 기본으로 쓰고, 없으면 지번주소로 대체한다.
          const base = data.roadAddress || data.jibunAddress || ''
          const building = data.buildingName ? ` (${data.buildingName})` : ''
          // 뒤에 상세주소를 이어 적을 수 있도록 끝에 공백을 남긴다.
          onChange(`(${data.zonecode}) ${base}${building} `)
        },
      }).open()
    } catch (err) {
      setScriptError(
        '주소 검색을 열 수 없습니다. 인터넷 연결을 확인하거나, 주소를 직접 입력해 주세요.',
      )
      // 개발 중 원인 파악용 — 사용자에게는 위 안내만 보인다.
      console.error(err)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div>
      {label && <label className={labelClassName}>{label}</label>}
      <div className="flex gap-2">
        <input
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className={inputClassName}
          placeholder={placeholder}
        />
        <button
          type="button"
          onClick={openSearch}
          disabled={loading}
          className="shrink-0 rounded-md border border-border px-3 py-2 text-sm text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
        >
          {loading ? '여는 중…' : '주소 검색'}
        </button>
      </div>
      {scriptError && <p className="mt-1 text-xs text-status-warning">{scriptError}</p>}
    </div>
  )
}
