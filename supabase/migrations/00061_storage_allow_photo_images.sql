-- 새봄고 입학전형 시스템 — 증명사진 업로드를 위한 스토리지 MIME 허용 (2026-09-16)
--
-- 00004에서 admission-documents 버킷을 만들 때 allowed_mime_types를
-- {application/pdf}로 못박았다. 당시에는 모든 제출서류가 PDF였기 때문이다.
--
-- 2026-09-04에 지원자 증명사진(서식 1 부착 사진의 스캔본)을 받게 되면서
-- JPG·PNG가 필요해졌는데, 버킷 제한이 그대로라 업로드가 스토리지 단계에서
-- 거부된다(메타데이터 등록 RPC까지 가지도 못한다). 허용 목록을 넓힌다.
--
-- 이미지만 추가하고 그 외 형식은 계속 막는다 — 실행 파일이나 임의 첨부가
-- 올라가는 경로가 되지 않도록 최소한으로만 연다.

update storage.buckets
set allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
where id = 'admission-documents';

-- 확인용 — 적용 후 이 결과가 3개 형식을 보여야 한다.
select id, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'admission-documents';
