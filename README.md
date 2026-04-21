<div align="center">

# Delta Forge

### Write SQL. Get a lakehouse, a graph database, and a geospatial engine.

Delta Forge is one SQL engine that does the work of five.
Read and write **Delta Lake** and **Iceberg V3** natively.
Run **graph algorithms** and **H3 geospatial** as table functions.
Parse **FHIR, HL7, and EDI** documents inline.
Commit your pipelines to Git and get **lineage automatically**.
Deploy on any cloud. Or your own datacenter. Or fully air-gapped.

[![Website](https://img.shields.io/badge/deltaforge.org-Visit-6366f1?style=flat-square)](https://deltaforge.org)
[![Install Guide](https://img.shields.io/badge/install-guide-8b5cf6?style=flat-square)](https://deltaforge.org/install)
[![Documentation](https://img.shields.io/badge/docs-read-0ea5e9?style=flat-square)](https://deltaforge.org/docs)
[![Release](https://img.shields.io/github/v/release/deltaforge-org/delta-forge?style=flat-square&label=latest&color=22c55e)](https://github.com/deltaforge-org/delta-forge/releases)
[![Platforms](https://img.shields.io/badge/Windows%20%7C%20macOS%20%7C%20Linux-supported-334155?style=flat-square)](#install)

</div>

---

## Why Delta Forge exists

A modern data team typically stitches together a **lakehouse engine** to touch
open table formats, a **graph database** for network queries, a **geospatial
service** for location data, a **lineage tool** nobody fully trusts, and a
growing pile of format parsers for every industry data spec that shows up.

Five systems. Five query languages. Five deploy pipelines. Five things that
break on different Tuesdays.

**Delta Forge replaces all of that with SQL.**

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│      Before                                After                 │
│      ──────                                ─────                  │
│      Spark cluster     ┐                                         │
│      Graph database    │                                         │
│      Geospatial svc    ├──────────►      Delta Forge            │
│      Lineage tool      │                                         │
│      Format parsers    ┘                  one SQL engine         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## What it does

### 🔷 Delta Lake and Iceberg, both, native

Read and write the two dominant open table formats from the same engine.
No connectors. No converters. No second copy of your data. Write to Delta,
expose the same bytes as Iceberg with UniForm. Time travel, ACID, schema
evolution, and deletion vectors are all first-class SQL.

```sql
SELECT region, SUM(revenue)
FROM orders VERSION AS OF 42
GROUP BY region;

CREATE ICEBERG TABLE metrics (day DATE, value DOUBLE)
LOCATION 's3://lake/metrics';
```

### 🔷 Graph analytics as table functions

Run PageRank, community detection, shortest path, and a dozen more graph
algorithms directly against your lake tables. Cypher queries sit inside a
SELECT and return results you can JOIN back to anything.

```sql
SELECT c.name, pr.score
FROM cypher('network', $$
  CALL algo.pageRank({dampingFactor: 0.85})
  YIELD node_id, score RETURN node_id, score
$$) AS (node_id BIGINT, score DOUBLE) pr
JOIN customers c ON pr.node_id = c.id
ORDER BY pr.score DESC LIMIT 10;
```

### 🔷 Billion-point geospatial in one SQL statement

H3 hexagonal indexing built into the engine. Spatial joins, containment,
proximity, and coverage queries run at lakehouse scale without a separate
geo service.

```sql
SELECT h3_cell_to_string(h3_latlng_to_cell(lat, lng, 9)) AS hex,
       COUNT(*) AS visits
FROM gps_points
GROUP BY hex
ORDER BY visits DESC;
```

### 🔷 Industry formats are data types

FHIR R4 resources, HL7 v2 messages, and X12 / EDIFACT transactions parse
into queryable structures at ingestion. The same `SELECT` that touches a
Delta table can crack open a FHIR bundle.

### 🔷 Git is your pipeline engine

Commit a `.sql` file. Delta Forge discovers it, schedules it, runs it, and
builds the dependency graph across your entire workspace from the source
itself. Lineage is not a separate tool. It is a byproduct of writing SQL.

```sql
PIPELINE 'daily_revenue'
  SCHEDULE '0 2 * * *'
  NOTIFY ON FAILURE 'ops@acme.com'
  RETRIES 3;
```

### 🔷 Runs where your data lives

AWS, Azure, Google Cloud, on-premises datacenter, air-gapped network.
No vendor dependencies. No telemetry leaving your perimeter unless you
opt in. Full data sovereignty.

---

## Install

See [**deltaforge.org/install**](https://deltaforge.org/install) for the canonical, up-to-date install commands.

<details open>
<summary><b>macOS</b> — Homebrew</summary>

```sh
brew tap deltaforge-org/tap
brew install --cask deltaforge        # Desktop application
brew install deltaforge-cli           # Command-line
brew install deltaforge-mcp           # Model Context Protocol server
brew install deltaforge-compute       # Compute node
```

</details>

<details>
<summary><b>Windows</b> — winget or Scoop</summary>

```powershell
# winget
winget install DeltaForge.Desktop
winget install DeltaForge.Cli
winget install DeltaForge.Mcp
winget install DeltaForge.Compute

# Scoop
scoop bucket add deltaforge https://github.com/deltaforge-org/scoop-bucket
scoop install deltaforge-cli deltaforge-mcp deltaforge-compute
```

</details>

<details>
<summary><b>Linux</b> — apt, dnf, or direct download</summary>

```sh
# Debian / Ubuntu (apt repo)
curl -fsSL https://deltaforge.org/pubkey.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/deltaforge.gpg
echo "deb [signed-by=/etc/apt/keyrings/deltaforge.gpg] https://apt.deltaforge.org stable main" \
  | sudo tee /etc/apt/sources.list.d/deltaforge.list
sudo apt update && sudo apt install deltaforge-cli

# Direct download
curl -fsSL https://github.com/deltaforge-org/delta-forge/releases/latest/download/deltaforge-cli-linux-x64.tar.gz \
  | sudo tar -xz -C /usr/local/bin
```

</details>

---

## Packages

| Package              | What it is                       | macOS | Windows | Linux |
| -------------------- | -------------------------------- | :---: | :-----: | :---: |
| `deltaforge`         | Desktop application              |  ✓    |    ✓    |   ✓   |
| `deltaforge-cli`     | Command-line interface           |  ✓    |    ✓    |   ✓   |
| `deltaforge-mcp`     | Model Context Protocol server    |  ✓    |    ✓    |   ✓   |
| `deltaforge-compute` | Compute node                     |  ✓    |    ✓    |   ✓   |

---

## Verify your download

Every release artifact is signed with the Delta Forge release GPG key and ships next to a `SHA256SUMS` manifest.

```sh
curl -fsSL https://github.com/deltaforge-org/delta-forge/raw/main/deltaforge-pubkey.asc \
  | gpg --import

gpg --verify deltaforge-cli-<version>-<platform>.tar.gz.sig \
             deltaforge-cli-<version>-<platform>.tar.gz
```

**Fingerprint:** `B461 8130 D4B0 3CF5 454E  28F0 A859 0BF7 C3DC E5F3`

---

## Links

| Resource       | Where                                                                    |
| -------------- | ------------------------------------------------------------------------ |
| Website        | [deltaforge.org](https://deltaforge.org)                                 |
| Install guide  | [deltaforge.org/install](https://deltaforge.org/install)                 |
| Documentation  | [deltaforge.org/docs](https://deltaforge.org/docs)                       |
| Pricing        | [deltaforge.org/pricing](https://deltaforge.org/pricing)                 |
| Contact        | [deltaforge.org/contact](https://deltaforge.org/contact)                 |
| Issues         | [Report a bug](https://github.com/deltaforge-org/delta-forge/issues)     |
| Releases       | [All versions](https://github.com/deltaforge-org/delta-forge/releases)   |

---

## License

Delta Forge is distributed under the **Delta Forge Community License**.
See [LICENSE](./LICENSE) and [deltaforge.org/terms](https://deltaforge.org/terms) for the full text.

For commercial and enterprise licensing: [deltaforge.org/contact](https://deltaforge.org/contact).
