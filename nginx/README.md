# Nginx reverse proxy

The nginx layer is the public entry point for the stack. It terminates
TLS, upgrades websockets for Odoo's longpolling/bus, applies security
headers, compresses responses, and reverse-proxies to the Odoo
application container on the private Docker network.

```
                            ┌─────────────────┐
   client (browser, API) ──►│   nginx :80     │── 301 ──┐
                            │                 │         │
                            │   nginx :443    │◄────────┘
                            └────────┬────────┘
                                     │  proxy_pass
                       ┌─────────────┴─────────────┐
                       │                           │
                ┌──────▼──────┐             ┌──────▼──────┐
                │ odoo :8069  │             │ odoo :8072  │
                │  (HTTP)     │             │ (longpoll/  │
                │             │             │  websocket) │
                └─────────────┘             └─────────────┘
```

After this layer lands, Odoo's host ports (`8069`, `8072`) are no
longer published — nginx is the only thing the host exposes
(`80`, `443`).

## File structure

```
nginx/
├── conf.d/
│   └── odoo.conf              # The vhost: upstreams, server blocks, locations
├── templates/
│   ├── proxy-params.conf      # X-Forwarded-* headers, buffering, timeouts
│   ├── ssl-params.conf        # TLS protocols, ciphers, session config
│   ├── security-headers.conf  # HSTS, X-Frame-Options, Referrer-Policy, ...
│   └── gzip.conf              # Compression on/off + types
├── certs/
│   ├── README.md              # How to provision TLS certs
│   ├── .gitkeep
│   ├── fullchain.pem          # (gitignored) chain
│   └── privkey.pem            # (gitignored) private key
└── README.md                  # ← this file
```

### Why `conf.d/` *and* `templates/`?

- **`conf.d/`** holds vhosts. Nginx auto-includes `/etc/nginx/conf.d/*.conf`
  from the default `nginx.conf`, so dropping a new file here is enough
  to add a new site.
- **`templates/`** holds **reusable snippets** that are explicitly
  `include`d by vhosts. They are *not* `*.template` envsubst files —
  they're plain nginx config fragments. Splitting concerns this way
  means a second vhost (e.g. for a status page, a dev/staging mirror,
  or a second Odoo instance) reuses the same TLS, security, and proxy
  rules without copy-paste.

If you later want envsubst-style runtime templating, rename a file to
`foo.conf.template` and put it in `templates/`. The stock
`nginx:alpine` image entrypoint will substitute `${VAR}` references
and drop the result in `/etc/nginx/conf.d/foo.conf` at container
startup.

## Request flow

1. Client connects to `:80` or `:443`.
2. **Port 80 server block** — answers `/.well-known/acme-challenge/`
   for cert renewal, serves `/nginx-health` for the container's
   healthcheck, and 301-redirects everything else to HTTPS.
3. **Port 443 server block** — terminates TLS using the certs in
   `nginx/certs/`, applies all four snippet bundles, then routes:
   - `/websocket` → Odoo longpolling upstream with HTTP/1.1 + Upgrade
     (60-minute read timeout so the websocket stays alive).
   - `/longpolling/` → same upstream, kept for Odoo ≤ 15 compatibility.
   - `/web/static/`, `/web/content/`, `/web/image/` → Odoo HTTP
     upstream, with proxy caching (60 min) and a 10-day `Cache-Control`.
   - Everything else → Odoo HTTP upstream.

## Setup

### 1. Provision TLS certs

See [`certs/README.md`](certs/README.md). For local dev, the
self-signed `openssl` one-liner is sufficient. Without certs, nginx
will fail to start.

### 2. Set your domain (optional)

In `conf.d/odoo.conf`, the `server_name` is `_` (catch-all). For a
production deployment, replace it with your real domain so nginx
won't accidentally answer for hostnames you don't own:

```nginx
server_name odoo.example.com;
```

The `DOMAIN` value in `.env` is informational for now; it gets used
by the ACME sidecar that lands in v0.5.

### 3. Bring the stack up

```bash
cp .env.example .env  # if you haven't already
# Edit .env (see top-level README)
docker compose up -d
```

Verify:

```bash
docker compose ps                 # nginx + odoo + db all "healthy"
curl -fsS http://localhost/nginx-health
curl -fsSk https://localhost/web/health    # -k for self-signed
```

## Customisation

### Domain

Edit `conf.d/odoo.conf` → `server_name`.

### Upload size

Edit `conf.d/odoo.conf` → `client_max_body_size`. Default is `200M`.

### Rate limiting

The zones are already defined in `conf.d/odoo.conf` but not yet
enforced (enforcement is v0.4 hardening). To turn them on now, add
inside the relevant `location` block:

```nginx
location /web/login {
    limit_req zone=odoo_login burst=10 nodelay;
    proxy_pass http://odoo_http;
}
```

### Adding a second vhost

Drop a new file in `conf.d/`:

```nginx
# nginx/conf.d/status.conf
server {
    listen 443 ssl;
    server_name status.example.com;
    ssl_certificate     /etc/nginx/certs/status-fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/status-privkey.pem;
    include /etc/nginx/templates/ssl-params.conf;
    include /etc/nginx/templates/security-headers.conf;
    # ...
}
```

Both vhosts share the snippets in `templates/` — change a default
once, applies everywhere.

### Horizontal Odoo scaling

In `conf.d/odoo.conf`, add to the upstream:

```nginx
upstream odoo_http {
    server odoo-1:8069;
    server odoo-2:8069;
    keepalive 32;
    # Optional: session affinity — Odoo workers don't share sessions
    # across processes by default; sticky-by-IP is the cheap fix.
    # hash $remote_addr consistent;
}
```

You'll also need to add the second Odoo service to
`docker-compose.yml` and point both at the same Postgres / filestore.

## Operations

### Test config before reloading

```bash
docker compose exec nginx nginx -t
```

Catches syntax errors and bad upstreams without taking the running
process down.

### Zero-downtime reload

```bash
docker compose exec nginx nginx -s reload
```

Running connections drain on the old worker processes; new
connections go to workers loading the updated config. Use this after
editing any file under `nginx/` — Compose volume mounts mean the new
content is already inside the container.

### Logs

```bash
docker compose logs -f nginx
# Or directly:
docker compose exec nginx tail -f /var/log/nginx/odoo.access.log
docker compose exec nginx tail -f /var/log/nginx/odoo.error.log
```

## Common pitfalls

| Symptom                                          | Cause                                                              |
|--------------------------------------------------|--------------------------------------------------------------------|
| Nginx won't start, `cannot load certificate`     | Missing `certs/fullchain.pem` or `certs/privkey.pem`               |
| "Disconnected" banner in Odoo chat               | `/websocket` location missing or Upgrade headers not forwarded     |
| Wrong scheme in Odoo-generated URLs (`http://`)  | `proxy_mode = False` in `odoo.conf` (must be `True` behind nginx)  |
| Browser blocks form submission cross-origin      | `Cross-Origin-*` headers in `security-headers.conf` too strict     |
| 413 on file upload                               | `client_max_body_size` smaller than the file                       |
| Login spam not throttled                         | Rate-limit zones defined but `limit_req` not yet applied (v0.4)    |
