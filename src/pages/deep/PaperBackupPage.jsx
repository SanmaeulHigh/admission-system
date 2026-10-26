import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { buildPaperBackupDocument } from '../../lib/paperBackupHtml'
import { workStatusText } from '../../config/statusLabels'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

const AREA_META = {
  group: {
    title: '모둠활동 평가표',
    description: '평가위원별 계획 모둠·순환 관찰 시간과 지원자 명단을 A4 가로 평가표로 출력합니다.',
  },
  interview: {
    title: '학생·학부모 면접 평가표',
    description: '면접조 2인 각각의 독립 평가표를 지원자별 A4 세로 1쪽으로 출력합니다.',
  },
  writing: {
    title: '지원자 글쓰기 평가표',
    description: '글쓰기 평가위원 2인 각각의 3문항 중 2택 채점표를 지원자별 A4 세로 1쪽으로 출력합니다.',
  },
}

function statusBadge(areaStatus) {
  if (areaStatus?.ready) return 'bg-brand-greenSoft text-brand-deepGreenStrong'
  if (areaStatus?.status === 'finalized') return 'bg-status-warningSoft text-status-warning'
  return 'bg-surface-subtle text-ink-secondary'
}

function statusText(areaStatus) {
  if (areaStatus?.ready) return '인쇄 준비 완료'
  if (areaStatus?.status === 'finalized') return '확정 · 서버 검증 필요'
  if (areaStatus?.status === 'draft') return '임시계획'
  return '계획 없음'
}

export default function PaperBackupPage() {
  const { year: YEAR, round: ROUND } = useAdmissionCycle()
  const [status, setStatus] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busyArea, setBusyArea] = useState(null)
  const [error, setError] = useState(null)
  const [message, setMessage] = useState(null)

  const loadStatus = useCallback(async () => {
    if (!YEAR || !ROUND) return
    setLoading(true)
    setError(null)
    const { data, error: loadError } = await supabase.rpc('get_m5e_paper_backup_status', {
      p_year: YEAR,
      p_round: ROUND,
    })
    if (loadError) {
      setStatus(null)
      setError(loadError.message)
    } else {
      setStatus(data)
    }
    setLoading(false)
  }, [YEAR, ROUND])

  useEffect(() => {
    loadStatus()
  }, [loadStatus])

  const candidateCount = Number(status?.candidateCount || 0)
  const allReady = status?.allReady === true
  const readyCount = useMemo(
    () => Object.keys(AREA_META).filter((area) => status?.[area]?.ready).length,
    [status],
  )

  const openPacket = async (area, printNow) => {
    const areaStatus = status?.[area]
    if (printNow && !areaStatus?.ready) {
      setError('운영용 인쇄는 해당 평가계획이 최종확정·서버 검증 완료된 뒤 가능합니다.')
      return
    }

    const previewWindow = window.open('', '_blank')
    if (!previewWindow) {
      setError('새 창이 차단되었습니다. 이 사이트의 팝업을 허용한 뒤 다시 시도하세요.')
      return
    }
    previewWindow.document.write('<!doctype html><meta charset="utf-8"><title>종이 백업 준비 중</title><p style="font-family:sans-serif;padding:24px">종이 백업 평가표를 준비하는 중입니다…</p>')

    setBusyArea(area)
    setError(null)
    setMessage(null)
    try {
      const { data: packet, error: packetError } = await supabase.rpc('get_m5e_paper_backup_packet', {
        p_year: YEAR,
        p_round: ROUND,
        p_area: area,
      })
      if (packetError) throw packetError

      const document = buildPaperBackupDocument(packet, { autoPrint: printNow })

      if (printNow) {
        const { error: logError } = await supabase.rpc('log_m5e_paper_backup_print', {
          p_year: YEAR,
          p_round: ROUND,
          p_area: area,
          p_page_count: document.pageCount,
          p_copy_count: 1,
          p_mode: 'print_dialog',
        })
        if (logError) throw logError
      }

      previewWindow.document.open()
      previewWindow.document.write(document.html)
      previewWindow.document.close()
      setMessage(`${AREA_META[area].title} ${document.pageCount}쪽 ${printNow ? '인쇄/PDF 창을 열었습니다.' : '초안 미리보기를 열었습니다.'}`)
    } catch (err) {
      previewWindow.close()
      setError(err.message)
    } finally {
      setBusyArea(null)
    }
  }

  if (loading) {
    return <p className="p-6 text-sm text-ink-muted">종이 백업 준비상태를 확인하는 중…</p>
  }

  return (
    <>
      <div className="mx-auto max-w-5xl">
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
          <div>
            <h1 className="text-lg font-semibold text-ink-primary">종이 채점표 출력</h1>
            <p className="mt-1 text-sm text-ink-muted">심층역량평가(모둠활동·면접·글쓰기)는 종이 채점표로 운영합니다. 수험번호·성명이 미리 인쇄된 A4 채점표를 뽑습니다.</p>
          </div>
          <span className={`rounded-full px-3 py-1 text-xs font-semibold ${allReady ? 'bg-brand-greenSoft text-brand-deepGreenStrong' : 'bg-status-warningSoft text-status-warning'}`}>
            {allReady ? '전 영역 인쇄 가능' : `${readyCount}/3 영역 준비`}
          </span>
        </div>

        <div className="space-y-4">
        {error && <div className="rounded-lg border border-status-danger bg-status-dangerSoft p-3 text-sm text-status-danger">{error}</div>}
        {message && <div className="rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-3 text-sm text-brand-deepGreenStrong">{message}</div>}

        <section className="grid gap-3 sm:grid-cols-3">
          <div className="rounded-xl border bg-white p-4">
            <p className="text-xs text-ink-muted">1단계 서류사정 평가대상</p>
            <p className="mt-1 text-2xl font-bold text-ink-primary">{candidateCount}명</p>
          </div>
          <div className="rounded-xl border bg-white p-4">
            <p className="text-xs text-ink-muted">인쇄 준비영역</p>
            <p className="mt-1 text-2xl font-bold text-ink-primary">{readyCount}/3</p>
          </div>
          <div className="rounded-xl border bg-white p-4">
            <p className="text-xs text-ink-muted">백업 기준</p>
            <p className="mt-1 text-sm font-bold text-ink-primary">1단계 사정 확정본</p>
            <p className="mt-1 truncate text-xs text-ink-muted">{status?.documentDecisionRunId || '-'}</p>
          </div>
        </section>

        <section className="rounded-xl border border-status-warning bg-status-warningSoft p-4 text-sm text-status-warning">
          <p className="font-semibold">종이 채점 운영 절차</p>
          <p className="mt-1 leading-relaxed">① 평가위원이 종이 채점표에 채점하고 자필 서명합니다. ② 관리자가 &lsquo;종이 채점 일괄 입력&rsquo;에서 위원별로 옮겨 적습니다. ③ 위원별 &lsquo;입력 확인표&rsquo;를 인쇄해 위원이 종이 원본과 대조·서명합니다. ④ 종이 원본과 확인표를 함께 회수·보존합니다. 초안 미리보기에는 “운영용 아님” 워터마크가 표시됩니다.</p>
        </section>

        <div className="grid gap-4 lg:grid-cols-3">
          {Object.entries(AREA_META).map(([area, meta]) => {
            const areaStatus = status?.[area] || {}
            const issues = areaStatus.blockingIssues || []
            const busy = busyArea === area
            return (
              <section key={area} className="flex flex-col rounded-xl border bg-white p-5">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <h2 className="text-sm font-semibold text-ink-primary">{meta.title}</h2>
                    <p className="mt-2 text-xs leading-relaxed text-ink-muted">{meta.description}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-1 text-[11px] font-semibold ${statusBadge(areaStatus)}`}>
                    {statusText(areaStatus)}
                  </span>
                </div>

                <div className="mt-4 rounded-lg bg-surface-subtle p-3 text-xs text-ink-secondary">
                  <p>계획 상태: <strong>{workStatusText(areaStatus.status) || '-'}</strong></p>
                  <p className="mt-1">계획 수정 차수: <strong>{areaStatus.planRevision ?? '-'}</strong></p>
                  <p className="mt-1">1단계 사정 확정본 일치: <strong>{areaStatus.sourceMatches ? '예' : '아니오'}</strong></p>
                </div>

                {issues.length > 0 && (
                  <div className="mt-3 max-h-36 space-y-2 overflow-y-auto">
                    {issues.map((issue, index) => (
                      <div key={`${issue.code}-${index}`} className="rounded-lg border border-status-danger bg-status-dangerSoft p-2 text-xs text-status-danger">
                        <p className="font-semibold">{issue.code}</p>
                        <p className="mt-1 leading-relaxed">{issue.message}</p>
                      </div>
                    ))}
                  </div>
                )}

                <div className="mt-auto flex flex-col gap-2 pt-4">
                  <button
                    type="button"
                    onClick={() => openPacket(area, false)}
                    disabled={busy || candidateCount === 0}
                    className="rounded-lg border border-border px-4 py-2 text-sm font-semibold text-ink-secondary disabled:opacity-40"
                  >
                    {busy ? '준비 중…' : '초안 미리보기'}
                  </button>
                  <button
                    type="button"
                    onClick={() => openPacket(area, true)}
                    disabled={busy || !areaStatus.ready || candidateCount === 0}
                    className="rounded-lg bg-brand-deepGreenStrong px-4 py-2 text-sm font-semibold text-white disabled:opacity-40"
                  >
                    인쇄 / PDF 저장
                  </button>
                </div>
              </section>
            )
          })}
        </div>

        <section className="rounded-xl border bg-white p-5">
          <h2 className="text-sm font-semibold text-ink-primary">출력 전 체크</h2>
          <div className="mt-3 grid gap-2 text-xs text-ink-secondary sm:grid-cols-2">
            <p>□ 프린터 용지 A4 및 흑백 출력 가독성 확인</p>
            <p>□ 수험번호·성명·전형위원 사전 인쇄 확인</p>
            <p>□ 모둠활동 평가표는 A4 가로 방향 확인</p>
            <p>□ 면접·글쓰기 평가표는 A4 세로 방향 확인</p>
            <p>□ 계획 수정 차수와 1단계 사정 확정본 일치 확인</p>
            <p>□ 전형 당일 영역별 예비 묶음 현장 비치</p>
          </div>
          <button
            type="button"
            onClick={loadStatus}
            className="mt-4 rounded-lg border border-brand-deepGreen px-4 py-2 text-sm font-semibold text-brand-deepGreenStrong"
          >
            준비상태 다시 확인
          </button>
        </section>
        </div>
      </div>
    </>
  )
}
