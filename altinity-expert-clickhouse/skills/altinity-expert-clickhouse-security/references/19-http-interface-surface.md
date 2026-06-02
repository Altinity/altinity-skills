# HTTP interface surface

Use this section for the HTTP/HTTPS interface beyond raw port exposure (covered in `05-network-exposure-and-tls.md`). The HTTP interface is the most commonly internet-exposed ClickHouse surface and has its own attack-relevant configuration.

## Check: HTTP-related server settings

```sql
SELECT
    name,
    value,
    changed
FROM system.server_settings
WHERE name IN
(
    'http_port',
    'https_port',
    'http_server_default_response',
    'enable_http_compression',
    'http_max_request_param_data_size',
    'keep_alive_timeout'
)
ORDER BY name;
```

Most handler and CORS configuration is config-only; request `config.xml`/`config.d` when the SQL view is insufficient.

## Check: custom HTTP handlers

`http_handlers` in config can expose predefined or **dynamic** query handlers at custom URL paths. A `dynamic_query_handler` lets a caller submit arbitrary SQL over HTTP; a `predefined_query_handler` pins specific queries.

Risk signals:

- `dynamic_query_handler` reachable without authentication or from untrusted networks.
- handlers that run queries as a fixed privileged user regardless of caller identity.
- predefined handlers embedding credentials or sensitive parameters.

## Check: Play UI and default credentials over HTTP

Risk signals:

- the Play UI (`/play`) reachable from untrusted networks, especially with a usable `default` user that has no password (see `02-identity-authentication.md`).
- HTTP basic-auth or URL-parameter credentials (`?user=&password=`) usable from broad networks — these appear in proxy/access logs.
- plaintext `http_port` exposed externally while `https_port` is the intended entry point (cross-reference `05`).

## Check: CORS and cross-origin exposure

If a browser-facing deployment sets permissive CORS (`Access-Control-Allow-Origin: *`) via handler config or a proxy, any origin can drive authenticated requests if credentials are present. Confirm from config or the fronting proxy; mark as not verifiable from SQL if neither is available.

Treat the HTTP surface as a distinct entry point: beyond TLS, `http_handlers` (especially `dynamic_query_handler`), the Play UI, and CORS are config-level and largely not SQL-verifiable.
