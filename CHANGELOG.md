# Changelog

All notable changes to the Delta Forge community edition are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Initial repository bootstrap. No public releases yet.

## [1.2.0] - 2026-07-16

The DeltaForge platform: the desktop app, the command-line interface, and the control-plane server. This is an architecture release. The platform is now a compute gateway rather than a single embedded process, which is what unlocks scale-to-zero cloud compute, and it adds AI models you can call directly from SQL.

### AI models and AI functions in SQL

- New `CREATE MODEL` command registers an external large language model as a first-class catalog object, with `ALTER MODEL`, `DROP MODEL`, `DESCRIBE MODEL`, and `SHOW MODELS` to manage it. Providers supported are OpenAI, Azure OpenAI, Anthropic, and Ollama, and the model's credentials are held in the same vault-backed credential storage as your data connections.
- Call the model per row straight from SQL with a family of AI functions: `AI_GENERATE` and `AI_GENERATE_EMBEDDINGS` for open-ended generation and vectorisation, plus task functions `AI_EXTRACT`, `AI_CLASSIFY`, `AI_SUMMARIZE`, `AI_TRANSLATE`, `AI_FIX_GRAMMAR`, and `AI_ANALYZE_SENTIMENT`.
- `AI_EXTRACT` returns clean JSON, ready to use directly in your query.
- A new AI and LLM demo category (with its own icon in the Formats sidebar) shows these functions end to end against sample data.

### New platform architecture: the compute gateway

- The desktop app supervises the control-plane server and a compute worker as managed background services, and routes interactive queries to that worker through a compute gateway. Startup gates on observed health signals rather than fixed delays, so the app opens only once the backend genuinely answers, and it tears the services down cleanly on exit.
- This is the same routing model the drivers and CLI use (the control plane hands out node addresses, clients talk to a node directly), so all of the platform's own queries flow through one path.
- Behaviour on the desktop is unchanged for you: a co-located worker is spawned automatically. The split is what makes the cloud autoscaler below possible.

### Scale-to-zero cloud compute

- Cloud deployments run a per-slot autoscaler pool: compute slots sit at zero replicas until a query arrives, the control plane warms a slot on demand, and idle slots drain back down. You pay for compute only while queries run.
- The Azure deployment is three cooperating container apps (the control-plane server, the web GUI, and the compute pool) on managed-TLS endpoints, with the browser's query routed to the control plane that owns the autoscaler so a cold pool warms on demand.
- The autoscaler authenticates to the cloud with the deployment's own managed identity by default, so no separate service-principal secret is required to scale slots.

### Multi-cloud deployment

- One-shot single-node deployment covers Azure, AWS, and GCP from native per-cloud infrastructure-as-code, and a fresh instance seeds its own catalog: the deployment's object store (Azure Blob, AWS S3, or GCP GCS), its credential storage, and a ready-to-use zone are created for you on first boot.
- Cloud table storage uses ambient credentials on every cloud (managed identity on Azure, task or pod role on AWS, service account on GCP); no static access keys are stored.
- Cloud zone roots resolve consistently to the deployment's storage account across the control plane, web API, and every compute node, so tables land where you expect on every cloud.

### Row-level index acceleration for UPDATE and DELETE

- Keyed `UPDATE` and `DELETE` statements use a row-level index to jump straight to the affected rows instead of scanning the table, and `SHOW STATS` reports whether the index served the statement.

### Graph on cloud storage

- Graph analytics run directly against cloud object stores (`abfss://` and `s3://`): the graph CSR topology and its `_delta_log` are resolved through the cloud-aware filesystem, and CSR provenance is captured so repeat graph queries reuse the built structure instead of re-scanning the whole table.

### Iceberg

- Date and timestamp partition values written by other engines read back correctly, so partitioned Iceberg tables from external writers line up with DeltaForge's own view of them.

### Pipelines and dashboards

- The pipeline health dashboard was reworked with a recency-weighted health signal, so a pipeline's recent runs carry more weight than stale history when its status is shown.
- Pipeline status refreshes automatically after you run a pipeline, and manual schedule runs honour each pipeline's fail-fast setting.
- The landing dashboard surfaces usage stats at a glance.

### Query Explorer and desktop polish

- The Running query loader stays smooth, alive, and cancellable, and shows a distinct compute-node spin-up state so a cold cloud slot reads as "starting" rather than a stalled query.
- Connection cards are editable in place (with the entity reference shown read-only), the Credential Storage "Test" action is cancellable, and page headers wrap their stats and actions on narrow viewports instead of crushing the title.
- The cloud web console resolves its control-plane address from the running deployment, so Connected Devices and compute-token pages work when the console is served from the cloud.

### Accessibility

- Text contrast was raised to WCAG AA across the catalog, admin, and workflow pages.

### Licensing

- A configured daily DFCU limit of 0 means unlimited for paid tiers.

### Fixes and improvements

- Credential, zone, and Key Vault resolution reports clear, specific errors, so a misconfigured cloud connection surfaces the real cause.
- The VS Code extension keeps its loading spinner smooth during long queries, and catalog insert actions open a new SQL editor when none is focused.
- GUI activity is attributed as `gui` in the usage dashboards.

<!-- built from 8136ae039abe1390bc8543c7228bff468985fff2 -->

## [1.0.8] - 2026-06-24

The DeltaForge platform: the desktop app, the command-line interface, and the control-plane server.

### Semantic Context

- New Semantic Context spaces ground AI and natural-language querying against your own catalog. Pin a set of tables, add general instructions an assistant should follow, and the space carries everything needed to answer questions about those tables in business terms.
- Declare virtual PRIMARY KEY, FOREIGN KEY, and UNIQUE constraints as metadata only. They describe how your tables relate without touching or altering the physical Delta or Iceberg tables, and they are never enforced.
- Define named, reusable SQL expressions (your common measures) and register trusted example queries, so the assistant answers from patterns you have approved rather than guessing.
- A new editor in the desktop app (About, Data, and Instructions tabs) shows sample rows, a 360-degree column view (type, nullability, protection, key role, and an example value per column), and a schema-relationships view that reads the captured join graph to suggest joins automatically.
- New SQL surface for managing these spaces: `SEMANTIC CONTEXT` create, alter, and drop, plus `SHOW` and `DESCRIBE`.
- Access control stays the boundary: a context is visible only to a user who can read every one of its pinned tables. A user who lacks read on any pinned table sees nothing of the context.
- Assistants can read these spaces over the MCP server as additive grounding, on top of the existing access-governed catalog tools.

### Table usage auditing

- Per-table usage logging in the style of a modern lakehouse: every query's table accesses are captured at plan time and shipped to the control plane in the background, so the audit trail does not slow your queries.
- A new Table usage dashboard (in the desktop app and the VS Code extension) answers who accessed a table, when, and with which queries, plus a `SHOW TABLE USAGE` command for the same view from SQL.
- The engine also captures the table join graph (which tables get joined to which, and on which keys), surfaced through `SHOW TABLE JOINS` and feeding the auto-detected joins inside Semantic Context.
- The usage and governance dashboard can be scoped by zone and schema to focus on the part of the lake you care about.
- Each access is tagged with how the lake was reached (the desktop app, the VS Code extension, the CLI, the ODBC and ADBC drivers, or an assistant over MCP), so the dashboard shows not just what was used but how. Administered by a single enable toggle in Settings.

### Cloud deployment

- One-shot single-node deployment to Azure, AWS, and GCP, building on the headless mode from the previous release and using native per-cloud infrastructure-as-code.
- The platform container serves the embedded web console and exposes the API over HTTPS (a Caddy sidecar on Azure), with a smart API base URL and local-disk Delta writes, so a fresh cloud instance is reachable and writable out of the box.
- External PostgreSQL connections now support TLS.
- Online-installer container images are available for both the platform and compute nodes.

### Query Explorer

- White catalog-tree icons for better contrast, search scoped to the active pane, a favorites toggle, and a schema list that refreshes immediately after a delete.

### SHOW STATS ACTUAL

- When a query spills to disk during execution (an external sort or aggregate that outgrows memory), `SHOW STATS ACTUAL` now reports the spill activity, so memory pressure is visible instead of silent.

### Connectors

- More robust auto-discovery: JSON-family files and FHIR NDJSON now register more reliably during discovery.

### Command-line interface

- CLI-run queries flow through the platform's direct-dial routing and appear in the new Table usage dashboards exactly like the desktop app, since the CLI is one of the tagged clients. You can see at a glance which activity came from automation versus interactive use.

### Fixes

- Fresh-install authentication errors are fixed, and stale logins now self-heal instead of failing.
- The headless server no longer self-deadlocks on its instance lock during a fresh boot.
- Zones: the default local path now resolves by zone name, fixing some setup flows, and the GUI zone dropdown and the bootstrap GPU page were tidied up.
- Linux: high-resolution launcher icons (the launcher icon was previously blurry), and the desktop app icon is now installed on AppImage installs.

<!-- built from fa643c77c5c40680383cf60209b61986d3044f92 -->

## [1.0.7] - 2026-06-20

The DeltaForge platform: the desktop app, the command-line interface, and the control-plane server.

### GPU-accelerated graph analytics

- Graph algorithms now run on the GPU end to end, with host preprocessing moved onto the device so the whole pipeline stays GPU-resident. Community detection (Louvain and Leiden), connected components, strongly connected components, triangle counting, local clustering coefficient, betweenness centrality, eigenvector centrality, and FastRP embeddings all execute on-device.
- Directed inputs are symmetrized on the GPU before community detection, so undirected community queries return correct partitions regardless of how the edges were loaded.
- Results come back in a columnar layout, and a class of numerical issues was fixed, including eigenvector and centrality values that could previously return NaN.

### Headless and container deployment

- The platform now runs as a single signed binary in `--headless` mode, sharing one backend composition with the desktop app for full feature parity without a UI.
- A new web API surface improves HTTP support for service and container deployments; the desktop app and headless server use the same bridge, so behavior is identical across both.

### Query Explorer

- New keyboard shortcuts for the editor and results layout, including a true 50/50 split between query and results.

### DISCOVER

- JSON and XML detection now uses statistics-driven record-anchor auto-detection, so the record boundary inside a document is found automatically instead of relying on a configured path.

### REST APIs

- The REST APIs page in the desktop app was redesigned to match the brand management-page layout used across the rest of the GUI.

### Fixes

- Fixed a query hang caused by the schema observer's flush blocking the query worker.
- Fixed a control-plane hang from Postgres connection-pool exhaustion under nested checkouts, along with related HTTP request-hang issues.
- Fixed AWS ECS deployment behavior and assorted styling.

<!-- built from 8a24d36767e73b1d9aa3eb06ee1ec33a4e90d6fd -->

## [1.0.6] - 2026-06-14

<!-- built from 31300f9761c2fc96c09cd0a6f3d6daa8f607f9b0 -->

## [1.0.5] - 2026-06-12

<!-- built from 2b86b4dbd3fd28ff5c5e856da53c822945ad13f5 -->

## [1.0.4] - 2026-06-09

The DeltaForge platform: the desktop app, the command-line interface, and the control-plane server.

<!-- built from 30fb9b2f7766e10c8ed262893d77a6eac82e38fa -->

