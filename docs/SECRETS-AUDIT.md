# Secrets Audit — Phase 1

Scope: full git history (`--all`) of all 11 existing IDP repos, scanned with `gitleaks` + `trufflehog`, plus a manual grep sweep for patterns the scanners' rulesets might miss. `IDP-StrategyManager` is not yet a git repo and will be scanned once initialized in Phase 5.

Date: 2026-10-27.

## Confirmed findings

### 1. IDP-Engine — real OpenAI API key committed in tracked properties files
- Files: `src/main/resources/application.properties` (commit `3b0bb9c`, 2025-06-22), `src/main/resources/application-prod.properties` (commit `9412ece`, 2025-09-30), and multiple commits in between.
- A real `sk-proj-...` OpenAI key was hardcoded directly (not in the gitignored `secrets.properties`) for several months before being replaced with the `${OPENAI_API_KEY:dummy}` placeholder pattern now in the working tree.
- **trufflehog confirmed this key is still verified-live against OpenAI's API as of this audit.**
- Classification: real secret, requires full git-history rewrite. Rotation is being handled separately by the repo owner, outside this audit's scope.

### 2. IDP-WebSearch — real-looking Serper API key committed in tracked properties files
- Files: `src/main/resources/application.properties` (commits `cb9663b`, `2492a3d`), `src/main/resources/application-prod.properties` (commit `e01d3a9`).
- A `serper.api.key` value (`1c65835067df71bc32f841ad650953f814ef4f8b`) was hardcoded directly, later replaced with `${SERPER_API_KEY:dummy}`.
- Serper isn't a detector trufflehog recognizes natively, so live/dead status wasn't independently verified by this audit — treat as a real secret regardless.
- Classification: real secret, requires full git-history rewrite.

### 3. IDP-Tools — hardcoded MySQL credentials (placeholder-style, never swapped out)
- File: `Docker/mysql/docker-compose.yml`, present since "Initial commit."
- `MYSQL_ROOT_PASSWORD: rootpassword` and `MYSQL_PASSWORD: db_password`, both with inline comments reading "Replace with a strong password" — i.e. these are template placeholders the owner never customized, not a credential that was ever live anywhere else.
- Classification: not a real-world credential exposure, but still bad practice to ship a literal password in a compose file others might deploy as-is. Requires forward-fix (env-var substitution, matching the pattern every other repo uses) + full history rewrite, per the repo owner's explicit decision to hold this to the same bar as a real secret.
- Also 3 local commits sitting unpushed to `origin/main` — rewrite before pushing.

## Reviewed and classified as no action needed

### IDP-Website — JWT-looking string in `backend-README.md`
- gitleaks flagged `"token": "eyJhbGciOiJIUzI1NiIs..."` as a `generic-api-key` match.
- Inspected: it's a truncated example value in API documentation illustrating a sample response shape (ends in literal `...`), not a real token.
- Classification: false positive. No action.

### IDP-Frontend — committed-then-deleted `.env` files
- `frontend/.env`, `frontend/.env.development`, `frontend/.env.production` (commits `d9185ec`, `6e1a94e`, `ee8900a`).
- Inspected: contents are only `REACT_APP_API_BASE_URL` (a URL, e.g. `http://localhost:8080/api`), no credentials of any kind.
- Classification: deliberately left as-is per the repo owner's decision. Already pushed to a currently-private repo; rewriting history for a URL-only exposure isn't worth the cost (force-push, any existing clones diverge). If IDP-Frontend is later folded into public release scope, re-run this audit against it at that time.

### IDP-Tools — vendored upstream Superset `.env` (now deleted)
- `Docker/superset/docker/.env`, added in commit `e22a286`, no longer present in the current working tree (superseded by `Docker/superset2/`).
- Inspected: this is the stock development `.env` shipped by the upstream Apache Superset project itself (Apache license header, generic dev defaults like `SUPERSET_SECRET_KEY=TEST_NON_DEV_SECRET`, `DATABASE_PASSWORD=superset`) — not anything specific to this program, and not a real secret.
- Classification: false positive / vendored boilerplate. No action. (Separately confirms the `Docker/superset` → `Docker/superset2` path rename already noted as a doc fix in the program `CLAUDE.md`.)

## Clean repos (no findings of any kind)

IDP-GeneralMCPServer, IDP-YahooFinanceInfoServer, IDP-yFinance-Proxy, IDP-StockApiClient, IDP-MCP-Enhancer, IDP-Centralised-Logging — scanned via gitleaks + trufflehog + manual grep sweep, nothing found.

## Remediation complete (Phase 1.3 and 1.4)

- [x] Forward-fix + full `git-filter-repo` history rewrite on `IDP-Tools/Docker/mysql/docker-compose.yml`, then force-pushed. New history tip: `fdd6419`.
- [x] Forward-fix (already done) + full history rewrite on `IDP-Engine`'s two properties files (`sk-proj-...` key replaced with `REDACTED-OPENAI-KEY` across all 117 commits), force-pushed. New history tip: `0689066`.
- [x] Forward-fix (already done) + full history rewrite on `IDP-WebSearch`'s two properties files (Serper key replaced with `REDACTED-SERPER-KEY` across all 12 commits), force-pushed. New history tip: `ef33b33`.
- [x] Re-ran gitleaks + trufflehog (`--only-verified`) on all three post-rewrite and post-push: no leaks, zero verified secrets, in any of them. Confirmed 2026-10-28.
- [ ] Scan `IDP-StrategyManager` once git-initialized in Phase 5.

Mirror backups of each repo's pre-rewrite state were made before each rewrite and remain in the session scratchpad, in case anything needs to be recovered.

Key rotation (OpenAI, Serper) is being handled separately by the repo owner — out of scope for this audit.
