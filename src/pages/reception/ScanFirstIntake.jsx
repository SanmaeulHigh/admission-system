// 스캔 먼저 접수 (2026-10-20)
//
// 1단계: 스캔 안내에 따라 서류마다 파일 하나씩 올린다(아직 서버에는 저장하지 않고 이 브라우저에만 둔다).
// 2단계: 왼쪽에 스캔한 원서를 띄워 놓고 오른쪽 입력칸에 옮겨 적는다.
// 3단계: '접수 등록'을 누르면 접수번호가 매겨지고, 그 지원자에게 스캔 파일이 한꺼번에 저장된다.
//
// 파일을 지원자 등록 전에 서버에 올리지 않는 이유: 서류 저장소는 지원자별 폴더·권한으로 묶여 있어
// 주인 없는 파일을 만들지 않기 위해서다. 그래서 등록 전에 새로고침하면 올려 둔 파일이 사라진다(경고를 띄운다).

import { useEffect, useMemo, useState } from 'react'
import RegisterApplicantForm from './RegisterApplicantForm'
import ScanSplitter from './ScanSplitter'
import { TUNNEL_UPLOAD_LIMIT, isTunnelHost, shrinkPdfFileIfNeeded } from '../../lib/pdfCompress'
import DocumentUrlView from '../../components/pdf/DocumentUrlView'

const ALL_AREAS = ['attendance', 'academic', 'community', 'essay', 'opinion', 'group', 'interview', 'writing']
const MAX_BYTES = 200 * 1024 * 1024 // 저장소 한도(00095: 200MB)

// 서류 칸 — 문서 종류·열람 범위는 서류 관리(DocumentUploadForm)와 같다.
const SLOTS = [
  { key: 'applicationForm', label: '입학원서', required: true, classification: 'reception', areas: [],
    guide: '서식 1 입학원서 앞·뒤 면을 한 PDF로. 이 파일을 보고 접수 정보를 입력합니다.' },
  { key: 'photo', label: '지원자 사진', image: true, classification: 'evaluation', areas: ALL_AREAS,
    guide: '원서에 붙은 증명사진(3.5×4.5cm) 부분만 컬러로 스캔해 JPG·PNG로. 수험표에 들어갑니다.' },
  { key: 'studentRecordSource', label: '학교생활기록부', classification: 'evaluation', areas: ['attendance', 'academic', 'community'],
    guide: '중학교 학교생활기록부 전체를 한 PDF로(쪽 순서대로). 검정고시 출신은 합격증명서·성적증명서를 한 PDF로.' },
  { key: 'essay', label: '자기소개서', classification: 'evaluation', areas: ['essay'],
    guide: '서식 자기소개서 전체를 한 PDF로. 다른 서류와 섞지 마세요(자소서 위원만 봅니다).' },
  { key: 'opinion', label: '학부모 소견서', classification: 'evaluation', areas: ['opinion'],
    guide: '서식 학부모 소견서 전체를 한 PDF로. 다른 서류와 섞지 마세요(소견서 위원만 봅니다).' },
  { key: 'consent', label: '동의서', classification: 'reception', areas: [],
    guide: '개인정보 수집·이용 동의서와 공동생활 규칙 동의서를 한 PDF로.' },
  { key: 'trackEvidence', label: '전형 자격 증빙', classification: 'reception', areas: [],
    guide: '인천학생추천·사회통합전형 지원자만. 추천서·증빙서류를 한 PDF로.' },
]

function sizeText(bytes) {
  return bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)}MB` : `${Math.max(1, Math.round(bytes / 1024))}KB`
}

export default function ScanFirstIntake({ year, round, onRegistered, onCancel }) {
  const [step, setStep] = useState(1)
  const [files, setFiles] = useState({}) // key → File
  const [errors, setErrors] = useState({})
  const [shrinking, setShrinking] = useState({}) // key → 진행 문구(용량 줄이는 중)
  const [viewKey, setViewKey] = useState('applicationForm')
  // 1단계 방식: 'slots' = 서류별로 따로 스캔해 올리기 / 'split' = 한 번에 스캔해 쪽 단위로 나누기
  const [uploadMode, setUploadMode] = useState('slots')
  const [splitNotice, setSplitNotice] = useState(null)

  // 미리보기 주소(브라우저 안에서만 유효)
  const urls = useMemo(() => {
    const out = {}
    for (const [k, f] of Object.entries(files)) out[k] = URL.createObjectURL(f)
    return out
  }, [files])
  useEffect(() => () => Object.values(urls).forEach((u) => URL.revokeObjectURL(u)), [urls])

  // 등록 전에 창을 닫거나 새로고침하면 올려 둔 파일이 사라진다
  const hasFiles = Object.keys(files).length > 0
  useEffect(() => {
    if (!hasFiles) return undefined
    const warn = (e) => {
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [hasFiles])

  const pick = async (slot, file) => {
    setErrors((e) => ({ ...e, [slot.key]: null }))
    if (!file) return
    const okType = slot.image ? ['image/jpeg', 'image/png'].includes(file.type) : file.type === 'application/pdf'
    if (!okType) {
      setErrors((e) => ({ ...e, [slot.key]: slot.image ? 'JPG 또는 PNG 파일만 올릴 수 있습니다.' : 'PDF 파일만 올릴 수 있습니다.' }))
      return
    }
    if (file.size > MAX_BYTES) {
      if (slot.image) {
        setErrors((e) => ({ ...e, [slot.key]: `사진 파일이 너무 큽니다(${sizeText(file.size)}). 해상도를 낮춰 다시 저장해 주세요.` }))
        return
      }
      // PDF는 브라우저 안에서 자동으로 용량을 줄인다(쪽마다 300dpi JPEG, 색 유지)
      try {
        setShrinking((m) => ({ ...m, [slot.key]: '용량 줄이는 중…' }))
        const smaller = await shrinkPdfFileIfNeeded(file, {
          onProgress: (d, n) => setShrinking((m) => ({ ...m, [slot.key]: `용량 줄이는 중… ${d}/${n}쪽` })),
        })
        setFiles((f) => ({ ...f, [slot.key]: smaller }))
        setErrors((e) => ({ ...e, [slot.key]: null }))
        setShrinking((m) => ({ ...m, [slot.key]: `${sizeText(file.size)} → ${sizeText(smaller.size)}로 줄였습니다` }))
      } catch (err) {
        setShrinking((m) => ({ ...m, [slot.key]: null }))
        setErrors((e) => ({ ...e, [slot.key]: err.message }))
      }
      return
    }
    setShrinking((m) => ({ ...m, [slot.key]: null }))
    if (isTunnelHost() && file.size > TUNNEL_UPLOAD_LIMIT) {
      setErrors((e) => ({ ...e, [slot.key]: `${sizeText(file.size)} 파일은 교외 주소로는 올릴 수 없습니다(100MB 제한). 서버 PC에서 https://local.example.org 로 접속해 올려 주세요.` }))
      return
    }
    setFiles((f) => ({ ...f, [slot.key]: file }))
  }

  const remove = (key) => setFiles((f) => {
    const next = { ...f }
    delete next[key]
    return next
  })

  const pendingDocuments = SLOTS.filter((s) => files[s.key]).map((s) => ({
    key: s.key, documentType: s.key, label: s.label, file: files[s.key], classification: s.classification, areas: s.areas,
  }))
  const viewable = SLOTS.filter((s) => files[s.key])

  const modeTabs = (
    <div className="mb-4 inline-flex rounded-lg border border-border bg-surface-subtle p-0.5" role="group" aria-label="스캔 방식">
      {[
        ['slots', '서류별로 따로 스캔해 올리기'],
        ['split', '한 번에 스캔해서 쪽으로 나누기'],
      ].map(([key, label]) => (
        <button
          key={key}
          type="button"
          onClick={() => setUploadMode(key)}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold ${uploadMode === key ? 'bg-brand-deepGreen text-white' : 'text-ink-secondary hover:bg-surface-card'}`}
        >
          {label}
        </button>
      ))}
    </div>
  )

  // ── 1단계(나누기 방식): 묶음 PDF → 쪽 단위로 서류 지정 ──
  if (step === 1 && uploadMode === 'split') {
    return (
      <div>
        {modeTabs}
        <ScanSplitter
          onCancel={() => setUploadMode('slots')}
          onDone={(split) => {
            setFiles((f) => ({ ...f, ...split }))
            setSplitNotice(`묶음 PDF를 서류 ${Object.keys(split).length}개로 나눴습니다. 아래 칸을 확인하고, 사진은 따로 올려 주세요.`)
            setUploadMode('slots')
          }}
        />
      </div>
    )
  }

  // ── 1단계: 스캔 안내 + 파일 올리기 ──
  if (step === 1) {
    return (
      <div>
        {modeTabs}
        {splitNotice && <p className="mb-3 rounded-md bg-brand-greenSoft px-3 py-2 text-sm text-brand-deepGreenStrong">{splitNotice}</p>}
        <div className="mb-4 rounded-lg border border-brand-deepGreen bg-brand-greenSoft/60 px-4 py-3 text-sm text-ink-secondary">
          <p className="font-semibold text-brand-deepGreenStrong">스캔 요령</p>
          <ul className="mt-1 list-disc space-y-0.5 pl-5 text-[13px]">
            <li><strong>서류마다 파일 하나</strong>로 나눠 스캔합니다(아래 칸 하나 = 파일 하나). 서류를 한 파일에 섞지 마세요 — 위원마다 볼 수 있는 서류가 다릅니다.</li>
            <li>스캐너 자동급지로 여러 장을 넣을 때는 <strong>서류 묶음별로 따로</strong> 스캔합니다(원서 → 저장, 자소서 → 저장 …).</li>
            <li>흑백 300dpi PDF를 권장합니다(사진만 컬러 JPG). 앞·뒤 면과 쪽 순서가 빠지지 않았는지 확인하세요. 한 파일 200MB까지 그대로 올라갑니다. 서류 업로드는 서버 PC에서 교내 주소(local.example.org)로 하세요.</li>
            <li>입학원서는 꼭 있어야 다음 단계로 갈 수 있습니다. 나머지는 없으면 비워 두고, 나중에 지원자 상세 → 서류 관리에서 올려도 됩니다.</li>
          </ul>
        </div>

        <ol className="grid gap-3 md:grid-cols-2">
          {SLOTS.map((slot, i) => {
            const f = files[slot.key]
            return (
              <li key={slot.key} className={`rounded-lg border p-3 ${f ? 'border-brand-deepGreen bg-white' : 'border-border bg-surface-card'}`}>
                <div className="flex items-start justify-between gap-2">
                  <p className="text-sm font-semibold text-ink-primary">
                    <span className="mr-1.5 text-ink-muted">{i + 1}.</span>{slot.label}
                    {slot.required && <span className="ml-1.5 rounded bg-status-dangerSoft px-1.5 py-0.5 text-[10px] font-bold text-status-danger">필수</span>}
                    <span className="ml-1.5 text-[11px] font-normal text-ink-muted">{slot.image ? 'JPG·PNG' : 'PDF'}</span>
                  </p>
                  {f && <span className="shrink-0 text-xs font-semibold text-brand-deepGreenStrong">✓ 준비됨</span>}
                </div>
                <p className="mt-1 text-xs leading-relaxed text-ink-muted">{slot.guide}</p>
                {f ? (
                  <div className="mt-2 flex items-center justify-between gap-2 rounded-md bg-surface-subtle px-2 py-1.5 text-xs">
                    <span className="min-w-0 truncate text-ink-secondary">{f.name} · {sizeText(f.size)}</span>
                    <button type="button" onClick={() => remove(slot.key)} className="shrink-0 text-ink-muted underline hover:text-status-danger">빼기</button>
                  </div>
                ) : (
                  <input
                    type="file"
                    accept={slot.image ? 'image/jpeg,image/png' : 'application/pdf'}
                    onChange={(e) => { pick(slot, e.target.files?.[0]); e.target.value = '' }}
                    className="mt-2 block w-full text-xs"
                  />
                )}
                {shrinking[slot.key] && <p className="mt-1 text-xs text-brand-deepGreenStrong">{shrinking[slot.key]}</p>}
                {errors[slot.key] && <p className="mt-1 text-xs text-status-danger">{errors[slot.key]}</p>}
              </li>
            )
          })}
        </ol>

        <div className="mt-4 flex flex-wrap items-center justify-between gap-2">
          <div className="flex gap-3">
            <button type="button" onClick={onCancel} className="text-sm text-ink-muted underline">취소</button>
            <button
              type="button"
              onClick={() => { setViewKey(null); setStep(2) }}
              className="text-sm text-ink-muted underline"
              title="스캔 없이 종이 원서를 보고 바로 입력합니다(서류는 나중에 서류 관리에서)"
            >
              스캔 없이 바로 입력
            </button>
          </div>
          <button
            type="button"
            disabled={!files.applicationForm}
            onClick={() => { setViewKey('applicationForm'); setStep(2) }}
            className="rounded-lg bg-brand-deepGreen px-5 py-2.5 text-sm font-bold text-white hover:bg-brand-deepGreenStrong disabled:opacity-40"
          >
            다음: 원서 보고 입력하기 →
          </button>
        </div>
      </div>
    )
  }

  // ── 2단계: 왼쪽 스캔본 보기 + 오른쪽 입력 ──
  const viewing = viewKey && files[viewKey] ? SLOTS.find((s) => s.key === viewKey) : null
  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <button type="button" onClick={() => setStep(1)} className="text-sm text-ink-muted underline">← 스캔 파일 다시 고르기</button>
        <p className="text-xs text-ink-muted">
          접수 등록을 누르면 접수번호가 매겨지고 스캔 파일 {pendingDocuments.length}개가 이 지원자에게 함께 저장됩니다.
        </p>
      </div>
      <div className={viewing ? 'grid gap-4 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]' : ''}>
        {viewing && (
          <div className="lg:sticky lg:top-2 lg:self-start">
            <div className="mb-2 flex flex-wrap gap-1">
              {viewable.map((s) => (
                <button
                  key={s.key}
                  type="button"
                  onClick={() => setViewKey(s.key)}
                  className={`rounded-md px-2.5 py-1.5 text-xs ${viewKey === s.key ? 'bg-brand-deepGreen font-semibold text-white' : 'bg-surface-subtle text-ink-secondary hover:bg-border'}`}
                >
                  {s.label}
                </button>
              ))}
            </div>
            <div className="h-[75vh] overflow-hidden rounded-lg border border-border bg-surface-subtle">
              {viewing.image ? (
                <div className="flex h-full items-center justify-center p-4">
                  <img src={urls[viewing.key]} alt={viewing.label} className="max-h-full max-w-full object-contain" />
                </div>
              ) : (
                <DocumentUrlView key={viewing.key} url={urls[viewing.key]} alt={viewing.label} />
              )}
            </div>
          </div>
        )}
        <div>
          <RegisterApplicantForm
            year={year}
            round={round}
            pendingDocuments={pendingDocuments}
            hidePhotoInput={Boolean(files.photo)}
            onRegistered={onRegistered}
            onCancel={onCancel}
          />
        </div>
      </div>
    </div>
  )
}
