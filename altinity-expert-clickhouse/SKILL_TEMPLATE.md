# SKILL.md template for `altinity-expert-clickhouse-*` skills

Every diagnostic skill follows the same shape so that a model of any size can
execute it the same way every time. Keep SKILL.md under ~90 lines; put
background material (settings tables, sizing guides, best practices) in
`reference.md` next to it, loaded only on demand.

Design rules, in priority order:

1. **The SQL does the judging.** Every check that can be graded returns a
   `severity` column with one of `Critical`, `Major`, `Moderate`, `Minor`, `OK`.
   The model copies the verdict, it does not invent one.
2. **One statement at a time.** Packs are split on `;`; each statement carries a
   `-- @check <id> <title>` header and, when needed, `-- @requires ...`.
   Never run a whole file with `--queries-file`/`--multiquery`: one failing
   statement would cancel the rest.
3. **Declare optional dependencies.** `-- @requires table:system.part_log`,
   `-- @requires keeper`, `-- @requires version>=26.8`, `-- @requires version<26.8`.
   Alternatives for the same check use the same id with complementary version
   requirements.
4. **No prose that is not an instruction or an interpretation rule.** Generic
   ClickHouse knowledge belongs in `reference.md` or nowhere.
5. **Fenced SQL in SKILL.md is always one complete, runnable statement.** Never
   fragments like `limit 100`. Template variables other than `{cluster}` are
   written as `{name}` and the placeholder rule below applies.
6. **Routing is an explicit tool call**: "Next: load skill
   `altinity-expert-clickhouse-<name>`".

## Template

```markdown
---
name: altinity-expert-clickhouse-<name>
description: <what it diagnoses>. Use when <symptoms / user phrasing>.
license: Apache-2.0
---

# <Title>

<One or two sentences: what this skill answers and from which system tables.>
Run `altinity-expert-clickhouse-connection` first if the connection mode,
cluster and time window are not yet established.

## Query packs

- `checks.sql` — <N> checks: <one-line summary of what they cover>.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

<Skill-specific, non-obvious rules mapping observations to conclusions. Bullets. This is the only place for domain knowledge.>

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- <condition> → load skill `altinity-expert-clickhouse-<name>`
```

## Statement header convention (query packs)

```sql
-- @check merges-04 Merge success/failure trend by hour (24h)
-- @requires table:system.part_log
SELECT ... ;
```

- `id`: `<skill-short>-<NN>` for `checks.sql`, `<skill-short>-<file>-<NN>` for
  other packs, or the Altinity check id when the SQL emits one (`'A3.0.5' AS id`).
- `tests/sql-matrix/annotate_packs.py --skills skills` adds missing headers;
  `tests/sql-matrix/sql_matrix.py` runs every statement against a ClickHouse
  version matrix and fails on any error that is not covered by `@requires`.
