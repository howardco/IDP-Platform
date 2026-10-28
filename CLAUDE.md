# CLAUDE.md

This file provides program-level guidance to Claude Code when working anywhere under `~/CODE/IDP`. It is extrapolated from the individual projects' own CLAUDE.md files, READMEs, and `.claude/settings.local.json` permission grants (several projects already grant cross-repo `Read` access to siblings here, confirming this is one coherent program, not unrelated repos).

## Program Overview

**IDP** = Investment Decision Platform, the engineering program behind **QuantView**, an Agentic AI platform for financial markets. QuantView leverages the Model Context Protocol (MCP) so an orchestrating agent (IDP-Engine) can call out to a set of specialized MCP tool servers (stock data, web search, location/word-of-day) and present results through a public website and an internal admin/demo frontend.

Three product tiers (per IDP-Website requirements): (1) curated stock recommendations from IDP-Engine, (2) user-authored trading strategies, (3) autonomous strategy optimization with AI-driven review/adjustment.

## Subprojects

| Folder | Role | Stack |
|---|---|---|
| **IDP-Engine** | Main aggregator/orchestrator. Integrates all MCP servers, exposes chatbot demo + Swagger + actuator health. Runs on :8080. | Spring Boot 3.5, Jakarta EE, Spring Data JPA (MySQL), Spring AI (OpenAI), WebFlux, Project Reactor |
| **IDP-Website** | Public-facing QuantView marketing/product site (Apple-style design). Full requirements in `IDP-Website/docs/REQUIREMENTS.md` — read before implementing features there. | Spring Boot backend + React Native Web frontend |
| **IDP-Frontend** | Internal demo/reference app: reactive JSON CRUD with SSE streaming. Not customer-facing QuantView UI — a generic Spring WebFlux + React/TS showcase (`com.example.jsoncrud`). | Spring Boot WebFlux, R2DBC (H2 dev/MySQL prod), React 19 + TS, React Query, SSE |
| **IDP-GeneralMCPServer** | MCP Server 1 — location/"word of the day" tools. Health :8081. | Spring Boot 3.5, Spring AI MCP |
| **IDP-YahooFinanceInfoServer** | MCP Server 2 — stock quotes, history, financials, earnings, options, technicals via Yahoo Finance data. Health :8082. | Spring Boot, Spring AI MCP |
| **IDP-yFinance-Proxy** | Python API server wrapping the `yfinance` library; likely the actual data source behind IDP-YahooFinanceInfoServer. Runs on :8000, `/docs` for OpenAPI. | Python 3.7+, yfinance |
| **IDP-StockApiClient** | Auto-generated (OpenAPI Generator) Java client library (`idp-stock-java-client`) for calling MCP Server 2 (Yahoo Finance server). Regenerate, don't hand-edit. | Java, OpenAPI Generator |
| **IDP-WebSearch** | MCP server exposing web search as a tool. Health :8083. | Spring Boot, Spring AI MCP |
| **IDP-MCP-Enhancer** | Cross-cutting Spring Boot Starter (`hco.digital.idp:spring-boot-starter-mcp-enhancement`) added as a dependency to the MCP servers. Auto-injects `strategy_execution_uid` into every `@Tool` schema and persists request/response telemetry to a `mcp_responses` MySQL table for cross-service correlation/observability. Experimental (1.0.0-SNAPSHOT). | Spring Boot Starter |
| **IDP-Centralised-Logging** | Docker Compose stack: OpenSearch + Logstash + OpenSearch Dashboards (ELK-style), for local log aggregation/observability. | Docker Compose |
| **IDP-Tools** | Infra/ops grab-bag: `Docker/ELK`, `Docker/mysql` (schema + views), `Docker/jenkins`, and `Docker/superset2` (Superset reporting setup, replacing the earlier vendored `Docker/superset` checkout). | Docker Compose, SQL |
| **IDP-StrategyManager** | Strategy/agent authoring and execution control plane. CRUD UI for strategy/agent definitions (byte-for-byte compatible with IDP-Engine's shapes), triggers executions on IDP-Engine via REST, deep-links to Superset for reporting. Runs on :8084. | Spring Boot 4, WebFlux, R2DBC (MySQL), React/TS |
| **IDP-Strategy-Model** | Shared library holding the canonical `StrategyDefinition`/`AgentDefinition` shapes, consumed as a Maven dependency by both IDP-Engine and IDP-StrategyManager so the two don't maintain hand-synced copies of the same types. No runtime service, no port. | Plain Java library (no Spring Boot parent) |

## Cross-Service Topology (from IDP-Engine's README)

- IDP-Engine (orchestrator): `:8080` — health `/actuator/health`, chatbot demo `/test.html`, Swagger `/webjars/swagger-ui/index.html`
- IDP-GeneralMCPServer: `:8081`
- IDP-YahooFinanceInfoServer: `:8082`
- IDP-yFinance-Proxy (Python): `:8000`, docs at `/docs`
- IDP-WebSearch: `:8083`
- IDP-StrategyManager: `:8084`
- Observability: OpenSearch `:9200`, Dashboards/Kibana `:5601`, Logstash `:9600`
- Jenkins (homelab CI): `http://192.168.30.123:8080`
- Superset (BI/dashboards): `http://192.168.30.123:9088/superset/welcome/`
- Proxmox (homelab virtualization): `https://proxmox.homelab:8006/`
- MySQL is the shared production datastore across IDP-Engine, IDP-MCP-Enhancer telemetry, IDP-StrategyManager, and IDP-Tools' `Docker/mysql` schema/views.

This is a homelab-hosted program: some infra runs on a local network (`192.168.30.123`) and Proxmox, not just localhost.

## Containerized Deploy

This directory (`~/CODE/IDP`) is itself the **IDP-Platform** repo — a top-level
git repo holding the 13 subprojects above as git submodules, plus a single
`docker-compose.yml` that brings up the full runtime stack (MySQL, the 3 MCP
servers + yFinance-Proxy, IDP-Engine, IDP-StrategyManager, the ELK stack, and
Superset) with exactly two required secrets. See `README.md` for the
quickstart and architecture diagram. IDP-Website and IDP-Frontend are
submodules here for program completeness but aren't part of the running
compose stack.

Three internal libraries — IDP-MCP-Enhancer, IDP-StockApiClient, and
IDP-Strategy-Model — are built once into a single `idp-shared-libs` Docker
image (`Dockerfile.shared-libs`) rather than being rebuilt from source inside
every consuming service's own Dockerfile. Run `./build.sh` to build that
image first and then the rest of the stack's images in one step; the
individual consumer Dockerfiles (IDP-Engine, IDP-StrategyManager,
IDP-WebSearch, IDP-YahooFinanceInfoServer) just `COPY --from=idp-shared-libs:latest`
the pre-built `.m2` repository.

## Naming Note

Some services use package name `hco.digital.demo.mcp.server.mcpserver1/2` internally (a legacy/generic naming scheme predating the "IDP" branding) — e.g. IDP-GeneralMCPServer is "MCP Server 1" and IDP-YahooFinanceInfoServer is "MCP Server 2" in code and in IDP-StockApiClient's generated docs. Don't be confused when code references "mcpserver1/2" — map back to this table.

## Working Across the Program

- Each subproject has its own CLAUDE.md (IDP-Frontend, IDP-Website) or none — check the subproject first for specifics; this file is the program-level index.
- When a change spans services (e.g. adding a new MCP tool that needs telemetry), expect to touch: the MCP server itself, possibly IDP-StockApiClient (regenerate client), and rely on IDP-MCP-Enhancer for automatic `strategy_execution_uid` + logging — no manual wiring needed there.
- For end-to-end testing, the full stack requires: MySQL, the relevant MCP server(s), IDP-Engine, and optionally the ELK stack from IDP-Centralised-Logging or IDP-Tools/Docker for observability.
