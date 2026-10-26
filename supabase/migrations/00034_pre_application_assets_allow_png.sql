-- 새봄고 입학전형 시스템 — pre-application-assets 버킷에 로고(PNG) 업로드 허용
--
-- 00030에서 이 버킷을 만들 때는 폰트(font/ttf 등)와 원본 양식 PDF만 염두에
-- 두고 allowed_mime_types를 좁게 잡았다. 이후 우편라벨에 학교 로고를 넣기로
-- 하면서(logo/school-logo.png) 관리자가 Supabase 대시보드에서 업로드를
-- 시도했으나 "Mime type image/png is not supported" 오류가 발생 — 버킷
-- 생성 시점엔 image/png가 허용 목록에 없었기 때문이다.
--
-- 00030은 `on conflict do nothing`이라 재실행해도 기존 버킷 설정을 덮어쓰지
-- 않으므로, 여기서는 별도로 update만 수행한다.

update storage.buckets
set allowed_mime_types = array[
  'font/ttf',
  'application/font-sfnt',
  'application/octet-stream',
  'application/pdf',
  'image/png'
]
where id = 'pre-application-assets';
