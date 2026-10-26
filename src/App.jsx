import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { AuthProvider } from './contexts/AuthContext'
import PrintStamp from './components/print/PrintStamp'
import { AdmissionCycleProvider } from './contexts/AdmissionCycleContext'
import RequireAuth from './components/guards/RequireAuth'
import RequireRole from './components/guards/RequireRole'
import AdminShell from './components/layout/AdminShell'
import Login from './pages/auth/Login'
import Dashboard from './pages/dashboard/Dashboard'
import ReceptionPage from './pages/reception/ReceptionPage'
import ReceiptPrint from './pages/reception/ReceiptPrint'
import ExamTicketPrint from './pages/reception/ExamTicketPrint'
import ExamTicketBulkPrint from './pages/reception/ExamTicketBulkPrint'
import FolderCoverPrint from './pages/reception/FolderCoverPrint'
import TranscriptionListPage from './pages/reception/transcription/TranscriptionListPage'
import TranscriptionEditorPage from './pages/reception/transcription/TranscriptionEditorPage'
import ReceptionLedgerPrint from './pages/reception/ReceptionLedgerPrint'
import DailyReceptionReport from './pages/reception/DailyReceptionReport'
import DailyBulletinPrint from './pages/reception/DailyBulletinPrint'
import PrincipalDocumentsPage from './pages/principal/PrincipalDocumentsPage'
import TransferAdmissionPage from './pages/transfer/TransferAdmissionPage'
import EvaluationRosterPage from './pages/evaluation/EvaluationRosterPage'
import DocumentViewer from './pages/evaluation/DocumentViewer'
import EvaluationMonitorPage from './pages/evaluation/EvaluationMonitorPage'
import DocumentDecisionPage from './pages/decision/DocumentDecisionPage'
import FinalDecisionPage from './pages/decision/FinalDecisionPage'
import FinalAnnouncePage from './pages/decision/FinalAnnouncePage'
import CommitteePacketPage from './pages/decision/CommitteePacketPage'
import CertificatesPage from './pages/decision/certificates/CertificatesPage'
import AuditLogPage from './pages/admin/AuditLogPage'
import UserManagementPage from './pages/admin/UserManagementPage'
import GroupPlanningPage from './pages/deep/GroupPlanningPage'
import GroupObservationPage from './pages/deep/GroupObservationPage'
import InterviewPlanningPage from './pages/deep/InterviewPlanningPage'
import InterviewScorePage from './pages/deep/InterviewScorePage'
import WritingPlanningPage from './pages/deep/WritingPlanningPage'
import WritingScorePage from './pages/deep/WritingScorePage'
import PaperBackupPage from './pages/deep/PaperBackupPage'
import AdminScoreEntryPage from './pages/deep/AdminScoreEntryPage'
import DocumentScoresheetPrintPage from './pages/evaluation/DocumentScoresheetPrintPage'
import LiveScoringMonitorPage from './pages/evaluation/LiveScoringMonitorPage'
import PaperScoreBulkEntryPage from './pages/deep/PaperScoreBulkEntryPage'
import CheckinPage from './pages/deep/CheckinPage'
import InterviewRunSheetPage from './pages/deep/InterviewRunSheetPage'
import AdmissionCycleSettingsPage from './pages/admin/AdmissionCycleSettingsPage'
import EvaluationStaffingPage from './pages/admin/EvaluationStaffingPage'
import InterviewDisplayPage from './pages/display/InterviewDisplayPage'
import PrivacyPolicyPage from './pages/portal/PrivacyPolicyPage'
import UpdatePrompt from './components/feedback/UpdatePrompt'

// UX1-A: 관리자/평가위원 데스크톱 업무 화면은 AdminShell로 감싼다.
// GroupObservationPage/InterviewScorePage/WritingScorePage(현장 평가, FieldShell
// 대상)는 이미 자체적으로 완결된 모바일 레이아웃을 갖고 있어 지금 당장 손대지
// 않는다 — FieldShell로의 실제 전환은 UX1-F 범위다(명세서 27장 구현단계).
// Login/ReceiptPrint(인쇄 출력)는 Shell 없이 그대로 둔다.

function App() {
  return (
    <BrowserRouter>
      <UpdatePrompt />
      <AuthProvider>
        <PrintStamp />
        <AdmissionCycleProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          {/* 대기실 프로젝터 송출 화면 — 종일 띄워두는 용도라 로그인을 요구하지
              않는다. 서버 RPC가 수험번호와 마스킹된 성명만 내려준다. */}
          <Route path="/display/interview" element={<InterviewDisplayPage />} />
          <Route
            path="/"
            element={
              <RequireAuth>
                <AdminShell>
                  <Dashboard />
                </AdminShell>
              </RequireAuth>
            }
          />
          <Route
            path="/reception"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <AdminShell fullBleed>
                    <ReceptionPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/reception/receipt/:applicantId"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <ReceiptPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 수험표는 superadmin/admin만 — 지원자 사진을 평가위원도 볼 수 있게
              'evaluation'으로 분류했는데, 문서 접근 판정(_can_access_document)이
              단일 분류라 접수 전용(reception) 계정은 evaluation 문서를 못 본다.
              접수 계정으로 열면 사진이 빈 칸으로 나오므로 아예 막는다. */}
          {/* 학교장 서류 열람 (점수 없이 서류만, 00082) */}
          <Route
            path="/principal/documents"
            element={
              <RequireAuth>
                <RequireRole roles={['principal', 'evaluator', 'quant', 'superadmin']}>
                  <AdminShell fullBleed>
                    <PrincipalDocumentsPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 원서 접수 일보 (하루 한 장, 결재란) */}
          <Route
            path="/reception/bulletin"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <DailyBulletinPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 일자별 원서 접수 현황표 (A4 세로, 결재란) */}
          <Route
            path="/reception/daily"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <DailyReceptionReport />
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 원서 접수대장 인쇄 (A4 가로, 결재란 담당·부장·교장) */}
          <Route
            path="/reception/ledger"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <ReceptionLedgerPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 자기소개서·학부모 소견서 입력본(00102) */}
          <Route
            path="/reception/transcriptions"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <AdminShell>
                    <TranscriptionListPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/reception/transcriptions/:applicantId/:type"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <AdminShell fullBleed>
                    <TranscriptionEditorPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* L자 화일 표지 (A4 절반) */}
          <Route
            path="/reception/folder-cover/:applicantId"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <FolderCoverPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/reception/exam-tickets"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <ExamTicketBulkPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/reception/exam-ticket/:applicantId"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <ExamTicketPrint />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/transfer-admission"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'reception']}>
                  <AdminShell>
                    <TransferAdmissionPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'evaluator', 'quant']}>
                  <AdminShell>
                    <EvaluationRosterPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation/documents/:applicantId"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin', 'evaluator', 'quant']}>
                  <AdminShell fullBleed>
                    <DocumentViewer />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation/monitor"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <EvaluationMonitorPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/decision/document"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <DocumentDecisionPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/decision/final"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <FinalDecisionPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/decision/final/announce"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <FinalAnnouncePage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/decision/final/committee-packet"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <CommitteePacketPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 확인서·합격증서 출력 (인쇄 전용, 셸 없음) */}
          <Route
            path="/decision/certificates"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <CertificatesPage />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/admin/audit-log"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <AuditLogPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/admin/users"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin']}>
                  <AdminShell>
                    <UserManagementPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/group-plan"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <GroupPlanningPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/group-observation"
            element={
              <RequireAuth>
                <RequireRole roles={['evaluator']}>
                  <GroupObservationPage />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/interview-plan"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <InterviewPlanningPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/interview-score"
            element={
              <RequireAuth>
                <RequireRole roles={['evaluator']}>
                  <InterviewScorePage />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/writing-plan"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <WritingPlanningPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/writing-score"
            element={
              <RequireAuth>
                <RequireRole roles={['evaluator']}>
                  <WritingScorePage />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/paper-backup"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <PaperBackupPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 입실 확인은 현장 노트북 전체 화면으로 쓰므로 사이드바 없이 띄운다. */}
          <Route
            path="/deep/checkin"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <CheckinPage />
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/interview-run-sheet"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <InterviewRunSheetPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/paper-entry"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <PaperScoreBulkEntryPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/admin-score-entry"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <AdminScoreEntryPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation/live-monitor"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin']}>
                  <AdminShell>
                    <LiveScoringMonitorPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation/scoresheet-print"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <DocumentScoresheetPrintPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/evaluation/staffing"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <EvaluationStaffingPage stage="document" />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/deep/staffing"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <EvaluationStaffingPage stage="deep" />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          <Route
            path="/admin/admission-cycle"
            element={
              <RequireAuth>
                <RequireRole roles={['superadmin', 'admin']}>
                  <AdminShell>
                    <AdmissionCycleSettingsPage />
                  </AdminShell>
                </RequireRole>
              </RequireAuth>
            }
          />
          {/* 개인정보처리방침 — RequireAuth 밖. */}
          <Route path="/privacy-policy" element={<PrivacyPolicyPage />} />
        </Routes>
        </AdmissionCycleProvider>
      </AuthProvider>
    </BrowserRouter>
  )
}

export default App
