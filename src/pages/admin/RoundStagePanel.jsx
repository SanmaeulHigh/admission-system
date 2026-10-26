// 전형 단계·열린 평가영역 설정 (2026-10-01)
//
// 서버 기능 set_round_stage(superadmin 전용, 감사 기록 남김)는 처음부터 있었지만
// 이를 쓰는 화면이 없어 단계 전환을 SQL로만 할 수 있었다. 채점 제출은 서버가
// "상태=열림 && 영역이 열린 평가영역에 포함"일 때만 받으므로, 서류평가를 닫고
// 심층역량평가를 여는 일을 이 화면에서 한다.

import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { roundToText } from '../../lib/applicantLabels'

export const STAGE_OPTIONS = [
  { value: 'pre_receipt', label: '접수 전' },
  { value: 'receipt', label: '접수' },
  { value: 'document_review', label: '서류평가' },
  { value: 'deep_evaluation', label: '심층역량평가' },
  { value: 'decision', label: '사정' },
  { value: 'closed', label: '종료' },
]

const STATUS_OPTIONS = [
  { value: 'open', label: '열림', hint: '채점 제출 가능' },
  { value: 'frozen', label: '동결', hint: '조회만, 제출 차단' },
  { value: 'closed', label: '닫힘', hint: '제출 차단' },
]

const DOCUMENT_AREAS = [
  { value: 'attendance', label: '출결' },
  { value: 'academic', label: '학업성실도' },
  { value: 'community', label: '공동체' },
  { value: 'essay', label: '자기소개서' },
  { value: 'opinion', label: '학부모소견서' },
]
const DEEP_AREAS = [
  { value: 'group', label: '모둠활동' },
  { value: 'interview', label: '면접' },
  { value: 'writing', label: '글쓰기' },
]
const ALL_AREAS = [...DOCUMENT_AREAS, ...DEEP_AREAS]
const AREA_ORDER = ALL_AREAS.map((a) => a.value)

// 단계를 바꾸면 그 단계에 맞는 영역을 먼저 골라 준다(그다음 직접 고칠 수 있다).
const PRESET = {
  document_review: DOCUMENT_AREAS.map((a) => a.value),
  deep_evaluation: DEEP_AREAS.map((a) => a.value),
}

const stageLabel = (v) => STAGE_OPTIONS.find((s) => s.value === v)?.label || v
const statusLabel = (v) => STATUS_OPTIONS.find((s) => s.value === v)?.label || v
const areaText = (list) => (list.length ? ALL_AREAS.filter((a) => list.includes(a.value)).map((a) => a.label).join(', ') : '없음')

export default function RoundStagePanel({ year, round, onClose, onChanged }) {
  const { hasRole } = useAuth()
  const canEdit = hasRole('superadmin')
  const [current, setCurrent] = useState(null)
  const [stage, setStage] = useState('')
  const [status, setStatus] = useState('closed')
  const [areas, setAreas] = useState([])
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)

  const load = async () => {
    setError(null)
    const { data, error: err } = await supabase
      .from('admission_rounds')
      .select('stage, stage_status, open_evaluation_areas')
      .eq('year', year)
      .eq('round', round)
      .maybeSingle()
    if (err) {
      setError(err.message)
      return
    }
    setCurrent(data)
    setStage(data?.stage || 'pre_receipt')
    setStatus(data?.stage_status || 'closed')
    setAreas(data?.open_evaluation_areas || [])
  }

  useEffect(() => {
    setNotice(null)
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [year, round])

  const changeStage = (value) => {
    setStage(value)
    setAreas(PRESET[value] || [])
    setStatus(PRESET[value] ? 'open' : status)
  }

  const toggleArea = (value) =>
    setAreas((cur) => (cur.includes(value) ? cur.filter((a) => a !== value) : [...cur, value]))

  const sortedAreas = AREA_ORDER.filter((a) => areas.includes(a))
  const changed = current && (
    stage !== current.stage
    || status !== current.stage_status
    || JSON.stringify(sortedAreas) !== JSON.stringify(AREA_ORDER.filter((a) => (current.open_evaluation_areas || []).includes(a)))
  )

  const save = async () => {
    const msg = [
      `${year}학년도 ${roundToText(round)}의 전형 단계를 바꿉니다.`,
      '',
      `단계: ${stageLabel(current.stage)} → ${stageLabel(stage)}`,
      `상태: ${statusLabel(current.stage_status)} → ${statusLabel(status)}`,
      `열린 평가영역: ${areaText(current.open_evaluation_areas || [])}`,
      `            → ${areaText(sortedAreas)}`,
      '',
      '닫히는 영역은 평가위원이 더 이상 제출할 수 없습니다. 계속할까요?',
    ].join('\n')
    // eslint-disable-next-line no-alert
    if (!window.confirm(msg)) return
    setSaving(true)
    setError(null)
    const { error: err } = await supabase.rpc('set_round_stage', {
      target_year: year,
      target_round: round,
      new_stage: stage,
      new_stage_status: status,
      new_open_areas: sortedAreas,
    })
    setSaving(false)
    if (err) {
      setError(err.message)
      return
    }
    setNotice('저장했습니다. 변경 내역은 감사 기록에 남았습니다. 열려 있는 다른 선생님 화면은 새로고침해야 반영됩니다.')
    await load()
    onChanged?.()
  }

  const areaBox = (list, title) => (
    <div>
      <p className="mb-1 text-xs font-semibold text-ink-muted">{title}</p>
      <div className="flex flex-wrap gap-x-4 gap-y-1">
        {list.map((a) => (
          <label key={a.value} className="flex items-center gap-1.5 text-sm">
            <input type="checkbox" checked={areas.includes(a.value)} disabled={!canEdit} onChange={() => toggleArea(a.value)} />
            {a.label}
          </label>
        ))}
      </div>
    </div>
  )

  return (
    <section className="mt-4 rounded-xl border border-brand-deepGreen bg-white p-5">
      <div className="mb-3 flex items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-ink-primary">{year}학년도 {roundToText(round)} · 전형 단계와 열린 평가영역</h2>
          <p className="mt-1 text-xs text-ink-muted">
            평가위원은 상태가 &lsquo;열림&rsquo;이고 그 영역이 체크된 동안에만 채점을 제출할 수 있습니다(관리자 대리 입력·엑셀 일괄 입력 포함).
          </p>
        </div>
        <button type="button" onClick={onClose} className="text-xs text-ink-muted underline">닫기</button>
      </div>

      {!canEdit && (
        <p className="mb-3 rounded-md bg-status-warningSoft px-3 py-2 text-xs text-status-warning">단계 변경은 슈퍼관리자만 할 수 있습니다. 현재 설정만 보여줍니다.</p>
      )}
      {error && <p className="mb-3 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {notice && <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">{notice}</p>}

      {!current ? (
        <p className="text-sm text-ink-muted">불러오는 중…</p>
      ) : (
        <div className="space-y-4">
          <div>
            <p className="mb-1 text-xs font-semibold text-ink-muted">진행 단계</p>
            <div className="flex flex-wrap gap-2">
              {STAGE_OPTIONS.map((s) => (
                <button
                  key={s.value}
                  type="button"
                  disabled={!canEdit}
                  onClick={() => changeStage(s.value)}
                  className={`rounded-lg border px-3 py-1.5 text-sm font-semibold disabled:cursor-not-allowed ${stage === s.value ? 'border-brand-deepGreen bg-brand-greenSoft text-brand-deepGreenStrong' : 'border-border text-ink-secondary hover:border-brand-deepGreen'}`}
                >
                  {s.label}
                </button>
              ))}
            </div>
            <p className="mt-1 text-[11px] text-ink-muted">단계를 고르면 그 단계의 평가영역이 자동으로 체크됩니다(서류평가 → 서류 5개, 심층역량평가 → 모둠·면접·글쓰기). 아래에서 직접 고칠 수 있습니다.</p>
          </div>

          <div>
            <p className="mb-1 text-xs font-semibold text-ink-muted">상태</p>
            <div className="flex flex-wrap gap-4">
              {STATUS_OPTIONS.map((s) => (
                <label key={s.value} className="flex items-center gap-1.5 text-sm">
                  <input type="radio" name="stage-status" checked={status === s.value} disabled={!canEdit} onChange={() => setStatus(s.value)} />
                  {s.label} <span className="text-xs text-ink-muted">({s.hint})</span>
                </label>
              ))}
            </div>
          </div>

          <div className="space-y-2 rounded-lg bg-surface-subtle p-3">
            <p className="text-xs font-semibold text-ink-secondary">열린 평가영역</p>
            {areaBox(DOCUMENT_AREAS, '서류평가')}
            {areaBox(DEEP_AREAS, '심층역량평가')}
            {status !== 'open' && sortedAreas.length > 0 && (
              <p className="text-[11px] text-status-warning">상태가 &lsquo;열림&rsquo;이 아니면 체크한 영역도 제출이 막힙니다.</p>
            )}
          </div>

          {canEdit && (
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={save}
                disabled={saving || !changed}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
              >
                {saving ? '저장 중…' : '단계 저장'}
              </button>
              {!changed && <span className="text-xs text-ink-muted">바뀐 내용이 없습니다.</span>}
            </div>
          )}
        </div>
      )}
    </section>
  )
}
