-- 새봄고 입학전형 시스템 — 용어 통일: '1차/2차' → '1단계/2단계' (2026-10-26)
--
-- 화면·문자는 프론트에서 바꿨고, 여기서는 DB 함수가 돌려주는 안내·오류 문구를 바꾼다.
-- 함수마다 다시 쓰지 않고, 지금 정의(pg_get_functiondef)에서 문구만 바꿔 그대로 다시 만든다
-- (CREATE OR REPLACE라 권한·인자·동작은 그대로).
--   바꾸는 것: 1차 사정 / 1차 서류(사정·평가·전형) / 1차 결과 / 1차 합격 / 1차 순위 / 1차 대상 / 2차 심층 / 2차 대상
--   안 바꾸는 것: '추가모집(1차)·(2차)' 같은 모집 회차 이름(뒤에 위 낱말이 오지 않으므로 걸리지 않음)
-- 바뀐 함수 이름은 NOTICE로 보여 준다. 두 번 실행해도 안전하다(바꿀 게 없으면 건너뜀).

do $$
declare
  r record;
  v_def text;
  v_new text;
  v_count int := 0;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosrc ~ '[12]차 ?(사정|서류|결과|합격|순위|대상|심층)'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, '([12])차( ?)(사정|서류|결과|합격|순위|대상|심층)', '\1단계\2\3', 'g');
    if v_new <> v_def then
      execute v_new;
      v_count := v_count + 1;
      raise notice '문구 바꿈: %', r.proname;
    end if;
  end loop;
  raise notice '함수 %개의 문구를 바꿨습니다.', v_count;
end $$;
