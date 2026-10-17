-- Первый этап: учётные профили и роли. Применять один раз миграцией Supabase.
-- Самостоятельная регистрация должна оставаться отключённой в Supabase Auth.
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  first_name text,
  last_name text,
  access_status text not null default 'active'
    check (access_status in ('active', 'disabled')),
  created_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid primary key references public.profiles (user_id) on delete cascade,
  role text not null default 'employee'
    check (role in ('admin', 'employee')),
  created_at timestamptz not null default now()
);

-- Одновременно может существовать не более одной строки с ролью admin.
create unique index one_system_admin on public.user_roles ((true))
  where role = 'admin';

-- После первоначального назначения администратора его нельзя удалить или понизить.
-- Назначение выполняется только доверенной миграцией / SQL Editor после проверки UUID.
create function private.guard_system_admin()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.role = 'admin' then
      raise exception 'The system administrator cannot be removed';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if old.role = 'admin' and
       (new.role <> 'admin' or new.user_id is distinct from old.user_id) then
      raise exception 'The system administrator cannot be replaced';
    end if;
  end if;

  if new.role = 'admin' and not exists (
    select 1 from public.profiles p
    where p.user_id = new.user_id and p.access_status = 'active'
  ) then
    raise exception 'The system administrator must have active access';
  end if;

  return new;
end;
$$;

create trigger guard_system_admin
before insert or update or delete on public.user_roles
for each row execute function private.guard_system_admin();

create function private.guard_admin_profile()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if exists (
      select 1 from public.user_roles r
      where r.user_id = old.user_id and r.role = 'admin'
    ) then
      raise exception 'The system administrator must keep an active profile';
    end if;
    return old;
  end if;

  if (new.user_id is distinct from old.user_id or new.access_status <> 'active')
     and exists (
       select 1 from public.user_roles r
       where r.user_id = old.user_id and r.role = 'admin'
     ) then
    raise exception 'The system administrator must keep an active profile';
  end if;

  return new;
end;
$$;

create trigger guard_admin_profile
before update or delete on public.profiles
for each row execute function private.guard_admin_profile();

-- Приглашение создаёт строку в auth.users до принятия письма. Профиль и
-- роль employee появляются после подтверждения email, в том числе для
-- пользователей, приглашённых до применения этой миграции.
-- Функция не принимает параметров от клиента и не выдаётся через Data API.
create function private.create_confirmed_employee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email_confirmed_at is null or new.email is null then
    return new;
  end if;

  insert into public.profiles (user_id, email, first_name, last_name)
  values (
    new.id,
    new.email,
    nullif(new.raw_user_meta_data ->> 'first_name', ''),
    nullif(new.raw_user_meta_data ->> 'last_name', '')
  )
  on conflict (user_id) do update set email = excluded.email;

  insert into public.user_roles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function private.guard_system_admin() from public, anon, authenticated;
revoke all on function private.guard_admin_profile() from public, anon, authenticated;
revoke all on function private.create_confirmed_employee() from public, anon, authenticated;

create trigger create_confirmed_employee
after insert or update on auth.users
for each row
when (new.email_confirmed_at is not null and new.email is not null)
execute function private.create_confirmed_employee();

-- Существующие подтверждённые пользователи не проходят через новый триггер.
insert into public.profiles (user_id, email, first_name, last_name)
select
  u.id,
  u.email,
  nullif(u.raw_user_meta_data ->> 'first_name', ''),
  nullif(u.raw_user_meta_data ->> 'last_name', '')
from auth.users u
where u.email_confirmed_at is not null and u.email is not null
on conflict (user_id) do nothing;

insert into public.user_roles (user_id)
select u.id
from auth.users u
where u.email_confirmed_at is not null and u.email is not null
on conflict (user_id) do nothing;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;

-- У Supabase могут быть широкие стандартные GRANT на таблицы public.
revoke all on table public.profiles, public.user_roles from public, anon, authenticated;
grant select on table public.profiles, public.user_roles to authenticated;

create policy "read own active profile"
on public.profiles for select to authenticated
using (user_id = (select auth.uid()) and access_status = 'active');

-- Проверка роли идёт через user_roles; её политика читает только собственную
-- строку и не обращается к profiles, поэтому рекурсии RLS нет.
create policy "administrator reads profiles"
on public.profiles for select to authenticated
using (
  exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin'
  )
);

create policy "read own role"
on public.user_roles for select to authenticated
using (user_id = (select auth.uid()));

-- INSERT / UPDATE / DELETE для браузерных ролей не выдаются. Роль и статус
-- доступа изменяются только будущими доверенными серверными операциями.
-- После применения миграции один подтверждённый активный пользователь должен
-- быть назначен администратором отдельным привилегированным действием.
commit;
