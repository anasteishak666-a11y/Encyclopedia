-- Read-only administrative roster. Reuse the same eligibility rules as employee tests.
begin;

create function public.testing_admin_employees(
  p_actor uuid, p_limit integer default 100, p_after uuid default null
)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_now timestamptz;
  v_rows jsonb := '[]'::jsonb;
  v_next uuid;
  v_last uuid;
  v_count integer := 0;
  v_row record;
  v_basic jsonb;
  v_full jsonb;
begin
  perform private.testing_require_actor(p_actor, 'admin');
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_limit' using errcode = '22023';
  end if;
  v_now := clock_timestamp();

  for v_row in
    select p.user_id, p.first_name, p.last_name, p.email, p.access_status,
           basic_result.percentage as basic_percentage,
           full_result.percentage as full_percentage,
           full_result.passed as full_passed,
           full_result.valid_until as full_valid_until
    from public.profiles p
    join public.user_roles role on role.user_id = p.user_id and role.role = 'employee'
    left join lateral (
      select result.percentage
      from private.attempts attempt
      join private.attempt_results result on result.attempt_id = attempt.id
      where attempt.employee_id = p.user_id and attempt.test_kind = 'basic'
      order by attempt.finished_at desc, attempt.id desc limit 1
    ) basic_result on true
    left join lateral (
      select result.percentage, result.passed, result.valid_until
      from private.attempts attempt
      join private.attempt_results result on result.attempt_id = attempt.id
      where attempt.employee_id = p.user_id and attempt.test_kind = 'full'
      order by attempt.finished_at desc, attempt.id desc limit 1
    ) full_result on true
    where p_after is null or p.user_id > p_after
    order by p.user_id
    limit p_limit + 1
  loop
    if v_count = p_limit then
      v_next := v_row.user_id;
      exit;
    end if;
    v_count := v_count + 1;
    v_last := v_row.user_id;
    if v_row.access_status = 'active' then
      v_basic := private.testing_eligibility(v_row.user_id, 'basic', v_now);
      v_full := private.testing_eligibility(v_row.user_id, 'full', v_now);
    else
      v_basic := jsonb_build_object('state', 'disabled');
      v_full := jsonb_build_object('state', 'disabled');
    end if;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'employee_id', v_row.user_id,
      'first_name', v_row.first_name,
      'last_name', v_row.last_name,
      'email', v_row.email,
      'access_status', v_row.access_status,
      'basic', jsonb_build_object(
        'state', v_basic->>'state', 'latest_percentage', v_row.basic_percentage),
      'full', jsonb_build_object(
        'state', v_full->>'state', 'latest_percentage', v_row.full_percentage,
        'valid_until_moscow', case
          when v_row.full_passed and v_row.full_valid_until > v_now
          then private.testing_moscow_label(v_row.full_valid_until) else null end)
    ));
  end loop;

  return jsonb_build_object('employees', v_rows,
    'next_cursor', case when v_next is not null then v_last::text else null end,
    'server_now', v_now);
end;
$$;

revoke all on function public.testing_admin_employees(uuid, integer, uuid)
  from public, anon, authenticated;
grant execute on function public.testing_admin_employees(uuid, integer, uuid)
  to service_role;

commit;
