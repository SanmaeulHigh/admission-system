// 년도/전형(회차) 설정 화면 (2026-07-15 추가, 2026-07-23 새 회차 생성 기능 추가)
//
// 상단: admission_rounds에 미리 만들어져 있는 (year, round) 조합 중 어느 것을
// "현재"로 볼지 superadmin/admin이 전환한다.
//
// 하단 "새 회차 만들기": 기존 회차 하나를 템플릿으로 골라 배점표(scoring_params)를
// 그대로 복사하고, 일정(schedule)·모집정원(quota)만 새로 입력해서
// create_config_draft → lock_config_revision → init_admission_round 세 RPC를
// 순서대로 호출한다. 출결/학업/공동체/자소서/학부모소견서/심층평가 세부 배점은
// 이 화면에서 바꾸지 않는다 — 배점 자체를 바꿔야 하는 경우는 실수로 전형 결과가
// 왜곡될 위험이 커서 별도 요청으로 처리한다(스펙 9.2 "문자열 수식 금지"와 같은
// 맥락의 안전장치). config_revisions는 잠기면 절대 수정 불가능하므로 생성 전
// TypedConfirmDialog로 한 번 더 확인한다.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import { roundToText } from '../../lib/applicantLabels'
import PageHeader from '../../components/layout/PageHeader'
import StatusBadge from '../../components/status/StatusBadge'
import TypedConfirmDialog from '../../components/actions/TypedConfirmDialog'
import RoundStagePanel from './RoundStagePanel'
import TransferModeNotice from '../../components/feedback/TransferModeNotice'
import { ADMISSION_MODES, useAdmissionMode } from '../../lib/admissionMode'

const STAGE_LABEL = {
  pre_receipt: '접수 전',
  receipt: '접수',
  document_review: '서류평가',
  deep_evaluation: '심층역량평가',
  decision: '사정',
  closed: '종료',
}

const ROUND_OPTIONS = ['main', 'extra1', 'extra2']

const SCHEDULE_FIELDS = [
  { key: 'receiptStart', label: '접수 시작' },
  { key: 'receiptEnd', label: '접수 종료' },
  { key: 'documentReviewStart', label: '서류심사 시작' },
  { key: 'documentReviewEnd', label: '서류심사 종료' },
  { key: 'deepEvaluationDate', label: '심층역량평가일' },
  { key: 'resultAnnounceDate', label: '결과 발표일' },
  { key: 'preApplicationStart', label: '사전접수 시작일' },
]

const UNFILLED_POLICY_OPTIONS = [
  { value: 'pending', label: '미확정' },
  { value: 'carryToGeneral', label: '일반전형 이월' },
  { value: 'remainVacant', label: '결원 유지' },
]

export default function AdmissionCycleSettingsPage() {
  const { year: currentYear, round: currentRound, refresh: refreshCycle } = useAdmissionCycle()
  const admissionMode = useAdmissionMode()
  const [rounds, setRounds] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [switchingKey, setSwitchingKey] = useState(null)
  const [stageTarget, setStageTarget] = useState(null) // { year, round } — 단계·평가영역 설정 패널

  // ---------- 새 회차 만들기 / 기존 회차 일정 수정 ----------
  // mode: 'create'(새 (year, round) 초기화) | 'edit'(기존 회차의 일정·모집정원만
  // 새 config revision으로 교체 — revision은 불변이라 "수정"도 내부적으로는
  // 새 revision 생성 + init_admission_round 재호출(같은 year/round라 config_revision_id만 갈아끼움)이다.
  const [mode, setMode] = useState('create')
  const [editTarget, setEditTarget] = useState(null) // { year, round } — mode==='edit'일 때만
  const [showCreate, setShowCreate] = useState(false)
  const [templateKey, setTemplateKey] = useState('')
  const [templateLoading, setTemplateLoading] = useState(false)
  const [templateError, setTemplateError] = useState(null)
  const [templateSchedule, setTemplateSchedule] = useState(null)
  const [templateScoringParams, setTemplateScoringParams] = useState(null)
  const [newYear, setNewYear] = useState('')
  const [newRound, setNewRound] = useState('')
  const [scheduleForm, setScheduleForm] = useState({})
  const [quotaForm, setQuotaForm] = useState({
    general: '', incheon: '', social: '', total: '', screeningMultiple: '', unfilledTrackPolicy: 'pending',
  })
  const [showConfirm, setShowConfirm] = useState(false)
  const [creating, setCreating] = useState(false)
  const [createError, setCreateError] = useState(null)
  const [createNotice, setCreateNotice] = useState(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('list_admission_rounds')
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setRounds(data || [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const switchTo = async (year, round) => {
    const key = `${year}_${round}`
    setSwitchingKey(key)
    setError(null)
    const { error: err } = await supabase.rpc('set_current_admission_cycle', {
      p_year: year,
      p_round: round,
    })
    setSwitchingKey(null)
    if (err) {
      setError(err.message)
      return
    }
    await load()
    await refreshCycle()
  }

  const existingKeys = useMemo(
    () => new Set((rounds || []).map((r) => `${r.year}_${r.round}`)),
    [rounds],
  )

  const roundOptionsForYear = useMemo(() => {
    if (!newYear) return ROUND_OPTIONS
    return ROUND_OPTIONS.filter((r) => !existingKeys.has(`${newYear}_${r}`))
  }, [newYear, existingKeys])

  const loadTemplate = async (year, round) => {
    setTemplateLoading(true)
    setTemplateError(null)
    setTemplateSchedule(null)
    setTemplateScoringParams(null)

    const { data: roundRow, error: roundErr } = await supabase
      .from('admission_rounds')
      .select('config_revision_id')
      .eq('year', year)
      .eq('round', round)
      .maybeSingle()

    if (roundErr || !roundRow) {
      setTemplateLoading(false)
      setTemplateError(roundErr?.message || '템플릿 회차 설정을 찾을 수 없습니다.')
      return
    }

    const { data: revRow, error: revErr } = await supabase
      .from('config_revisions')
      .select('schedule, scoring_params')
      .eq('id', roundRow.config_revision_id)
      .maybeSingle()

    setTemplateLoading(false)
    if (revErr || !revRow) {
      setTemplateError(revErr?.message || '템플릿 설정을 불러오지 못했습니다.')
      return
    }

    const schedule = revRow.schedule || {}
    const scoringParams = revRow.scoring_params || {}
    setTemplateSchedule(schedule)
    setTemplateScoringParams(scoringParams)
    setScheduleForm(Object.fromEntries(SCHEDULE_FIELDS.map((f) => [f.key, schedule[f.key] || ''])))
    const q = scoringParams.quota || {}
    setQuotaForm({
      general: q.general ?? '',
      incheon: q.incheon ?? '',
      social: q.social ?? '',
      total: q.total ?? '',
      screeningMultiple: q.screeningMultiple ?? '',
      unfilledTrackPolicy: q.unfilledTrackPolicy || 'pending',
    })
  }

  const openCreateForm = () => {
    setMode('create')
    setEditTarget(null)
    setCreateError(null)
    setCreateNotice(null)
    const defaultTemplate = (rounds || []).find((r) => r.isCurrent) || (rounds || [])[0]
    if (defaultTemplate) {
      setTemplateKey(`${defaultTemplate.year}_${defaultTemplate.round}`)
      setNewYear(String(defaultTemplate.year))
      loadTemplate(defaultTemplate.year, defaultTemplate.round)
    } else {
      setTemplateKey('')
      setNewYear('')
    }
    setNewRound('')
    setShowCreate(true)
  }

  const openEditForm = (year, round) => {
    setMode('edit')
    setEditTarget({ year, round })
    setCreateError(null)
    setCreateNotice(null)
    setTemplateKey(`${year}_${round}`)
    setNewYear(String(year))
    setNewRound(round)
    loadTemplate(year, round)
    setShowCreate(true)
  }

  const handleTemplateChange = (key) => {
    setTemplateKey(key)
    const [y, r] = key.split('_')
    loadTemplate(Number(y), r)
  }

  const canSubmitCreate =
    Boolean(newYear) && !Number.isNaN(Number(newYear)) && Boolean(newRound) && Boolean(templateScoringParams) && !templateLoading
    && (mode === 'edit' || roundOptionsForYear.includes(newRound))

  const templateLabel = templateKey
    ? `${templateKey.split('_')[0]}학년도 ${roundToText(templateKey.split('_')[1])}`
    : '-'

  const handleCreate = async () => {
    setCreating(true)
    setCreateError(null)
    try {
      const mergedSchedule = { ...(templateSchedule || {}), ...scheduleForm }
      const mergedScoringParams = {
        ...(templateScoringParams || {}),
        quota: {
          ...(templateScoringParams?.quota || {}),
          general: Number(quotaForm.general) || 0,
          incheon: Number(quotaForm.incheon) || 0,
          social: Number(quotaForm.social) || 0,
          total: Number(quotaForm.total) || 0,
          screeningMultiple: quotaForm.screeningMultiple === '' ? (templateScoringParams?.quota?.screeningMultiple ?? 1) : Number(quotaForm.screeningMultiple),
          unfilledTrackPolicy: quotaForm.unfilledTrackPolicy,
        },
      }

      const { data: revisionId, error: draftErr } = await supabase.rpc('create_config_draft', {
        target_year: Number(newYear),
        new_schedule: mergedSchedule,
        new_scoring_params: mergedScoringParams,
      })
      if (draftErr) throw draftErr

      const { error: lockErr } = await supabase.rpc('lock_config_revision', { revision_id: revisionId })
      if (lockErr) throw lockErr

      const { error: initErr } = await supabase.rpc('init_admission_round', {
        target_year: Number(newYear),
        target_round: newRound,
        revision_id: revisionId,
      })
      if (initErr) throw initErr

      const createdYear = newYear
      const createdRound = newRound
      setShowConfirm(false)
      setShowCreate(false)
      setCreateNotice(
        mode === 'edit'
          ? `${createdYear}학년도 ${roundToText(createdRound)}의 일정·모집정원을 갱신했습니다. 진행 단계(접수/평가/사정 등)와 전환 상태는 그대로 유지됩니다.`
          : `${createdYear}학년도 ${roundToText(createdRound)} 회차를 만들었습니다. 아직 "현재 적용 중"으로 전환되지는 않았습니다 — 준비가 끝나면 아래 목록에서 "이 회차로 전환"을 눌러 적용하세요.`,
      )
      await load()
    } catch (err) {
      setCreateError(err.message)
    } finally {
      setCreating(false)
    }
  }

  // 2026-10-20: 이 화면은 아직 신입학 회차만 다룬다. 전편입학 화면에서는 착각해 신입학 회차를 바꾸지 않도록 안내만 보인다.
  if (admissionMode === ADMISSION_MODES.TRANSFER) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-6 sm:px-6">
        <PageHeader title="년도·전형(회차) 설정" description="전입생 모집전형 회차" />
        <TransferModeNotice>
          이 화면은 지금 신입학 전형 회차만 다룹니다. 전입생 모집전형 회차(1회 동계·2회 하계)는 신입학 전형이 끝난 뒤
          전입생 전형을 신입학 시스템과 통합하면서 이곳에 따로 만들어집니다. 신입학 회차를 보거나 바꾸려면 신입학 화면으로 전환하세요.
        </TransferModeNotice>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-3xl px-4 py-6 sm:px-6">
      <PageHeader
        title="년도·전형(회차) 설정"
        description="현재 시스템 전체(접수·평가·사정·발표 등 모든 화면)가 기본으로 바라보는 년도·전형을 전환하거나, 새 회차를 만듭니다."
      />

      <div className="mb-4 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-4">
        <p className="text-xs text-ink-muted">현재 적용 중</p>
        <p className="mt-1 text-lg font-bold text-brand-deepGreenStrong">
          {currentYear ? `${currentYear}학년도 · ${roundToText(currentRound)}` : '지정되지 않음'}
        </p>
      </div>

      {error && <p className="mb-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{error}</p>}
      {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}

      {rounds && rounds.length === 0 && (
        <div className="rounded-xl border border-dashed bg-white p-6 text-center text-sm text-ink-muted">
          초기화된 회차가 없습니다. 아래 "새 회차 만들기"로 먼저 하나를 만들어주세요.
        </div>
      )}

      {rounds && rounds.length > 0 && (
        <div className="overflow-hidden rounded-lg border border-border bg-white">
          <table className="min-w-full text-sm">
            <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
              <tr>
                <th className="px-3 py-2">년도</th>
                <th className="px-3 py-2">전형(회차)</th>
                <th className="px-3 py-2">진행 단계</th>
                <th className="px-3 py-2">상태</th>
                <th className="px-3 py-2 text-right">설정</th>
                <th className="px-3 py-2 text-right">전환</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {rounds.map((r) => {
                const key = `${r.year}_${r.round}`
                return (
                  <tr key={key} className={r.isCurrent ? 'bg-brand-greenSoft' : ''}>
                    <td className="px-3 py-2 font-semibold text-ink-primary">{r.year}</td>
                    <td className="px-3 py-2">{roundToText(r.round)}</td>
                    <td className="px-3 py-2 text-ink-secondary">{STAGE_LABEL[r.stage] || r.stage}</td>
                    <td className="px-3 py-2">
                      <StatusBadge
                        label={r.stageStatus === 'open' ? '열림' : r.stageStatus === 'frozen' ? '동결' : '닫힘'}
                        tone={r.stageStatus === 'open' ? 'success' : r.stageStatus === 'frozen' ? 'warning' : 'neutral'}
                      />
                    </td>
                    <td className="px-3 py-2 text-right">
                      <div className="flex justify-end gap-1.5">
                        <button
                          type="button"
                          onClick={() => setStageTarget({ year: r.year, round: r.round })}
                          className={`rounded-md border px-3 py-1.5 text-xs font-medium hover:bg-surface-subtle ${stageTarget?.year === r.year && stageTarget?.round === r.round ? 'border-brand-deepGreen text-brand-deepGreenStrong' : 'border-border text-ink-secondary'}`}
                        >
                          단계·평가영역
                        </button>
                        <button
                          type="button"
                          onClick={() => openEditForm(r.year, r.round)}
                          className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle"
                        >
                          접수기간·전형일자 수정
                        </button>
                      </div>
                    </td>
                    <td className="px-3 py-2 text-right">
                      {r.isCurrent ? (
                        <StatusBadge label="현재 적용 중" tone="success" />
                      ) : (
                        <button
                          type="button"
                          disabled={switchingKey === key}
                          onClick={() => switchTo(r.year, r.round)}
                          className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
                        >
                          {switchingKey === key ? '전환 중…' : '이 회차로 전환'}
                        </button>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {stageTarget && (
        <RoundStagePanel
          key={`${stageTarget.year}_${stageTarget.round}`}
          year={stageTarget.year}
          round={stageTarget.round}
          onClose={() => setStageTarget(null)}
          onChanged={load}
        />
      )}

      <p className="mt-4 text-xs text-ink-muted">
        회차를 전환하면 이후 모든 사용자가 새로고침 시 이 회차 기준 화면을 보게 됩니다. 전형 기간 중 실수로 전환하지 않도록 주의하세요.
      </p>

      {/* ---------- 새 회차 만들기 ---------- */}
      <div className="mt-8 border-t border-border pt-6">
        {createNotice && (
          <div className="mb-4 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-3 text-sm text-brand-deepGreenStrong">
            {createNotice}
          </div>
        )}

        {!showCreate ? (
          <button
            type="button"
            onClick={openCreateForm}
            disabled={!rounds || rounds.length === 0}
            className="rounded-md border border-brand-deepGreen px-4 py-2 text-sm font-semibold text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-40"
          >
            + 새 회차 만들기
          </button>
        ) : (
          <section className="rounded-xl border border-border bg-white p-5">
            <h3 className="text-sm font-semibold text-ink-primary">
              {mode === 'edit'
                ? `${editTarget?.year}학년도 ${roundToText(editTarget?.round)} — 접수기간·전형일자 수정`
                : '새 회차 만들기'}
            </h3>
            <p className="mt-1 text-xs text-ink-muted">
              출결·학업·공동체·자기소개서·학부모소견서·심층역량평가 등 세부 배점표는{' '}
              {mode === 'edit' ? '현재 설정과' : '아래 템플릿 회차와'} 완전히 동일하게 그대로 복사됩니다(여기서 배점
              자체는 바꿀 수 없습니다). 일정과 모집정원만 새로 입력하세요. config revision은 한 번 생성·잠기면 되돌리거나
              수정할 수 없어서 {mode === 'edit' ? '"수정"도 내부적으로는 새 revision을 만들어 교체하는 방식입니다.' : '만들기 전에 값을 다시 한번 확인하세요.'}
              {mode === 'edit' && ' 진행 단계(접수/평가/사정 등)와 현재 전환 상태는 그대로 유지됩니다.'}
            </p>

            {mode === 'create' && (
              <label className="mt-4 block text-sm font-medium text-ink-primary">
                배점표를 복사할 템플릿 회차
                <select
                  value={templateKey}
                  onChange={(e) => handleTemplateChange(e.target.value)}
                  className="mt-1.5 w-full rounded-md border border-border px-3 py-2 text-sm"
                >
                  {(rounds || []).map((r) => (
                    <option key={`${r.year}_${r.round}`} value={`${r.year}_${r.round}`}>
                      {r.year}학년도 {roundToText(r.round)}
                    </option>
                  ))}
                </select>
              </label>
            )}

            {templateLoading && <p className="mt-2 text-xs text-ink-muted">{mode === 'edit' ? '현재 설정을' : '템플릿 설정을'} 불러오는 중…</p>}
            {templateError && (
              <p className="mt-2 rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{templateError}</p>
            )}

            {mode === 'create' ? (
              <div className="mt-4 grid gap-3 sm:grid-cols-2">
                <label className="text-sm font-medium text-ink-primary">
                  새 회차 년도
                  <input
                    type="number"
                    value={newYear}
                    onChange={(e) => {
                      setNewYear(e.target.value)
                      setNewRound('')
                    }}
                    className="mt-1.5 w-full rounded-md border border-border px-3 py-2 text-sm"
                    placeholder="예: 2027"
                  />
                </label>
                <label className="text-sm font-medium text-ink-primary">
                  전형(회차)
                  <select
                    value={newRound}
                    onChange={(e) => setNewRound(e.target.value)}
                    className="mt-1.5 w-full rounded-md border border-border px-3 py-2 text-sm"
                  >
                    <option value="">선택하세요</option>
                    {roundOptionsForYear.map((r) => (
                      <option key={r} value={r}>{roundToText(r)}</option>
                    ))}
                  </select>
                </label>
              </div>
            ) : (
              <div className="mt-4 rounded-md bg-surface-subtle p-3 text-sm text-ink-primary">
                대상 회차: <strong>{editTarget?.year}학년도 {roundToText(editTarget?.round)}</strong>
              </div>
            )}
            {mode === 'create' && newYear && roundOptionsForYear.length === 0 && (
              <p className="mt-2 text-xs text-status-warning">
                {newYear}학년도는 이미 본전형·추가모집(1차)·추가모집(2차)이 모두 만들어져 있습니다.
              </p>
            )}

            <h4 className="mt-5 text-sm font-semibold text-ink-primary">일정</h4>
            <div className="mt-2 grid gap-3 sm:grid-cols-2">
              {SCHEDULE_FIELDS.map((f) => (
                <label key={f.key} className="text-xs font-medium text-ink-secondary">
                  {f.label}
                  <input
                    type="date"
                    value={scheduleForm[f.key] || ''}
                    onChange={(e) => setScheduleForm((current) => ({ ...current, [f.key]: e.target.value }))}
                    className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                  />
                </label>
              ))}
            </div>

            <h4 className="mt-5 text-sm font-semibold text-ink-primary">모집정원</h4>
            <div className="mt-2 grid gap-3 sm:grid-cols-3">
              <label className="text-xs font-medium text-ink-secondary">
                일반
                <input
                  type="number"
                  value={quotaForm.general}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, general: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                />
              </label>
              <label className="text-xs font-medium text-ink-secondary">
                인천학생추천
                <input
                  type="number"
                  value={quotaForm.incheon}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, incheon: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                />
              </label>
              <label className="text-xs font-medium text-ink-secondary">
                사회통합
                <input
                  type="number"
                  value={quotaForm.social}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, social: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                />
              </label>
              <label className="text-xs font-medium text-ink-secondary">
                총원
                <input
                  type="number"
                  value={quotaForm.total}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, total: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                />
              </label>
              <label className="text-xs font-medium text-ink-secondary">
                서류사정 배수
                <input
                  type="number"
                  step="0.1"
                  value={quotaForm.screeningMultiple}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, screeningMultiple: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                />
              </label>
              <label className="text-xs font-medium text-ink-secondary">
                미충원 정책
                <select
                  value={quotaForm.unfilledTrackPolicy}
                  onChange={(e) => setQuotaForm((c) => ({ ...c, unfilledTrackPolicy: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
                >
                  {UNFILLED_POLICY_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>{o.label}</option>
                  ))}
                </select>
              </label>
            </div>

            {createError && (
              <p className="mt-4 rounded-md bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">{createError}</p>
            )}

            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowCreate(false)}
                className="rounded-md border border-border px-4 py-2 text-sm text-ink-secondary hover:bg-surface-subtle"
              >
                취소
              </button>
              <button
                type="button"
                disabled={!canSubmitCreate}
                onClick={() => setShowConfirm(true)}
                className="rounded-md bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
              >
                {mode === 'edit' ? '일정·모집정원 저장' : '새 회차 만들기'}
              </button>
            </div>
          </section>
        )}
      </div>

      <TypedConfirmDialog
        open={showConfirm}
        title={mode === 'edit' ? '일정·모집정원을 저장하겠습니까?' : '새 회차를 만들겠습니까? — 배점표 설정은 되돌릴 수 없습니다'}
        description={
          mode === 'edit'
            ? 'config revision은 불변이라 저장 시 새 revision을 만들어 이 회차에 연결합니다. 배점표(출결·학업·심층평가 등)는 현재 설정 그대로 유지되고, 일정·모집정원만 지금 입력한 값으로 바뀝니다.'
            : 'config revision은 한 번 잠기면 절대 수정할 수 없습니다. 배점표는 위 템플릿 회차와 동일하게 복사되고, 일정·모집정원만 지금 입력한 값으로 저장됩니다.'
        }
        fields={[
          ...(mode === 'create' ? [{ label: '템플릿(배점표 복사 대상)', value: templateLabel }] : []),
          { label: mode === 'edit' ? '대상 회차' : '새 회차', value: newYear && newRound ? `${newYear}학년도 ${roundToText(newRound)}` : '-' },
          { label: '접수기간', value: `${scheduleForm.receiptStart || '-'} ~ ${scheduleForm.receiptEnd || '-'}` },
          { label: '모집정원(일반/인천/사회통합/총원)', value: `${quotaForm.general || 0} / ${quotaForm.incheon || 0} / ${quotaForm.social || 0} / ${quotaForm.total || 0}` },
        ]}
        confirmPhrase={mode === 'edit' ? '일정 수정' : '새 회차 생성'}
        confirmLabel={mode === 'edit' ? '저장' : '생성'}
        onConfirm={handleCreate}
        onCancel={() => setShowConfirm(false)}
        submitting={creating}
        error={createError}
      />
    </div>
  )
}
