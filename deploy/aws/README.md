# DeltaForge on AWS (CloudFormation)

Single-node DeltaForge on AWS, the analogue of [`deploy/azure`](../azure). One
CloudFormation stack provisions and bootstraps everything with no manual steps:

```
┌──────────────────────────── VPC (2 public subnets) ─────────────────────────┐
│                                                                              │
│  Network Load Balancer (stable DNS)                                          │
│        │  443/80  (or 3031/3000 when EnableHttps=false)                      │
│        ▼                                                                      │
│  ECS Fargate task                         RDS for PostgreSQL                  │
│   ├─ platform  :3000 control plane ──────►  catalog DB (TLS, sslmode=require) │
│   │            :3031 console/web bridge                                       │
│   └─ caddy     :443/:80  terminates HTTPS, proxies → localhost:3031           │
│        │                                                                      │
│        ├─ EFS  /data   (config + git workspace clones + engine state)         │
│        └─ S3 bucket     (Delta/zone table data; task IAM role, no keys)        │
│                                                                              │
│  Secrets Manager: license, admin/engineer passwords, DB URL                   │
└──────────────────────────────────────────────────────────────────────────────┘
```

The Platform serves its web console on the same origin as the API. Storage auth
is keyless: the ECS **task role** grants S3 access and the engine picks it up via
the default credential chain (`AmazonS3Builder::from_env`), so no access keys are
stored anywhere. Entitlement is the DeltaForge **license key** (DeltaForge meters
itself); there is no AWS Marketplace metering wiring.

## Prerequisites

- An AWS account and the AWS CLI configured (`aws configure`).
- A DeltaForge license key.
- The platform image somewhere ECS can pull it: push to **ECR** (recommended) or
  use a public image. For a private non-ECR registry (e.g. ghcr.io) create a
  Secrets Manager secret holding `{"username":"...","password":"..."}` and pass
  its ARN as `RegistryCredentialsArn`.

## Deploy

```bash
aws cloudformation deploy \
  --stack-name deltaforge \
  --template-file deploy/aws/cloudformation/deltaforge-platform.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      Image=<acct>.dkr.ecr.<region>.amazonaws.com/deltaforge-platform:latest \
      LicenseKey=<deltaforge-license-key> \
      AdminEmail=admin@yourcompany.com \
      AdminPassword=<min-12-chars> \
      EngineerEmail=engineer@yourcompany.com \
      EngineerPassword=<min-12-chars> \
      PgAdminPassword=<min-12-chars>

# Read the console URL
aws cloudformation describe-stacks --stack-name deltaforge \
  --query "Stacks[0].Outputs[?OutputKey=='ConsoleUrl'].OutputValue" --output text
```

First boot runs the non-interactive headless bootstrap (provisions the catalog
schema in PostgreSQL, seeds the admin/engineer accounts, activates the license).
Give it a couple of minutes, then browse to `ConsoleUrl`.

### HTTPS (`EnableHttps`, default true)

A Caddy sidecar terminates TLS in front of the console (mirrors the Azure
template). With `EnableHttps=true` the load balancer exposes 443 and 80; the raw
3000/3031 ports are not public.

- **`CustomDomain` set**: Caddy uses public ACME (Let's Encrypt) for a trusted
  cert. After the first deploy, point the domain's DNS (a CNAME) at the
  `LoadBalancerDns` output.
- **`CustomDomain` empty**: Caddy uses its internal CA. HTTPS is real but the cert
  is self-signed, so clients warn unless they trust it (`curl -k`). Use the
  `LoadBalancerDns` value.

## Tear down

```bash
aws cloudformation delete-stack --stack-name deltaforge
```

The S3 tables bucket and the RDS final snapshot are retained (`DeletionPolicy:
Retain`/`Snapshot`) so data is not lost on stack delete; remove them manually if
you want a full wipe.

## AWS Marketplace

This template is the deployment artifact for an AWS Marketplace **CloudFormation**
delivery: the `Parameters` block is the launch form. List the platform image as a
container product (ECR) or reference a public image, and attach this template.
No marketplace **metering** is wired (entitlement is the license key), so this is
a "bring your own license" listing, not a metered/transactable SaaS offer.

## Notes / knobs

- `TaskCpu`/`TaskMemory` must be a valid Fargate pairing (default 4096 / 8192).
- `DbInstanceClass` defaults to `db.t3.small`; raise for real workloads.
- The Fargate task gets a public IP for image pull + egress; inbound is only via
  the load balancer security group.
- The bucket URL (`TablesBucketZoneRoot`, `s3://...`) is what you use when
  creating a zone in the console; it is an output, not baked into the engine.
