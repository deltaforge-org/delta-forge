<div align="center">

# Delta Forge

### Delta Lake. Iceberg. Graph. Geospatial. Industry formats.<br>One SQL engine. No Spark.

Write a Delta table from Delta Forge. Read it in Spark, in Databricks, in any
Delta-native tool. Same bytes. Same guarantees. Same Iceberg V3 metadata
exposed via UniForm. Then take the graph algorithms, the H3 geospatial
indexing, the FHIR / HL7 / EDI parsers, and the Git-native pipeline engine
that nobody else puts in the same box — and run them all as SQL against
the same tables.

[![Website](https://img.shields.io/badge/deltaforge.org-Visit-6366f1?style=flat-square)](https://deltaforge.org)
[![Install Guide](https://img.shields.io/badge/install-guide-8b5cf6?style=flat-square)](https://deltaforge.org/install)
[![Documentation](https://img.shields.io/badge/docs-read-0ea5e9?style=flat-square)](https://deltaforge.org/docs)
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
| Read/write Delta Lake             | Spark cluster                          |     SQL     |
| Read/write Iceberg V3             | Iceberg connector + catalog service    |     SQL     |
| Tables readable by Spark + Databricks | Running Spark yourself              |     SQL     |
| Graph algorithms (PageRank, etc.) | Separate graph database                |     SQL     |
| H3 geospatial at scale            | Separate geo service                   |     SQL     |
| Parse FHIR / HL7 / EDI            | Custom parsers + ETL                   |     SQL     |
| Data lineage                      | Separate lineage tool + annotations    |   built-in  |
| Pipeline orchestration            | DAG builder + scheduler                | Git + SQL   |

No other tool ships this combination. And none of it requires Spark.

---

## The promise, in SQL

```sql
-- Write a Delta table. Spark can read it. Databricks can read it.
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

## Interoperability you can verify

Delta Forge writes **real Delta Lake** transaction logs and **real Iceberg V3**
metadata. Not a lookalike, not a bridge. The tables and manifests are
byte-compatible with the public format specs.

- Write here, read in **any Delta-compatible engine** (Spark, Databricks, or other Delta readers).
- Write here, read in **any Iceberg-compatible engine** via UniForm.
- Read anything Spark wrote. Read anything Databricks wrote. Read anything that wrote to spec.

Runs on AWS, Azure, Google Cloud, on-prem, and fully air-gapped.
No vendor lock-in. No proprietary catalog. No telemetry leaving your perimeter.

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
<summary><b>Linux</b> — apt or direct download</summary>

```sh
# Debian / Ubuntu
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
