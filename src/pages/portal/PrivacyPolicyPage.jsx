// 개인정보처리방침 공개 페이지 (2026-07-11 신설)
//
// 로그인 없이 접근하는 공개 라우트다(App.jsx에서 RequireAuth 밖에 위치).
//
// 내용 출처: docs/개인정보처리방침_초안_2026-07-11.md (Opus 서브에이전트가
// 개인정보보호법 제30조·제28조의8 및 개인정보보호위원회 실무 해석을 조사해
// 작성한 초안 — 담당자명/연락처/시행일자는 학교가 채워야 할 플레이스홀더로
// 남겨둔다. 이 페이지는 "웹 반영"까지만 범위이며(2026-07-11 사용자 결정),
// 종이 원서에 동봉되는 실제 개인정보 동의서 PDF(2026 합본 14페이지)는 이번
// 반영 대상이 아니다 — 2027학년도 원서 양식 반영(#18) 때 함께 다룬다.
//
// 2026-07-13: 온라인 사전작성(M8) 포털 포기 결정에 따라 관련 문구 전부 제거.

const SECTION_CLS = 'space-y-2'
const H2_CLS = 'text-base font-bold text-ink-primary'
const P_CLS = 'text-sm leading-relaxed text-ink-secondary'
const TABLE_CLS = 'w-full border-collapse text-sm'
const TH_CLS = 'border border-border bg-surface-subtle px-3 py-2 text-left font-semibold text-ink-primary'
const TD_CLS = 'border border-border px-3 py-2 align-top text-ink-secondary'

export default function PrivacyPolicyPage() {
  return (
    <div className="mx-auto min-h-screen max-w-3xl bg-surface-canvas px-4 py-8">
      <header className="mb-6 flex items-center gap-2">
        <svg width="28" height="28" viewBox="0 0 32 32" aria-hidden="true">
          <rect width="32" height="32" rx="8" fill="#009944" />
          <text x="16" y="22" fontSize="15" fontFamily="sans-serif" fontWeight="700" fill="white" textAnchor="middle">
            산
          </text>
        </svg>
        <span className="text-base font-bold text-ink-primary">새봄고등학교 개인정보처리방침</span>
      </header>

      <div className="mb-6 rounded-md border border-status-warningSoft bg-status-warningSoft/40 px-3 py-2 text-xs text-ink-secondary">
        본 방침은 초안이며 법률 자문이 아닙니다. 게시 전 학교 개인정보 보호책임자의 최종 검토가 필요합니다.
        <br />
        시행일자: [2026-XX-XX] (담당자 확정 후 채워질 예정)
      </div>

      <div className="space-y-6 rounded-lg border border-border bg-surface-card p-5 shadow-sm">
        <p className={P_CLS}>
          새봄고등학교(이하 "학교")는 「개인정보 보호법」 제30조에 따라 정보주체의 개인정보를 보호하고
          이와 관련한 고충을 신속하고 원활하게 처리할 수 있도록 하기 위하여 다음과 같이 개인정보처리방침을
          수립·공개합니다.
        </p>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제1조 (개인정보의 처리 목적)</h2>
          <p className={P_CLS}>학교는 다음의 목적을 위하여 개인정보를 처리하며, 이외의 용도로는 이용하지 않습니다.</p>
          <ul className="list-disc space-y-1 pl-5 text-sm text-ink-secondary">
            <li>입학전형 관리 — 원서접수, 지원자격·지원결격 사유 확인, 면접, 성적산출, 합격자 명부 관리, 합격증명서 발급, 합격자 통지, 통계 자료 산출</li>
            <li>본인 확인 및 연락 — 접수 관련 안내(문자·전화·이메일), 제출서류 준비 안내</li>
          </ul>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제2조 (처리하는 개인정보의 항목)</h2>
          <p className={P_CLS}>수집 경로에 따라 항목이 다를 수 있습니다.</p>
          <p className={P_CLS}>
            <strong>전편입학전형 수기접수 / 종이 원서 접수 항목:</strong> 사진, 성명, 생년월일, 주소, 전화번호,
            휴대전화번호, 이메일, 학적사항, 가족사항(보호자 성명·생년월일·전화번호), 출결사항, 봉사활동
            이수시간, 검정고시 합격증서 번호
          </p>
          <p className={P_CLS}>
            <strong>자동 수집 정보:</strong> 접속 IP 주소, 브라우저·기기 정보, 접속 로그
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제3조 (개인정보의 처리 및 보유 기간)</h2>
          <table className={TABLE_CLS}>
            <thead>
              <tr>
                <th className={TH_CLS}>수집 경로</th>
                <th className={TH_CLS}>보유·이용 기간</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className={TD_CLS}>정식 입학전형(종이 원서·수기접수) 정보</td>
                <td className={TD_CLS}>입학관리 업무를 계속하는 동안 보유·이용하며, 업무 완료 후 3년간 보관 목적으로만 관리한 뒤 지체 없이 파기</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제4조 (개인정보 처리의 법령상 근거)</h2>
          <p className={P_CLS}>
            입학원서 등에 기재된 개인정보 처리업무는 「초·중등교육법」 제47조 및 동법 시행령 제81조, 제82조,
            제84조, 제98조와 본교의 입학전형 실시계획 등에 근거합니다.
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제5조 (개인정보의 제3자 제공)</h2>
          <p className={P_CLS}>
            학교는 원칙적으로 정보주체의 개인정보를 제3자에게 제공하지 않습니다. 다만 법령에 근거가 있거나
            정보주체의 별도 동의가 있는 경우에 한하여 제공합니다. (현재 상시적 제3자 제공 현황: 해당 없음)
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제6조 (개인정보 처리업무의 위탁)</h2>
          <p className={P_CLS}>
            학교는 원활한 입학전형 업무 처리를 위하여 아래와 같이 개인정보 처리업무를 위탁하고 있습니다.
            위탁계약 시 「개인정보 보호법」 제26조에 따라 안전한 관리를 위한 사항을 규정하고 이를 감독합니다.
          </p>
          <table className={TABLE_CLS}>
            <thead>
              <tr>
                <th className={TH_CLS}>수탁자</th>
                <th className={TH_CLS}>위탁 업무 내용</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className={TD_CLS}>Supabase Inc. (미국 법인)</td>
                <td className={TD_CLS}>데이터베이스 저장·처리 인프라 운영 — 데이터는 서울 리전(ap-northeast-2)에 저장됨</td>
              </tr>
              <tr>
                <td className={TD_CLS}>국내 SMS 발송 대행사(문자나라 등) — 예정, 미연동</td>
                <td className={TD_CLS}>접수 안내 문자(SMS) 발송 대행</td>
              </tr>
              <tr>
                <td className={TD_CLS}>Google LLC (Firebase Hosting, 미국 법인)</td>
                <td className={TD_CLS}>프론트엔드 정적 자산 호스팅 — 개인정보 자체는 저장하지 않음</td>
              </tr>
            </tbody>
          </table>
          <p className={P_CLS}>
            참고: 다음(카카오) 우편번호 검색 API는 주소 검색 스크립트를 브라우저에서 실행하는 방식으로,
            학교가 입력정보를 카카오 서버에 전송·저장하지 않으므로 처리위탁으로 보지 않습니다.
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제7조 (개인정보의 국외 이전에 관한 사항)</h2>
          <p className={P_CLS}>
            「개인정보 보호법」 제28조의8에 따라, 국외 "이전"에는 국외 제공·처리위탁·보관뿐 아니라 국외에서
            접근할 수 있도록 하는 경우까지 포함됩니다. 따라서 국외 이전 해당 여부는 데이터의 물리적 저장
            위치만으로 결정되지 않으며, 데이터가 실제로 국외에 저장·처리되는지 및 국외 사업자가 접근권한을
            갖는지를 함께 고려합니다. 해외 클라우드 사업자의 국내 리전을 이용해 개인정보가 전적으로
            국내에서 저장·처리되는 구조라면 국외 이전에 해당하지 않는 것으로 볼 여지가 있으나,{' '}
            <strong>"서버가 국내에 있으면 무조건 국외 이전이 아니다"라는 확립된 공식 유권해석은 존재하지
            않으며</strong>, 사안별로 사실관계에 따라 판단이 달라질 수 있습니다.
          </p>
          <p className={P_CLS}>
            <strong>Supabase Inc.</strong> — 서울 리전(ap-northeast-2)에 데이터가 저장되어 전형적인 국외
            이전에 해당하지 않을 여지가 크나, 미국 법인의 운영·기술지원 과정에서의 국외 접근 가능성 및
            백업·장애복구 정책상 국외 이동 가능성을 배제할 수 없어 투명성 확보를 위해 명시합니다.
          </p>
          <p className={P_CLS}>
            위 사항의 법적 성격(동의 필요 여부 등)은 사안별로 달라질 수 있으며, 최종 확인은 학교 개인정보
            보호책임자 또는 법률 자문을 통해 이루어져야 합니다.
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제8조 (정보주체와 법정대리인의 권리·의무 및 행사방법)</h2>
          <ul className="list-disc space-y-1 pl-5 text-sm text-ink-secondary">
            <li>정보주체(지원자, 만 14세 미만 미성년자의 경우 법정대리인 포함)는 언제든지 개인정보 열람·정정·삭제·처리정지·파기를 요구할 수 있습니다.</li>
            <li>개인정보 보호법을 위반한 행위로 손해가 발생한 경우 같은 법 제39조에 따라 손해배상을 청구할 수 있습니다.</li>
            <li>권리 행사는 서면·전자우편 등을 통해 할 수 있으며, 학교는 지체 없이 조치합니다.</li>
            <li>미성년자인 지원자의 개인정보는 법정대리인(보호자)이 권리를 행사할 수 있습니다.</li>
          </ul>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제9조 (개인정보의 파기 절차 및 방법)</h2>
          <p className={P_CLS}>
            보유기간이 경과하거나 처리목적이 달성된 개인정보는 지체 없이 파기합니다. 전자적 파일은 복구·재생이
            불가능한 방법으로 영구 삭제하며, 종이 문서는 파쇄 또는 소각합니다.
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제10조 (개인정보의 안전성 확보조치)</h2>
          <ul className="list-disc space-y-1 pl-5 text-sm text-ink-secondary">
            <li>접근권한 관리(수기접수는 로그인된 직원만 입력 가능), 접근통제, 접속기록 보관</li>
            <li>전송·저장 구간 암호화 등 기술적 보호조치</li>
            <li>개인정보 취급 직원 최소화 및 교육</li>
            <li>처리 인프라(Supabase)의 접근통제 및 보안설정 관리</li>
          </ul>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제11조 (동의 거부 권리 및 불이익)</h2>
          <p className={P_CLS}>
            정보주체는 개인정보 수집·이용에 대한 동의를 거부할 권리가 있습니다. 다만 필수 항목에 대한 동의를
            거부할 경우 지원결격 사유 조회 등 입학관리 업무를 수행할 수 없어 원서를 접수할 수 없습니다.
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제12조 (개인정보 보호책임자 및 열람 청구 접수 부서)</h2>
          <table className={TABLE_CLS}>
            <tbody>
              <tr>
                <td className={TH_CLS}>개인정보 보호책임자</td>
                <td className={TD_CLS}>성명 [담당자명] / 직위 [직위]</td>
              </tr>
              <tr>
                <td className={TH_CLS}>연락처</td>
                <td className={TD_CLS}>전화 [연락처] / 이메일 [이메일]</td>
              </tr>
              <tr>
                <td className={TH_CLS}>열람청구·고충처리 부서</td>
                <td className={TD_CLS}>[부서명] / [연락처]</td>
              </tr>
            </tbody>
          </table>
          <p className={P_CLS}>
            정보주체는 개인정보 침해에 대한 상담·신고가 필요한 경우 아래 기관에 문의할 수 있습니다: 개인정보침해
            신고센터(privacy.go.kr / 국번없이 118), 개인정보 분쟁조정위원회(kopico.go.kr / 1833-6972), 대검찰청
            사이버수사과(1301), 경찰청 사이버수사국(182)
          </p>
        </section>

        <section className={SECTION_CLS}>
          <h2 className={H2_CLS}>제13조 (개인정보처리방침의 변경)</h2>
          <p className={P_CLS}>
            이 개인정보처리방침은 [2026-XX-XX]부터 적용됩니다. 내용의 추가·삭제·수정이 있을 경우 시행 최소
            7일 전부터 학교 웹사이트를 통해 공지합니다.
          </p>
        </section>
      </div>
    </div>
  )
}
