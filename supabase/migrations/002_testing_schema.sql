-- Схема данных тестирования. Применяется после 001_users_and_roles.sql.
-- Таблицы private не должны добавляться в Exposed schemas Supabase Data API.
-- Браузер не получает прямых прав на них. Будущие доверенные серверные операции
-- обязаны проверять active/employee/admin, квоты, сроки и допустимые переходы.
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Настройки версионируются: попытка ссылается на правила своего запуска.
create table private.test_rules (
  id uuid primary key default gen_random_uuid(),
  test_kind text not null check (test_kind in ('basic', 'full')),
  version integer not null check (version > 0),
  question_count integer not null check (question_count > 0),
  duration_seconds integer not null check (duration_seconds > 0),
  pass_count integer not null check (pass_count between 1 and question_count),
  retry_after interval not null check (retry_after > interval '0 seconds'),
  recertification_months integer check (recertification_months > 0),
  created_at timestamptz not null default now(),
  unique (test_kind, version),
  unique (id, test_kind),
  check ((test_kind = 'full') = (recertification_months is not null))
);

create table private.active_test_rules (
  test_kind text primary key check (test_kind in ('basic', 'full')),
  rule_id uuid not null unique,
  foreign key (rule_id, test_kind) references private.test_rules (id, test_kind)
);

create table private.topics (
  slug text primary key,
  title text not null unique,
  display_order smallint not null unique check (display_order > 0),
  -- Относительный адрес главы/галереи из страницы testing/.
  encyclopedia_href text not null check (length(btrim(encyclopedia_href)) > 0)
);

create table private.test_topic_quotas (
  rule_id uuid not null references private.test_rules (id),
  topic_slug text not null references private.topics (slug),
  question_count integer not null check (question_count > 0),
  primary key (rule_id, topic_slug)
);

create table private.test_difficulty_quotas (
  rule_id uuid not null references private.test_rules (id),
  difficulty text not null check (difficulty in ('basic', 'medium', 'hard')),
  question_count integer not null check (question_count > 0),
  primary key (rule_id, difficulty)
);

-- Идентичность вопроса сохраняется при выпуске новых версий. Разрешено только
-- переключать is_active; формулировка, варианты и ключ новой версии добавляются.
create table private.questions (
  id uuid primary key default gen_random_uuid(),
  test_kind text not null check (test_kind in ('basic', 'full')),
  topic_slug text not null references private.topics (slug),
  difficulty text check (difficulty in ('basic', 'medium', 'hard')),
  question_type text not null check (question_type in (
    'single', 'multiple', 'scenario_single', 'scenario_multiple', 'photo_single', 'photo_multiple'
  )),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check ((test_kind = 'full') = (difficulty is not null)),
  unique (id, test_kind)
);

create table private.question_versions (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references private.questions (id),
  version integer not null check (version > 0),
  prompt text not null check (length(btrim(prompt)) > 0),
  source_reference text not null check (length(btrim(source_reference)) > 0),
  created_at timestamptz not null default now(),
  unique (question_id, version),
  unique (id, question_id)
);

create table private.question_photos (
  id uuid primary key default gen_random_uuid(),
  question_version_id uuid not null references private.question_versions (id),
  display_order smallint not null check (display_order > 0),
  storage_path text not null check (length(btrim(storage_path)) > 0),
  caption text,
  unique (question_version_id, display_order)
);

create table private.question_options (
  id uuid primary key default gen_random_uuid(),
  question_version_id uuid not null references private.question_versions (id),
  display_order smallint not null check (display_order > 0),
  label text not null check (length(btrim(label)) > 0),
  unique (question_version_id, display_order),
  unique (id, question_version_id)
);

-- Ключи никогда не выдаются браузеру. Даже для базового разбора их возвращает
-- только отдельная серверная операция после завершения своей попытки.
create table private.answer_keys (
  question_version_id uuid not null,
  option_id uuid not null,
  primary key (question_version_id, option_id),
  foreign key (option_id, question_version_id)
    references private.question_options (id, question_version_id)
);

create table private.attempts (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles (user_id) on delete cascade,
  test_kind text not null check (test_kind in ('basic', 'full')),
  rule_id uuid not null,
  is_reattest boolean not null default false,
  state text not null default 'in_progress'
    check (state in ('in_progress', 'completed', 'timed_out')),
  started_at timestamptz not null default now(),
  deadline_at timestamptz not null,
  finished_at timestamptz,
  foreign key (rule_id, test_kind) references private.test_rules (id, test_kind),
  check (deadline_at > started_at),
  check ((state = 'in_progress') = (finished_at is null)),
  check (finished_at is null or finished_at >= started_at),
  check (test_kind = 'full' or is_reattest = false),
  unique (id, test_kind),
  unique (id, employee_id, test_kind)
);

create unique index one_open_attempt_per_test
  on private.attempts (employee_id, test_kind)
  where state = 'in_progress';
create index attempts_employee_history
  on private.attempts (employee_id, started_at desc);
create index attempts_open_deadline
  on private.attempts (deadline_at) where state = 'in_progress';

-- Порядок и версия фиксируются при старте. Старые версии не удаляются.
create table private.attempt_questions (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references private.attempts (id) on delete cascade,
  position smallint not null check (position > 0),
  question_id uuid not null,
  question_version_id uuid not null,
  topic_slug text not null references private.topics (slug),
  difficulty text check (difficulty in ('basic', 'medium', 'hard')),
  unique (attempt_id, position),
  unique (attempt_id, question_id),
  unique (id, question_version_id),
  foreign key (question_version_id, question_id)
    references private.question_versions (id, question_id)
);

create table private.attempt_question_options (
  attempt_question_id uuid not null,
  question_version_id uuid not null,
  option_id uuid not null,
  position smallint not null check (position > 0),
  primary key (attempt_question_id, option_id),
  unique (attempt_question_id, position),
  foreign key (attempt_question_id, question_version_id)
    references private.attempt_questions (id, question_version_id) on delete cascade,
  foreign key (option_id, question_version_id)
    references private.question_options (id, question_version_id)
);

-- Один подтверждённый ответ на вопрос. request_id помогает серверу вернуть
-- тот же результат при повторной отправке после потери связи.
create table private.attempt_answers (
  attempt_question_id uuid primary key
    references private.attempt_questions (id) on delete cascade,
  request_id uuid not null unique,
  answered_at timestamptz not null default now(),
  is_correct boolean not null
);

create table private.attempt_answer_selections (
  attempt_question_id uuid not null
    references private.attempt_answers (attempt_question_id) on delete cascade,
  option_id uuid not null,
  primary key (attempt_question_id, option_id),
  foreign key (attempt_question_id, option_id)
    references private.attempt_question_options (attempt_question_id, option_id)
);

-- Итог сохраняется один раз. Браузер не записывает процент, статус или сроки.
create table private.attempt_results (
  attempt_id uuid primary key references private.attempts (id) on delete cascade,
  test_kind text not null check (test_kind in ('basic', 'full')),
  correct_count integer not null check (correct_count >= 0),
  question_count integer not null check (question_count > 0),
  percentage numeric(6,3) not null check (percentage between 0 and 100),
  knowledge_level text not null check (knowledge_level in (
    'insufficient', 'basic', 'good', 'excellent'
  )),
  passed boolean not null,
  outcome text not null check (outcome in (
    'basic_passed', 'basic_failed', 'attestation_passed',
    'attestation_failed', 'attestation_not_confirmed'
  )),
  retry_available_at timestamptz,
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  foreign key (attempt_id, test_kind) references private.attempts (id, test_kind),
  check (correct_count <= question_count),
  check (percentage = round(correct_count::numeric * 100 / question_count, 3)),
  check (
    (percentage < 60 and knowledge_level = 'insufficient') or
    (percentage >= 60 and percentage < 80 and knowledge_level = 'basic') or
    (percentage >= 80 and percentage < 90 and knowledge_level = 'good') or
    (percentage >= 90 and knowledge_level = 'excellent')
  ),
  check ((retry_available_at is null) = passed),
  check ((valid_until is not null) = (test_kind = 'full' and passed)),
  check (passed = (outcome in ('basic_passed', 'attestation_passed'))),
  check (
    (test_kind = 'basic' and outcome in ('basic_passed', 'basic_failed')) or
    (test_kind = 'full' and outcome in (
      'attestation_passed', 'attestation_failed', 'attestation_not_confirmed'
    ))
  )
);

create table private.attempt_topic_results (
  attempt_id uuid not null references private.attempt_results (attempt_id) on delete cascade,
  topic_slug text not null references private.topics (slug),
  correct_count integer not null check (correct_count >= 0),
  question_count integer not null check (question_count > 0),
  percentage numeric(6,3) not null check (percentage between 0 and 100),
  primary key (attempt_id, topic_slug),
  check (correct_count <= question_count),
  check (percentage = round(correct_count::numeric * 100 / question_count, 3))
);

-- Административное разрешение действует для будущей попытки и сохраняется
-- как отдельное событие. Использование фиксирует сервер при старте попытки.
create table private.retake_overrides (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles (user_id) on delete cascade,
  test_kind text not null check (test_kind in ('basic', 'full')),
  granted_by uuid not null references public.profiles (user_id),
  granted_at timestamptz not null default now(),
  used_by_attempt_id uuid unique,
  note text,
  foreign key (used_by_attempt_id, employee_id, test_kind)
    references private.attempts (id, employee_id, test_kind)
);
create index retake_overrides_employee
  on private.retake_overrides (employee_id, test_kind, granted_at desc);

-- История, версии вопросов и ключи только дополняются. Удаление истории
-- допускается исключительно в будущей доверенной операции удаления персональных
-- данных с SET LOCAL testing.personal_data_erasure = 'authorized'.
create function private.guard_append_only()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' and
     current_setting('testing.personal_data_erasure', true) = 'authorized' then
    return old;
  end if;
  raise exception 'Historical testing records are immutable';
end;
$$;

create function private.guard_bank_immutable()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'Published testing bank records are immutable';
end;
$$;

create function private.guard_question_identity()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Question identity cannot be deleted';
  end if;
  if (to_jsonb(new) - 'is_active') is distinct from
     (to_jsonb(old) - 'is_active') then
    raise exception 'Only question activity can change; create a new version';
  end if;
  return new;
end;
$$;

create function private.guard_topic_metadata()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' or
     (to_jsonb(new) - 'encyclopedia_href') is distinct from
     (to_jsonb(old) - 'encyclopedia_href') then
    raise exception 'Topic identity cannot change';
  end if;
  return new;
end;
$$;

create function private.guard_retake_override()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if current_setting('testing.personal_data_erasure', true) = 'authorized' then
      return old;
    end if;
    raise exception 'Retake authorization cannot be deleted';
  end if;
  if (to_jsonb(new) - 'used_by_attempt_id') is distinct from
     (to_jsonb(old) - 'used_by_attempt_id') or
     old.used_by_attempt_id is not null or new.used_by_attempt_id is null then
    raise exception 'Retake authorization can only be consumed once';
  end if;
  return new;
end;
$$;

create function private.guard_attempt_state()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if current_setting('testing.personal_data_erasure', true) = 'authorized' then
      return old;
    end if;
    raise exception 'Attempt history cannot be deleted';
  end if;
  if old.state <> 'in_progress' or
     (to_jsonb(new) - 'state' - 'finished_at') is distinct from
     (to_jsonb(old) - 'state' - 'finished_at') or
     new.state not in ('completed', 'timed_out') then
    raise exception 'Only an open attempt can be finalized';
  end if;
  return new;
end;
$$;

create trigger guard_question_identity before update or delete on private.questions
  for each row execute function private.guard_question_identity();
create trigger guard_topic_metadata before update or delete on private.topics
  for each row execute function private.guard_topic_metadata();
create trigger guard_attempt_state before update or delete on private.attempts
  for each row execute function private.guard_attempt_state();
create trigger guard_retake_override before update or delete on private.retake_overrides
  for each row execute function private.guard_retake_override();

create trigger guard_test_rules before update or delete on private.test_rules
  for each row execute function private.guard_bank_immutable();
create trigger guard_topic_quotas before update or delete on private.test_topic_quotas
  for each row execute function private.guard_bank_immutable();
create trigger guard_difficulty_quotas before update or delete on private.test_difficulty_quotas
  for each row execute function private.guard_bank_immutable();
create trigger guard_question_versions before update or delete on private.question_versions
  for each row execute function private.guard_bank_immutable();
create trigger guard_question_photos before update or delete on private.question_photos
  for each row execute function private.guard_bank_immutable();
create trigger guard_question_options before update or delete on private.question_options
  for each row execute function private.guard_bank_immutable();
create trigger guard_answer_keys before update or delete on private.answer_keys
  for each row execute function private.guard_bank_immutable();
create trigger guard_attempt_questions before update or delete on private.attempt_questions
  for each row execute function private.guard_append_only();
create trigger guard_attempt_question_options before update or delete on private.attempt_question_options
  for each row execute function private.guard_append_only();
create trigger guard_attempt_answers before update or delete on private.attempt_answers
  for each row execute function private.guard_append_only();
create trigger guard_answer_selections before update or delete on private.attempt_answer_selections
  for each row execute function private.guard_append_only();
create trigger guard_attempt_results before update or delete on private.attempt_results
  for each row execute function private.guard_append_only();
create trigger guard_topic_results before update or delete on private.attempt_topic_results
  for each row execute function private.guard_append_only();

-- В браузере нет даже SELECT к закрытым таблицам, поэтому ключи и ответы
-- полной аттестации не могут уйти через обычные запросы Data API.
alter table private.test_rules enable row level security;
alter table private.active_test_rules enable row level security;
alter table private.topics enable row level security;
alter table private.test_topic_quotas enable row level security;
alter table private.test_difficulty_quotas enable row level security;
alter table private.questions enable row level security;
alter table private.question_versions enable row level security;
alter table private.question_photos enable row level security;
alter table private.question_options enable row level security;
alter table private.answer_keys enable row level security;
alter table private.attempts enable row level security;
alter table private.attempt_questions enable row level security;
alter table private.attempt_question_options enable row level security;
alter table private.attempt_answers enable row level security;
alter table private.attempt_answer_selections enable row level security;
alter table private.attempt_results enable row level security;
alter table private.attempt_topic_results enable row level security;
alter table private.retake_overrides enable row level security;

revoke all on table
  private.test_rules, private.active_test_rules, private.topics,
  private.test_topic_quotas, private.test_difficulty_quotas,
  private.questions, private.question_versions, private.question_photos,
  private.question_options, private.answer_keys, private.attempts,
  private.attempt_questions, private.attempt_question_options,
  private.attempt_answers, private.attempt_answer_selections,
  private.attempt_results, private.attempt_topic_results, private.retake_overrides
from public, anon, authenticated;
revoke all on function private.guard_append_only() from public, anon, authenticated;
revoke all on function private.guard_bank_immutable() from public, anon, authenticated;
revoke all on function private.guard_question_identity() from public, anon, authenticated;
revoke all on function private.guard_topic_metadata() from public, anon, authenticated;
revoke all on function private.guard_retake_override() from public, anon, authenticated;
revoke all on function private.guard_attempt_state() from public, anon, authenticated;

-- Доверенный сервер может работать с private через прямое соединение или
-- будущие узкие RPC. service_role никогда не размещается в браузере.
grant usage on schema private to service_role;
grant select, insert, update, delete on table
  private.test_rules, private.active_test_rules, private.topics,
  private.test_topic_quotas, private.test_difficulty_quotas,
  private.questions, private.question_versions, private.question_photos,
  private.question_options, private.answer_keys, private.attempts,
  private.attempt_questions, private.attempt_question_options,
  private.attempt_answers, private.attempt_answer_selections,
  private.attempt_results, private.attempt_topic_results, private.retake_overrides
to service_role;

insert into private.test_rules (
  test_kind, version, question_count, duration_seconds, pass_count,
  retry_after, recertification_months
) values
  ('basic', 1, 20, 1500, 16, interval '24 hours', null),
  ('full', 1, 50, 4500, 45, interval '7 days', 3);

insert into private.active_test_rules (test_kind, rule_id)
select test_kind, id from private.test_rules where version = 1;

insert into private.topics (slug, title, display_order, encyclopedia_href) values
  ('content_standards', 'Стандарты работы с контентом', 1, '../index.html#chapter-1'),
  ('item_relevance', 'Актуальность вещей', 2, '../index.html#chapter-4'),
  ('outfits', 'Гармоничные образы', 3, '../index.html#chapter-5'),
  ('flat_lays', 'Раскладки', 4, '../index.html#chapter-6'),
  ('color', 'Цвет', 5, '../index.html#chapter-4'),
  ('announcement', 'Анонс', 6, '../index.html#chapter-7'),
  ('seller_with_items', 'Продавец с вещами', 7, '../index.html#seller-photo-gallery'),
  ('photo_backdrop', 'Фото на фотофоне', 8, '../index.html#photo-background-gallery'),
  ('shoes', 'Фото обуви', 9, '../index.html#shoe-photo-gallery');

insert into private.test_topic_quotas (rule_id, topic_slug, question_count)
select r.id, q.topic_slug, q.question_count
from private.test_rules r
cross join (values
  ('content_standards', 9), ('item_relevance', 9), ('outfits', 6),
  ('flat_lays', 6), ('color', 4), ('announcement', 7),
  ('seller_with_items', 3), ('photo_backdrop', 3), ('shoes', 3)
) as q(topic_slug, question_count)
where r.test_kind = 'full' and r.version = 1;

insert into private.test_difficulty_quotas (rule_id, difficulty, question_count)
select r.id, q.difficulty, q.question_count
from private.test_rules r
cross join (values ('basic', 15), ('medium', 25), ('hard', 10))
  as q(difficulty, question_count)
where r.test_kind = 'full' and r.version = 1;

-- Обязательства будущего серверного слоя:
-- * подбор 20/50 вопросов и совместное соблюдение квот темы/сложности;
-- * проверка полноты активного банка до запуска, предпочтение новых вопросов;
-- * получение времени из БД, завершение по deadline_at и по последнему ответу;
-- * точное сравнение множества вариантов с answer_keys и идемпотентность;
-- * расчёт 24 часов / 7 суток от finished_at и 3 календарных месяцев в
--   Europe/Moscow с ограничением дня последним днём целевого месяца;
-- * выдача только текущего вопроса, итогов по темам и допустимого базового
--   разбора после завершения; проверка роли и активного профиля на каждом вызове.
commit;
