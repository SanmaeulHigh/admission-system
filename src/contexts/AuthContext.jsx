// AuthContext (Supabase 버전)
// 마스터 스펙 v1.2 섹션 2.11의 목적(역할·활성상태의 신뢰할 수 있는 반영)을
// Supabase Auth + Postgres RLS로 구현한다.
//
// Firebase 버전과 달라진 점:
//   * Custom Claims / accessRevision 개념 폐기 — RLS가 매 쿼리마다 users
//     테이블을 직접 확인하므로 "낡은 토큰에 남은 권한" 문제가 없다.
//     revisionMismatch 상태도 따라서 불필요.
//   * 역할(roles)도 users 테이블 한 곳에서만 읽는다 (단일 진실 원천).
//
// 불변 조건 (유지):
//   * 이 컨텍스트는 UI 분기용일 뿐, 접근 통제의 최종 경계는 항상 RLS다.
//   * 로그인/가입 성공 ≠ 권한 부여 (섹션 2.2). users 행이 없으면
//     'unregistered' 상태로 승인 대기 화면을 보여준다.
//   * users.active = false 이면 즉시 로그아웃 처리한다.

import { createContext, useContext, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { clearGroupWorkspaceCache } from '../lib/groupWorkspaceCache'
import { setPrintIdentity } from '../lib/printStamp'

const AuthContext = createContext(null)

const INITIAL_STATE = {
  status: 'loading', // 'loading' | 'signedOut' | 'unregistered' | 'mfa' | 'ready'
  session: null,
  access: null, // 교외 접속 인증 상태(get_access_status, 00085)
  userDoc: null, // public.users 행 (display_name, roles, assigned_areas, active 등)
}

export function AuthProvider({ children }) {
  const [state, setState] = useState(INITIAL_STATE)
  const reloadRef = useRef(() => {})

  useEffect(() => {
    let userChannel = null

    async function loadUserDoc(session) {
      if (!session?.user) {
        setState({ ...INITIAL_STATE, status: 'signedOut' })
        return
      }

      // 2026-10-26: 인증 서버에 세션이 아직 살아 있는지 확인한다.
      // 다른 기기에서 로그아웃 등으로 세션이 지워져도 토큰은 만료 전까지 DB 조회가 되지만,
      // 서버 함수(문자·학교 검색·메일)는 세션까지 확인해 401로 거절한다 — 화면은 되는데 기능만 안 되는 상태.
      // 세션이 없으면 이 기기의 로그인 정보만 지우고 로그인 화면으로 보낸다.
      const { error: liveErr } = await supabase.auth.getUser()
      if (liveErr && (liveErr.status === 401 || liveErr.status === 403 || /session/i.test(liveErr.message || ''))) {
        // eslint-disable-next-line no-console
        console.warn('[auth] 서버에 세션이 없어 다시 로그인합니다', liveErr.message)
        try { await supabase.auth.signOut({ scope: 'local' }) } catch { /* 이미 끊긴 세션 */ }
        setState({ ...INITIAL_STATE, status: 'signedOut' })
        return
      }

      // 2026-10-13: 교외 접속이면 휴대폰 인증을 먼저 받는다(00085).
      // 실제 차단은 서버(Caddy 관문)가 하므로, 여기서는 화면만 인증 단계로 보낸다.
      // 함수가 아직 없거나 실패하면 그냥 지나간다(교내 서버 직접 접속 등).
      const { data: access, error: accessErr } = await supabase.rpc('get_access_status')
      if (!accessErr && access?.mfaRequired && !access?.mfaVerified) {
        setState({ status: 'mfa', session, userDoc: null, access })
        return
      }

      const { data, error } = await supabase
        .from('users')
        .select('*')
        .eq('id', session.user.id)
        .maybeSingle()

      if (error) {
        // RLS 거부 등 — 계정 상태 이상. 안전하게 로그아웃 상태로.
        // eslint-disable-next-line no-console
        console.error('[auth] users 행 조회 실패', error)
        setState({ ...INITIAL_STATE, status: 'signedOut' })
        return
      }

      if (!data) {
        // 승인 대기. superadmin이 upsert_user_access를 실행하면 아래
        // Realtime 구독이 insert 이벤트를 받아 자동으로 ready로 전환된다.
        setState({ status: 'unregistered', session, userDoc: null, access: null })
        return
      }

      if (data.active === false) {
        clearGroupWorkspaceCache(session.user.id)
        await supabase.auth.signOut({ scope: 'local' })
        return
      }

      setPrintIdentity(data.display_name || session.user.email) // 출력물 하단 인쇄자 표시
      setState({ status: 'ready', session, userDoc: data, access: accessErr ? null : access })
    }
    reloadRef.current = () => supabase.auth.getSession().then(({ data: { session } }) => loadUserDoc(session))

    function subscribeToOwnRow(session) {
      if (userChannel) {
        supabase.removeChannel(userChannel)
        userChannel = null
      }
      if (!session?.user) return

      userChannel = supabase
        .channel(`users-row-${session.user.id}`)
        .on(
          'postgres_changes',
          {
            event: '*',
            schema: 'public',
            table: 'users',
            filter: `id=eq.${session.user.id}`,
          },
          () => {
            // 권한 변경(승인/역할변경/비활성화)이 실시간으로 반영된다.
            loadUserDoc(session)
          }
        )
        .subscribe()
    }

    // 초기 세션 로드
    supabase.auth.getSession().then(({ data: { session } }) => {
      loadUserDoc(session)
      subscribeToOwnRow(session)
    })

    // 로그인/로그아웃/토큰갱신 이벤트
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      // 2026-10-26: 이 콜백 안에서 바로 supabase.rpc/from을 부르면, 토큰 갱신(밤새 만료된 세션) 중
      // 인증 잠금이 풀리지 않아 서로 기다리다 화면이 '불러오는 중…'에서 멈췄다(supabase-js 알려진 교착).
      // 잠금이 풀린 뒤 실행되도록 한 박자 미룬다.
      setTimeout(() => {
        loadUserDoc(session)
        subscribeToOwnRow(session)
      }, 0)
    })

    return () => {
      subscription.unsubscribe()
      if (userChannel) supabase.removeChannel(userChannel)
    }
  }, [])

  const signOut = async () => {
    clearGroupWorkspaceCache(state.session?.user?.id)
    // 2026-10-26: 이 기기만 로그아웃한다(scope: 'local'). 기본값(global)은 같은 계정의 모든 기기 세션을 끊어,
    // 다른 PC·아이패드에서 문자·학교 검색 등 서버 기능이 401로 실패했다.
    await supabase.auth.signOut({ scope: 'local' })
  }

  const roles = state.userDoc?.roles || []
  const hasRole = (role) => roles.includes(role)
  const hasAnyRole = (list) => list.some((r) => roles.includes(r))
  const hasArea = (area) =>
    Array.isArray(state.userDoc?.assigned_areas) && state.userDoc.assigned_areas.includes(area)

  const value = {
    ...state,
    roles,
    email: state.session?.user?.email || null,
    hasRole,
    hasAnyRole,
    hasArea,
    signOut,
    reloadAuth: () => reloadRef.current(),
    isSuperAdmin: hasRole('superadmin'),
    isAdmin: hasRole('admin'),
  }

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth는 AuthProvider 내부에서만 사용할 수 있습니다.')
  return ctx
}
