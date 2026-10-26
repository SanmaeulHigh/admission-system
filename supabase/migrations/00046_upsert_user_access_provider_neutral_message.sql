-- 2026-07-13: 로그인 방식을 Google OAuth에서 자체 이메일/비밀번호로 전환하면서
-- (feature/local-server-migration, Login.jsx 개편) upsert_user_access의 에러
-- 메시지에 남아있던 "Google로 로그인" 문구를 provider-중립 표현으로 교체한다.
-- 로직(auth.users 존재 여부 확인) 자체는 그대로 — 애초에 이 함수는 provider를
-- 구분하지 않았고, 문구만 구글 전용으로 돼 있었다.

create or replace function public.upsert_user_access(
  target_email text,
  new_display_name text,
  new_roles app_role[],
  new_assigned_areas evaluation_area[] default '{}',
  new_year_scopes int[] default '{2027}',
  new_round_scopes admission_round[] default '{main}'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  target uuid;
  was_new boolean;
begin
  caller := public._require_superadmin();

  if new_display_name is null or length(trim(new_display_name)) = 0 then
    raise exception 'display_name은 필수입니다.';
  end if;
  if new_roles is null or array_length(new_roles, 1) is null then
    raise exception '최소 1개 이상의 역할이 필요합니다.';
  end if;

  select id into target from auth.users where lower(email) = lower(target_email);
  if target is null then
    raise exception '% 계정이 아직 로그인(가입)한 적이 없습니다. 대상자가 먼저 앱에서 계정을 만들고 1회 로그인한 뒤 다시 시도하세요.', target_email;
  end if;

  was_new := not exists (select 1 from public.users where id = target);

  insert into public.users
    (id, display_name, email, active, roles, assigned_areas, year_scopes, round_scopes,
     created_by, updated_by)
  values
    (target, new_display_name, lower(target_email), true, new_roles, new_assigned_areas,
     new_year_scopes, new_round_scopes, caller::text, caller::text)
  on conflict (id) do update set
    display_name = excluded.display_name,
    active = true,
    roles = excluded.roles,
    assigned_areas = excluded.assigned_areas,
    year_scopes = excluded.year_scopes,
    round_scopes = excluded.round_scopes,
    updated_at = now(),
    updated_by = caller::text;

  insert into public.audit_logs
    (actor_type, actor_uid, action, resource_type, resource_id, metadata)
  values
    ('user', caller::text,
     case when was_new then 'user.access.created' else 'user.access.updated' end,
     'users', target::text,
     json_build_object(
       'roles', new_roles, 'assignedAreas', new_assigned_areas,
       'yearScopes', new_year_scopes, 'roundScopes', new_round_scopes
     )::jsonb);

  return json_build_object('uid', target, 'isNewUser', was_new);
end;
$$;
