# Task 6 — Logging Layout

## Reverse proxy (Nginx)
- **Where:** bind-mounted to the host at `./logs/nginx/`
  (`access.log` and `error.log`), mapped to `/var/log/nginx` in the container.
- **Format:** structured JSON, one object per request line
  (`json_combined` format defined in `proxy/nginx.conf`).
- **Why:** this is the single public entry point. Bind-mounting means logs
  are readable directly from the host with `cat`/`tail`, without needing
  `docker exec`, and they survive container restarts and rebuilds.

## Backend (Node/Express)
- **Where:** stdout, captured by Docker's own logging driver.
  Viewed with `docker compose logs backend`.
- **Why:** the app already logs its own Sequelize queries and startup
  messages to stdout. This is the standard container logging pattern —
  "log to stdout, let the container platform collect it" — and needs no
  extra volume or code change. It also means log rotation, shipping, and
  retention are the platform's job (or `docker`'s built-in log rotation),
  not something we have to build.

## Database (MySQL)
- **Where:** stdout, default MySQL behavior, viewed with
  `docker compose logs database`.
- Not a deliverable target for this task, listed for completeness.

## Sample log line (proxy, JSON)
    {"time":"2026-09-25T12:40:00+00:00","remote_addr":"172.19.0.1","request":"GET / HTTP/1.1","status":200,"body_bytes_sent":24980,"request_time":0.045,"http_referer":"-","http_user_agent":"curl/8.5.0"}

## Optional forwarder (described, not built)
For a larger deployment, a lightweight log forwarder like Fluent Bit could
tail `./logs/nginx/access.log` and the backend's stdout, and ship both to a
central log store (e.g., CloudWatch Logs on AWS). Not implemented here —
the assignment allows describing this rather than building it, and our
scale (one VM, one app) doesn't need it yet.

## Tested
[TODAY'S DATE] — generated four requests (page, API, static asset, 404),
confirmed all four appear as JSON lines in `logs/nginx/access.log` on the
host, and confirmed the log file persists after `docker compose restart
reverse-proxy`.
