# Row and column policy security checks

Use this section for row-level security, column grants, and policy bypass risk.

## Check: row policies

```sql
SELECT
    name,
    short_name,
    database,
    table,
    select_filter,
    is_restrictive,
    apply_to_all,
    apply_to_list,
    apply_to_except
FROM system.row_policies
ORDER BY database, table, name;
```

Risk signals:

- `TO ALL EXCEPT` excluding admin-like users unexpectedly.
- permissive policies that combine with `OR` and unintentionally broaden access.
- restrictive policies missing for some users.
- database-wide policies that interact unexpectedly with table policies.
- policies using constant `1` for non-admin users.

## Check: users not covered by policies

If row policies exist on a table, evaluate whether users with table `SELECT` are covered by intended policies. Also inspect settings:

```text
access_control_improvements.users_without_row_policies_can_read_rows
access_control_improvements.throw_on_unmatched_row_policies
```

If not visible through SQL, request config.

## Check: bypass by write/copy privileges

Row policies make sense for read-only users. Flag users subject to row policies who also have:

- `INSERT`
- `ALTER`
- `CREATE`
- `DROP`
- partition copy/move permissions
- broad access to create intermediate tables
- source/table function privileges that can export data

## Check: column-level grants and sensitive-column exposure

For workloads with regulated or sensitive data (PII, payment/wallet, credentials, health, gaming integrity), enumerating *who can read which columns* is as important as row policies — and is usually the bigger gap, because the default state is "everyone with table `SELECT` reads every column".

Column-scoped grants populate the `column` field in `system.grants`:

```sql
-- Column-restricted SELECT grants (the intended fine-grained access).
SELECT user_name, role_name, database, table, column, access_type
FROM system.grants
WHERE column IS NOT NULL
ORDER BY database, table, column;
```

```sql
-- Table/database-wide SELECT that bypasses any column intent.
SELECT user_name, role_name, database, table, access_type
FROM system.grants
WHERE access_type = 'SELECT' AND column IS NULL AND table IS NOT NULL
ORDER BY database, table;
```

Risk signals:

- a sensitive table has **no** column grants — every principal with table `SELECT` sees all columns, including PII/secret columns.
- a principal holds table-level or `database.*` `SELECT` where only specific columns were intended (the broad grant silently overrides the fine-grained design).
- a definer view (`04`) re-exposes restricted columns to callers who lack direct column access.
- `SELECT *` patterns in `query_log` against sensitive tables by non-privileged users.

Map the sensitive tables first (with the data owner if needed), then list their readers; do not assume column protection exists because a policy or role looks scoped.
