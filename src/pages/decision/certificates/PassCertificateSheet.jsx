// 합격증서 한 장 (2026-10-20) — A4 세로 전체를 쓰는 새 디자인
//
// 디자인: 새봄(산 + 마을) 정체성을 능선 겹(초록 3단)과 등고선으로, 미래지향은 점 격자·가는 선·넓은 여백으로.
// 색은 학교 로고 색(초록 #00873C·#6EB92B·#006B2F, 주황 #F39800)을 고정값으로 쓴다(전편입 파란 테마와 무관).
// 배경은 SVG라 프린터 해상도 그대로 선명하다. 인쇄 창에서 '배경 그래픽' 이 켜져 있어야 색이 나온다.
// 일반 프린터는 가장자리 3~5mm를 못 찍으므로 글·직인은 모두 안쪽 18mm 안에 둔다.

import schoolLogo from '../../../assets/school-logo.png'
import schoolSeal from '../../../assets/schooi-seal.png'

const C = { deep: '#006B2F', green: '#00873C', light: '#6EB92B', orange: '#F39800', ink: '#1D241F', sub: '#4E5A52', paper: '#FBFCF7' }

function fmtBirth(v) {
  if (!v) return '-'
  const [y, m, d] = String(v).slice(0, 10).split('-')
  return `${y}년 ${Number(m)}월 ${Number(d)}일`
}

function CertificateBackground() {
  return (
    <svg viewBox="0 0 210 297" width="210mm" height="297mm" style={{ position: 'absolute', inset: 0 }} aria-hidden="true">
      <defs>
        <pattern id="pc-dots" width="4" height="4" patternUnits="userSpaceOnUse">
          <circle cx="2" cy="2" r="0.32" fill={C.light} />
        </pattern>
        <radialGradient id="pc-sun" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor={C.orange} stopOpacity="0.16" />
          <stop offset="1" stopColor={C.orange} stopOpacity="0" />
        </radialGradient>
        <radialGradient id="pc-dotmask-g" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#fff" stopOpacity="1" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </radialGradient>
        <mask id="pc-dotmask">
          <circle cx="182" cy="44" r="46" fill="url(#pc-dotmask-g)" />
        </mask>
      </defs>

      <rect width="210" height="297" fill={C.paper} />
      {/* 해(주황 빛) + 점 격자 — 오른쪽 위 */}
      <circle cx="176" cy="40" r="48" fill="url(#pc-sun)" />
      <rect width="210" height="110" fill="url(#pc-dots)" mask="url(#pc-dotmask)" opacity="0.55" />

      {/* 등고선 — 왼쪽 위 */}
      <g fill="none" stroke={C.green} strokeWidth="0.25" opacity="0.28">
        {[0, 1, 2, 3, 4, 5, 6].map((i) => (
          <path key={i} d={`M ${-10 + i * 2} ${60 + i * 7} C ${20 + i * 3} ${40 + i * 6}, ${40 + i * 4} ${78 + i * 5}, ${78 + i * 3} ${30 + i * 8}`} />
        ))}
      </g>

      {/* 능선 3겹 — 아래쪽 (새봄) */}
      <path d="M0 236 C 30 222, 52 214, 78 226 S 128 246, 154 228 S 196 212, 210 220 L210 297 L0 297 Z" fill={C.light} opacity="0.13" />
      <path d="M0 252 C 24 242, 50 236, 74 246 S 120 262, 150 248 S 192 238, 210 244 L210 297 L0 297 Z" fill={C.green} opacity="0.13" />
      <path d="M0 268 C 34 258, 62 256, 92 264 S 150 276, 178 266 S 202 260, 210 262 L210 297 L0 297 Z" fill={C.deep} opacity="0.16" />
      {/* 능선 위 가는 빛줄기 */}
      <path d="M0 236 C 30 222, 52 214, 78 226 S 128 246, 154 228 S 196 212, 210 220" fill="none" stroke={C.orange} strokeWidth="0.35" opacity="0.6" />

      {/* 테두리: 진초록 + 안쪽 주황 가는 선 */}
      <rect x="10" y="10" width="190" height="277" rx="4" fill="none" stroke={C.deep} strokeWidth="0.7" />
      <rect x="13" y="13" width="184" height="271" rx="2.5" fill="none" stroke={C.orange} strokeWidth="0.25" />
      {/* 모서리 장식 */}
      {[[13, 13, 1, 1], [197, 13, -1, 1], [13, 284, 1, -1], [197, 284, -1, -1]].map(([x, y, sx, sy]) => (
        <path key={`${x}-${y}`} d={`M ${x} ${y + sy * 9} L ${x} ${y} L ${x + sx * 9} ${y}`} fill="none" stroke={C.green} strokeWidth="0.9" />
      ))}
    </svg>
  )
}

// 항목명은 글자를 같은 폭에 고르게 벌려 세운다(성  명 / 수험번호 / 출신중학교)
function InfoRow({ label, big, mono, children }) {
  return (
    <tr>
      <th style={{ width: '30mm', paddingRight: '9mm', fontWeight: 500, color: C.sub, whiteSpace: 'nowrap' }}>
        <span style={{ display: 'flex', justifyContent: 'space-between' }}>
          {label.replace(/\s/g, '').split('').map((ch, i) => <span key={i}>{ch}</span>)}
        </span>
      </th>
      <td style={{
        fontWeight: big ? 800 : 600,
        fontSize: big ? '20pt' : undefined,
        letterSpacing: big ? '0.25em' : '0.02em',
        fontFamily: mono ? 'ui-monospace, Consolas, monospace' : undefined,
      }}
      >
        {children}
      </td>
    </tr>
  )
}

export default function PassCertificateSheet({ item, year, announceDateText }) {
  return (
    <div
      className="pass-certificate"
      style={{
        // 296mm: 297mm 꽉 채우면 브라우저 반올림으로 빈 둘째 쪽이 생기는 일이 있다
        position: 'relative', width: '210mm', height: '296mm', overflow: 'hidden', background: C.paper,
        WebkitPrintColorAdjust: 'exact', printColorAdjust: 'exact', color: C.ink,
      }}
    >
      <CertificateBackground />

      {/* 로고 워터마크 */}
      <img src={schoolLogo} alt="" aria-hidden="true" style={{ position: 'absolute', left: '50%', top: '128mm', width: '96mm', transform: 'translateX(-50%)', opacity: 0.05 }} />

      <div style={{ position: 'absolute', inset: '22mm 24mm 24mm 24mm', display: 'flex', flexDirection: 'column' }}>
        <p style={{ fontSize: '10.5pt', color: C.sub, letterSpacing: '0.04em' }}>
          제 <span style={{ fontFamily: 'ui-monospace, Consolas, monospace', fontWeight: 700, color: C.ink }}>{item.certNo || '—'}</span> 호
        </p>

        <div style={{ marginTop: '14mm', textAlign: 'center' }}>
          <img src={schoolLogo} alt="" style={{ height: '15mm', margin: '0 auto' }} />
          <h1 style={{ marginTop: '7mm', fontSize: '40pt', fontWeight: 800, letterSpacing: '0.55em', paddingLeft: '0.55em', color: C.deep }}>합격증서</h1>
          <div style={{ margin: '4mm auto 0', width: '22mm', height: '1.2mm', borderRadius: '1mm', background: `linear-gradient(90deg, ${C.green}, ${C.orange})` }} />
          <p style={{ marginTop: '3.5mm', fontSize: '9pt', letterSpacing: '0.42em', color: C.green }}>CERTIFICATE OF ADMISSION</p>
        </div>

        <table style={{ margin: '16mm auto 0', fontSize: '13.5pt', borderCollapse: 'separate', borderSpacing: '0 3mm' }}>
          <tbody>
            <InfoRow label="수험번호" mono>{item.examNo || '-'}</InfoRow>
            <InfoRow label="성명" big>{item.name}</InfoRow>
            <InfoRow label="생년월일">{fmtBirth(item.birthDate)}</InfoRow>
            <InfoRow label="출신 중학교">{item.school || '-'}</InfoRow>
          </tbody>
        </table>

        <p style={{ marginTop: '14mm', textAlign: 'center', fontSize: '15.5pt', lineHeight: 2.1, wordBreak: 'keep-all' }}>
          위 사람은 {year}학년도 새봄고등학교<br />
          신입생 입학전형에 <strong style={{ color: C.deep }}>최종 합격</strong>하였기에<br />
          이 증서를 드립니다.
        </p>

        <p style={{ marginTop: 'auto', paddingTop: '8mm', textAlign: 'center', fontSize: '13pt', letterSpacing: '0.08em' }}>{announceDateText}</p>

        <div style={{ marginTop: '8mm', marginBottom: '24mm', display: 'flex', justifyContent: 'center' }}>
          <p style={{ fontSize: '20pt', fontWeight: 800, letterSpacing: '0.35em' }}>
            새봄고등학교
            <span style={{ position: 'relative', display: 'inline-block' }}>
              장
              <img
                src={schoolSeal}
                alt="새봄고등학교장 직인"
                style={{ position: 'absolute', left: '-1mm', top: '50%', transform: 'translateY(-50%)', width: '2.4cm', height: '2.4cm', maxWidth: 'none' }}
              />
            </span>
          </p>
        </div>
      </div>
    </div>
  )
}
