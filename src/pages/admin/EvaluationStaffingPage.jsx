// 평가 준비 — 전형위원 배정 현황 (2026-09-28 추가)
//
// 담당 영역 배정 자체는 "사용자(선생님) 권한 관리"에서도 할 수 있다. 다만
// 그 화면은 사람 단위라 "자기소개서 평가위원이 지금 몇 명인가"를 볼 수 없다.
// 이 화면은 같은 데이터(users.assigned_areas)를 영역 중심으로 뒤집어 본다.
//
// 왜 중요한가: 서류평가는 영역마다 제출해야 할 위원 수가 정해져 있고, 그 인원이
// 채워지지 않으면 1단계 사정 확정이 막힌다. 지금까지는 사정 단계에 가서야 알 수
// 있었는데, 준비 단계에서 미리 보여주려는 것이다.
//
// 배정 변경은 superadmin만 가능하다(기존 담당영역 변경 권한과 동일). admin은
// 현황 조회만 한다 — 누가 어떤 지원자를 채점하는지가 바뀌는 일이라서다.

import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import PageHeader from '../../components/layout/PageHeader'

const AREA_LABEL = {
  attendance: '출결',
  academic: '학업성실도',
  community: '공동체생활적합성',
  essay: '자기소개서',
  opinion: '학부모소견서',
  group: '모둠활동',
  interview: '학생·학부모 면접',
  writing: '글쓰기',
}

const ROLE_LABEL = { quant: '정량평가(quant)', evaluator: '평가위원(evaluator)' }

const STAGE_META = {
  document: {
    title: '서류평가 준비',
    description:
      '영역별로 채점에 참여할 전형위원을 정합니다. 필요 인원이 채워지지 않으면 1단계 사정을 확정할 수 없습니다.',
  },
  deep: {
    title: '심층역량평가 준비',
    description:
      '모둠활동·면접·글쓰기에 참여할 전형위원을 정합니다. 실제 몇 명이 필요한지는 조 편성에서 결정되므로 여기서는 참여 위원만 정합니다.',
  },
}

export default function EvaluationStaffingPage({ stage }) {
  const { hasAnyRole } = useAuth()
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [busyKey, setBusyKey] = useState(null)
  const [openArea, setOpenArea] = useState(null)

  const canEdit = hasAnyRole?.(['superadmin'])
  const meta = STAGE_META[stage]

  const load = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data: result, error: err } = await supabase.rpc('get_evaluation_staffing', {
      p_year: YEAR,
      p_round: ROUND,
      p_stage: stage,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setData(result)
  }, [YEAR, ROUND, stage])

  useEffect(() => {
    setOpenArea(null)
    load()
  }, [load])

  const toggleAssignment = async (area, uid, assigned) => {
    setBusyKey(`${area}:${uid}`)
    setError(null)
    const { error: err } = await supabase.rpc('set_user_area_assignment', {
      p_target_uid: uid,
      p_area: area,
      p_assigned: assigned,
    })
    setBusyKey(null)
    if (err) {
      setError(err.message)
      return
    }
    await load()
  }

  if (loading) return <p className="p-6 text-sm text-ink-muted">불러오는 중…</p>

  const areas = data?.areas || []
  const available = data?.availableUsers || []

  return (
    <div className="mx-auto max-w-4xl px-4 py-6 sm:px-6">
      <PageHeader title={meta.title} description={meta.description} />

      {error && (
        <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>
      )}

      {!canEdit && (
        <p className="mb-4 rounded-md bg-surface-subtle px-3 py-2 text-sm text-ink-secondary">
          배정 변경은 총괄관리자(superadmin)만 할 수 있습니다. 이 화면에서는 현황만 확인하실 수 있습니다.
        </p>
      )}

      <div className="space-y-3">
        {areas.map((a) => {
          const assigned = a.assigned || []
          const required = a.requiredCount
          const short = required != null && assigned.length < required
          const over = required != null && assigned.length > required
          const isOpen = openArea === a.area

          // 이 영역에 배정 가능한 사람 = 필요한 역할을 가진 활성 사용자
          const candidates = available.filter(
            (u) => (u.roles || []).includes(a.requiredRole) &&
              !assigned.some((x) => x.uid === u.uid),
          )

          return (
            <section
              key={a.area}
              className={`rounded-xl border bg-surface-card p-4 ${
                short ? 'border-status-warning' : 'border-border'
              }`}
            >
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h3 className="text-base font-semibold text-ink-primary">{AREA_LABEL[a.area] || a.area}</h3>
                  <p className="mt-0.5 text-xs text-ink-muted">
                    {ROLE_LABEL[a.requiredRole] || a.requiredRole} 역할 필요
                  </p>
                </div>

                <div className="text-right">
                  {required != null ? (
                    <>
                      <p
                        className={`text-2xl font-bold tabular-nums ${
                          short ? 'text-status-warning' : 'text-brand-deepGreenStrong'
                        }`}
                      >
                        {assigned.length}
                        <span className="text-base font-normal text-ink-muted"> / {required}명</span>
                      </p>
                      {short && (
                        <p className="text-xs font-medium text-status-warning">
                          {required - assigned.length}명 부족 — 1단계 사정이 막힙니다
                        </p>
                      )}
                      {over && (
                        <p className="text-xs text-ink-muted">
                          필요 인원보다 많습니다. 초과 인원의 채점은 집계되지 않을 수 있습니다.
                        </p>
                      )}
                    </>
                  ) : (
                    <p className="text-2xl font-bold tabular-nums text-ink-primary">
                      {assigned.length}
                      <span className="text-base font-normal text-ink-muted">명</span>
                    </p>
                  )}
                </div>
              </div>

              {/* 배정된 위원 */}
              <div className="mt-3 flex flex-wrap gap-2">
                {assigned.map((u) => (
                  <span
                    key={u.uid}
                    className="inline-flex items-center gap-2 rounded-full border border-border bg-surface-subtle py-1 pl-3 pr-1.5 text-sm"
                  >
                    <span className="text-ink-primary">{u.displayName}</span>
                    {canEdit && (
                      <button
                        type="button"
                        disabled={busyKey === `${a.area}:${u.uid}`}
                        onClick={() => toggleAssignment(a.area, u.uid, false)}
                        className="rounded-full px-1.5 text-ink-muted hover:bg-status-dangerSoft hover:text-status-danger disabled:opacity-40"
                        title="이 영역에서 제외"
                        aria-label={`${u.displayName} 제외`}
                      >
                        ×
                      </button>
                    )}
                  </span>
                ))}
                {assigned.length === 0 && (
                  <p className="text-sm text-ink-muted">아직 배정된 위원이 없습니다.</p>
                )}
              </div>

              {/* 추가 */}
              {canEdit && (
                <div className="mt-3 border-t border-border pt-3">
                  <button
                    type="button"
                    onClick={() => setOpenArea(isOpen ? null : a.area)}
                    className="text-sm font-medium text-brand-deepGreenStrong hover:underline"
                  >
                    {isOpen ? '닫기' : '+ 위원 추가'}
                  </button>

                  {isOpen && (
                    <div className="mt-2 flex flex-wrap gap-2">
                      {candidates.map((u) => (
                        <button
                          key={u.uid}
                          type="button"
                          disabled={busyKey === `${a.area}:${u.uid}`}
                          onClick={() => toggleAssignment(a.area, u.uid, true)}
                          className="rounded-full border border-brand-deepGreen px-3 py-1 text-sm text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-40"
                        >
                          + {u.displayName}
                        </button>
                      ))}
                      {candidates.length === 0 && (
                        <p className="text-sm text-ink-muted">
                          추가할 수 있는 사람이 없습니다.{' '}
                          <Link to="/admin/users" className="underline">
                            사용자 권한 관리
                          </Link>
                          에서 {ROLE_LABEL[a.requiredRole] || a.requiredRole} 역할을 먼저 부여하세요.
                        </p>
                      )}
                    </div>
                  )}
                </div>
              )}
            </section>
          )
        })}
      </div>

      <p className="mt-6 text-xs leading-relaxed text-ink-muted">
        여기서 정한 배정은 사용자(선생님) 권한 관리의 담당 영역과 같은 값입니다. 어느 쪽에서 바꾸든 동일하게 반영됩니다.
        {stage === 'deep' && ' 조 편성과 시간표는 심층역량평가 · 전형 준비에서 이어서 진행합니다.'}
      </p>
    </div>
  )
}
