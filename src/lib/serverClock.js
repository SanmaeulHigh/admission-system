// 서버 시각 맞추기 (2026-10-19, 00094 get_server_time)
//
// 기기 시계는 틀릴 수 있어서, 서버 시각을 받아 '서버 - 기기' 차이(offset)를 구해 둔다.
// 응답이 오가는 시간의 절반을 보정한다. 5분마다 다시 맞춘다. 여러 화면이 함께 써도 한 번만 묻는다.

import { useEffect, useState } from 'react'
import { supabase } from './supabase'

const RESYNC_MS = 5 * 60 * 1000
let offsetMs = 0
let syncedAt = 0
let inflight = null
const listeners = new Set()

async function syncOnce() {
  if (inflight) return inflight
  inflight = (async () => {
    const t0 = Date.now()
    const { data, error } = await supabase.rpc('get_server_time')
    const t1 = Date.now()
    if (!error && data) {
      const server = new Date(data).getTime()
      if (!Number.isNaN(server)) {
        offsetMs = server + (t1 - t0) / 2 - t1
        syncedAt = t1
        listeners.forEach((fn) => fn())
      }
    }
    inflight = null
  })()
  return inflight
}

// 1초마다 바뀌는 '지금'(서버 기준)과 동기화 여부
export function useServerClock() {
  const [now, setNow] = useState(() => new Date(Date.now() + offsetMs))
  const [synced, setSynced] = useState(syncedAt > 0)

  useEffect(() => {
    const onSync = () => setSynced(true)
    listeners.add(onSync)
    if (!syncedAt || Date.now() - syncedAt > RESYNC_MS) syncOnce()
    const tick = setInterval(() => setNow(new Date(Date.now() + offsetMs)), 1000)
    const resync = setInterval(syncOnce, RESYNC_MS)
    return () => {
      listeners.delete(onSync)
      clearInterval(tick)
      clearInterval(resync)
    }
  }, [])

  return { now, synced, offsetMs }
}
