<div align="center">

# Delta Forge

### Your entire data stack. One unified platform.

Graph your tables. Index a billion GPS points. Travel back to version 42.
Parse a FHIR document in the same query that joins an Iceberg snapshot.
Commit the pipeline to Git and get lineage automatically.

[![Website](https://img.shields.io/badge/deltaforge.org-Visit-6366f1?style=flat-square)](https://deltaforge.org)
[![Install Guide](https://img.shields.io/badge/install-guide-8b5cf6?style=flat-square)](https://deltaforge.org/install)
[![Documentation](https://img.shields.io/badge/docs-read-0ea5e9?style=flat-square)](https://deltaforge.org/docs)
[![Release](https://img.shields.io/github/v/release/deltaforge-org/delta-forge?style=flat-square&label=latest&color=22c55e)](https://github.com/deltaforge-org/delta-forge/releases)
[![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux-334155?style=flat-square)](#install)

</div>

---

## What it does

One SQL engine that reads and writes **Delta Lake** and **Apache Iceberg V3**
natively, runs **graph algorithms** and **H3 geospatial** as table functions,
parses **FHIR / HL7 / EDI** inline, and builds **data lineage** automatically
from the SQL files you commit to Git. Deploys on your cloud, your datacenter,
or fully air-gapped.

### Capabilities

| Area              | What's in the box                                                                     |
| ----------------- | ------------------------------------------------------------------------------------- |
| Open tables       | Delta Lake, Iceberg V3, UniForm, time travel, ACID, schema evolution, deletion vectors |
| Analytics         | PageRank, community detection, Cypher, H3 spatial indexing, spatial joins             |
| Pipelines         | Git-native `PIPELINE` SQL command, auto-lineage, scheduling, retries, SLAs            |
| Industry formats  | FHIR R4, HL7 v2, X12 / EDIFACT parsed as SQL                                          |
| Interfaces        | Desktop GUI, CLI, Model Context Protocol server, VS Code extension                    |
| Deployment        | AWS, Azure, Google Cloud, on-prem, air-gapped                                         |

---

## Install

See [**deltaforge.org/install**](https://deltaforge.org/install) for the full, up-to-date list of channels per platform.

### Quick install

<details open>
<summary><b>macOS</b> (Homebrew)</summary>

```sh
brew tap deltaforge-org/tap
brew install --cask deltaforge           # Desktop application
brew install deltaforge-cli              # CLI
brew install deltaforge-mcp              # Model Context Protocol server
brew install deltaforge-compute          # Compute node
```

</details>

<details>
<summary><b>Windows</b> (winget or Scoop)</summary>

```powershell
# winget (recommended)
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
<summary><b>Linux</b> (apt, dnf, or direct download)</summary>

```sh
# Debian / Ubuntu (once apt repo is live)
curl -fsSL https://deltaforge.org/pubkey.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/deltaforge.gpg
echo "deb [signed-by=/etc/apt/keyrings/deltaforge.gpg] https://apt.deltaforge.org stable main" \
  | sudo tee /etc/apt/sources.list.d/deltaforge.list
sudo apt update && sudo apt install deltaforge-cli

# Direct download (works today)
curl -fsSL https://github.com/deltaforge-org/delta-forge/releases/latest/download/deltaforge-cli-linux-x64.tar.gz \
  | tar -xz -C /usr/local/bin deltaforge-cli
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

## Verify downloads

Every release artifact is signed with the Delta Forge release GPG key and accompanied by a `SHA256SUMS` file.

```sh
# Import the signing key (one-time)
curl -fsSL https://github.com/deltaforge-org/delta-forge/raw/main/deltaforge-pubkey.asc \
  | gpg --import

# Verify an artifact
gpg --verify deltaforge-cli-<version>-<platform>.tar.gz.sig \
             deltaforge-cli-<version>-<platform>.tar.gz
```

**Fingerprint:** `B461 8130 D4B0 3CF5 454E  28F0 A859 0BF7 C3DC E5F3`

---

## A taste of the SQL

```sql
-- Delta Lake + time travel
SELECT name, tier, lifetime_value
FROM customers VERSION AS OF 42
WHERE tier = 'Gold';

-- Iceberg V3 alongside Delta, same engine
CREATE ICEBERG TABLE metrics (
  day DATE, value DOUBLE
) LOCATION 's3://lake/metrics';

-- Graph analytics as a table function
SELECT c.name, pr.score
FROM cypher('network', $$
  CALL algo.pageRank({dampingFactor: 0.85})
  YIELD node_id, score RETURN node_id, score
$$) AS (node_id BIGINT, score DOUBLE) pr
JOIN customers c ON pr.node_id = c.id
ORDER BY pr.score DESC LIMIT 10;

-- H3 geospatial indexing
SELECT h3_cell_to_string(h3_latlng_to_cell(lat, lng, 9)) AS hex,
       COUNT(*) AS visits
FROM gps_points
GROUP BY hex ORDER BY visits DESC;

-- A pipeline, scheduled and lineage-traced
PIPELINE 'daily_revenue'
  SCHEDULE '0 2 * * *'
  NOTIFY ON FAILURE 'ops@acme.com'
  RETRIES 3;
```

---

## Links

| Resource       | Where                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------- |
| Website        | [deltaforge.org](https://deltaforge.org)                                                     |
| Install guide  | [deltaforge.org/install](https://deltaforge.org/install)                                     |
| Documentation  | [deltaforge.org/docs](https://deltaforge.org/docs)                                           |
| Pricing        | [deltaforge.org/pricing](https://deltaforge.org/pricing)                                     |
| Contact        | [deltaforge.org/contact](https://deltaforge.org/contact)                                     |
| Issues         | [github.com/deltaforge-org/delta-forge/issues](https://github.com/deltaforge-org/delta-forge/issues) |
| Releases       | [github.com/deltaforge-org/delta-forge/releases](https://github.com/deltaforge-org/delta-forge/releases) |

---

## License

Delta Forge is distributed under the **Delta Forge Community License**.
See [LICENSE](./LICENSE) and [deltaforge.org/terms](https://deltaforge.org/terms) for the full text.

For commercial licensing and enterprise use: [deltaforge.org/contact](https://deltaforge.org/contact).
