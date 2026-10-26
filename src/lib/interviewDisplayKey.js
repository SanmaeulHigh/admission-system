// 대기실 프로젝터 화면 주소(열쇠 포함) — 00087
// 화면 주소 = /display/interview?key=<열쇠>. 열쇠는 관리자·면접 담당 위원만 받아 온다.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from './supabase'

export function interviewDisplayUrl(key) {
  return key ? `/display/interview?key=${encodeURIComponent(key)}` : '/display/interview'
}

export function useInterviewDisplayKey() {
  const [key, setKey] = useState(null)
  const [updatedAt, setUpdatedAt] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    let active = true
    supabase.rpc('get_interview_display_key').then(({ data, error: err }) => {
      if (!active) return
      if (err) setError(err.message)
      else {
        setKey(data?.key || null)
        setUpdatedAt(data?.updatedAt || null)
      }
    })
    return () => {
      active = false
    }
  }, [])

  // 관리자 전용: 열쇠를 바꾸면 예전 주소로 열린 화면은 바로 '주소 오류'가 된다.
  const rotate = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('rotate_interview_display_key')
    if (err) {
      setError(err.message)
      return false
    }
    setKey(data?.key || null)
    setUpdatedAt(data?.updatedAt || null)
    setError(null)
    return true
  }, [])

  return { key, updatedAt, error, url: interviewDisplayUrl(key), rotate }
}
