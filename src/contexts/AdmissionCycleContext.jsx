// 현재 활성 년도/전형(회차) 컨텍스트 (2026-07-15 추가)
//
// 배경: YEAR=2027 / ROUND='main'이 화면마다 하드코딩돼 있어서 관리자가
// 실제로 년도·회차를 바꿀 방법이 없었다(admission_round enum이 애초에
// main/extra1/extra2로 설계됐는데도). 00055 마이그레이션으로 DB에
// admission_rounds.is_current 플래그와 조회/전환 RPC를 추가했고, 이
// 컨텍스트는 그 값을 앱 전체에 공급한다.
//
// AuthContext와 같은 패턴(Provider + 커스텀 훅)을 따른다. 로그인된 사용자
// (status === 'ready')에게만 조회하며, 아직 아무도 현재 회차를 지정하지
// 않았다면 서버가 가장 최근 admission_round를 잠정 기본값으로 돌려준다.

import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from './AuthContext'

const AdmissionCycleContext = createContext(null)

export function AdmissionCycleProvider({ children }) {
  const { status } = useAuth()
  const [year, setYear] = useState(null)
  const [round, setRound] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('get_current_admission_cycle')
    if (err) {
      setError(err.message)
      setLoading(false)
      return
    }
    setYear(data?.year ?? null)
    setRound(data?.round ?? null)
    setLoading(false)
  }, [])

  useEffect(() => {
    if (status === 'ready') {
      refresh()
    } else if (status === 'signedOut' || status === 'unregistered') {
      setYear(null)
      setRound(null)
      setLoading(false)
    }
  }, [status, refresh])

  const value = { year, round, loading, error, refresh }

  return <AdmissionCycleContext.Provider value={value}>{children}</AdmissionCycleContext.Provider>
}

export function useAdmissionCycle() {
  const ctx = useContext(AdmissionCycleContext)
  if (!ctx) throw new Error('useAdmissionCycle은 AdmissionCycleProvider 내부에서만 사용할 수 있습니다.')
  return ctx
}
