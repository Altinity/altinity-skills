# Executable UDFs and server-side code execution

Use this section to assess the capability for command execution on the server, not just observed usage. File `11-query-log-threat-hunting.md` detects past use of executable UDFs; this section assesses whether the capability exists and who can reach it.

## Why this matters

Executable user-defined functions run an external command or script on the ClickHouse server for each invocation. They are effectively a controlled remote-code-execution surface: the command runs as the ClickHouse server OS user. A misconfigured or over-granted executable UDF is typically the highest-severity finding on a node.

## Check: configured executable UDFs

Executable UDFs are defined in configuration (`user_defined_executable_functions_config`, usually `*_function.xml`), not in SQL DDL. Request that config and inventory each function's `command`, `type` (`executable` / `executable_pool`), and input/output format.

If available, list registered functions and their origin:

```sql
SELECT
    name,
    origin,
    create_query
FROM system.functions
WHERE origin != 'System'
ORDER BY origin, name;
```

`origin = 'ExecutableUserDefinedFunction'` (or similar non-`SQLUserDefinedFunction`/non-`System` origin) indicates an executable UDF backed by a server-side command.

## Risk signals

- Any executable UDF whose `command` invokes a shell, interpreter, or script that accepts attacker-influenced input.
- Executable UDFs reachable by application/BI users (any user who can call the function name in a query can trigger the command).
- `command` paths writable by non-root users (command could be replaced).
- `execute_direct = false` / shell-wrapped commands that allow argument injection.
- SQL UDFs (`CREATE FUNCTION`) that wrap or expose executable UDFs to broader roles.

## Check: who can create UDFs

```sql
-- search SHOW ACCESS for:
```

```text
CREATE FUNCTION
DROP FUNCTION
```

`CREATE FUNCTION` grants SQL UDF creation. Executable UDFs themselves come from config, but creation/replacement grants still matter for the SQL-level wrappers.

The capability is the finding: an executable UDF runs a server-side command as the ClickHouse OS user, and any principal that can call the function triggers it. Treat it as a code-execution surface, not a query feature; confirm the command and restrict the function to trusted roles.
