// M7a 감사 로그 조회 (마스터 스펙 M7 "감사 로그 조회... 평가 잠금 해제·재제출·
// 위원 대체배정 이력")
//
// audit_logs 자체는 이미 M4~M6 전체 RPC가 기록하고 있다. 이 화면은 그 데이터를
// 필터링해서 보여주기만 한다 — 새 로깅을 추가하지 않는다.
//
// UX1-G(27장) 리터치: 이 화면은 UX1-A~F 재설계 범위에 포함되지 않았던
// 페이지라 raw Tailwind 회색(gray-*)과 제목의 M-code("M7a/b")가 그대로
// 남아 있었다. PageHeader/디자인 토큰으로 정리하고, 상세보기를 표로 접혀
// 있던 <pre> JSON에서 다른 화면과 동일한 우측 Drawer로 옮긴다("audit detail
// drawer visual standard").

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import PageHeader from '../../components/layout/PageHeader'
import Drawer from '../../components/layout/Drawer'
import EmptyState from '../../components/feedback/EmptyState'
import ErrorState from '../../components/feedback/ErrorState'
import { useAdmissionCycle } from '../../contexts/AdmissionCycleContext'

const CATEGORIES = [
  { label: '전체', pattern: null },
  { label: '잠금해제·재제출·대체배정', pattern: '%reopened%' },
  { label: '사정 실행(1단계/최종)', pattern: 'decision.%' },
  { label: '채점 제출', pattern: 'score.%.submitted' },
  { label: '평가계획(모둠/면접/글쓰기)', pattern: '%_plan.%' },
  { label: '설정/라운드 변경', pattern: null, custom: ['config.%', 'admission_round.%'] },
  { label: '계정 관리', pattern: 'user.access.%' },
  { label: '내보내기·상세열람', pattern: null, custom: ['decision.final.pass_list_exported%', 'paper_backup.%', 'document.viewed', 'score.detail_viewed'] },
  { label: '지원자 접수', pattern: 'applicant.%' },
]

const PAGE_SIZE = 30

function formatDate(iso) {
  return new Date(iso).toLocaleString('ko-KR', { dateStyle: 'medium', timeStyle: 'short' })
}

export default function AuditLogPage() {
  const { year: YEAR } = useAdmissionCycle()
  const [view, setView] = useState('audit')
  const [round, setRound] = useState('main')
  const [categoryIdx, setCategoryIdx] = useState(0)
  const [page, setPage] = useState(0)
  const [items, setItems] = useState([])
  const [totalCount, setTotalCount] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [detailItem, setDetailItem] = useState(null)
  const [exportItems, setExportItems] = useState([])
  const [exportTotal, setExportTotal] = useState(0)
  const [exportLoading, setExportLoading] = useState(false)

  const load = useCallback(async () => {
    if (!YEAR) return
    setLoading(true)
    setError(null)
    const category = CATEGORIES[categoryIdx]

    // custom(복수 패턴)인 카테고리는 클라이언트에서 순차 조회 후 합쳐서 보여준다.
    if (category.custom) {
      const results = await Promise.all(
        category.custom.map((pattern) =>
          supabase.rpc('get_audit_logs', {
            p_year: YEAR,
            p_round: round || null,
            p_action_like: pattern,
            p_limit: PAGE_SIZE,
            p_offset: 0,
          }),
        ),
      )
      const err = results.find((r) => r.error)
      if (err) {
        setError(err.error.message)
        setLoading(false)
        return
      }
      const merged = results.flatMap((r) => r.data.items)
      merged.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
      setItems(merged.slice(0, PAGE_SIZE))
      setTotalCount(results.reduce((sum, r) => sum + r.data.totalCount, 0))
      setLoading(false)
      return
    }

    const { data, error: err } = await supabase.rpc('get_audit_logs', {
      p_year: YEAR,
      p_round: round || null,
      p_action_like: category.pattern,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE,
    })
    setLoading(false)
    if (err) {
      setError(err.message)
      return
    }
    setItems(data.items)
    setTotalCount(data.totalCount)
  }, [round, categoryIdx, page, YEAR])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (view !== 'exports' || !YEAR) return
    let cancelled = false
    setExportLoading(true)
    supabase
      .rpc('get_export_history', { p_year: YEAR, p_round: round || null, p_limit: PAGE_SIZE })
      .then(({ data, error: err }) => {
        if (cancelled) return
        setExportLoading(false)
        if (err) {
          setError(err.message)
          return
        }
        setExportItems(data.items)
        setExportTotal(data.totalCount)
      })
    return () => {
      cancelled = true
    }
  }, [view, round, YEAR])

  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE))

  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      <PageHeader
        title="감사 로그 · 내보내기 이력"
        description={`${YEAR}학년도 · 누가·언제·무엇을 했는지 전체 기록`}
      />

      <div className="mb-4 flex gap-2 border-b border-border">
        <button
          type="button"
          onClick={() => setView('audit')}
          className={`px-3 py-2 text-sm ${view === 'audit' ? 'border-b-2 border-brand-deepGreen font-semibold text-brand-deepGreenStrong' : 'text-ink-muted'}`}
        >
          감사 로그
        </button>
        <button
          type="button"
          onClick={() => setView('exports')}
          className={`px-3 py-2 text-sm ${view === 'exports' ? 'border-b-2 border-brand-deepGreen font-semibold text-brand-deepGreenStrong' : 'text-ink-muted'}`}
        >
          내보내기 이력
        </button>
      </div>

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <select
          value={round}
          onChange={(e) => {
            setRound(e.target.value)
            setPage(0)
          }}
          className="rounded-md border border-border px-3 py-1.5 text-sm"
        >
          <option value="">전체 차수</option>
          <option value="main">본전형</option>
          <option value="extra1">추가모집(1차)</option>
          <option value="extra2">추가모집(2차)</option>
        </select>
        {view === 'audit' && (
          <select
            value={categoryIdx}
            onChange={(e) => {
              setCategoryIdx(Number(e.target.value))
              setPage(0)
            }}
            className="rounded-md border border-border px-3 py-1.5 text-sm"
          >
            {CATEGORIES.map((c, i) => (
              <option key={c.label} value={i}>
                {c.label}
              </option>
            ))}
          </select>
        )}
        <span className="text-xs text-ink-muted">총 {view === 'audit' ? totalCount : exportTotal}건</span>
      </div>

      {error && <ErrorState description={error} onRetry={load} />}

      {view === 'audit' && (
        <>
          {loading && <p className="text-sm text-ink-muted">불러오는 중…</p>}

          {!loading && items.length === 0 && !error && (
            <EmptyState title="해당 조건의 기록이 없습니다" />
          )}

          {!loading && items.length > 0 && (
            <div className="overflow-x-auto rounded-lg border border-border bg-surface-card">
              <table className="min-w-full text-sm">
                <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
                  <tr>
                    <th className="px-3 py-2">시각</th>
                    <th className="px-3 py-2">수행자</th>
                    <th className="px-3 py-2">동작</th>
                    <th className="px-3 py-2">대상</th>
                    <th className="px-3 py-2">사유</th>
                    <th className="px-3 py-2" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {items.map((it) => (
                    <tr key={it.id}>
                      <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-muted">{formatDate(it.createdAt)}</td>
                      <td className="px-3 py-2">
                        {it.actorType === 'system' ? (
                          <span className="text-ink-muted">시스템</span>
                        ) : (
                          it.actorName || <span className="text-ink-muted">알 수 없음</span>
                        )}
                      </td>
                      <td className="px-3 py-2 font-mono text-xs">{it.action}</td>
                      <td className="px-3 py-2 text-xs text-ink-secondary">
                        {it.resourceType}
                        {it.resourceId ? ` · ${it.resourceId}` : ''}
                      </td>
                      <td className="px-3 py-2 text-xs text-ink-secondary">{it.reasonCode || '-'}</td>
                      <td className="px-3 py-2">
                        {it.metadata && Object.keys(it.metadata).length > 0 && (
                          <button
                            type="button"
                            onClick={() => setDetailItem(it)}
                            className="text-xs text-brand-deepGreenStrong underline"
                          >
                            상세
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {!loading && totalPages > 1 && (
            <div className="mt-4 flex items-center justify-center gap-3">
              <button
                type="button"
                onClick={() => setPage((p) => Math.max(0, p - 1))}
                disabled={page === 0}
                className="rounded-md border border-border px-3 py-1.5 text-xs disabled:opacity-40"
              >
                이전
              </button>
              <span className="text-xs text-ink-muted">
                {page + 1} / {totalPages}
              </span>
              <button
                type="button"
                onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
                disabled={page >= totalPages - 1}
                className="rounded-md border border-border px-3 py-1.5 text-xs disabled:opacity-40"
              >
                다음
              </button>
            </div>
          )}
        </>
      )}

      {view === 'exports' && (
        <>
          {exportLoading && <p className="text-sm text-ink-muted">불러오는 중…</p>}
          {!exportLoading && exportItems.length === 0 && (
            <EmptyState title="내보내기 기록이 없습니다" />
          )}
          {!exportLoading && exportItems.length > 0 && (
            <div className="overflow-x-auto rounded-lg border border-border bg-surface-card">
              <table className="min-w-full text-sm">
                <thead className="bg-surface-subtle text-left text-xs text-ink-muted">
                  <tr>
                    <th className="px-3 py-2">시각</th>
                    <th className="px-3 py-2">종류</th>
                    <th className="px-3 py-2">형식</th>
                    <th className="px-3 py-2">건수</th>
                    <th className="px-3 py-2">생성자</th>
                    <th className="px-3 py-2">체크섬(SHA-256)</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {exportItems.map((it) => (
                    <tr key={it.id}>
                      <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-muted">{formatDate(it.generatedAt)}</td>
                      <td className="px-3 py-2 text-xs">{it.exportType}</td>
                      <td className="px-3 py-2 text-xs uppercase text-ink-muted">{it.fileFormat}</td>
                      <td className="px-3 py-2 text-xs">{it.rowCount ?? '-'}</td>
                      <td className="px-3 py-2 text-xs">{it.generatedByName || '-'}</td>
                      <td className="px-3 py-2 font-mono text-[10px] text-ink-muted" title={it.checksumSha256}>
                        {it.checksumSha256.slice(0, 16)}…
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      <Drawer
        open={Boolean(detailItem)}
        onClose={() => setDetailItem(null)}
        title="감사 로그 상세"
        subtitle={detailItem?.action}
      >
        {detailItem && (
          <>
            <dl className="mb-5 space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-ink-muted">시각</dt>
                <dd className="text-ink-primary">{formatDate(detailItem.createdAt)}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-ink-muted">수행자</dt>
                <dd className="text-ink-primary">{detailItem.actorType === 'system' ? '시스템' : detailItem.actorName || '알 수 없음'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-ink-muted">대상</dt>
                <dd className="text-ink-primary">
                  {detailItem.resourceType}
                  {detailItem.resourceId ? ` · ${detailItem.resourceId}` : ''}
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-ink-muted">사유</dt>
                <dd className="text-ink-primary">{detailItem.reasonCode || '-'}</dd>
              </div>
            </dl>
            <p className="mb-1 text-xs font-medium text-ink-secondary">부가 정보</p>
            <pre className="whitespace-pre-wrap rounded-md bg-surface-subtle p-3 text-xs text-ink-secondary">
              {JSON.stringify(detailItem.metadata, null, 2)}
            </pre>
          </>
        )}
      </Drawer>
    </div>
  )
}
