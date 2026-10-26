-- 01. 첫 최고관리자(superadmin) 만들기 — 프로젝트당 딱 한 번
--
-- 준비: Supabase 대시보드 > Authentication > Users > [Add user] 에서
--       최고관리자가 쓸 이메일·비밀번호로 사용자를 하나 만든다(Auto Confirm 켜기).
--       셀프 호스팅이면 Studio(http://서버주소:8000) 의 같은 메뉴에서 만든다.
--
-- 사용법: 아래 세 값을 바꾼 뒤 SQL Editor 에서 실행한다. 'superadmin 1명 준비됨'이 나오면 성공.
--   v_email : 위에서 만든 사용자의 이메일
--   v_name  : 화면에 보일 이름
--   v_phone : 휴대전화(교외 접속 때 문자 인증에 쓴다. 교내에서만 쓰면 null 로 둬도 된다)
--   v_year  : 운영할 학년도(예: 2027 → 2026년 가을 원서 접수)
--
-- 이 방법은 감사 기록을 남기지 않으므로 처음 한 번만 쓴다.
-- 그다음 계정은 앱의 [계정 관리] 화면에서 만든다.

do $$
declare
  v_email text := 'admin@school.example.kr';
  v_name  text := '최고관리자';
  v_phone text := null;          -- 예: '010-0000-0000'
  v_year  int  := 2027;
  v_id uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);
  if v_id is null then
    raise exception '% 사용자가 없습니다. Authentication > Users 에서 먼저 만드세요.', v_email;
  end if;

  insert into public.users
    (id, display_name, email, active, roles, assigned_areas, year_scopes, round_scopes,
     mobile_phone, created_by, updated_by)
  values
    (v_id, v_name, v_email, true,
     array['superadmin']::app_role[], '{}'::evaluation_area[], array[v_year],
     array['main', 'extra1', 'extra2']::admission_round[],
     v_phone, 'bootstrap-sql', 'bootstrap-sql')
  on conflict (id) do update set
    roles = array['superadmin']::app_role[],
    active = true,
    year_scopes = array[v_year],
    mobile_phone = coalesce(excluded.mobile_phone, public.users.mobile_phone),
    updated_at = now(),
    updated_by = 'bootstrap-sql';

  raise notice 'superadmin 1명 준비됨: %', v_email;
end $$;
