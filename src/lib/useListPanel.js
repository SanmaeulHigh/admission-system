// 서류 열람·채점 화면의 지원자 목록 접기/펴기(2026-10-26). 두 화면이 같은 값을 기억한다.
import { useState } from 'react'

const KEY = 'sanmaeul.applicantListOpen'

export default function useListPanel() {
  const [open, setOpenState] = useState(() => {
    try { return localStorage.getItem(KEY) !== '0' } catch { return true }
  })
  const setOpen = (v) => {
    setOpenState(v)
    try { localStorage.setItem(KEY, v ? '1' : '0') } catch { /* 기억만 못 함 */ }
  }
  return [open, setOpen]
}
