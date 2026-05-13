# `nginx/certs/` — TLS material

This directory is bind-mounted into the nginx container at
`/etc/nginx/certs/` (read-only). Nginx expects two files:

| File                  | Purpose                                         |
|-----------------------|-------------------------------------------------|
| `fullchain.pem`       | Server cert + intermediate(s), PEM-encoded      |
| `privkey.pem`         | Server private key, PEM-encoded, **never** committed |

Both files are caught by `.gitignore` (`*.pem`, `*.key`). The
directory itself is tracked via `.gitkeep` so the bind mount target
exists at `git clone` time.

> ⚠ Without these files at the expected paths, nginx will fail to
> start. Provision the certs **before** running `docker compose up`.

---

## Local development — self-signed certs

```bash
# Run from the repository root. Generates a cert valid for 365 days
# covering localhost + your dev hostname. Browsers will warn about
# trust — that's expected for self-signed.
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/certs/privkey.pem \
  -out    nginx/certs/fullchain.pem \
  -subj   "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:odoo.local,IP:127.0.0.1"

chmod 600 nginx/certs/privkey.pem
```

Add `127.0.0.1  odoo.local` to your `hosts` file if you want to use
a real hostname locally (recommended — Odoo's cookies are scoped to
the host).

---

## Production — Let's Encrypt

A `certbot` sidecar with auto-renewal is on ROADMAP v0.5. Until then,
provision certs out-of-band and drop them into this directory:

```bash
# On the host where Let's Encrypt was run:
sudo cp /etc/letsencrypt/live/<your-domain>/fullchain.pem \
        /etc/letsencrypt/live/<your-domain>/privkey.pem \
        ./nginx/certs/

# Reload nginx (zero-downtime — running connections drain):
docker compose exec nginx nginx -s reload
```

Renewals require copying the new files in and reloading nginx. The
v0.5 sidecar will automate both steps.

---

## Production — commercial / custom CA

Concatenate your server cert and the issuing intermediate(s) into
`fullchain.pem` (server first, then intermediates, root last —
match the order in your CA's documentation). Drop the matching
private key in `privkey.pem`. Reload nginx as above.

Sanity-check before reloading:

```bash
# Confirm the cert and key match (the moduli must be identical):
openssl x509 -noout -modulus -in nginx/certs/fullchain.pem | openssl md5
openssl rsa  -noout -modulus -in nginx/certs/privkey.pem  | openssl md5

# Inspect what's actually in the chain:
openssl x509 -noout -text -in nginx/certs/fullchain.pem | head -20
```

---

## Rotation

When you rotate:

1. Copy the new files in **alongside** the old ones (different names).
2. Update the paths in `nginx/conf.d/odoo.conf` to point at the new files.
3. `docker compose exec nginx nginx -t` to test.
4. `docker compose exec nginx nginx -s reload`.
5. Delete the old files only after at least one successful reload.

Never overwrite the live files in place — if the new key is bad,
you can't reload without taking nginx down.
