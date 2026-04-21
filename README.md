<div align="center">

# Delta Forge

### Query a Delta table right now. No cluster to wait on. No Spark. No proprietary format.

Delta Forge is one SQL engine that reads and writes Delta Lake and Iceberg V3
natively, runs graph algorithms and H3 geospatial as SQL, parses FHIR / HL7 / EDI
inline, and builds data lineage from the SQL files you commit to Git.

Write a Delta table here. Read it in any tool that speaks the Delta Lake
specification. Same bytes. Same transaction log. Same Iceberg V3 metadata
through UniForm. No bespoke catalog. No side trip into someone else's
ecosystem. Your tables stay yours, in an open format, on your object storage.

> **This repository distributes the community edition — free, full-featured
> for everyday lakehouse work.** For commercial and enterprise licensing,
> see [deltaforge.org/pages/pricing.html](https://deltaforge.org/pages/pricing.html).

[![Website](https://img.shields.io/badge/deltaforge.org-Visit-6366f1?style=flat-square)](https://deltaforge.org)
[![Install](https://img.shields.io/badge/install-guide-8b5cf6?style=flat-square)](https://deltaforge.org/pages/install.html)
[![Documentation](https://img.shields.io/badge/docs.deltaforge.org-read-0ea5e9?style=flat-square)](https://docs.deltaforge.org)
[![Release](https://img.shields.io/github/v/release/deltaforge-org/delta-forge?style=flat-square&label=latest&color=22c55e)](https://github.com/deltaforge-org/delta-forge/releases)
[![Platforms](https://img.shields.io/badge/Windows%20%7C%20macOS%20%7C%20Linux-supported-334155?style=flat-square)](#install)

</div>

---

## Why this is different

**Every other route to a lakehouse drags a cluster behind it.** To touch Delta
tables you spin up Spark. To touch Iceberg you configure a catalog. To run
graph queries you stand up a separate graph database. To index GPS points
you run a geospatial service. To track data lineage you buy a fifth tool
that still gets it wrong.

**Delta Forge puts all of that into one engine and talks SQL to it.**

| The work                          | Usually needs                          | Delta Forge |
| --------------------------------- | -------------------------------------- | :---------: |
| Query a Delta table *right now*   | Start cluster, wait 3-5 min            |   instant   |
| Read/write Delta Lake             | A Spark cluster                        |     SQL     |
| Read/write Iceberg V3             | Iceberg connector + catalog service    |     SQL     |
| Interop with other Delta engines  | Whatever runtime they ship             |  spec-level |
| Graph algorithms (PageRank, etc.) | Separate graph database                |     SQL     |
| H3 geospatial at scale            | Separate geo service                   |     SQL     |
| Parse FHIR / HL7 / EDI            | Custom parsers + ETL                   |     SQL     |
| Data lineage                      | Separate lineage tool + annotations    |   built-in  |
| Pipeline orchestration            | DAG builder + scheduler                | Git + SQL   |

No other tool ships this combination. None of it requires Spark.
None of it locks your data into a proprietary format.

---

## The promise, in SQL

```sql
-- Write a real Delta Lake table. Any Delta-compliant engine can read it.
CREATE DELTA TABLE customers (
  id BIGINT, name STRING, tier STRING, lifetime_value DOUBLE
) LOCATION 's3://lake/customers'
TBLPROPERTIES ('delta.enableChangeDataFeed' = 'true');

-- Time-travel the same table.
SELECT name, tier, lifetime_value
FROM customers VERSION AS OF 42
WHERE tier = 'Gold';

-- Write Iceberg V3. Same engine, same SQL.
CREATE ICEBERG TABLE metrics (day DATE, value DOUBLE)
LOCATION 's3://lake/metrics';

-- Graph algorithms as a table function.
SELECT c.name, pr.score
FROM cypher('network', $$
  CALL algo.pageRank({dampingFactor: 0.85})
  YIELD node_id, score RETURN node_id, score
$$) AS (node_id BIGINT, score DOUBLE) pr
JOIN customers c ON pr.node_id = c.id
ORDER BY pr.score DESC LIMIT 10;

-- Billion-point geospatial, indexed, joined to the same lake.
SELECT h3_cell_to_string(h3_latlng_to_cell(lat, lng, 9)) AS hex,
       COUNT(*) AS visits
FROM gps_points
GROUP BY hex
ORDER BY visits DESC;

-- A pipeline in 4 lines. Lineage is automatic.
PIPELINE 'daily_revenue'
  SCHEDULE '0 2 * * *'
  NOTIFY ON FAILURE 'ops@acme.com'
  RETRIES 3;
```

---

## Open standards, verifiable interop

Delta Forge writes **real Delta Lake** transaction logs and **real Iceberg V3**
metadata. Not a lookalike, not a bridge, not a translation layer. The tables
and manifests are byte-compatible with the public Delta Lake and Apache
Iceberg V3 specifications.

- Write here. Read anywhere that implements the Delta spec (Spark, Databricks, Trino, Flink, Polars, or any other conformant reader).
- Write here. Read anywhere that implements the Iceberg spec via UniForm.
- Read anything any conformant engine wrote.
- Walk away whenever you want. Your tables are on your object storage,
  in an open format, owned by you.

Runs on AWS, Azure, Google Cloud, on-prem, and fully air-gapped.
No proprietary catalog. No vendor dependency. No telemetry leaving
your perimeter unless you turn it on.

---

## Install

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
<summary><b>Linux</b> — direct download (apt repository coming soon)</summary>

```sh
# Direct download, latest release
curl -fsSL https://github.com/deltaforge-org/delta-forge/releases/latest/download/deltaforge-cli-linux-x64.tar.gz \
  | sudo tar -xz -C /usr/local/bin
```

An apt-style signed package repository will be published at a later date.
Until then, grab tarballs from [GitHub Releases](https://github.com/deltaforge-org/delta-forge/releases).

</details>

For the canonical, always-up-to-date install instructions, see
[**deltaforge.org/pages/install.html**](https://deltaforge.org/pages/install.html).

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

Every release artifact is GPG-signed. Every release ships a `SHA256SUMS` manifest.

```sh
curl -fsSL https://github.com/deltaforge-org/delta-forge/raw/main/deltaforge-pubkey.asc \
  | gpg --import

gpg --verify deltaforge-cli-<version>-<platform>.tar.gz.sig \
             deltaforge-cli-<version>-<platform>.tar.gz
```

**Fingerprint:** `B461 8130 D4B0 3CF5 454E  28F0 A859 0BF7 C3DC E5F3`

---

## Links

| Resource       | Where                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------- |
| Website        | [deltaforge.org](https://deltaforge.org)                                                     |
| Install        | [deltaforge.org/pages/install.html](https://deltaforge.org/pages/install.html)               |
| Features       | [deltaforge.org/pages/features.html](https://deltaforge.org/pages/features.html)             |
| Documentation  | [docs.deltaforge.org](https://docs.deltaforge.org)                                           |
| Console        | [console.deltaforge.org](https://console.deltaforge.org)                                     |
| Pricing        | [deltaforge.org/pages/pricing.html](https://deltaforge.org/pages/pricing.html)               |
| Contact        | [deltaforge.org/pages/contact.html](https://deltaforge.org/pages/contact.html)               |
| Issues         | [Report a bug](https://github.com/deltaforge-org/delta-forge/issues)                         |
| Releases       | [All versions](https://github.com/deltaforge-org/delta-forge/releases)                       |

---

## License

Delta Forge is distributed under the **Delta Forge Community License**.
See [LICENSE](./LICENSE) and [deltaforge.org/pages/terms-of-service.html](https://deltaforge.org/pages/terms-of-service.html) for the full text.

For commercial and enterprise licensing: [deltaforge.org/pages/contact.html](https://deltaforge.org/pages/contact.html).
