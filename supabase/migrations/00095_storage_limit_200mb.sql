-- 서류 저장소 한 파일 한도 25MB → 200MB (2026-10-20)
-- 스캔 서류(컬러·300dpi 이상)가 25MB를 쉽게 넘는다. 화질을 낮추는 압축 대신 한도를 올린다.
-- 서류 업로드는 서버 PC에서 교내 주소(https://local.example.org)로만 한다(2026-10-20 결정).
-- 교외 주소(ipsi)는 Cloudflare 터널을 지나 요청당 100MB 제한이 있으므로, 화면에서 95MB 넘는 파일은 교내 주소로 안내한다.
-- ※ 저장소 서비스 자체 한도(storage 컨테이너 FILE_SIZE_LIMIT)도 200MB 이상이어야 한다.
update storage.buckets
set file_size_limit = 209715200
where id = 'admission-documents';

select id, file_size_limit from storage.buckets where id = 'admission-documents';
