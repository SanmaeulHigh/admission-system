// 출력물 결재란 — 담당 · 부장 · 교장 (2026-10-12)

const DEFAULT_APPROVERS = ['담당', '부장', '교장']

export default function ApprovalBox({ approvers = DEFAULT_APPROVERS }) {
  return (
    <table className="shrink-0 border-collapse text-center text-black" aria-label="결재">
      <tbody>
        <tr>
          <th rowSpan={2} className="w-[7mm] border border-black px-1 text-[9pt] font-semibold" style={{ writingMode: 'vertical-rl', letterSpacing: '4px' }}>결재</th>
          {approvers.map((a) => (
            <th key={a} className="w-[22mm] border border-black py-1 text-[9pt] font-semibold">{a}</th>
          ))}
        </tr>
        <tr>
          {approvers.map((a) => <td key={a} className="h-[17mm] border border-black" />)}
        </tr>
      </tbody>
    </table>
  )
}
