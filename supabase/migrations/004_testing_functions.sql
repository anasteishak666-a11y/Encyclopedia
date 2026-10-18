-- Серверные операции тестирования. Выполнять после 001, 002 и 003.
-- Вызываются только доверенным сервером с отдельной ролью service_role.
-- Edge Function обязана проверить Supabase Auth и передать подтверждённый UUID
-- как p_actor; UUID из тела запроса нельзя принимать за подтверждённую личность.
-- private остаётся вне Exposed schemas. Функции public доступны по RPC только
-- service_role; браузерные anon/authenticated не имеют EXECUTE.
begin;

create function private.testing_require_actor(p_actor uuid, p_role text default null)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_role text;
begin
  select r.role into v_role
  from public.profiles p
  join public.user_roles r on r.user_id = p.user_id
  where p.user_id = p_actor and p.access_status = 'active';
  if v_role is null or (p_role is not null and v_role <> p_role) then
    raise exception 'access_denied' using errcode = '42501';
  end if;
end;
$$;

create function private.testing_moscow_label(p_time timestamptz)
returns text language sql stable security invoker set search_path = '' as $$
  select case when p_time is null then null else
    to_char(p_time at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI') || ' МСК'
  end;
$$;

-- Названный часовой пояс и сложение календарных месяцев сохраняют местное
-- время и ограничивают 31-е число последним днём короткого месяца.
create function private.testing_valid_until(p_finished timestamptz, p_months integer)
returns timestamptz language sql stable security invoker set search_path = '' as $$
  select ((p_finished at time zone 'Europe/Moscow') +
          make_interval(months => p_months)) at time zone 'Europe/Moscow';
$$;

-- Возвращает только последнюю версию активного вопроса с заполненными
-- вариантами, проверенным ключом и фотографией для фото-вопроса.
create function private.testing_candidates(p_kind text, p_employee uuid)
returns table (question_id uuid, version_id uuid, topic_slug text,
               difficulty text, unseen boolean)
language sql stable security invoker set search_path = '' as $$
  with latest as (
    select distinct on (q.id)
      q.id as question_id, v.id as version_id, q.topic_slug,
      q.difficulty, q.question_type
    from private.questions q
    join private.question_versions v on v.question_id = q.id
    where q.test_kind = p_kind and q.is_active
    order by q.id, v.version desc
  )
  select l.question_id, l.version_id, l.topic_slug, l.difficulty,
    not exists (
      select 1 from private.attempts a
      join private.attempt_questions aq on aq.attempt_id = a.id
      where a.employee_id = p_employee and aq.question_id = l.question_id
    ) as unseen
  from latest l
  where (select count(*) from private.question_options o
         where o.question_version_id = l.version_id) >= 2
    and (
      (l.question_type in ('single', 'scenario_single', 'photo_single') and
       (select count(*) from private.answer_keys k
        where k.question_version_id = l.version_id) = 1)
      or
      (l.question_type in ('multiple', 'scenario_multiple', 'photo_multiple') and
       (select count(*) from private.answer_keys k
        where k.question_version_id = l.version_id) >= 1)
    )
    and (l.question_type not in ('photo_single', 'photo_multiple') or
         exists (select 1 from private.question_photos ph
                 where ph.question_version_id = l.version_id));
$$;

-- Потоковая проверка совместимости девяти квот тем и трёх квот сложности.
-- Рёбра topic -> difficulty имеют ёмкость по числу пригодных вопросов.
-- Пустой результат означает, что 50 вопросов с обеими квотами набрать нельзя.
create function private.testing_full_plan(p_rule uuid, p_employee uuid)
returns table (topic_slug text, difficulty text, needed integer)
language plpgsql security invoker set search_path = '' as $$
declare
  v_topics text[];
  v_topic_counts integer[];
  v_difficulty_counts integer[];
  v_difficulties text[] := array['basic', 'medium', 'hard'];
  v_residual integer[][] := array_fill(0, array[14, 14]);
  v_parent integer[];
  v_queue integer[];
  v_head integer;
  v_tail integer;
  v_u integer;
  v_v integer;
  v_i integer;
  v_j integer;
  v_flow integer;
  v_total integer := 0;
  v_expected integer;
  v_row record;
begin
  select array_agg(t.slug order by t.display_order),
         array_agg(q.question_count order by t.display_order),
         sum(q.question_count)::integer
  into v_topics, v_topic_counts, v_expected
  from private.test_topic_quotas q
  join private.topics t on t.slug = q.topic_slug
  where q.rule_id = p_rule;
  select array_agg(q.question_count
                   order by array_position(v_difficulties, q.difficulty))
  into v_difficulty_counts
  from private.test_difficulty_quotas q where q.rule_id = p_rule;
  if cardinality(v_topics) is distinct from 9 or v_expected is distinct from 50 or
     v_topic_counts is distinct from array[9,9,6,6,4,7,3,3,3] or
     v_difficulty_counts is distinct from array[15,25,10] then
    return;
  end if;

  for v_row in
    select t.slug, q.question_count
    from private.test_topic_quotas q
    join private.topics t on t.slug = q.topic_slug
    where q.rule_id = p_rule
  loop
    v_i := array_position(v_topics, v_row.slug);
    v_residual[1][v_i + 1] := v_row.question_count;
  end loop;
  for v_row in
    select q.difficulty, q.question_count
    from private.test_difficulty_quotas q where q.rule_id = p_rule
  loop
    v_j := array_position(v_difficulties, v_row.difficulty);
    v_residual[10 + v_j][14] := v_row.question_count;
  end loop;
  for v_row in
    select c.topic_slug, c.difficulty, count(*)::integer as capacity
    from private.testing_candidates('full', p_employee) c
    group by c.topic_slug, c.difficulty
  loop
    v_i := array_position(v_topics, v_row.topic_slug);
    v_j := array_position(v_difficulties, v_row.difficulty);
    if v_i is not null and v_j is not null then
      v_residual[v_i + 1][10 + v_j] := v_row.capacity;
    end if;
  end loop;

  loop
    v_parent := array_fill(0, array[14]);
    v_queue := array_fill(0, array[14]);
    v_parent[1] := -1;
    v_queue[1] := 1;
    v_head := 1;
    v_tail := 1;
    while v_head <= v_tail and v_parent[14] = 0 loop
      v_u := v_queue[v_head];
      v_head := v_head + 1;
      for v_v in 2..14 loop
        if v_parent[v_v] = 0 and v_residual[v_u][v_v] > 0 then
          v_parent[v_v] := v_u;
          v_tail := v_tail + 1;
          v_queue[v_tail] := v_v;
        end if;
      end loop;
    end loop;
    exit when v_parent[14] = 0;
    v_flow := 50;
    v_v := 14;
    while v_v <> 1 loop
      v_u := v_parent[v_v];
      v_flow := least(v_flow, v_residual[v_u][v_v]);
      v_v := v_u;
    end loop;
    v_v := 14;
    while v_v <> 1 loop
      v_u := v_parent[v_v];
      v_residual[v_u][v_v] := v_residual[v_u][v_v] - v_flow;
      v_residual[v_v][v_u] := v_residual[v_v][v_u] + v_flow;
      v_v := v_u;
    end loop;
    v_total := v_total + v_flow;
  end loop;
  if v_total <> 50 then return; end if;
  for v_i in 1..9 loop
    for v_j in 1..3 loop
      if v_residual[10 + v_j][v_i + 1] > 0 then
        topic_slug := v_topics[v_i];
        difficulty := v_difficulties[v_j];
        needed := v_residual[10 + v_j][v_i + 1];
        return next;
      end if;
    end loop;
  end loop;
end;
$$;

create function private.testing_eligibility(p_employee uuid, p_kind text,
                                            p_at timestamptz)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_open private.attempts%rowtype;
  v_last_passed boolean;
  v_last_retry timestamptz;
  v_last_valid timestamptz;
  v_basic_passed boolean;
  v_override boolean;
  v_rule uuid;
  v_rule_data private.test_rules%rowtype;
  v_count integer;
  v_state text := 'available';
  v_next timestamptz;
begin
  if p_kind not in ('basic', 'full') then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;
  select * into v_open from private.attempts
  where employee_id = p_employee and test_kind = p_kind
    and state = 'in_progress'
  limit 1;
  if found then
    return jsonb_build_object('kind', p_kind, 'state', 'in_progress',
      'can_start', false, 'active_attempt_id', v_open.id,
      'deadline_at', v_open.deadline_at, 'next_allowed_at', null,
      'next_allowed_moscow', null);
  end if;

  select exists (
    select 1 from private.attempts a
    join private.attempt_results r on r.attempt_id = a.id
    where a.employee_id = p_employee and a.test_kind = 'basic' and r.passed
  ) into v_basic_passed;
  select exists (
    select 1 from private.retake_overrides o
    where o.employee_id = p_employee and o.test_kind = p_kind
      and o.used_by_attempt_id is null
  ) into v_override;
  select r.passed, r.retry_available_at, r.valid_until
  into v_last_passed, v_last_retry, v_last_valid
  from private.attempts a
  join private.attempt_results r on r.attempt_id = a.id
  where a.employee_id = p_employee and a.test_kind = p_kind
  order by a.finished_at desc, a.id desc limit 1;

  if p_kind = 'basic' and v_basic_passed then
    v_state := 'passed';
  elsif p_kind = 'full' and not v_basic_passed then
    v_state := 'prerequisite_required';
  elsif v_last_passed and p_kind = 'full' and v_last_valid > p_at
        and not v_override then
    v_state := 'valid_until_due';
    v_next := v_last_valid;
  elsif not v_last_passed and v_last_retry > p_at
        and not v_override then
    v_state := 'cooldown';
    v_next := v_last_retry;
  end if;

  if v_state = 'available' then
    select r.* into v_rule_data from private.active_test_rules a
    join private.test_rules r on r.id = a.rule_id
    where a.test_kind = p_kind;
    v_rule := v_rule_data.id;
    if v_rule is null or
       (p_kind = 'basic' and
        (v_rule_data.question_count <> 20 or
         v_rule_data.duration_seconds <> 1500 or
         v_rule_data.pass_count <> 16 or
         v_rule_data.retry_after <> interval '24 hours')) or
       (p_kind = 'full' and
        (v_rule_data.question_count <> 50 or
         v_rule_data.duration_seconds <> 4500 or
         v_rule_data.pass_count <> 45 or
         v_rule_data.retry_after <> interval '7 days' or
         v_rule_data.recertification_months <> 3)) then
      v_state := 'bank_unavailable';
    elsif p_kind = 'basic' then
      select count(*) into v_count
      from private.testing_candidates(p_kind, p_employee);
      if v_count < (select r.question_count from private.test_rules r
                    where r.id = v_rule) then
        v_state := 'bank_unavailable';
      end if;
    else
      select coalesce(sum(plan.needed), 0) into v_count
      from private.testing_full_plan(v_rule, p_employee) plan;
      if v_count <> (select r.question_count from private.test_rules r
                     where r.id = v_rule) then
        v_state := 'bank_unavailable';
      end if;
    end if;
  end if;
  return jsonb_build_object('kind', p_kind, 'state', v_state,
    'can_start', v_state = 'available', 'active_attempt_id', null,
    'deadline_at', null, 'next_allowed_at', v_next,
    'next_allowed_moscow', private.testing_moscow_label(v_next));
end;
$$;

-- Вызывающий код либо уже держит FOR UPDATE на попытке, либо получает её здесь.
-- Функция вызывается только в рамках одного серверного запроса/транзакции.
create function private.testing_finalize(p_attempt uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_attempt private.attempts%rowtype;
  v_rule private.test_rules%rowtype;
  v_now timestamptz;
  v_finished timestamptz;
  v_answered integer;
  v_assigned integer;
  v_correct integer;
  v_last_answered_at timestamptz;
  v_pct numeric(6,3);
  v_passed boolean;
  v_level text;
  v_outcome text;
  v_retry timestamptz;
  v_valid timestamptz;
  v_state text;
begin
  select * into v_attempt from private.attempts where id = p_attempt for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_attempt.state <> 'in_progress' then
    return jsonb_build_object('attempt_id', p_attempt, 'state', v_attempt.state,
      'finished_at', v_attempt.finished_at);
  end if;
  select * into v_rule from private.test_rules where id = v_attempt.rule_id;
  v_now := clock_timestamp();
  select count(*), count(aa.attempt_question_id),
         coalesce(sum(case when aa.is_correct and
                                  aa.answered_at < v_attempt.deadline_at
                           then 1 else 0 end), 0),
         max(aa.answered_at)
    into v_assigned, v_answered, v_correct, v_last_answered_at
  from private.attempt_questions aq
  left join private.attempt_answers aa on aa.attempt_question_id = aq.id
  where aq.attempt_id = p_attempt;
  if v_assigned <> v_rule.question_count then
    raise exception 'attempt_question_count_mismatch' using errcode = 'P0001';
  end if;
  if v_answered < v_rule.question_count and v_now < v_attempt.deadline_at then
    raise exception 'attempt_incomplete' using errcode = 'P0001';
  end if;
  v_state := case when v_answered = v_rule.question_count
                    and v_last_answered_at < v_attempt.deadline_at
                  then 'completed' else 'timed_out' end;
  -- При позднем фоновом завершении срок пересдачи идёт от реального дедлайна.
  v_finished := case when v_state = 'timed_out' then v_attempt.deadline_at
                     else v_last_answered_at end;
  v_pct := round(v_correct::numeric * 100 / v_rule.question_count, 3);
  v_passed := v_correct >= v_rule.pass_count;
  v_level := case when v_pct < 60 then 'insufficient'
                  when v_pct < 80 then 'basic'
                  when v_pct < 90 then 'good' else 'excellent' end;
  v_outcome := case
    when v_attempt.test_kind = 'basic' and v_passed then 'basic_passed'
    when v_attempt.test_kind = 'basic' then 'basic_failed'
    when v_passed then 'attestation_passed'
    when v_attempt.is_reattest then 'attestation_not_confirmed'
    else 'attestation_failed' end;
  if v_passed and v_attempt.test_kind = 'full' then
    v_valid := private.testing_valid_until(v_finished,
                                            v_rule.recertification_months);
  elsif not v_passed then
    -- 24 часа / 7 суток считаются как точное число секунд независимо от
    -- TimeZone сессии (interval '7 days' может зависеть от перехода на DST).
    v_retry := v_finished +
      (interval '1 second' *
       extract(epoch from v_rule.retry_after)::double precision);
  end if;

  insert into private.attempt_results (
    attempt_id, test_kind, correct_count, question_count, percentage,
    knowledge_level, passed, outcome, retry_available_at, valid_until
  ) values (
    p_attempt, v_attempt.test_kind, v_correct, v_rule.question_count, v_pct,
    v_level, v_passed, v_outcome, v_retry, v_valid
  );
  if v_attempt.test_kind = 'full' then
    insert into private.attempt_topic_results (
      attempt_id, topic_slug, correct_count, question_count, percentage
    )
    select p_attempt, aq.topic_slug,
      sum(case when aa.is_correct and
                    aa.answered_at < v_attempt.deadline_at
               then 1 else 0 end)::integer,
      count(*)::integer,
      round(sum(case when aa.is_correct and
                          aa.answered_at < v_attempt.deadline_at
                     then 1 else 0 end)::numeric *
            100 / count(*), 3)
    from private.attempt_questions aq
    left join private.attempt_answers aa on aa.attempt_question_id = aq.id
    where aq.attempt_id = p_attempt
    group by aq.topic_slug;
  end if;
  update private.attempts set state = v_state, finished_at = v_finished
  where id = p_attempt;
  return jsonb_build_object('attempt_id', p_attempt, 'state', v_state,
    'finished_at', v_finished);
end;
$$;

create function public.testing_availability(p_actor uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_full_passed boolean;
  v_full_outcome text;
  v_full_valid timestamptz;
  v_expired uuid;
  v_status text := 'not_started';
  v_now timestamptz;
begin
  perform private.testing_require_actor(p_actor, 'employee');
  select a.id into v_expired from private.attempts a
  where a.employee_id = p_actor and a.state = 'in_progress'
    and a.deadline_at <= clock_timestamp()
  limit 1 for update;
  if found then perform private.testing_finalize(v_expired); end if;
  v_now := clock_timestamp();
  select r.passed, r.outcome, r.valid_until
    into v_full_passed, v_full_outcome, v_full_valid
  from private.attempts a
  join private.attempt_results r on r.attempt_id = a.id
  where a.employee_id = p_actor and a.test_kind = 'full'
  order by a.finished_at desc, a.id desc limit 1;
  if found then
    v_status := case when v_full_outcome = 'attestation_not_confirmed'
                       then 'attestation_not_confirmed'
                     when v_full_passed and v_full_valid > v_now
                       then 'valid'
                     when v_full_passed then 'expired'
                     else 'not_passed' end;
  end if;
  return jsonb_build_object('server_now', v_now,
    'tests', jsonb_build_array(
      private.testing_eligibility(p_actor, 'basic', v_now),
      private.testing_eligibility(p_actor, 'full', v_now)),
    'attestation', jsonb_build_object('status', v_status,
      'valid_until', case when v_full_passed then v_full_valid else null end,
      'valid_until_moscow', case when v_full_passed then
        private.testing_moscow_label(v_full_valid) else null end));
end;
$$;

create function public.testing_start_or_resume(p_actor uuid, p_kind text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_open private.attempts%rowtype;
  v_rule private.test_rules%rowtype;
  v_eligibility jsonb;
  v_versions uuid[] := array[]::uuid[];
  v_cell uuid[];
  v_cell_row record;
  v_override uuid;
  v_started timestamptz;
  v_attempt uuid;
  v_is_reattest boolean;
  v_answered integer;
begin
  if p_kind not in ('basic', 'full') or p_kind is null then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;
  -- Общая блокировка сотрудника сериализует start и grant. Второй start
  -- увидит созданную первым попытку и вернёт её, не генерируя новый набор.
  perform 1 from public.profiles where user_id = p_actor for update;
  perform private.testing_require_actor(p_actor, 'employee');
  select * into v_open from private.attempts
  where employee_id = p_actor and test_kind = p_kind and state = 'in_progress'
  for update;
  if found then
    if clock_timestamp() >= v_open.deadline_at then
      return private.testing_finalize(v_open.id) ||
        jsonb_build_object('result_url', '/attempts/' || v_open.id || '/result',
                           'server_now', clock_timestamp());
    end if;
    select count(*) into v_answered from private.attempt_questions aq
    join private.attempt_answers aa on aa.attempt_question_id = aq.id
    where aq.attempt_id = v_open.id;
    return jsonb_build_object('attempt_id', v_open.id, 'kind', p_kind,
      'state', 'in_progress', 'resumed', true,
      'question_count', (select question_count from private.test_rules
                         where id = v_open.rule_id),
      'answered_count', v_answered, 'started_at', v_open.started_at,
      'deadline_at', v_open.deadline_at, 'server_now', clock_timestamp());
  end if;
  select * into v_open from private.attempts a
  where a.employee_id = p_actor and a.state = 'in_progress'
    and a.deadline_at <= clock_timestamp() limit 1 for update;
  if found then
    return private.testing_finalize(v_open.id) ||
      jsonb_build_object('result_url', '/attempts/' || v_open.id || '/result',
                         'server_now', clock_timestamp());
  end if;
  if exists (
    select 1 from private.attempts a where a.employee_id = p_actor
      and a.state = 'in_progress'
  ) then
    raise exception 'another_attempt_in_progress' using errcode = 'P0001';
  end if;
  v_eligibility := private.testing_eligibility(p_actor, p_kind,
                                                clock_timestamp());
  if v_eligibility ->> 'state' <> 'available' then
    raise exception '%', v_eligibility ->> 'state' using errcode = 'P0001';
  end if;
  select r.* into v_rule from private.active_test_rules ar
  join private.test_rules r on r.id = ar.rule_id
  where ar.test_kind = p_kind;
  if not found then raise exception 'bank_unavailable' using errcode = 'P0001'; end if;

  if p_kind = 'basic' then
    select array_agg(x.version_id) into v_versions from (
      select c.version_id from private.testing_candidates(p_kind, p_actor) c
      order by c.unseen desc, random() limit v_rule.question_count
    ) x;
  else
    for v_cell_row in
      select * from private.testing_full_plan(v_rule.id, p_actor)
    loop
      select array_agg(x.version_id) into v_cell from (
        select c.version_id from private.testing_candidates(p_kind, p_actor) c
        where c.topic_slug = v_cell_row.topic_slug
          and c.difficulty = v_cell_row.difficulty
        order by c.unseen desc, random() limit v_cell_row.needed
      ) x;
      v_versions := v_versions || coalesce(v_cell, array[]::uuid[]);
    end loop;
  end if;
  if cardinality(v_versions) is distinct from v_rule.question_count then
    raise exception 'bank_unavailable' using errcode = 'P0001';
  end if;
  select id into v_override from private.retake_overrides
  where employee_id = p_actor and test_kind = p_kind
    and used_by_attempt_id is null for update;
  select exists (
    select 1 from private.attempts a where a.employee_id = p_actor
      and a.test_kind = 'full'
      and exists (select 1 from private.attempt_results r
                  where r.attempt_id = a.id and r.passed)
  ) into v_is_reattest;
  v_started := clock_timestamp();
  insert into private.attempts (
    employee_id, test_kind, rule_id, is_reattest, started_at, deadline_at
  ) values (
    p_actor, p_kind, v_rule.id, p_kind = 'full' and v_is_reattest,
    v_started, v_started + make_interval(secs => v_rule.duration_seconds)
  ) returning id into v_attempt;

  insert into private.attempt_questions (
    attempt_id, position, question_id, question_version_id,
    topic_slug, difficulty
  )
  select v_attempt, row_number() over (order by random())::smallint,
    q.id, v.id, q.topic_slug, q.difficulty
  from unnest(v_versions) as chosen(version_id)
  join private.question_versions v on v.id = chosen.version_id
  join private.questions q on q.id = v.question_id;

  insert into private.attempt_question_options (
    attempt_question_id, question_version_id, option_id, position
  )
  select aq.id, aq.question_version_id, o.id,
    row_number() over (partition by aq.id order by random())::smallint
  from private.attempt_questions aq
  join private.question_options o
    on o.question_version_id = aq.question_version_id
  where aq.attempt_id = v_attempt;
  if v_override is not null then
    update private.retake_overrides set used_by_attempt_id = v_attempt
    where id = v_override;
  end if;
  return jsonb_build_object('attempt_id', v_attempt, 'kind', p_kind,
    'state', 'in_progress', 'resumed', false,
    'question_count', v_rule.question_count, 'answered_count', 0,
    'started_at', v_started,
    'deadline_at', v_started + make_interval(secs => v_rule.duration_seconds),
    'server_now', clock_timestamp());
end;
$$;

create function public.testing_current_question(p_actor uuid, p_attempt uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_attempt private.attempts%rowtype;
  v_question private.attempt_questions%rowtype;
  v_payload jsonb;
  v_now timestamptz;
begin
  perform private.testing_require_actor(p_actor, 'employee');
  select * into v_attempt from private.attempts
  where id = p_attempt and employee_id = p_actor for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_attempt.state <> 'in_progress' then
    return jsonb_build_object('attempt_id', p_attempt, 'state', v_attempt.state,
      'result_url', '/attempts/' || p_attempt || '/result',
      'server_now', clock_timestamp());
  end if;
  v_now := clock_timestamp();
  if v_now >= v_attempt.deadline_at then
    return private.testing_finalize(p_attempt) ||
      jsonb_build_object('result_url', '/attempts/' || p_attempt || '/result',
                         'server_now', clock_timestamp());
  end if;
  select * into v_question from private.attempt_questions aq
  where aq.attempt_id = p_attempt and not exists (
    select 1 from private.attempt_answers aa
    where aa.attempt_question_id = aq.id
  ) order by aq.position limit 1;
  if not found then
    return private.testing_finalize(p_attempt) ||
      jsonb_build_object('result_url', '/attempts/' || p_attempt || '/result',
                         'server_now', clock_timestamp());
  end if;
  select jsonb_build_object(
    'attempt_question_id', v_question.id,
    'type', q.question_type,
    'prompt', v.prompt,
    'topic', t.title,
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object('storage_path', ph.storage_path,
                                         'caption', ph.caption)
                       order by ph.display_order)
      from private.question_photos ph
      where ph.question_version_id = v_question.question_version_id
    ), '[]'::jsonb),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label)
                       order by ao.position)
      from private.attempt_question_options ao
      join private.question_options o on o.id = ao.option_id
      where ao.attempt_question_id = v_question.id
    ), '[]'::jsonb)
  ) into v_payload
  from private.question_versions v
  join private.questions q on q.id = v.question_id
  join private.topics t on t.slug = v_question.topic_slug
  where v.id = v_question.question_version_id;
  return jsonb_build_object('attempt_id', p_attempt,
    'position', v_question.position,
    'question_count', (select r.question_count from private.test_rules r
                       where r.id = v_attempt.rule_id),
    'question', v_payload,
    'deadline_at', v_attempt.deadline_at, 'server_now', v_now,
    'remaining_seconds', greatest(0,
      ceil(extract(epoch from v_attempt.deadline_at - v_now))::integer));
end;
$$;

create function public.testing_submit_answer(
  p_actor uuid, p_attempt uuid, p_request uuid,
  p_question uuid, p_options uuid[]
)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_attempt private.attempts%rowtype;
  v_existing private.attempt_answers%rowtype;
  v_existing_question uuid;
  v_current uuid;
  v_type text;
  v_selected uuid[];
  v_saved uuid[];
  v_key uuid[];
  v_total integer;
  v_answered integer;
  v_result jsonb;
  v_now timestamptz;
begin
  perform private.testing_require_actor(p_actor, 'employee');
  select * into v_attempt from private.attempts
  where id = p_attempt and employee_id = p_actor for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if p_request is null or p_question is null or p_options is null or
     cardinality(p_options) = 0 or array_position(p_options, null) is not null then
    raise exception 'invalid_options' using errcode = '22023';
  end if;
  select array_agg(x.id order by x.id) into v_selected
  from (select distinct id from unnest(p_options) as ids(id)) x;
  if cardinality(v_selected) <> cardinality(p_options) then
    raise exception 'invalid_options' using errcode = '22023';
  end if;

  -- Прежде чем проверять таймер, подтверждаем уже записанный ответ: сетевой
  -- повтор после последнего вопроса и после дедлайна остаётся идемпотентным.
  select aa.attempt_question_id into v_existing_question
  from private.attempt_answers aa where aa.request_id = p_request;
  if v_existing_question is not null and v_existing_question <> p_question then
    raise exception 'request_id_conflict' using errcode = 'P0001';
  end if;
  select aa.* into v_existing from private.attempt_answers aa
  join private.attempt_questions aq on aq.id = aa.attempt_question_id
  where aa.attempt_question_id = p_question and aq.attempt_id = p_attempt;
  if found then
    select array_agg(s.option_id order by s.option_id) into v_saved
    from private.attempt_answer_selections s
    where s.attempt_question_id = p_question;
    if v_saved is distinct from v_selected then
      raise exception 'answer_locked' using errcode = 'P0001';
    end if;
    select count(*) into v_answered from private.attempt_questions aq
    join private.attempt_answers aa on aa.attempt_question_id = aq.id
    where aq.attempt_id = p_attempt;
    return jsonb_build_object('saved', true, 'already_saved', true,
      'request_id', p_request, 'attempt_question_id', p_question,
      'answered_count', v_answered, 'attempt_state', v_attempt.state,
      'server_now', clock_timestamp(),
      'result_url', case when v_attempt.state <> 'in_progress' then
        '/attempts/' || p_attempt || '/result' else null end);
  end if;
  if v_attempt.state <> 'in_progress' then
    raise exception 'attempt_finished' using errcode = 'P0001';
  end if;
  v_now := clock_timestamp();
  if v_now >= v_attempt.deadline_at then
    return private.testing_finalize(p_attempt) ||
      jsonb_build_object('saved', false, 'result_url',
        '/attempts/' || p_attempt || '/result', 'server_now', clock_timestamp());
  end if;
  select aq.id into v_current from private.attempt_questions aq
  where aq.attempt_id = p_attempt and not exists (
    select 1 from private.attempt_answers aa
    where aa.attempt_question_id = aq.id
  ) order by aq.position limit 1;
  if v_current is distinct from p_question then
    raise exception 'question_out_of_order' using errcode = 'P0001';
  end if;
  select q.question_type into v_type
  from private.attempt_questions aq
  join private.question_versions v on v.id = aq.question_version_id
  join private.questions q on q.id = v.question_id
  where aq.id = p_question;
  if v_type in ('single', 'scenario_single', 'photo_single') and
     cardinality(v_selected) <> 1 then
    raise exception 'invalid_options' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_selected) x(id)
    where not exists (
      select 1 from private.attempt_question_options ao
      where ao.attempt_question_id = p_question and ao.option_id = x.id
    )
  ) then
    raise exception 'invalid_options' using errcode = '22023';
  end if;
  select array_agg(k.option_id order by k.option_id) into v_key
  from private.attempt_questions aq
  join private.answer_keys k on k.question_version_id = aq.question_version_id
  where aq.id = p_question;
  insert into private.attempt_answers (
    attempt_question_id, request_id, answered_at, is_correct
  ) values (p_question, p_request, v_now, v_selected = v_key);
  insert into private.attempt_answer_selections (attempt_question_id, option_id)
  select p_question, x.id from unnest(v_selected) x(id);
  select count(*), count(aa.attempt_question_id) into v_total, v_answered
  from private.attempt_questions aq
  left join private.attempt_answers aa on aa.attempt_question_id = aq.id
  where aq.attempt_id = p_attempt;
  if v_answered = v_total then
    v_result := private.testing_finalize(p_attempt);
    return jsonb_build_object('saved', true, 'already_saved', false,
      'request_id', p_request, 'attempt_question_id', p_question,
      'answered_count', v_answered, 'attempt_state', v_result ->> 'state',
      'server_now', clock_timestamp(),
      'result_url', '/attempts/' || p_attempt || '/result');
  end if;
  return jsonb_build_object('saved', true, 'already_saved', false,
    'request_id', p_request, 'attempt_question_id', p_question,
    'answered_count', v_answered, 'attempt_state', 'in_progress',
    'server_now', clock_timestamp(),
    'next_question_url', '/attempts/' || p_attempt || '/current-question');
end;
$$;

create function public.testing_finish(p_actor uuid, p_attempt uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_attempt private.attempts%rowtype;
begin
  perform private.testing_require_actor(p_actor, 'employee');
  select * into v_attempt from private.attempts
  where id = p_attempt and employee_id = p_actor for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  return private.testing_finalize(p_attempt) ||
    jsonb_build_object('result_url', '/attempts/' || p_attempt || '/result',
                       'server_now', clock_timestamp());
end;
$$;

create function public.testing_result(p_actor uuid, p_attempt uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_attempt private.attempts%rowtype;
  v_result private.attempt_results%rowtype;
  v_role text;
  v_topics jsonb;
  v_recommendations jsonb;
  v_mistakes jsonb;
  v_payload jsonb;
begin
  perform private.testing_require_actor(p_actor);
  select role into v_role from public.user_roles where user_id = p_actor;
  select * into v_attempt from private.attempts where id = p_attempt;
  if not found or (v_attempt.employee_id <> p_actor and v_role <> 'admin') then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_attempt.state = 'in_progress' then
    if clock_timestamp() < v_attempt.deadline_at then
      raise exception 'result_pending' using errcode = 'P0001';
    end if;
    perform private.testing_finalize(p_attempt);
  end if;
  select * into v_result from private.attempt_results where attempt_id = p_attempt;
  if not found then raise exception 'result_pending' using errcode = 'P0001'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'topic', t.title, 'correct_count', tr.correct_count,
    'question_count', tr.question_count, 'percentage', tr.percentage
  ) order by t.display_order), '[]'::jsonb)
  into v_topics from private.attempt_topic_results tr
  join private.topics t on t.slug = tr.topic_slug
  where tr.attempt_id = p_attempt;
  select coalesce(jsonb_agg(jsonb_build_object(
    'topic', t.title, 'encyclopedia_href', t.encyclopedia_href
  ) order by t.display_order), '[]'::jsonb)
  into v_recommendations from private.attempt_topic_results tr
  join private.topics t on t.slug = tr.topic_slug
  where tr.attempt_id = p_attempt and tr.percentage < 80;
  v_payload := jsonb_build_object(
    'attempt_id', p_attempt, 'kind', v_attempt.test_kind,
    'state', (select a.state from private.attempts a where a.id = p_attempt),
    'started_at', v_attempt.started_at,
    'finished_at', (select a.finished_at from private.attempts a
                    where a.id = p_attempt),
    'correct_count', v_result.correct_count,
    'question_count', v_result.question_count,
    'percentage', v_result.percentage,
    'knowledge_level', v_result.knowledge_level,
    'passed', v_result.passed, 'outcome', v_result.outcome,
    'retry_available_at', v_result.retry_available_at,
    'retry_available_moscow',
      private.testing_moscow_label(v_result.retry_available_at),
    'valid_until', v_result.valid_until,
    'valid_until_moscow', private.testing_moscow_label(v_result.valid_until),
    'topics', v_topics, 'recommendations', v_recommendations);

  -- Только владелец завершённого базового теста получает разбор ошибок.
  if v_attempt.test_kind = 'basic' and v_attempt.employee_id = p_actor then
    select coalesce(jsonb_agg(jsonb_build_object(
      'prompt', qv.prompt,
      'options', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', qo.id, 'label', qo.label) order by ao.position),
                   '[]'::jsonb)
                  from private.attempt_question_options ao
                  join private.question_options qo on qo.id = ao.option_id
                  where ao.attempt_question_id = aq.id),
      'selected_option_ids', (select coalesce(jsonb_agg(s.option_id), '[]'::jsonb)
                              from private.attempt_answer_selections s
                              where s.attempt_question_id = aq.id),
      'correct_option_ids', (select coalesce(jsonb_agg(k.option_id), '[]'::jsonb)
                             from private.answer_keys k
                             where k.question_version_id = aq.question_version_id)
    ) order by aq.position), '[]'::jsonb)
    into v_mistakes
    from private.attempt_questions aq
    join private.question_versions qv on qv.id = aq.question_version_id
    left join private.attempt_answers aa on aa.attempt_question_id = aq.id
    where aq.attempt_id = p_attempt and coalesce(aa.is_correct, false) = false;
    v_payload := v_payload || jsonb_build_object('mistakes', v_mistakes);
  end if;
  return v_payload;
end;
$$;

create function public.testing_history(
  p_actor uuid, p_employee uuid default null, p_limit integer default 50,
  p_before_finished timestamptz default null, p_before_id uuid default null
)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_role text;
  v_subject uuid := coalesce(p_employee, p_actor);
  v_expired uuid;
  v_items jsonb;
  v_latest jsonb := '{}'::jsonb;
  v_best jsonb := '{}'::jsonb;
  v_kind text;
  v_row record;
begin
  perform private.testing_require_actor(p_actor);
  select role into v_role from public.user_roles where user_id = p_actor;
  if v_subject <> p_actor and v_role <> 'admin' then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_limit is null or p_limit not between 1 and 100 or
     ((p_before_finished is null) <> (p_before_id is null)) then
    raise exception 'invalid_pagination' using errcode = '22023';
  end if;
  select a.id into v_expired from private.attempts a
  where a.employee_id = v_subject and a.state = 'in_progress'
    and a.deadline_at <= clock_timestamp()
  limit 1 for update;
  if found then perform private.testing_finalize(v_expired); end if;
  select coalesce(jsonb_agg(x.item order by x.finished_at desc, x.id desc),
                  '[]'::jsonb)
  into v_items from (
    select a.id, a.finished_at,
      jsonb_build_object(
        'attempt_id', a.id, 'kind', a.test_kind, 'state', a.state,
        'finished_at', a.finished_at, 'percentage', r.percentage,
        'knowledge_level', r.knowledge_level, 'outcome', r.outcome,
        'topics', case when a.test_kind = 'full' then
          (select coalesce(jsonb_agg(jsonb_build_object(
            'topic', t.title, 'percentage', tr.percentage
          ) order by t.display_order), '[]'::jsonb)
           from private.attempt_topic_results tr
           join private.topics t on t.slug = tr.topic_slug
           where tr.attempt_id = a.id)
          else '[]'::jsonb end
      ) as item
    from private.attempts a
    join private.attempt_results r on r.attempt_id = a.id
    where a.employee_id = v_subject
      and (p_before_finished is null or
           (a.finished_at, a.id) < (p_before_finished, p_before_id))
    order by a.finished_at desc, a.id desc limit p_limit
  ) x;
  foreach v_kind in array array['basic', 'full'] loop
    select a.id, r.percentage, r.outcome, a.finished_at into v_row
    from private.attempts a join private.attempt_results r on r.attempt_id = a.id
    where a.employee_id = v_subject and a.test_kind = v_kind
    order by a.finished_at desc, a.id desc limit 1;
    if found then
      v_latest := v_latest || jsonb_build_object(v_kind,
        jsonb_build_object('attempt_id', v_row.id,
          'percentage', v_row.percentage, 'outcome', v_row.outcome,
          'finished_at', v_row.finished_at));
    end if;
    select a.id, r.percentage, r.outcome, a.finished_at into v_row
    from private.attempts a join private.attempt_results r on r.attempt_id = a.id
    where a.employee_id = v_subject and a.test_kind = v_kind
    order by r.percentage desc, a.finished_at desc, a.id desc limit 1;
    if found then
      v_best := v_best || jsonb_build_object(v_kind,
        jsonb_build_object('attempt_id', v_row.id,
          'percentage', v_row.percentage, 'outcome', v_row.outcome,
          'finished_at', v_row.finished_at));
    end if;
  end loop;
  return jsonb_build_object('items', v_items, 'latest', v_latest,
    'best', v_best, 'server_now', clock_timestamp());
end;
$$;

create function public.testing_grant_retake(
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
     length(coalesce(p_note, '')) > 500 then
    raise exception 'invalid_request' using errcode = '22023';
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
       v_existing.note is distinct from p_note then
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
  ) values (p_employee, p_kind, p_actor, p_request, p_note)
  returning * into v_new;
  return jsonb_build_object('override_id', v_new.id,
    'employee_id', p_employee, 'kind', p_kind,
    'granted_at', v_new.granted_at, 'used_by_attempt_id', null);
end;
$$;

-- Задание Supabase Cron может периодически вызывать эту функцию. Оно не
-- назначается миграцией: расписание и секреты настраиваются отдельно.
create function public.testing_finalize_due(p_limit integer default 100)
returns integer language plpgsql security invoker set search_path = '' as $$
declare v_row record; v_count integer := 0;
begin
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'invalid_limit' using errcode = '22023';
  end if;
  for v_row in
    select a.id from private.attempts a
    where a.state = 'in_progress' and a.deadline_at <= clock_timestamp()
    order by a.deadline_at, a.id limit p_limit for update skip locked
  loop
    perform private.testing_finalize(v_row.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Явные права: создание функций по умолчанию даёт EXECUTE роли PUBLIC.
-- Все вызовы ниже разрешены лишь доверенному серверу.
-- SELECT FOR UPDATE профиля требует UPDATE хотя профиль не изменяется.
-- Выдаём service_role ровно необходимые права независимо от настроек проекта.
grant select on table public.profiles, public.user_roles to service_role;
grant update (access_status) on table public.profiles to service_role;
revoke all on function private.testing_require_actor(uuid, text)
  from public, anon, authenticated;
revoke all on function private.testing_moscow_label(timestamptz)
  from public, anon, authenticated;
revoke all on function private.testing_valid_until(timestamptz, integer)
  from public, anon, authenticated;
revoke all on function private.testing_candidates(text, uuid)
  from public, anon, authenticated;
revoke all on function private.testing_full_plan(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.testing_eligibility(uuid, text, timestamptz)
  from public, anon, authenticated;
revoke all on function private.testing_finalize(uuid)
  from public, anon, authenticated;
revoke all on function public.testing_availability(uuid)
  from public, anon, authenticated;
revoke all on function public.testing_start_or_resume(uuid, text)
  from public, anon, authenticated;
revoke all on function public.testing_current_question(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.testing_submit_answer(uuid, uuid, uuid, uuid, uuid[])
  from public, anon, authenticated;
revoke all on function public.testing_finish(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.testing_result(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.testing_history(uuid, uuid, integer, timestamptz, uuid)
  from public, anon, authenticated;
revoke all on function public.testing_grant_retake(uuid, uuid, text, uuid, text)
  from public, anon, authenticated;
revoke all on function public.testing_finalize_due(integer)
  from public, anon, authenticated;

grant execute on function
  private.testing_require_actor(uuid, text),
  private.testing_moscow_label(timestamptz),
  private.testing_valid_until(timestamptz, integer),
  private.testing_candidates(text, uuid),
  private.testing_full_plan(uuid, uuid),
  private.testing_eligibility(uuid, text, timestamptz),
  private.testing_finalize(uuid),
  public.testing_availability(uuid),
  public.testing_start_or_resume(uuid, text),
  public.testing_current_question(uuid, uuid),
  public.testing_submit_answer(uuid, uuid, uuid, uuid, uuid[]),
  public.testing_finish(uuid, uuid),
  public.testing_result(uuid, uuid),
  public.testing_history(uuid, uuid, integer, timestamptz, uuid),
  public.testing_grant_retake(uuid, uuid, text, uuid, text),
  public.testing_finalize_due(integer)
to service_role;

commit;
