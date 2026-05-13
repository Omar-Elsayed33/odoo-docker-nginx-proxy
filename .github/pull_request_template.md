<!-- markdownlint-disable MD041 -->
<!--
PR templates conventionally don't begin with a top-level heading
(the PR title is the H1). MD041 is suppressed for this file only.

Thanks for the contribution. The sections below mirror what reviewers
look for. Delete anything that doesn't apply — empty sections are
worse than absent ones.
-->

## Summary

<!-- 1–3 sentences describing the change and the motivation behind it. -->

## Type of change

<!-- Tick what applies. Drives the Conventional Commits prefix. -->

- [ ] `feat` — new functionality
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `chore` — tooling / deps / refactor with no behaviour change
- [ ] `security` — security fix or hardening
- [ ] `perf` — performance improvement

## What changed

<!--
Bulleted list of meaningful changes. The diff already describes WHAT;
this list describes WHY each item is there.
-->

-

## What's out of scope

<!--
Anything you considered but deliberately didn't include, and why.
Empty is fine — but if you cut a tempting follow-up, naming it here
prevents reviewers from asking about it.
-->

## Test plan

<!-- Tick the boxes you actually ran. CI will verify the first two. -->

- [ ] `docker compose -f docker-compose.yml config --quiet` passes
- [ ] `docker compose -f docker-compose.yml -f docker-compose.prod.yml config --quiet` passes
- [ ] `./scripts/install.sh && ./scripts/start.sh` brings the stack up clean from a fresh `.env.example`
- [ ] Any new or modified shell scripts pass `shellcheck`
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]`
- [ ] No secrets, real domain names, or production data in the diff
- [ ] Documentation updated for any new env vars, scripts, or behaviour

## Notes for reviewers

<!--
Anything subtle, anything you tested manually, anything you want
extra eyes on. PRs that touch the request path (nginx vhost, Odoo
workers, PgBouncer pool config) should include a paragraph here
about what was tested manually — `compose config` validation is
necessary but not sufficient.
-->
