-- Optional editorial explanation for a specific version of a question.
-- Stored in the closed private schema; no API or permission changes here.
begin;

alter table private.question_versions
  add column if not exists explanation_text text;

commit;
