-- Return the full review only to the employee who owns a finished basic attempt.
-- Requires 004_testing_functions.sql and 005_question_explanations.sql.
begin;

create or replace function public.testing_result(p_actor uuid, p_attempt uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_attempt private.attempts%rowtype;
  v_result private.attempt_results%rowtype;
  v_role text;
  v_topics jsonb;
  v_recommendations jsonb;
  v_review jsonb;
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
    select * into v_attempt from private.attempts where id = p_attempt;
  end if;
  if v_attempt.state not in ('completed', 'timed_out') then
    raise exception 'result_pending' using errcode = 'P0001';
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
    'state', v_attempt.state,
    'started_at', v_attempt.started_at,
    'finished_at', v_attempt.finished_at,
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

  -- Never return review data for full attestation or an administrative request.
  if v_attempt.test_kind = 'basic'
     and v_attempt.employee_id = p_actor and v_role = 'employee' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'position', aq.position,
      'prompt', qv.prompt,
      'options', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', qo.id, 'label', qo.label) order by ao.position),
                   '[]'::jsonb)
                  from private.attempt_question_options ao
                  join private.question_options qo on qo.id = ao.option_id
                  where ao.attempt_question_id = aq.id),
      'answered', aa.attempt_question_id is not null,
      'selected_option_ids', (select coalesce(jsonb_agg(s.option_id), '[]'::jsonb)
                              from private.attempt_answer_selections s
                              where s.attempt_question_id = aq.id),
      'correct_option_ids', (select coalesce(jsonb_agg(k.option_id), '[]'::jsonb)
                             from private.answer_keys k
                             where k.question_version_id = aq.question_version_id),
      'explanation_text', qv.explanation_text
    ) order by aq.position), '[]'::jsonb)
    into v_review
    from private.attempt_questions aq
    join private.question_versions qv on qv.id = aq.question_version_id
    left join private.attempt_answers aa on aa.attempt_question_id = aq.id
    where aq.attempt_id = p_attempt;
    v_payload := v_payload || jsonb_build_object('review', v_review);
  end if;
  return v_payload;
end;
$$;

-- CREATE OR REPLACE retains existing function grants; restate the intended ACL.
revoke all on function public.testing_result(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.testing_result(uuid, uuid) to service_role;

commit;
