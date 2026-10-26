// 전·편입생 선발 전형 1단계 서류전형(1000점) 채점 패널 — 지원자 상세 drawer 안에 표시.
// 출결·학업성실도는 요강 점수표를 그대로 RPC가 서버에서 계산하고(클라이언트는
// 원본 입력값만 보냄), 자기소개서·보호자소견서는 서면 평가 결과를 직접 입력한다.

import { useState } from 'react'
import { supabase } from '../../lib/supabase'

function scoreOrDash(v) {
  return v === null || v === undefined ? '—' : v
}

export default function TransferScorePanel({ applicantId, scores, onUpdated }) {
  const [attendanceType, setAttendanceType] = useState(scores?.attendance_record_type || 'schoolRecord')
  const [absences, setAbsences] = useState(scores?.attendance_inputs?.unexcusedAbsences ?? 0)
  const [otherEvents, setOtherEvents] = useState(scores?.attendance_inputs?.otherEventCount ?? 0)

  const [academicType, setAcademicType] = useState(scores?.academic_record_type || 'schoolRecord')
  const [subjects, setSubjects] = useState(
    scores?.academic_inputs?.subjects?.length
      ? scores.academic_inputs.subjects
      : [{ subject: '', achievement: 'A', rawScore: '' }],
  )

  const [selfIntro, setSelfIntro] = useState(scores?.self_intro_score ?? '')
  const [guardianOpinion, setGuardianOpinion] = useState(scores?.guardian_opinion_score ?? '')

  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)

  const inputCls =
    'w-full rounded-md border border-border px-2 py-1.5 text-sm focus:border-brand-deepGreen focus:outline-none focus:ring-1 focus:ring-sanmaeul-500'

  const totalKnown =
    scores?.attendance_score != null &&
    scores?.academic_score != null &&
    scores?.self_intro_score != null &&
    scores?.guardian_opinion_score != null
  const total = totalKnown
    ? scores.attendance_score + scores.academic_score + scores.self_intro_score + scores.guardian_opinion_score
    : null

  const runRpc = async (name, args, key) => {
    setError(null)
    setBusy(key)
    const { error: rpcError } = await supabase.rpc(name, args)
    setBusy(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onUpdated?.()
  }

  const submitAttendance = () =>
    runRpc(
      'submit_transfer_attendance_score',
      {
        p_applicant_id: applicantId,
        p_record_type: attendanceType,
        p_unexcused_absences: attendanceType === 'schoolRecord' ? Number(absences) : null,
        p_other_event_count: attendanceType === 'schoolRecord' ? Number(otherEvents) : null,
      },
      'attendance',
    )

  const submitAcademic = () =>
    runRpc(
      'submit_transfer_academic_score',
      {
        p_applicant_id: applicantId,
        p_record_type: academicType,
        p_subjects:
          academicType === 'equivalentNoRecord'
            ? []
            : subjects
                .filter((s) => s.subject)
                .map((s) =>
                  academicType === 'ged'
                    ? { subject: s.subject, rawScore: Number(s.rawScore) }
                    : { subject: s.subject, achievement: s.achievement },
                ),
      },
      'academic',
    )

  const submitEssays = () =>
    runRpc(
      'submit_transfer_essay_scores',
      {
        p_applicant_id: applicantId,
        p_self_intro_score: selfIntro === '' ? null : Number(selfIntro),
        p_guardian_opinion_score: guardianOpinion === '' ? null : Number(guardianOpinion),
      },
      'essays',
    )

  const updateSubject = (idx, key, value) =>
    setSubjects((list) => list.map((s, i) => (i === idx ? { ...s, [key]: value } : s)))
  const addSubjectRow = () => setSubjects((list) => [...list, { subject: '', achievement: 'A', rawScore: '' }])
  const removeSubjectRow = (idx) => setSubjects((list) => list.filter((_, i) => i !== idx))

  return (
    <div className="space-y-5">
      <div className="rounded-md bg-brand-greenSoft px-3 py-2 text-sm">
        1단계 서류전형 총점: <strong>{total ?? '미채점 항목 있음'}</strong> / 1000
        <div className="mt-1 text-xs text-ink-muted">
          출결 {scoreOrDash(scores?.attendance_score)}/200 · 학업성실도 {scoreOrDash(scores?.academic_score)}/100 ·
          자기소개서 {scoreOrDash(scores?.self_intro_score)}/500 · 보호자소견서 {scoreOrDash(scores?.guardian_opinion_score)}/200
        </div>
      </div>

      {error && <p className="rounded-md bg-status-dangerSoft px-3 py-2 text-xs text-status-danger">{error}</p>}

      {/* 출결 200점 */}
      <div className="rounded-md border border-border p-3">
        <h4 className="mb-2 text-sm font-semibold text-ink-primary">출결 (200점)</h4>
        <select value={attendanceType} onChange={(e) => setAttendanceType(e.target.value)} className={`${inputCls} mb-2`}>
          <option value="schoolRecord">중학교 학생부 제출(일반 계산)</option>
          <option value="ged">중학교 졸업학력 검정고시 출신(180점 고정)</option>
          <option value="noRecord">중학교 학생부 미제출(0점)</option>
        </select>
        {attendanceType === 'schoolRecord' && (
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-xs text-ink-muted">미인정 결석 일수</label>
              <input type="number" min="0" value={absences} onChange={(e) => setAbsences(e.target.value)} className={inputCls} />
            </div>
            <div>
              <label className="mb-1 block text-xs text-ink-muted">미인정 조퇴·지각·결과 합산 횟수(3회=1일)</label>
              <input type="number" min="0" value={otherEvents} onChange={(e) => setOtherEvents(e.target.value)} className={inputCls} />
            </div>
          </div>
        )}
        <button
          type="button"
          onClick={submitAttendance}
          disabled={busy === 'attendance'}
          className="mt-2 rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-medium text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-50"
        >
          {busy === 'attendance' ? '계산 중…' : '출결 점수 계산·저장'}
        </button>
      </div>

      {/* 학업성실도 100점 */}
      <div className="rounded-md border border-border p-3">
        <h4 className="mb-2 text-sm font-semibold text-ink-primary">학업성실도 (100점)</h4>
        <select value={academicType} onChange={(e) => setAcademicType(e.target.value)} className={`${inputCls} mb-2`}>
          <option value="schoolRecord">중학교 학생부 성취도(A~E)</option>
          <option value="ged">검정고시 성적증명서 원점수</option>
          <option value="equivalentNoRecord">동등학력 인정자 중 학생부 미제출(70점 고정)</option>
        </select>
        {academicType !== 'equivalentNoRecord' && (
          <div className="space-y-2">
            <p className="text-xs text-ink-muted">반영 학기의 과목을 모두 입력하면 서버가 상위 5개를 자동 선정합니다.</p>
            {subjects.map((s, idx) => (
              <div key={idx} className="flex items-center gap-2">
                <input
                  placeholder="과목명"
                  value={s.subject}
                  onChange={(e) => updateSubject(idx, 'subject', e.target.value)}
                  className={`${inputCls} flex-1`}
                />
                {academicType === 'schoolRecord' ? (
                  <select
                    value={s.achievement}
                    onChange={(e) => updateSubject(idx, 'achievement', e.target.value)}
                    className={`${inputCls} w-20`}
                  >
                    {['A', 'B', 'C', 'D', 'E'].map((g) => (
                      <option key={g} value={g}>
                        {g}
                      </option>
                    ))}
                  </select>
                ) : (
                  <input
                    type="number"
                    min="0"
                    max="100"
                    placeholder="원점수"
                    value={s.rawScore}
                    onChange={(e) => updateSubject(idx, 'rawScore', e.target.value)}
                    className={`${inputCls} w-24`}
                  />
                )}
                <button type="button" onClick={() => removeSubjectRow(idx)} className="text-xs text-ink-muted hover:text-status-danger">
                  삭제
                </button>
              </div>
            ))}
            <button type="button" onClick={addSubjectRow} className="text-xs font-medium text-brand-deepGreenStrong underline">
              + 과목 추가
            </button>
          </div>
        )}
        <button
          type="button"
          onClick={submitAcademic}
          disabled={busy === 'academic'}
          className="mt-2 rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-medium text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-50"
        >
          {busy === 'academic' ? '계산 중…' : '학업성실도 점수 계산·저장'}
        </button>
      </div>

      {/* 자기소개서·보호자소견서 */}
      <div className="rounded-md border border-border p-3">
        <h4 className="mb-2 text-sm font-semibold text-ink-primary">자기소개서(500) · 보호자소견서(200) — 서면 평가 입력</h4>
        <div className="grid grid-cols-2 gap-2">
          <div>
            <label className="mb-1 block text-xs text-ink-muted">자기소개서 점수(0~500)</label>
            <input
              type="number"
              min="0"
              max="500"
              value={selfIntro}
              onChange={(e) => setSelfIntro(e.target.value)}
              className={inputCls}
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-ink-muted">보호자소견서 점수(0~200)</label>
            <input
              type="number"
              min="0"
              max="200"
              value={guardianOpinion}
              onChange={(e) => setGuardianOpinion(e.target.value)}
              className={inputCls}
            />
          </div>
        </div>
        <button
          type="button"
          onClick={submitEssays}
          disabled={busy === 'essays'}
          className="mt-2 rounded-md border border-brand-deepGreen px-3 py-1.5 text-xs font-medium text-brand-deepGreenStrong hover:bg-brand-greenSoft disabled:opacity-50"
        >
          {busy === 'essays' ? '저장 중…' : '서면 평가 점수 저장'}
        </button>
      </div>
    </div>
  )
}
