-- Allow trusted administrators to correct employee names without changing identity/history.
-- Require a meaningful reason for every new early-retake override.
begin;

grant update (first_name, last_name) on public.profiles to service_role;

create function public.testing_update_employee_name(
  p_actor uuid, p_employee uuid, p_first_name text, p_last_name text
)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_profile public.profiles%rowtype;
begin
  perform private.testing_require_actor(p_actor, 'admin');
  if p_employee is null or p_first_name is null or p_last_name is null or
     length(btrim(p_first_name)) not between 1 and 100 or
     length(btrim(p_last_name)) not between 1 and 100 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  perform 1 from public.user_roles
  where user_id = p_employee and role = 'employee';
  if not found then raise exception 'employee_not_found' using errcode = 'P0002'; end if;
  update public.profiles
  set first_name = btrim(p_first_name), last_name = btrim(p_last_name)
  where user_id = p_employee
  returning * into v_profile;
  if not found then raise exception 'employee_not_found' using errcode = 'P0002'; end if;
  return jsonb_build_object('employee_id', v_profile.user_id,
    'first_name', v_profile.first_name, 'last_name', v_profile.last_name);
end;
$$;

revoke all on function public.testing_update_employee_name(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.testing_update_employee_name(uuid, uuid, text, text)
  to service_role;

create or replace function public.testing_grant_retake(
  p_actor uuid, p_employee uuid, p_kind text,
  p_request uuid, p_note text default null
)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_existing private.retake_overrides%rowtype;
  v_state text;
  v_expired uuid;
  v_new private.retake_overrides%rowtype;
begin
  perform private.testing_require_actor(p_actor, 'admin');
  if p_request is null or p_employee is null or
     p_kind not in ('basic', 'full') or p_kind is null or
     p_note is null or length(btrim(p_note)) not between 1 and 500 then
    raise exception 'invalid_note' using errcode = '22023';
  end if;
  perform 1 from public.profiles where user_id = p_employee for update;
  if not found then raise exception 'employee_not_found' using errcode = 'P0002'; end if;
  perform private.testing_require_actor(p_employee, 'employee');
  select * into v_existing from private.retake_overrides
  where request_id = p_request;
  if found then
    if v_existing.employee_id <> p_employee or
       v_existing.test_kind <> p_kind or
       v_existing.granted_by <> p_actor or
       v_existing.note is distinct from btrim(p_note) then
      raise exception 'request_id_conflict' using errcode = 'P0001';
    end if;
    return jsonb_build_object('override_id', v_existing.id,
      'employee_id', p_employee, 'kind', p_kind,
      'granted_at', v_existing.granted_at,
      'used_by_attempt_id', v_existing.used_by_attempt_id);
  end if;
  if exists (select 1 from private.retake_overrides o
             where o.employee_id = p_employee and o.test_kind = p_kind
               and o.used_by_attempt_id is null) then
    raise exception 'override_already_open' using errcode = 'P0001';
  end if;
  select a.id into v_expired from private.attempts a
  where a.employee_id = p_employee and a.test_kind = p_kind
    and a.state = 'in_progress' and a.deadline_at <= clock_timestamp()
  limit 1 for update;
  if found then perform private.testing_finalize(v_expired); end if;
  v_state := (private.testing_eligibility(p_employee, p_kind,
                                           clock_timestamp()) ->> 'state');
  if v_state not in ('cooldown', 'valid_until_due') then
    raise exception 'override_not_needed' using errcode = 'P0001';
  end if;
  insert into private.retake_overrides (
    employee_id, test_kind, granted_by, request_id, note
  ) values (p_employee, p_kind, p_actor, p_request, btrim(p_note))
  returning * into v_new;
  return jsonb_build_object('override_id', v_new.id,
    'employee_id', p_employee, 'kind', p_kind,
    'granted_at', v_new.granted_at, 'used_by_attempt_id', null);
end;
$$;

revoke all on function public.testing_grant_retake(uuid, uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.testing_grant_retake(uuid, uuid, text, uuid, text)
  to service_role;

commit;
