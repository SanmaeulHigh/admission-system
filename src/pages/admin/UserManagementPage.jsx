// 사용자(선생님) 권한 관리 화면 (2026-07-11 신설)
//
// 배경: upsert_user_access/set_user_active_status RPC는 00001부터 있었지만
// 이걸 쓰는 화면이 없었다 — 선생님이 로그인(가입)만 하고 승인 대기 상태로
// 머물러도 관리자가 SQL을 직접 써야만 승인할 수 있었다(2026-07-11 사용자
// 지적). list_pending_signins RPC(00039)로 "로그인은 했지만 아직 미승인"
// 계정을 찾아 이 화면에서 바로 이름·역할을 부여한다.
//
// 접근 통제: 이 화면은 RequireRole(['superadmin'])로 감싼다 — 실제 쓰기
// RPC(upsert_user_access/set_user_active_status)가 _require_superadmin()로
// superadmin만 허용하므로 화면 접근도 동일하게 맞춘다(화면 숨김이 곧 권한
// 통제가 아니라는 원칙은 유지 — 최종 경계는 항상 RLS/RPC 쪽 검증).

import { useEffect, useState } from 'react'
import { supabase, getEdgeFunctionErrorMessage } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import PageHeader from '../../components/layout/PageHeader'
import TransferModeNotice from '../../components/feedback/TransferModeNotice'
import DestructiveActionDialog from '../../components/actions/DestructiveActionDialog'
import { ROUND_LABEL } from '../../lib/applicantLabels'

const ROLE_OPTIONS = [
  { value: 'superadmin', label: '슈퍼관리자' },
  { value: 'admin', label: '관리자' },
  { value: 'reception', label: '접수(원서·전편입 접수)' },
  { value: 'quant', label: '정량평가' },
  { value: 'evaluator', label: '평가위원' },
  { value: 'viewer', label: '열람 전용' },
  { value: 'principal', label: '학교장 (서류 열람만, 점수 없음)' },
]

const AREA_OPTIONS = [
  { value: 'attendance', label: '출결' },
  { value: 'academic', label: '학업성실도' },
  { value: 'community', label: '공동체역량' },
  { value: 'essay', label: '자기소개서' },
  { value: 'opinion', label: '보호자소견서' },
  { value: 'group', label: '모둠활동' },
  { value: 'interview', label: '면접' },
  { value: 'writing', label: '글쓰기' },
]

const ROUND_OPTIONS = ['main', 'extra1', 'extra2']

// 서류 열람 권한(2026-10-01) — 종이 전형 때처럼 기본은 "서류 일체 열람"이고,
// 필요한 위원만 특정 서류를 끈다. DB에는 NULL(=전체) 또는 허용 종류 배열로 저장.
const DOC_VIEW_OPTIONS = [
  { value: 'applicationForm', label: '입학원서' },
  { value: 'photo', label: '사진' },
  { value: 'studentRecordSource', label: '학생부' },
  { value: 'essay', label: '자기소개서' },
  { value: 'opinion', label: '학부모 소견서' },
  { value: 'portfolio', label: '포트폴리오' },
  { value: 'writingAnswer', label: '글쓰기 답안' },
  { value: 'trackEvidence', label: '자격 증빙' },
  { value: 'consent', label: '동의서' },
]
const ALL_DOC_VIEW = DOC_VIEW_OPTIONS.map((o) => o.value)
// 예전 학생부 영역별 발췌본은 체크박스에 없고 학생부를 따라간다.
const STUDENT_RECORD_EXCERPTS = ['studentRecordAttendanceView', 'studentRecordAcademicView', 'studentRecordCommunityView']

// 화면용 체크 목록(전체면 9종 모두) ↔ DB 값(NULL 또는 배열)
const docViewToChecked = (types) => (types == null ? ALL_DOC_VIEW : ALL_DOC_VIEW.filter((t) => types.includes(t)))
const checkedToDocView = (checked) => {
  if (ALL_DOC_VIEW.every((t) => checked.includes(t))) return null
  return checked.includes('studentRecordSource') ? [...checked, ...STUDENT_RECORD_EXCERPTS] : checked
}
const docViewSummary = (types) => {
  if (types == null) return '전체'
  const checked = docViewToChecked(types)
  if (checked.length === 0) return '없음'
  const labels = DOC_VIEW_OPTIONS.filter((o) => checked.includes(o.value)).map((o) => o.label)
  return labels.length > 3 ? `${labels.slice(0, 3).join(', ')} 외 ${labels.length - 3}종` : labels.join(', ')
}

function EditForm({ initial, onCancel, onSave, saving, error }) {
  const [displayName, setDisplayName] = useState(initial.displayName || '')
  const [roles, setRoles] = useState(initial.roles || [])
  const [areas, setAreas] = useState(initial.areas || [])
  const [yearScope, setYearScope] = useState(initial.yearScope ?? 2027)
  const [rounds, setRounds] = useState(initial.rounds || ['main'])
  const [docView, setDocView] = useState(docViewToChecked(initial.docTypes ?? null))
  const [mobilePhone, setMobilePhone] = useState(initial.mobilePhone || '')

  const toggle = (list, setList, value) =>
    setList(list.includes(value) ? list.filter((v) => v !== value) : [...list, value])

  return (
    <div className="mt-3 space-y-3 rounded-md border border-border bg-surface-subtle p-3">
      <div>
        <label className="mb-1 block text-xs font-medium text-ink-secondary">표시 이름</label>
        <input
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          placeholder="예: 홍길동"
          className="w-full rounded-md border border-border px-2 py-1.5 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500"
        />
      </div>

      <div>
        <label className="mb-1 block text-xs font-medium text-ink-secondary">휴대전화 (교외 접속 인증번호를 받는 번호)</label>
        <input
          value={mobilePhone}
          onChange={(e) => setMobilePhone(e.target.value)}
          placeholder="예: 010-1234-5678 · 비워 두면 교외 접속 불가"
          inputMode="tel"
          className="w-full rounded-md border border-border px-2 py-1.5 font-mono text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500"
        />
      </div>

      <div>
        <p className="mb-1 text-xs font-medium text-ink-secondary">역할 (1개 이상)</p>
        <div className="flex flex-wrap gap-x-4 gap-y-1">
          {ROLE_OPTIONS.map((r) => (
            <label key={r.value} className="flex items-center gap-1.5 text-sm">
              <input
                type="checkbox"
                checked={roles.includes(r.value)}
                onChange={() => toggle(roles, setRoles, r.value)}
              />
              {r.label}
            </label>
          ))}
        </div>
      </div>

      {(roles.includes('evaluator') || roles.includes('quant')) && (
        <div>
          <p className="mb-1 text-xs font-medium text-ink-secondary">담당 평가 영역(평가위원·정량평가만 해당)</p>
          <div className="flex flex-wrap gap-x-4 gap-y-1">
            {AREA_OPTIONS.map((a) => (
              <label key={a.value} className="flex items-center gap-1.5 text-sm">
                <input
                  type="checkbox"
                  checked={areas.includes(a.value)}
                  onChange={() => toggle(areas, setAreas, a.value)}
                />
                {a.label}
              </label>
            ))}
          </div>
        </div>
      )}

      {(roles.includes('evaluator') || roles.includes('quant')) && (
        <div>
          <div className="mb-1 flex items-center gap-2">
            <p className="text-xs font-medium text-ink-secondary">
              서류 열람 (기본: 지원자 제출 서류 일체 · 담당 영역과 관계없이 적용)
            </p>
            <button
              type="button"
              onClick={() => setDocView(docView.length === ALL_DOC_VIEW.length ? [] : ALL_DOC_VIEW)}
              className="rounded border border-border px-1.5 py-0.5 text-[11px] text-ink-secondary hover:bg-surface-card"
            >
              {docView.length === ALL_DOC_VIEW.length ? '전체 해제' : '전체 선택'}
            </button>
          </div>
          <div className="flex flex-wrap gap-x-4 gap-y-1">
            {DOC_VIEW_OPTIONS.map((o) => (
              <label key={o.value} className="flex items-center gap-1.5 text-sm">
                <input
                  type="checkbox"
                  checked={docView.includes(o.value)}
                  onChange={() => toggle(docView, setDocView, o.value)}
                />
                {o.label}
              </label>
            ))}
          </div>
          <p className="mt-1 text-[11px] text-ink-muted">체크를 해제한 서류는 이 선생님에게 보이지 않습니다. 모든 열람은 기록됩니다.</p>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="mb-1 block text-xs font-medium text-ink-secondary">적용 연도</label>
          <input
            type="number"
            value={yearScope}
            onChange={(e) => setYearScope(Number(e.target.value))}
            className="w-full rounded-md border border-border px-2 py-1.5 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500"
          />
        </div>
        <div>
          <p className="mb-1 text-xs font-medium text-ink-secondary">적용 차수</p>
          <div className="flex flex-wrap gap-x-3 gap-y-1">
            {ROUND_OPTIONS.map((r) => (
              <label key={r} className="flex items-center gap-1 text-sm">
                <input type="checkbox" checked={rounds.includes(r)} onChange={() => toggle(rounds, setRounds, r)} />
                {r}
              </label>
            ))}
          </div>
        </div>
      </div>

      {error && <p className="text-xs text-status-danger">{error}</p>}

      <div className="flex gap-2">
        <button
          type="button"
          disabled={saving}
          onClick={() => onSave({ displayName, roles, areas, yearScope, rounds, docTypes: checkedToDocView(docView), mobilePhone: mobilePhone.trim() })}
          className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong disabled:opacity-50"
        >
          {saving ? '저장 중…' : '저장'}
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle"
        >
          취소
        </button>
      </div>
    </div>
  )
}

// 임시 비밀번호: 헷갈리는 글자(0/O, 1/l/I) 없이 10자
function makeTempPassword() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  const a = new Uint32Array(10)
  crypto.getRandomValues(a)
  return `Sm-${Array.from(a, (n) => chars[n % chars.length]).join('')}`
}

// 전달용 안내(아이디·임시 비밀번호). 화면에 한 번만 보이고 저장되지 않는다.
function CredentialNotice({ info, onClose }) {
  const text = `[새봄고 입학전형관리시스템]\n주소: ${window.location.origin}\n아이디: ${info.email}\n임시 비밀번호: ${info.password}\n처음 로그인하면 새 비밀번호를 정하는 화면이 나옵니다.`
  const [copied, setCopied] = useState(false)
  return (
    <div className="mb-4 rounded-lg border border-brand-deepGreen bg-brand-greenSoft p-4 text-sm">
      <p className="font-semibold text-brand-deepGreenStrong">{info.title}</p>
      <pre className="mt-2 whitespace-pre-wrap rounded-md bg-white px-3 py-2 font-mono text-xs text-ink-primary">{text}</pre>
      <p className="mt-1 text-xs text-ink-muted">이 내용은 지금 한 번만 보입니다. 복사해서 선생님께 따로 전달하세요.</p>
      <div className="mt-2 flex gap-2">
        <button type="button" onClick={async () => { await navigator.clipboard?.writeText(text); setCopied(true) }}
          className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong">
          {copied ? '복사됨' : '복사하기'}
        </button>
        <button type="button" onClick={onClose} className="rounded-md border border-border bg-white px-3 py-1.5 text-xs text-ink-secondary">닫기</button>
      </div>
    </div>
  )
}

// 최고관리자 계정 생성(자체 회원가입은 닫음 — admin-manage-user Edge Function)
function CreateUserPanel({ onCreated }) {
  const [open, setOpen] = useState(false)
  const [email, setEmail] = useState('')
  const [tempPw, setTempPw] = useState(makeTempPassword)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)

  const save = async (form) => {
    setError(null)
    setSaving(true)
    const { data, error: err } = await supabase.functions.invoke('admin-manage-user', {
      body: {
        action: 'create',
        email: email.trim(),
        password: tempPw,
        displayName: form.displayName.trim(),
        roles: form.roles,
        areas: form.areas,
        yearScopes: [form.yearScope],
        roundScopes: form.rounds,
        mobilePhone: form.mobilePhone,
      },
    })
    if (err) {
      setSaving(false)
      setError(await getEdgeFunctionErrorMessage(err, '계정을 만들지 못했습니다.'))
      return
    }
    // 평가위원·정량평가의 서류 열람 범위(전체가 아니면)
    if ((form.roles.includes('evaluator') || form.roles.includes('quant')) && form.docTypes !== null && data?.userId) {
      await supabase.rpc('set_user_document_access', { p_user_ids: [data.userId], p_types: form.docTypes })
    }
    setSaving(false)
    setNotice({ title: `${form.displayName.trim()} 선생님 계정을 만들었습니다.${data?.phoneWarning ? ` (${data.phoneWarning})` : ''}`, email: email.trim(), password: tempPw })
    setOpen(false)
    setEmail('')
    setTempPw(makeTempPassword())
    onCreated?.()
  }

  return (
    <section className="mb-8">
      {notice && <CredentialNotice info={notice} onClose={() => setNotice(null)} />}
      {!open ? (
        <button type="button" onClick={() => { setOpen(true); setError(null) }}
          className="rounded-lg bg-brand-deepGreen px-4 py-2 text-sm font-semibold text-white hover:bg-brand-deepGreenStrong">
          + 새 계정 만들기
        </button>
      ) : (
        <div className="rounded-lg border border-border bg-surface-card p-4 shadow-sm">
          <h2 className="mb-2 text-base font-bold text-ink-primary">새 계정 만들기</h2>
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-ink-secondary">아이디(이메일)</label>
              <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="예: hong@school.example.kr" autoComplete="off"
                className="w-full rounded-md border border-border px-2 py-1.5 text-sm focus:border-brand-deepGreen focus:outline-none" />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-ink-secondary">임시 비밀번호 (첫 로그인 때 본인이 바꿈)</label>
              <div className="flex gap-1">
                <input value={tempPw} onChange={(e) => setTempPw(e.target.value)} className="w-full rounded-md border border-border px-2 py-1.5 font-mono text-sm focus:border-brand-deepGreen focus:outline-none" />
                <button type="button" onClick={() => setTempPw(makeTempPassword())} className="shrink-0 rounded-md border border-border px-2 text-xs text-ink-secondary hover:bg-surface-subtle">새로</button>
              </div>
            </div>
          </div>
          <EditForm initial={{}} saving={saving} error={error} onCancel={() => setOpen(false)} onSave={save} />
        </div>
      )}
    </section>
  )
}

// 심층평가 당일 투입 대상: 모둠·면접·글쓰기 담당이거나 관리자·접수 역할인 활성 계정
const DEEP_DAY_AREAS = ['group', 'interview', 'writing']
const DEEP_DAY_ROLES = ['superadmin', 'admin', 'reception']
function isDeepDayUser(u) {
  if (!u.active) return false
  return (u.assigned_areas || []).some((a) => DEEP_DAY_AREAS.includes(a)) || (u.roles || []).some((r) => DEEP_DAY_ROLES.includes(r))
}

export default function UserManagementPage() {
  const { session } = useAuth()
  const [pending, setPending] = useState([])
  const [users, setUsers] = useState([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(null)
  const [editingId, setEditingId] = useState(null) // pending: 'pending:<uid>', user: user.id
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState(null)
  const [toggleBusyId, setToggleBusyId] = useState(null)
  const [deleteTarget, setDeleteTarget] = useState(null) // { id, email, displayName }
  const [resetNotice, setResetNotice] = useState(null)
  const [resetBusyId, setResetBusyId] = useState(null)
  const [deleting, setDeleting] = useState(false)
  const [deleteError, setDeleteError] = useState(null)
  // 일괄 적용(연도·차수) — 2026-09-29
  const [selected, setSelected] = useState([])
  const [bulkYear, setBulkYear] = useState(2027)
  const [bulkRounds, setBulkRounds] = useState(['main'])
  const [bulkMode, setBulkMode] = useState('replace')
  const [bulkBusy, setBulkBusy] = useState(false)
  const [bulkMsg, setBulkMsg] = useState(null)
  // 심층평가 당일 점검(2026-10-14): 교외(본관) 접속은 휴대폰 인증이 필요하다.
  const [onlyMissingPhone, setOnlyMissingPhone] = useState(false)

  const deployedUsers = users.filter(isDeepDayUser)
  const deployedMissingPhone = deployedUsers.filter((u) => !u.mobile_phone)
  const visibleUsers = onlyMissingPhone ? deployedMissingPhone : users

  const load = async () => {
    setLoading(true)
    setLoadError(null)
    const [pendingRes, usersRes] = await Promise.all([
      supabase.rpc('list_pending_signins'),
      supabase.from('users').select('*').order('created_at', { ascending: false }),
    ])
    setLoading(false)
    if (pendingRes.error || usersRes.error) {
      setLoadError((pendingRes.error || usersRes.error).message)
      return
    }
    setPending(pendingRes.data || [])
    setUsers(usersRes.data || [])
  }

  useEffect(() => {
    load()
  }, [])

  // userId: 서류 열람 설정을 저장할 대상, prevDocTypes: 바뀐 경우에만 저장하기 위한 이전 값
  const handleApprove = async (email, form, userId, prevDocTypes = null, prevPhone = null) => {
    setSaving(true)
    setSaveError(null)
    const { error } = await supabase.rpc('upsert_user_access', {
      target_email: email,
      new_display_name: form.displayName.trim(),
      new_roles: form.roles,
      new_assigned_areas: form.areas,
      new_year_scopes: [form.yearScope],
      new_round_scopes: form.rounds,
    })
    if (error) {
      setSaving(false)
      setSaveError(error.message)
      return
    }
    const isEvaluatorLike = form.roles.includes('evaluator') || form.roles.includes('quant')
    if (isEvaluatorLike && JSON.stringify(form.docTypes) !== JSON.stringify(prevDocTypes)) {
      const { error: docErr } = await supabase.rpc('set_user_document_access', {
        p_user_ids: [userId],
        p_types: form.docTypes,
      })
      if (docErr) {
        setSaving(false)
        setSaveError(`역할은 저장했지만 서류 열람 설정 저장에 실패했습니다: ${docErr.message}`)
        await load()
        return
      }
    }
    // 휴대폰 번호(교외 접속 인증, 00085) — 바뀐 경우에만
    if (userId && (form.mobilePhone || '') !== (prevPhone || '')) {
      const { error: phoneErr } = await supabase.rpc('set_user_mobile_phone', { p_user_id: userId, p_phone: form.mobilePhone || null })
      if (phoneErr) {
        setSaving(false)
        setSaveError(`역할은 저장했지만 휴대폰 번호 저장에 실패했습니다: ${phoneErr.message}`)
        await load()
        return
      }
    }
    setSaving(false)
    setEditingId(null)
    await load()
  }

  const toggleSelect = (id) => setSelected((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]))
  const toggleBulkRound = (r) => setBulkRounds((cur) => (cur.includes(r) ? cur.filter((x) => x !== r) : [...cur, r]))

  const applyBulkScopes = async () => {
    setBulkMsg(null)
    if (selected.length === 0) return
    if (!bulkYear && bulkRounds.length === 0) {
      setBulkMsg({ error: true, text: '연도나 차수를 하나 이상 지정하세요.' })
      return
    }
    const roundText = bulkRounds.map((r) => ROUND_LABEL[r] || r).join(', ') || '(차수 변경 없음)'
    if (!window.confirm(`${selected.length}명의 적용 범위를 ${bulkMode === 'replace' ? '다음으로 바꿉니다' : '에 다음을 추가합니다'}.\n연도: ${bulkYear || '(변경 없음)'}\n차수: ${roundText}`)) return
    setBulkBusy(true)
    const { data, error } = await supabase.rpc('set_user_scopes_bulk', {
      p_user_ids: selected,
      p_year_scopes: bulkYear ? [Number(bulkYear)] : [],
      p_round_scopes: bulkRounds,
      p_mode: bulkMode,
    })
    setBulkBusy(false)
    if (error) {
      setBulkMsg({ error: true, text: error.message })
      return
    }
    setBulkMsg({ error: false, text: `${data?.updated ?? selected.length}명에게 적용했습니다.` })
    setSelected([])
    await load()
  }

  const handleToggleActive = async (user) => {
    setToggleBusyId(user.id)
    const { error } = await supabase.rpc('set_user_active_status', {
      target_uid: user.id,
      new_active: !user.active,
    })
    setToggleBusyId(null)
    if (error) {
      // eslint-disable-next-line no-alert
      alert(error.message)
      return
    }
    await load()
  }

  const handleDelete = async (reason) => {
    setDeleteError(null)
    setDeleting(true)
    const { error } = await supabase.rpc('delete_deactivated_user', {
      p_target_uid: deleteTarget.id,
      p_reason: reason,
    })
    setDeleting(false)
    if (error) {
      setDeleteError(error.message)
      return
    }
    setDeleteTarget(null)
    await load()
  }

  const handleResetPassword = async (u) => {
    // eslint-disable-next-line no-alert
    if (!window.confirm(`${u.display_name} 선생님의 비밀번호를 임시 비밀번호로 바꿉니다. 지금 쓰는 비밀번호로는 더 이상 로그인할 수 없습니다. 계속할까요?`)) return
    const password = makeTempPassword()
    setResetBusyId(u.id)
    const { error } = await supabase.functions.invoke('admin-manage-user', { body: { action: 'reset_password', userId: u.id, password } })
    setResetBusyId(null)
    if (error) {
      // eslint-disable-next-line no-alert
      window.alert(await getEdgeFunctionErrorMessage(error, '비밀번호를 바꾸지 못했습니다.'))
      return
    }
    setResetNotice({ title: `${u.display_name} 선생님 비밀번호를 재설정했습니다.`, email: u.email, password })
  }

  return (
    <div className="mx-auto max-w-4xl px-4 py-6 sm:px-6">
      <PageHeader
        title="사용자(선생님) 권한 관리"
        description="자체 회원가입은 닫혀 있습니다. [새 계정 만들기]로 계정을 만들고 임시 비밀번호를 전달하세요(첫 로그인 때 본인이 바꿉니다). 역할 변경·비밀번호 재설정·비활성화도 여기서 합니다."
        secondaryActions={[{ label: '새로고침', onClick: load }]}
      />
      <TransferModeNotice>
        지금 권한은 신입학·전편입학 공통입니다. 여기서 바꾸면 신입학 권한도 함께 바뀝니다. 전입생 전형용 권한을 따로 두는 기능은
        전입생 전형을 신입학 시스템과 통합할 때(신입학 전형 종료 후) 추가됩니다.
      </TransferModeNotice>

      {loadError && (
        <p className="mb-4 rounded-md border border-status-danger bg-status-dangerSoft px-3 py-2 text-sm text-status-danger">
          {loadError}
        </p>
      )}

      <CreateUserPanel onCreated={load} />
      {resetNotice && <CredentialNotice info={resetNotice} onClose={() => setResetNotice(null)} />}

      <section className="mb-8">
        <h2 className="mb-2 text-base font-bold text-ink-primary">승인 대기 ({pending.length})</h2>
        {loading ? (
          <p className="text-sm text-ink-muted">불러오는 중…</p>
        ) : pending.length === 0 ? (
          <p className="text-sm text-ink-muted">승인 대기 중인 계정이 없습니다.</p>
        ) : (
          <ul className="space-y-2">
            {pending.map((p) => (
              <li key={p.id} className="rounded-lg border border-border bg-surface-card p-3 shadow-sm">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-ink-primary">{p.email}</p>
                    <p className="text-xs text-ink-muted">
                      로그인: {new Date(p.created_at).toLocaleString('ko-KR')}
                    </p>
                  </div>
                  {editingId !== `pending:${p.id}` && (
                    <button
                      type="button"
                      onClick={() => {
                        setEditingId(`pending:${p.id}`)
                        setSaveError(null)
                      }}
                      className="rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-deepGreenStrong"
                    >
                      승인하기
                    </button>
                  )}
                </div>
                {editingId === `pending:${p.id}` && (
                  <EditForm
                    initial={{ displayName: '', roles: [], areas: [], yearScope: 2027, rounds: ['main'] }}
                    saving={saving}
                    error={saveError}
                    onCancel={() => setEditingId(null)}
                    onSave={(form) => handleApprove(p.email, form, p.id)}
                  />
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <div className="mb-2 flex items-center justify-between gap-2">
          <h2 className="text-base font-bold text-ink-primary">등록된 사용자 ({users.length})</h2>
          <label className="ml-auto flex items-center gap-1.5 text-xs text-ink-secondary">
            <input type="checkbox" checked={onlyMissingPhone} onChange={(e) => setOnlyMissingPhone(e.target.checked)} />
            휴대폰 미등록만 보기
          </label>
          <label className="flex items-center gap-1.5 text-xs text-ink-secondary">
            <input
              type="checkbox"
              checked={users.length > 0 && selected.length === users.length}
              onChange={(e) => setSelected(e.target.checked ? users.map((u) => u.id) : [])}
            />
            전체 선택
          </label>
        </div>

        {/* 심층평가 당일 투입 인원(모둠·면접·글쓰기 위원, 관리자, 접수) 휴대폰 등록 현황 */}
        <p
          className={`mb-3 rounded-md px-3 py-2 text-xs ${
            deployedMissingPhone.length > 0 ? 'bg-status-warningSoft text-status-warning' : 'bg-brand-greenSoft text-brand-deepGreenStrong'
          }`}
        >
          심층평가 당일 투입 {deployedUsers.length}명 중 휴대폰 미등록 {deployedMissingPhone.length}명
          {deployedMissingPhone.length > 0 && ` — ${deployedMissingPhone.map((u) => u.display_name).join(', ')} (교외에서 로그인 불가)`}
        </p>

        {/* 선택한 사용자에게 적용 연도·차수 일괄 지정. 역할·영역은 '역할 수정'과 '평가 준비'에서 따로 한다. */}
        <div className="mb-3 rounded-lg border border-brand-deepGreen bg-brand-greenSoft/50 p-3">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <span className="font-semibold text-ink-primary">선택한 {selected.length}명 적용 범위</span>
            <label className="flex items-center gap-1 text-xs text-ink-secondary">
              학년도
              <input
                type="number"
                value={bulkYear}
                onChange={(e) => setBulkYear(e.target.value)}
                className="w-20 rounded-md border-border py-1 text-sm"
              />
            </label>
            <span className="flex items-center gap-2 text-xs text-ink-secondary">
              차수
              {Object.entries(ROUND_LABEL).map(([r, label]) => (
                <label key={r} className="flex items-center gap-1">
                  <input type="checkbox" checked={bulkRounds.includes(r)} onChange={() => toggleBulkRound(r)} />
                  {label}
                </label>
              ))}
            </span>
            <select value={bulkMode} onChange={(e) => setBulkMode(e.target.value)} className="rounded-md border-border py-1 text-xs">
              <option value="replace">이것으로 바꾸기</option>
              <option value="add">기존에 추가하기</option>
            </select>
            <button
              type="button"
              onClick={applyBulkScopes}
              disabled={bulkBusy || selected.length === 0}
              className="ml-auto rounded-md bg-brand-deepGreen px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
            >
              {bulkBusy ? '적용 중…' : '일괄 적용'}
            </button>
          </div>
          <p className="mt-1 text-[11px] text-ink-muted">
            목록에서 선생님을 체크한 뒤 적용하세요. 역할과 평가 영역은 바뀌지 않습니다(역할 수정 · 평가 준비 메뉴에서 지정).
          </p>
          {bulkMsg && (
            <p className={`mt-1 text-xs ${bulkMsg.error ? 'text-status-danger' : 'text-brand-deepGreenStrong'}`}>{bulkMsg.text}</p>
          )}
        </div>
        {loading ? (
          <p className="text-sm text-ink-muted">불러오는 중…</p>
        ) : (
          <ul className="space-y-2">
            {onlyMissingPhone && visibleUsers.length === 0 && (
              <li className="rounded-lg border border-dashed border-border p-4 text-center text-sm text-ink-muted">당일 투입 인원은 모두 휴대폰이 등록되어 있습니다.</li>
            )}
            {visibleUsers.map((u) => (
              <li key={u.id} className="rounded-lg border border-border bg-surface-card p-3 shadow-sm">
                <div className="flex items-center justify-between gap-3">
                  <input
                    type="checkbox"
                    checked={selected.includes(u.id)}
                    onChange={() => toggleSelect(u.id)}
                    aria-label={`${u.display_name} 선택`}
                    className="shrink-0"
                  />
                  <div className="flex-1">
                    <p className="text-sm font-medium text-ink-primary">
                      {u.display_name}{' '}
                      <span className="font-normal text-ink-muted">({u.email})</span>
                      {!u.active && (
                        <span className="ml-2 rounded-full bg-status-dangerSoft px-2 py-0.5 text-xs text-status-danger">
                          비활성화됨
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-ink-muted">
                      역할: {u.roles?.join(', ') || '없음'}
                      {u.assigned_areas?.length ? ` · 담당영역: ${u.assigned_areas.join(', ')}` : ''}
                      {' · 적용: '}
                      {u.year_scopes?.length ? u.year_scopes.join(', ') + '학년도' : '모든 학년도'}
                      {' '}
                      {u.round_scopes?.length ? u.round_scopes.map((r) => ROUND_LABEL[r] || r).join(', ') : '모든 차수'}
                      {(u.roles?.includes('evaluator') || u.roles?.includes('quant')) &&
                        ` · 서류 열람: ${docViewSummary(u.viewable_document_types)}`}
                      {' · 휴대폰: '}
                      {u.mobile_phone ? <span className="font-mono">{u.mobile_phone}</span> : <span className="text-status-warning">미등록(교외 접속 불가)</span>}
                    </p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setEditingId(u.id)
                        setSaveError(null)
                      }}
                      className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle"
                    >
                      역할 수정
                    </button>
                    <button
                      type="button"
                      disabled={resetBusyId === u.id || !u.active}
                      onClick={() => handleResetPassword(u)}
                      className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                    >
                      {resetBusyId === u.id ? '재설정 중…' : '비밀번호 재설정'}
                    </button>
                    <button
                      type="button"
                      disabled={toggleBusyId === u.id || u.id === session?.user?.id}
                      onClick={() => handleToggleActive(u)}
                      title={u.id === session?.user?.id ? '본인 계정은 스스로 비활성화할 수 없습니다.' : undefined}
                      className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-ink-secondary hover:bg-surface-subtle disabled:opacity-50"
                    >
                      {u.active ? '비활성화' : '다시 활성화'}
                    </button>
                    <button
                      type="button"
                      disabled={u.active || u.id === session?.user?.id}
                      onClick={() => {
                        setDeleteTarget({ id: u.id, email: u.email, displayName: u.display_name })
                        setDeleteError(null)
                      }}
                      title={
                        u.id === session?.user?.id
                          ? '본인 계정은 삭제할 수 없습니다.'
                          : u.active
                            ? '먼저 비활성화한 뒤 삭제할 수 있습니다.'
                            : undefined
                      }
                      className="rounded-md border border-status-danger px-3 py-1.5 text-xs font-medium text-status-danger hover:bg-status-dangerSoft disabled:opacity-50"
                    >
                      삭제
                    </button>
                  </div>
                </div>
                {editingId === u.id && (
                  <EditForm
                    initial={{
                      displayName: u.display_name,
                      roles: u.roles || [],
                      areas: u.assigned_areas || [],
                      yearScope: u.year_scopes?.[0] ?? 2027,
                      rounds: u.round_scopes || ['main'],
                      docTypes: u.viewable_document_types ?? null,
                      mobilePhone: u.mobile_phone || '',
                    }}
                    saving={saving}
                    error={saveError}
                    onCancel={() => setEditingId(null)}
                    onSave={(form) => handleApprove(u.email, form, u.id, u.viewable_document_types ?? null, u.mobile_phone || null)}
                  />
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <DestructiveActionDialog
        open={Boolean(deleteTarget)}
        title="계정 삭제 — 되돌릴 수 없습니다"
        description="비활성화된 계정을 완전히 삭제합니다. 로그인 자체가 불가능해지며, 평가 기록이 남아있는 계정은 삭제할 수 없습니다(먼저 데이터 정리가 필요합니다)."
        fields={
          deleteTarget
            ? [
                { label: '이름', value: deleteTarget.displayName || '—' },
                { label: '이메일', value: deleteTarget.email },
              ]
            : []
        }
        reasonLabel="삭제 사유 (필수, 5자 이상)"
        reasonMinLength={5}
        reasonPlaceholder="예: 퇴직 처리 / 중복 가입 정리"
        confirmLabel="삭제 실행"
        submitting={deleting}
        error={deleteError}
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
      />
    </div>
  )
}
