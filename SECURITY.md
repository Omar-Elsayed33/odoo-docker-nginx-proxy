# Security Policy

## Supported versions

This project is in early development. Only the `main` branch and the latest tagged release receive security updates.

| Version    | Supported          |
|------------|--------------------|
| `main`     | :white_check_mark: |
| latest tag | :white_check_mark: |
| older tags | :x:                |

## Reporting a vulnerability

**Please do not open public GitHub issues for security vulnerabilities.** Public disclosure before a fix is available puts every user of this template at risk.

Instead:

1. Email **security@dgtera.com** (or open a [private GitHub security advisory](https://docs.github.com/en/code-security/security-advisories/repository-security-advisories/privately-reporting-a-security-vulnerability)).
2. Include:
   - A clear description of the issue and its impact.
   - Steps to reproduce, or a proof-of-concept.
   - The affected version / commit SHA.
   - Your name and how you'd like to be credited (or "anonymous").
3. You will receive an acknowledgement within **72 hours**.
4. We will work with you on a fix and a coordinated disclosure timeline. Typical target: a patch released within **30 days** for high-severity issues, **90 days** otherwise.

## Scope

In scope:

- The Compose stack and any configuration files in this repository.
- Default configurations that result in insecure deployments (weak defaults, exposed admin endpoints, missing TLS, etc.).
- Documentation that leads users to misconfigure their deployments.
- Backup/restore scripts that could leak data or destroy it.

Out of scope:

- Vulnerabilities in **upstream images** (Odoo, PostgreSQL, PgBouncer, Nginx) — please report those to the upstream projects. We will pin or patch as quickly as upstream allows.
- Issues that require an attacker to already have shell or root on the host.
- Self-inflicted issues from user-supplied custom addons.
- Social engineering or physical attacks.

## Hardening guidance for operators

If you are running this in production, treat the following as a minimum bar:

- **Secrets**: never commit `.env`. Use Docker secrets, a vault, or an env-injection mechanism at deploy time.
- **TLS**: use a real certificate. Disable HTTP except for the ACME challenge path.
- **Database manager**: set `list_db = False` and block `/web/database/*` at the Nginx layer in production.
- **Admin password**: `ODOO_ADMIN_PASSWD` must be a high-entropy random string. Rotate after any team-member departure.
- **Network exposure**: only Nginx should publish ports. Odoo, PgBouncer, and PostgreSQL must remain on the internal Docker network.
- **Backups**: encrypted, off-host, and tested with a real restore at least quarterly.
- **Updates**: subscribe to security advisories for each upstream image. Patch promptly.
- **Monitoring**: log shipment to a remote host so logs survive a compromise.

## Disclosure history

No advisories have been published yet. Resolved advisories will be listed here with CVE IDs where applicable.
