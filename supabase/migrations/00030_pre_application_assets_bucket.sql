-- 새봄고 입학전형 시스템 — M8b 정적 자산(한글 폰트·원본 양식 PDF) Storage 버킷
-- `generate-application-bundle` Edge Function이 폰트 2종·원본 양식 PDF 3종을
-- 함수 코드에 직접 묻지 않고(배포 페이로드 제한으로 두 번 실패했음 — 자세한
-- 내용은 supabase/functions/_shared/pdfKoreanFont.ts 상단 주석 참고)
-- 이 버킷에서 매 호출마다 service_role로 다운로드해서 쓴다.
--
-- 이 마이그레이션은 버킷만 만든다. 실제 파일 5개(fonts/Pretendard-Regular.ttf,
-- fonts/Pretendard-Bold.ttf, formTemplates/2026-draft-v1/general.pdf,
-- formTemplates/2026-draft-v1/incheonRecommend.pdf,
-- formTemplates/2026-draft-v1/socialIntegration.pdf)는 Supabase 대시보드
-- Storage 화면에서 관리자가 직접 업로드한다 — CLI/코드가 아니라 사람이
-- 올려두는 정적 자산이라는 점이 다른 버킷과 다르다.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pre-application-assets',
  'pre-application-assets',
  false,
  10485760,
  array['font/ttf', 'application/font-sfnt', 'application/octet-stream', 'application/pdf']
)
on conflict (id) do nothing;

-- 의도적으로 storage.objects 정책을 하나도 만들지 않는다 — RLS enabled +
-- 정책 없음 = anon/authenticated 전면 차단. Edge Function의 service_role만
-- 다운로드 가능(00027/00028과 동일한 원칙).
