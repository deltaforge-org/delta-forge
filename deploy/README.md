# DeltaForge cloud deployment templates

One template per cloud, in that cloud's native infrastructure language. Each
provisions the full DeltaForge platform: web console, control plane, managed
PostgreSQL catalog, object storage for tables, a secret store, and HTTPS.
Storage auth is keyless (managed identity, IAM task role, or service account),
and a Community license is provisioned automatically on first boot.

| Cloud | Language | Start here |
| --- | --- | --- |
| Microsoft Azure | Bicep | [deploy/azure](azure/README-slot-pool.md) |
| Amazon Web Services | CloudFormation | [deploy/aws](aws/README.md) |
| Google Cloud | Terraform | [deploy/gcp](gcp/README.md) |

The `deploy/azure/*.json` files are the compiled ARM output of the tier Bicep
templates (`community` / `standard` / `professional`); the Azure portal's
"Deploy to Azure" flow consumes the JSON together with
`createUiDefinition.json`. Do not edit the JSON by hand; it is regenerated
from the Bicep on every publish.

Install guides with the full walkthrough: https://deltaforge.org/install#cloud
