# IDP Public Release: Docker Compose Deploy + Strategy Manager Integration

## Context

The IDP program (QuantView) is 12 sibling repos today — 11 documented in the program `CLAUDE.md`, plus a 12th, `IDP-StrategyManager`, which exists on disk but isn't tracked in git or mentioned in that file. Howard wants to release this program publicly on GitHub as a showcase, but wants it private until the cleanup below is actually done. Three things are driving this plan:

1. **A real deploy story doesn't exist yet.** Only 2 of 12 repos have a Dockerfile, and only pieces of infra (ELK, parts of IDP-Tools) have compose files. Howard wants a single `docker-compose.yml` where the only things a deployer supplies are two secrets (`OPENAI_API_KEY`, `SERPER_API_KEY`) — everything else (DB creds, service networking) is internal to Docker's network and pre-wired.
2. **Secrets hygiene has to be bulletproof before anything goes public**, even though it stays private for now. Research already found one confirmed hardcoded-plaintext-password commit in `IDP-Tools` sitting unpushed — that needs a full history rewrite, not just a forward-fix, per Howard's explicit decision.
3. **IDP-StrategyManager needs to become the real control-plane app it was designed to be.** It already has a CRUD UI for authoring strategies that deliberately mirrors IDP-Engine's data shapes, plus "Reporting" and "Execution" nav items stubbed as "Coming soon." Today none of that is wired up — IDP-Engine doesn't know StrategyManager exists. Howard wants StrategyManager promoted to the central place to trigger executions, edit/manage strategies, and link to Superset reports — with IDP-Engine switched over to read strategies from StrategyManager instead of its own classpath files (hard cutover, no fallback, per Howard's decision).

Intended outcome: a new top-level `IDP` repo (currently not a git repo) holding a `docker-compose.yml`, a README with an architecture diagram, and git-submodule references to the (by-then-cleaned) subproject repos — everything privately committed and runnable end-to-end via `docker compose up`, with the public flip to be a separate future decision.

## Key decisions already made (do not re-derive)

- **Compose scope**: core runtime (IDP-Engine, IDP-GeneralMCPServer, IDP-YahooFinanceInfoServer, IDP-WebSearch, IDP-yFinance-Proxy, MySQL) + IDP-StrategyManager + Superset (reporting) + full ELK stack (IDP-Centralised-Logging). IDP-Website and IDP-Frontend are out of the running stack (still included as submodules of the new top-level repo for program completeness, clearly marked as not part of the deploy).
- **Shape**: one `docker-compose.yml`, each service keeps its own Dockerfile, one internal Docker network, exactly 2 user-supplied runtime secrets: `OPENAI_API_KEY`, `SERPER_API_KEY`.
- **LLM provider**: stays OpenAI. No Anthropic/Claude wiring is added — IDP-Engine today uses `spring-ai-starter-model-openai`, property `spring.ai.openai.api-key`, model `gpt-5-mini`. "Claude API key" in the original ask was shorthand; `OPENAI_API_KEY` is the real secret.
- **New top-level repo**: `git init` at `~/CODE/IDP` itself. Subprojects are **git submodules**, not merged into a monorepo. (Each of the 12 repos stays independent, with its own history/remote/push workflow — the new repo only holds commit-SHA pointers to each, plus the compose file and docs. Updating a subproject later requires a separate step to bump its pointer in the top-level repo.)
- **Diagram**: Mermaid, committed into the new repo's `README.md`.
- **IDP-Tools' hardcoded MySQL password**: forward-fix **and** full git-history rewrite (not just HEAD), done as a step in this plan, before its 3 pending local commits are pushed.
- **IDP-Frontend's already-pushed `.env*` history** (URL only, no credential): leave as-is, documented as a deliberate decision, not scrubbed.
- **StrategyManager / IDP-Engine integration — the real scope-setter for this plan**:
  - IDP-Engine's `StrategyCatalog` switches to calling StrategyManager's REST API as the **sole** source of strategy/agent definitions. No additive merge, no classpath fallback.
  - IDP-Engine's existing classpath files (`src/main/resources/strategies/*.yaml`, `src/main/resources/agents/*.md`) are **deleted** once the switch is live.
  - If StrategyManager is unreachable, strategy execution **fails fast** — no cache, no last-known-good fallback. Acceptable for this release.
  - StrategyManager triggers executions and reads status via **REST calls to IDP-Engine only** — never touches IDP-Engine's MySQL tables directly. Same ownership boundary in both directions.
  - StrategyManager's "Reporting" tab **deep-links to Superset** (opens Superset in a new tab, optionally with a filter param) — no iframe embedding in this release.
  - **IDP-MCP-Enhancer will be published to GitHub Packages** (Maven registry) so the 3 MCP server Dockerfiles can resolve it as a normal remote dependency — this removes the need for any cross-submodule Docker build-context trick. Treat "publish IDP-MCP-Enhancer to GitHub Packages" as a prerequisite sub-step of Phase 2, done once, before the 3 MCP servers' Dockerfiles are written.
- **Timeline**: no rush — sequence correctly, don't cut corners (e.g. don't skip the full history scan on the other 11 repos just because 1 known issue was already found).

## Phase 0 — Tooling prerequisites

Install `gitleaks` (primary git-history secret scanner) and `git-filter-repo` (for the IDP-Tools history rewrite — preferred over BFG because it can do scoped content-replacement in one pass rather than whole-file deletion, which matters since the file must survive in history with corrected content). Optionally install `trufflehog` as a cross-check (it can verify whether a found credential is actually live, useful for triaging ambiguous matches across 11 repos that haven't been manually combed yet).

## Phase 1 — Secrets audit & remediation (all 12 repos)

**1.1 Known findings to action:**
- `IDP-Tools/Docker/mysql/docker-compose.yml`: plaintext `MYSQL_ROOT_PASSWORD: rootpassword`, `MYSQL_PASSWORD: db_password` committed since "Initial commit." Needs forward-fix + full history rewrite (see 1.3).
- `IDP-Frontend`: `frontend/.env`, `.env.development`, `.env.production` were committed then deleted (commits `d9185ec`, `6e1a94e`, `ee8900a`); content is only `REACT_APP_API_BASE_URL=http://localhost:8080/api` — a URL, not a credential. **Leave as-is** per Howard's decision; document the decision in the new repo's secrets-audit note so it isn't mistaken for an oversight later.

**1.2 General scan protocol, run identically against all 12 repos** (including the 2 above as a completeness check, and including IDP-StrategyManager once it's git-initialized in Phase 5):
```
cd <repo>
gitleaks detect --source . --log-opts="--all" --report-path <scratch>/<repo>-gitleaks.json --report-format json
trufflehog git file://. --json > <scratch>/<repo>-trufflehog.json
```
Plus a manual grep sweep for patterns scanners might miss (e.g. a real-looking `serper.api.key` literal, or a `secrets.properties`/`.env`/key-material file ever added despite `.gitignore`):
```
git log --all -p | grep -iE "serper.api.key\s*=\s*[A-Za-z0-9]{10,}|api[_-]?key.{0,3}[:=]\s*['\"][A-Za-z0-9]{20,}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY"
git log --all --diff-filter=A --name-only | grep -iE "secrets\.properties$|\.env$|\.env\.|id_rsa|\.pem$|\.p12$|\.jks$"
```
For any hit, `git show <first-commit> -- <path>` to inspect actual content before judging severity — don't classify by filename alone.

**1.3 IDP-Tools history rewrite** (do this before pushing its 3 pending local commits, to avoid a second disruptive force-push later):
1. Forward-fix the file to match the env-var-substitution pattern every other repo already uses:
   ```yaml
   environment:
     MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-change-me}
     MYSQL_USER: ${MYSQL_USER:-db_user}
     MYSQL_PASSWORD: ${MYSQL_PASSWORD:-db_password}
   ```
   Commit normally.
2. Rewrite history with `git-filter-repo --replace-text`, scoped tightly to the two known plaintext values **as they appear in that file's specific lines** (not a blanket token replace — `db_password` is also used elsewhere as an intentional non-secret placeholder default, so an unscoped replace risks collateral damage).
3. Re-run `gitleaks detect --source . --log-opts="--all"` post-rewrite to confirm clean, and `git log -p -- Docker/mysql/docker-compose.yml` across all history to confirm no plaintext remains and nothing unrelated was mangled.
4. Before force-pushing: grep the other 11 repos for any hardcoded reference to an IDP-Tools commit SHA (none expected, but cheap to check since rewriting changes every downstream commit hash).
5. `git push --force origin main`.

## Phase 2 — Dockerization

**Prerequisite: publish IDP-MCP-Enhancer to GitHub Packages** (Maven registry, tied to `howardco/IDP-MCP-Enhancer`) so it resolves as a normal remote dependency. Do this once, before writing Dockerfiles for the 3 MCP servers that depend on it.

**New Dockerfiles needed** (standard multi-stage Maven pattern, each repo's own Java version — 17 for GeneralMCPServer, 21 for the rest):
- `IDP-Engine` (:8080)
- `IDP-GeneralMCPServer` (:8081)
- `IDP-YahooFinanceInfoServer` (:8082)
- `IDP-WebSearch` (:8083)
- `IDP-StrategyManager` (:8084) — combined React+Spring build; check `pom.xml` for `frontend-maven-plugin` wiring (same mechanism as IDP-Frontend). If present, a single `mvn package` triggers both the React build and the Spring packaging in one Maven stage. If not present, add an explicit Node build stage before the Maven stage. Also check `IDP-StrategyManager/.gitignore` — `frontend/build/` currently looks checked in; it should be gitignored so the Docker build produces it fresh rather than relying on a possibly-stale committed artifact.

Standard pattern (adjust Java version/port per service):
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B package -DskipTests
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
```
The 3 MCP servers' Dockerfiles will need a `settings.xml` (or `~/.m2/settings.xml` mounted/copied in during the build stage) with GitHub Packages credentials (a `GITHUB_TOKEN`-style build-time credential — note this is a **build-time** secret, separate from the 2 runtime secrets, and should be documented as such).

**Already has a Dockerfile**: `IDP-yFinance-Proxy` (`python:3.9-slim`, port 8000) — reuse as-is.

**No Dockerfile needed**: `IDP-StockApiClient` (build-time-only generated client, consumed as a Maven dependency at build time by whichever service uses it — verify during Phase 2 execution whether it also needs a GitHub Packages publish, or is already resolvable). `IDP-MCP-Enhancer` itself doesn't run as a service — only needs the GitHub Packages publish above.

## Phase 3 — docker-compose.yml design

**Startup order**: `mysql` → `general-mcp-server`, `yahoo-finance-server`, `yfinance-proxy`, `web-search` → `idp-engine` → `strategy-manager` → `opensearch`/`logstash`/`opensearch-dashboards` + `superset` (and its redis/metadata-db).

**Healthchecks**: use `/actuator/health` for every Spring Boot service (all already expose it), not bare port checks — Spring Boot startup is slow (JVM warm-up + first-boot DB work). Example:
```yaml
idp-engine:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
    interval: 10s
    timeout: 5s
    retries: 20
    start_period: 60s
```
MySQL uses `mysqladmin ping`; yFinance-Proxy checks its `/docs` page; OpenSearch uses its own cluster-health check.

**Internal network**: single bridge network shared by everything. This requires editing `IDP-Engine/src/main/resources/application-prod.properties`, which currently has two problems that must be fixed regardless of networking:
- It overrides `spring.ai.openai.base-url` to point at a local LLM (`http://192.168.0.136:8079/v1`, model `mlx-community/Qwen3.5-9B-4bit`) instead of real OpenAI. Since the decision is to keep OpenAI, this override must not be active in the dockerized stack.
- It hardcodes homelab LAN IPs (`192.168.30.123` for MySQL/logstash, `192.168.30.102` for MCP servers) that need to become Docker service names.

Recommend a new `application-docker.properties` profile per service (activated via `SPRING_PROFILES_ACTIVE=docker`) rather than further overloading `-prod`, since "runs in Docker" and "this is the homelab production deployment" are different axes and shouldn't be entangled.

**The 2 user-facing secrets**, in a top-level `.env.example`:
```
OPENAI_API_KEY=
SERPER_API_KEY=
```
Everything else (DB creds, `SUPERSET_SECRET_KEY`, `SUPERSET_ADMIN_PASSWORD`, etc.) gets fixed, pre-generated non-placeholder values committed directly in the compose file or a separate shipped `.env` — these are internal-only values on a network nothing external reaches, not secrets a deployer needs to supply. Generate `SUPERSET_SECRET_KEY` once via `openssl rand -base64 42` and commit the fixed result.

**Named volumes**: `mysql-data`, `opensearch-data`, `superset2-home` — reuse the existing volume definitions/mounts already correct in `IDP-Tools/Docker/mysql/docker-compose.yml` and `IDP-Tools/Docker/superset2/docker-compose.yml`, just relocated into the single top-level compose file. Also update Superset's `build_dashboard.py` / `.env` — `IDP_ENGINE_MYSQL_HOST` currently points at `host.docker.internal`, needs to become the compose service name `mysql`.

## Phase 4 — StrategyManager / IDP-Engine integration (the real new feature work)

**4.1 — IDP-Engine reads strategies exclusively from StrategyManager**

Current state: `IDP-Engine/src/main/java/hco/digital/idp/engine/services/definitions/StrategyCatalog.java` loads from `${idp.strategies.location:classpath*:strategies/*.yaml}` via `PathMatchingResourcePatternResolver`, reloading on every `get()` — a useful existing seam to repoint. `IDP-StrategyManager/src/main/java/hco/digital/idp/strategymanager/controller/StrategyController.java` already exposes `GET /api/strategies`, `GET /api/strategies/{name}`, `GET /api/strategies/latest`.

Changes:
- Add `idp.strategies.remote.base-url=${STRATEGY_MANAGER_URL:http://strategy-manager:8084}` to `IDP-Engine`'s config.
- Replace `StrategyCatalog`'s classpath-loading logic with a call to StrategyManager's API (`GET /api/strategies`, then per-entry detail) as the **only** source. Map `StrategyDto` fields directly to `StrategyDefinition` — verify field-by-field during implementation that the "byte-for-byte compatible" claim in StrategyManager's DTO comments actually holds, rather than assuming it.
- Keep `StrategyValidator` (`IDP-Engine/.../services/definitions/StrategyValidator.java`) as the sole validation gate for referential correctness (agent/tool catalog checks) — StrategyManager's own `StructuralValidator` only checks shape at authoring time and isn't a substitute.
- If StrategyManager is unreachable: fail fast, no cache, no classpath fallback — per Howard's decision. Log clearly so the failure mode is obvious in ELK.
- **Delete** `IDP-Engine/src/main/resources/strategies/*.yaml` and `IDP-Engine/src/main/resources/agents/*.md` once the switch is live and verified — they become dead weight and would mislead future readers into thinking they're still read.

**4.2 — StrategyManager triggers executions on IDP-Engine via REST, polls status via REST**

Current state: `IDP-Engine/src/main/java/hco/digital/idp/engine/controllers/EngineExecutionController.java` already exposes `GET /api/engine/execute-strategy?strategyId={name}`, calling `StrategyExecutor.execute(strategyName)` and returning `{"status":"success","executionUid": "<uuid>"}` — this UUID is exactly the `strategy_execution_uid` IDP-MCP-Enhancer already propagates through telemetry. There's also an SSE streaming variant (`/api/engine/execute-strategy/stream`) for live progress.

Changes:
- Add an execute action to `IDP-StrategyManager`'s `StrategyController` (or a new `ExecutionController`) that calls IDP-Engine's existing endpoint via `WebClient` (StrategyManager is already WebFlux-based, so this is idiomatic) — prefer relaying the **SSE stream** variant so the "Execution" tab shows live progress rather than blocking on a long-running call.
- Add a status-read path: StrategyManager calls an IDP-Engine REST status endpoint (check if one exists beyond the execute call; if not, add `GET /api/engine/executions/{uid}` to `EngineExecutionController` backed by `StrategyExecutionRepository`) — StrategyManager never reads IDP-Engine's MySQL tables directly, matching the same ownership boundary as 4.1.
- New config in StrategyManager: `idp.engine.base-url=${IDP_ENGINE_URL:http://idp-engine:8080}`.
- Store the returned `executionUid` against the triggering strategy in StrategyManager's own DB (check `IDP-StrategyManager/src/main/java/hco/digital/idp/strategymanager/model/Strategy.java` for whether a `lastExecutionUid`/history field needs adding) so the Reporting tab (4.3) knows what to link.

**4.3 — StrategyManager's "Reporting" tab deep-links to Superset**

Current state: "Reporting" and "Execution" are stubbed "Coming soon" in StrategyManager's frontend — no `ReportingPage.tsx`/`ExecutionPage.tsx` exist yet, these are net-new pages. Superset (`IDP-Tools/Docker/superset2`) is the confirmed sole reporting tool, already reading the shared `idp_engine` MySQL DB via `build_dashboard.py`.

Changes:
- New `ReportingPage.tsx` that, given a strategy name (and once 4.2's history field exists, an executionUid), renders an "Open in Superset" link using `superset.base-url=${SUPERSET_BASE_URL:http://localhost:8088}` — this is browser-facing, so it correctly uses `localhost`, not the internal Docker service name, unlike 4.1/4.2's server-to-server URLs.
- Check `IDP-Tools/Docker/superset2/build_dashboard.py` during implementation to see whether it already parameterizes dashboards by strategy name (determines whether per-execution deep-linking via URL filter params is feasible now or a documented next-iteration item). A static link to Superset's dashboard list is an acceptable first cut — this doesn't need to be the final design since Howard plans to develop StrategyManager further over time.

## Phase 5 — Git repo setup, in strict order

1. **`git init` IDP-StrategyManager first** (zero history today, nothing to scrub) and push to a new `howardco/IDP-StrategyManager` remote, matching the naming convention of all other repos. Do this before Phase 4's integration code lands, so that work has normal commit history rather than being folded into one opaque initial commit.
2. **Run Phase 1's secrets remediation across all 12 repos**, including the IDP-Tools history rewrite and force-push — must fully complete **before** step 3, because submodule references pin exact commit SHAs, and rewriting a repo's history after it's been pinned as a submodule orphans the pin.
3. **Create the new top-level `IDP` repo**: `git init` at `~/CODE/IDP`, then `git submodule add` each of the 12 subprojects using each one's existing remote URL/protocol as-is (don't normalize SSH vs HTTPS inconsistencies — unrelated to this release). Include IDP-Website and IDP-Frontend as submodules too, for program completeness, clearly marked in the README as not part of the running compose stack.
4. Add `docker-compose.yml`, `.env.example`, `README.md` (diagram + quickstart), commit.

## Phase 6 — Architecture diagram (Mermaid in the new README)

One `flowchart` with:
- A subgraph for the Docker internal network containing all compose services (mysql, the 3 MCP servers, yfinance-proxy, idp-engine, strategy-manager, opensearch/logstash/dashboards, superset + its dependencies).
- Two external nodes outside the network boundary, visually distinct: `OPENAI_API_KEY` → `idp-engine`, `SERPER_API_KEY` → `web-search`.
- Execution flow arrows: `strategy-manager → idp-engine` (labeled "execute-strategy, strategy_execution_uid"), `idp-engine → general-mcp-server / yahoo-finance-server / web-search`, `yahoo-finance-server → yfinance-proxy`.
- Telemetry arrows: each MCP server and idp-engine → `mysql`.
- Logging arrows: every service → `logstash → opensearch → opensearch-dashboards`.
- Reporting arrows: `mysql → superset` (build_dashboard.py), `strategy-manager → superset` (Reporting tab link).

Validate the Mermaid syntax before committing (a broken diagram silently renders as a plain code block on GitHub).

## Phase 7 — Verification

1. `docker compose up -d`, then `docker compose ps` until all report healthy (not just running).
2. Hit health endpoints in dependency order: MySQL (`mysqladmin ping`) → each MCP server's `/actuator/health` → yfinance-proxy `/docs` → idp-engine `/actuator/health` → strategy-manager `/actuator/health` → OpenSearch/Dashboards → Superset `/health`.
3. **Confirm the 2 secrets actually work**, not just that they're passed through:
   - `OPENAI_API_KEY`: call IDP-Engine's chatbot demo (`/test.html` / `OpenAIChatController`) with a real prompt — a successful completion proves the key is live, not just present.
   - `SERPER_API_KEY`: trigger IDP-WebSearch's search tool and confirm a real result, not a Serper auth error.
4. **Confirm the StrategyManager integration end-to-end**: trigger an execution via StrategyManager's new endpoint, confirm it returns an `executionUid`, confirm a matching `strategy_execution` row appears in MySQL, and confirm corresponding `mcp_responses` telemetry rows share the same UID.
5. Confirm ELK ingestion picks up logs from the triggered execution (check OpenSearch/Dashboards for matching entries), confirming `logstash.host` correctly resolved to the Docker service name.
6. Confirm Superset shows the triggered execution's data after `build_dashboard.py` is pointed at the compose `mysql` service name.

## Phase 8 — Documentation

**New `IDP/README.md`**: program description, the Mermaid diagram, quickstart (`git clone --recurse-submodules`, `cp .env.example .env` + fill in the 2 keys, `docker compose up -d`, abbreviated smoke-test), a table of all 12 submodules with role + link, explicit note that IDP-Website/IDP-Frontend aren't part of the running stack, and a short secrets/security section referencing the Phase 1 audit trail.

**Update `~/CODE/IDP/CLAUDE.md`**: add the missing `IDP-StrategyManager` row to the Subprojects table (role, port :8084, stack), fix the `Docker/superset` → `Docker/superset2` path typo, add StrategyManager to the Cross-Service Topology section, and note the new top-level `IDP` repo as the containerized-deploy entry point.

## Verification summary

End-to-end test is `docker compose up -d` from the new top-level repo, followed by the health-check and secret-flow checks in Phase 7 — this proves the whole released stack actually works, not just that it builds.
