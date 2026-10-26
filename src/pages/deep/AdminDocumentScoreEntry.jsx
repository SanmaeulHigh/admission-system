// 서류평가 관리자 대리 채점 입력 (2026-09-28 추가)
//
// 심층역량평가 대리 입력(AdminScoreEntryPage)과 같은 화면 안에서 동작하는
// 서류평가 5개 영역(출결·학업성실도·공동체·자기소개서·학부모소견서)용 패널이다.
//
// 설계상 중요한 점: 채점 입력 UI를 새로 만들지 않고 평가위원이 실제로 쓰는
// 폼 컴포넌트를 그대로 재사용한다. proxy prop만 넘기면 폼이 admin_* RPC를
// 호출한다. 이렇게 해야 (1) 입력 검증이 평가위원 화면과 어긋나지 않고
// (2) 나중에 채점 항목이 바뀌어도 한 군데만 고치면 된다.

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'
import AttendanceScoreForm from '../evaluation/AttendanceScoreForm'
import AcademicScoreForm from '../evaluation/AcademicScoreForm'
import CommunityScoreForm from '../evaluation/CommunityScoreForm'
import EssayScoreForm from '../evaluation/EssayScoreForm'
import OpinionScoreForm from '../evaluation/OpinionScoreForm'
import StatusBadge from '../../components/status/StatusBadge'
import ReopenScoreButton from '../../components/actions/ReopenScoreButton'

const FORM_BY_AREA = {
  attendance: AttendanceScoreForm,
  academic: AcademicScoreForm,
  community: CommunityScoreForm,
  essay: EssayScoreForm,
  opinion: OpinionScoreForm,
}

const AREA_LABEL = {
  attendance: '출결',
  academic: '학업성실도',
  community: '공동체생활적합성',
  essay: '자기소개서',
  opinion: '학부모소견서',
}

function scoreOf(serverComputed) {
  if (!serverComputed) return null
  return serverComputed.score ?? serverComputed.total ?? null
}

export default function AdminDocumentScoreEntry({ area, evaluatorUid, reasonCode, reasonText, onSubmitted }) {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [context, setContext] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [selectedApplicantId, setSelectedApplicantId] = useState(null)
  const [reopenTick, setReopenTick] = useState(0) // 재개방 후 채점 폼을 새로 띄우기 위함

  const load = useCallback(async () => {
    if (!YEAR || !ROUND || !evaluatorUid) {
      setContext(null)
      return
    }
    setLoading(true)
    setError(null)
    const { data, error: err } = await supabase.rpc('admin_get_document_score_entry_context', {
      p_year: YEAR,
      p_round: ROUND,
      p_area: area,
      p_target_evaluator_uid: evaluatorUid,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      setContext(null)
      return
    }
    setContext(data)
  }, [YEAR, ROUND, area, evaluatorUid])

  useEffect(() => {
    setSelectedApplicantId(null)
    load()
  }, [load])

  if (!evaluatorUid) {
    return (
      <div className="rounded-xl border border-dashed border-border bg-white p-6 text-center text-sm text-ink-muted">
        대상 평가위원을 선택하면 담당 지원자 명단이 표시됩니다.
      </div>
    )
  }

  if (loading) return <div className="text-sm text-ink-muted">불러오는 중…</div>
  if (error) {
    return <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>
  }
  if (!context) return null

  const items = context.items || []
  const selected = items.find((i) => i.applicantId === selectedApplicantId) || null
  const FormComponent = FORM_BY_AREA[area]
  const doneCount = items.filter((i) => i.submissionState === 'submitted').length

  return (
    <div className="space-y-4">
      {!context.areaOpen && (
        <div className="rounded-lg border border-status-warning bg-status-warningSoft p-3 text-sm text-status-warning">
          현재 {AREA_LABEL[area]} 평가영역이 열려있지 않아 제출이 서버에서 차단됩니다.
          시스템 관리에서 해당 영역을 먼저 열어주세요.
        </div>
      )}

      {/* 지원자 목록 */}
      {!selected && (
        <section className="rounded-xl border border-border bg-white p-4">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-ink-primary">
              {AREA_LABEL[area]} — 이 평가위원의 채점 대상
            </h3>
            <span className="text-xs text-ink-muted">{doneCount} / {items.length} 제출</span>
          </div>

          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {items.map((item) => {
              const submitted = item.submissionState === 'submitted'
              const score = scoreOf(item.serverComputed)
              return (
                <button
                  key={item.applicantId}
                  type="button"
                  onClick={() => setSelectedApplicantId(item.applicantId)}
                  className="rounded-lg border border-border p-3 text-left hover:border-brand-deepGreen"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate font-semibold text-ink-primary">{item.displayName}</p>
                      <p className="font-mono text-xs text-ink-muted">{item.examNo || item.receiptNo}</p>
                    </div>
                    <StatusBadge
                      status={item.submissionState || 'draft'}
                      label={item.submissionState ? undefined : '미입력'}
                    />
                  </div>
                  {submitted && score !== null && (
                    <p className="mt-2 text-right text-xs font-semibold text-brand-deepGreenStrong">{score}점</p>
                  )}
                </button>
              )
            })}
          </div>

          {items.length === 0 && (
            <p className="py-6 text-center text-sm text-ink-muted">
              이 평가위원에게 배정된 지원자가 없습니다.
            </p>
          )}
        </section>
      )}

      {/* 선택한 지원자 채점 — 평가위원이 쓰는 폼을 그대로 띄운다 */}
      {selected && FormComponent && (
        <section className="rounded-xl border border-border bg-white p-4">
          <button
            type="button"
            onClick={() => setSelectedApplicantId(null)}
            className="text-xs text-ink-muted underline hover:text-ink-primary"
          >
            ← 대상 목록
          </button>

          <div className="mt-2 mb-4 flex flex-wrap items-center justify-between gap-2 border-b border-border pb-3">
            <div>
              <p className="text-lg font-bold text-ink-primary">{selected.displayName}</p>
              <p className="font-mono text-xs text-ink-muted">{selected.examNo || selected.receiptNo}</p>
            </div>
            {selected.submissionState === 'submitted' && (
              <div className="flex items-center gap-2 rounded-md bg-status-warningSoft px-3 py-2 text-xs text-status-warning">
                <span>이미 제출확정된 채점입니다. 고치려면 먼저 재개방하세요.</span>
                <ReopenScoreButton
                  area={area}
                  applicantId={selected.applicantId}
                  evaluatorUid={evaluatorUid}
                  targetText={selected.displayName}
                  onDone={async () => { setReopenTick((t) => t + 1); await load() }}
                />
              </div>
            )}
          </div>

          <FormComponent
            key={`${area}-${selected.applicantId}-${evaluatorUid}-${reopenTick}`}
            applicantId={selected.applicantId}
            proxy={{ evaluatorUid, reasonCode, reasonText }}
            onSubmitted={async () => {
              await load()
              onSubmitted?.()
            }}
          />
        </section>
      )}
    </div>
  )
}
