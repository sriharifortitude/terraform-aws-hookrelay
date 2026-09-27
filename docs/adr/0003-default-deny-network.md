# ADR 3: default-deny security groups, one resource per rule

## Status
Accepted

## Context
A security group written with inline `ingress`/`egress` blocks is one
resource whose rules can't be referenced individually, and two security
groups that reference each other inline create a cycle Terraform can't
order. The AWS provider now recommends
`aws_vpc_security_group_ingress_rule` / `_egress_rule`, one resource per
rule.

Writing the module that way exposed two gaps in this portfolio's own
Terraform scanner, [tfwarden](https://github.com/sriharifortitude/tfwarden).
v0.1.0 read only inline rules, so every rule here would have been
invisible to it. It also read only IPv4, so `::/0` passed. Both are fixed
in tfwarden v0.2.0, which this repository's CI runs.

## Decision
- Five security groups (load balancer, API, worker, database, Redis),
  none with inline rules. Terraform removes the allow-all egress rule AWS
  adds by default, so anything not listed is denied, both ways.
- The database and Redis accept connections only from the API and worker
  security groups (`referenced_security_group_id`), never from a CIDR.
  `terraform test` asserts that for every one of those rules.
- Only the load balancer accepts traffic from outside, on 443 and on 80,
  where the listener only redirects to 443.
- The worker's egress to the internet is limited to `worker_egress_ports`
  (443 by default).

## Consequences
- **The worker can reach any host on 443.** It delivers webhooks to
  customer-chosen URLs, so there's no smaller set to allow. hookrelay's
  own URL screening (no private or link-local addresses, https only,
  redirects not followed) is what stands between a malicious endpoint URL
  and the VPC. `ALLOW_INSECURE_ENDPOINTS` is hard-coded to `false` in the
  task definitions rather than exposed as a variable.
- **A webhook endpoint on a port other than 443 is unreachable** until
  it's added to `worker_egress_ports`. Deliveries to it fail and
  dead-letter, which hookrelay records. That's the trade for not opening
  arbitrary egress.
- **No VPC endpoints.** Image pulls, Secrets Manager and CloudWatch Logs
  go out through the NAT gateway on 443. Interface endpoints would remove
  that path at a fixed monthly cost per endpoint per AZ. They aren't in
  the module; they belong to whoever owns the VPC.
