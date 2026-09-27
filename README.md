# terraform-aws-hookrelay

[![CI](https://github.com/sriharifortitude/terraform-aws-hookrelay/actions/workflows/ci.yml/badge.svg)](https://github.com/sriharifortitude/terraform-aws-hookrelay/actions/workflows/ci.yml)

Terraform module that runs [hookrelay](https://github.com/sriharifortitude/hookrelay)
(outbound webhook delivery) on AWS: ECS Fargate for the API and the
delivery worker, RDS PostgreSQL, ElastiCache Redis, and an HTTPS load
balancer. One customer-managed KMS key covers the data at rest, and no
credential ever enters Terraform state. MIT.

**Honest scope up front: this has never been applied to a real AWS
account.** It's verified by `terraform validate` against the real AWS
provider schema, by 12 `terraform test` runs with the provider mocked,
and by a full plan of the example (69 resources) produced without an
account and scanned by
[tfwarden](https://github.com/sriharifortitude/tfwarden). The
[Verification](#verification) section lists exactly what that does and
doesn't prove.

```
internet ─443/80─▶ ALB (public subnets, TLS 1.3/1.2 policy, 80 → 301 to 443)
                    │ 4000
                    ▼
            ┌─ API tasks ───────────┐      ┌─ worker tasks ──────────┐
            │ migrate ─SUCCESS─▶ api│      │ worker ──443──▶ webhook  │
            └──────┬───────┬────────┘      └───┬───────┬──── endpoints
                   │5432   │6379               │5432   │6379
                   ▼       ▼                   ▼       ▼
               RDS Postgres 17            ElastiCache Redis 7.1
               Multi-AZ, encrypted         2 nodes, TLS + auth token,
               force_ssl, private          encrypted, noeviction
```

## Usage

```hcl
module "hookrelay" {
  source = "github.com/sriharifortitude/terraform-aws-hookrelay?ref=v0.1.0"

  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnets
  private_subnet_ids = module.vpc.private_subnets
  image              = "ghcr.io/sriharifortitude/hookrelay:0.2.0"
  certificate_arn    = aws_acm_certificate.hooks.arn
}
```

[`examples/complete`](examples/complete) adds a minimal two-AZ VPC. Point
a DNS name covered by the certificate at `alb_dns_name` / `alb_zone_id`,
then read the admin API key from Secrets Manager (`admin_api_key_secret_arn`)
to create your first application.

Requires Terraform 1.11+ and AWS provider 6.x, for write-only arguments.

## What it gets right, and how that's checked

| Property | Checked by |
| --- | --- |
| No password, auth token or admin key in state or plan: ephemeral values sent only through write-only arguments ([ADR 1](docs/adr/0001-no-credential-in-state.md)) | CI asserts every credential field is `null` in the example's plan JSON |
| Database private, encrypted with the module's KMS key, `rds.force_ssl=1`, deletion protection, final snapshot, backups that can't be set to zero | `terraform test` + a variable validation |
| Redis encrypted in transit and at rest, auth token required, **`maxmemory-policy noeviction`** | `terraform test` |
| The database and Redis reachable only from the task security groups, never a CIDR; only the load balancer is public ([ADR 3](docs/adr/0003-default-deny-network.md)) | `terraform test` + tfwarden |
| Containers run non-root with a read-only root filesystem; credentials arrive through `secrets`, never `environment`; ECS Exec off | `terraform test` |
| Migrations run before the API starts, in the same task, so the schema can't lag the code ([ADR 2](docs/adr/0002-migrations-inside-the-api-task.md)) | `terraform test` |
| Execution role scoped to this deployment's three secrets, one key and three log groups; task role has no permissions; ECR pull rights only if asked for | `terraform test` reads the rendered policy |
| Image pinned to a version or digest, never `:latest` | variable validation, tested both ways |

Two of those rows exist because the obvious configuration is quietly
wrong:

- **Redis eviction.** ElastiCache's default for Redis 7 is
  `volatile-lru`. BullMQ, the queue hookrelay uses, requires
  `noeviction`: under memory pressure Redis would otherwise delete keys,
  including queued deliveries, and nothing would log it.
- **Credentials in state.** The standard `random_password` → `password`
  pattern writes the database password into state and saved plans. With
  write-only arguments it reaches AWS and never touches either. The cost
  is that rotation is a version bump (below), not an edit.

## Verification

What was run, on Terraform 1.16.4 and AWS provider 6.66.0:

- `terraform validate` on the module and the example, against the real
  provider schema.
- `terraform test`: 12 runs, the AWS provider mocked, so fully offline.
  They're mutation-checked: making the database public, reverting
  Redis to `volatile-lru`, or moving `DATABASE_URL` into `environment`
  each fails exactly the test written for it.
- A real `terraform plan` of the example with no AWS account
  (`scripts/offline-plan.sh`: credential checks skipped, nothing
  refreshed, and no data source in the example calls the AWS API).
- tfwarden over that plan (`scripts/tfwarden-gate.sh`): no failing
  finding. The gate also opens the database's ingress rule to
  `0.0.0.0/0` in a copy of the plan and requires tfwarden to fail it, so
  a pass can't come from a scanner that can't read the module. The one
  remaining result is "indeterminate", for the execution-role policy:
  it embeds secret ARNs that don't exist until apply, so no plan-time
  scanner can read it. `terraform test` checks that policy instead.

What was **not** verified:

- **An apply.** Nothing here has created a real resource. Plan-time
  checks can't catch an API-side rejection: a parameter group value AWS
  refuses, a quota, an instance class not offered in the region, or an
  ordering problem that only shows up during creation.
- **hookrelay running on it end to end**: TLS to RDS with
  `sslmode=require`, `rediss://` with an auth token, a delivery going
  out through the NAT gateway. The image itself is tested in hookrelay's
  CI (migrate, API and worker on a read-only root filesystem against
  real Postgres and Redis), but not against RDS or ElastiCache.
- **Cost.** Two NAT-routed Fargate services, Multi-AZ RDS, two Redis
  nodes and a load balancer aren't free. No figure is given, because
  none was measured.

## Found along the way

- **hookrelay had never been packaged to run anywhere but a dev machine.**
  No Dockerfile, `npm start` required a `.env` file, and the worker had
  only a `tsx` dev script. hookrelay 0.2.0 adds the production image this
  module deploys.
- **tfwarden couldn't read this module.** Three separate bugs, all fixed
  in tfwarden v0.2.0 with regression tests on real `terraform show -json`
  output:
  - It read only inline security-group rules, so every rule here was
    invisible to it.
  - It never treated `::/0` as the whole internet.
  - It never matched a resource inside a module, or created with
    `count`/`for_each`, to its configuration, so it reported this
    module's fully configured log bucket as unencrypted, publicly
    accessible and unversioned.

## Rotating credentials

```bash
terraform apply -var credentials_version=2
aws ecs update-service --cluster hookrelay --service api --force-new-deployment
aws ecs update-service --cluster hookrelay --service worker --force-new-deployment
```

The apply generates a new database password, Redis auth token and admin
key, sets them on RDS and ElastiCache, and rewrites the three secrets.
Running tasks keep the old values until they're replaced, so redeploy
both services straight after.

## Limitations

- **No autoscaling, no WAF, no VPC endpoints, no DNS or certificate
  management.** Fixed task counts; the load balancer isn't behind AWS
  WAF; image pulls, secrets and logs go through the NAT gateway.
- **IPv4 only** at the load balancer (`allowed_ingress_cidrs`).
- **Webhook endpoints on ports other than 443 are unreachable** until
  added to `worker_egress_ports`. That's a deliberate trade, see ADR 3.
- **The image must be pullable without credentials** (a public registry
  such as ghcr.io), or be in ECR via `ecr_repository_arns`. Private
  third-party registries aren't wired up.
- **ALB access logs use SSE-S3**, not the module's KMS key, because load
  balancer log delivery supports only SSE-S3.

## Licence

[MIT](LICENSE).
