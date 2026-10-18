-- Дополнение к 002_testing_schema.sql: идемпотентность и единственное
-- неиспользованное разрешение пересдачи на сотрудника и вид теста.
-- Существующие разрешения и история их использования сохраняются.
begin;

-- Проверка и изменение выполняются под одной блокировкой: между ними нельзя
-- добавить ещё одно неиспользованное разрешение.
lock table private.retake_overrides in access exclusive mode;

do $$
begin
  if exists (
    select 1
    from private.retake_overrides
    where used_by_attempt_id is null
    group by employee_id, test_kind
    having count(*) > 1
  ) then
    raise exception
      'Duplicate unused retake overrides exist; resolve them before applying 003';
  end if;
end;
$$;

-- ADD COLUMN с volatile DEFAULT присваивает отдельный UUID каждой старой
-- строке без обычного UPDATE, который запрещён защитным триггером из 002.
-- Затем DEFAULT снимается: будущий сервер обязан передать request_id запроса.
alter table private.retake_overrides
  add column request_id uuid not null default gen_random_uuid();

alter table private.retake_overrides
  alter column request_id drop default;

alter table private.retake_overrides
  add constraint retake_overrides_request_id_key unique (request_id);

-- Использованные строки не входят в индекс и остаются в истории в любом числе.
create unique index one_unused_retake_override
  on private.retake_overrides (employee_id, test_kind)
  where used_by_attempt_id is null;

-- Однократное потребление уже защищено миграцией 002:
-- guard_retake_override разрешает только переход used_by_attempt_id NULL -> UUID;
-- UNIQUE на used_by_attempt_id не даёт использовать одну попытку дважды;
-- составной FK проверяет совпадение сотрудника и вида теста с попыткой.
-- Сервер должен в одной транзакции создать попытку и заполнить это поле.
commit;
