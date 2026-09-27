# `terraform test`, fully offline: the AWS provider is mocked, so every
# computed value (ARNs, IDs) is a known placeholder and the assertions can
# read things a real plan leaves unknown, like the rendered IAM policy and
# the container definitions. The random provider is real.

mock_provider "aws" {
  # The provider still validates arguments under a mock, and its random
  # placeholders are not ARNs. Only resources whose ARN feeds a validated
  # argument need one.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-central-1:111122223333:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-central-1:111122223333:loadbalancer/app/mock/0123456789abcdef" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-central-1:111122223333:targetgroup/mock/0123456789abcdef" }
  }
}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
  public_subnet_ids  = ["subnet-0bbbbbbbbbbbbbbb1", "subnet-0bbbbbbbbbbbbbbb2"]
  image              = "ghcr.io/sriharifortitude/hookrelay:0.2.0"
  certificate_arn    = "arn:aws:acm:eu-central-1:111122223333:certificate/00000000-0000-0000-0000-000000000000"
}

run "database_is_private_encrypted_and_recoverable" {
  command = apply

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must not be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.kms_key_id == aws_kms_key.this.arn
    error_message = "The database must be encrypted with the module's own KMS key."
  }
  assert {
    condition     = aws_db_instance.this.deletion_protection && !aws_db_instance.this.skip_final_snapshot && aws_db_instance.this.backup_retention_period >= 1
    error_message = "Deletion protection, a final snapshot and automated backups must all be on by default."
  }
  assert {
    condition     = contains([for p in aws_db_parameter_group.this.parameter : "${p.name}=${p.value}"], "rds.force_ssl=1")
    error_message = "The database must refuse unencrypted connections."
  }
}

run "redis_is_encrypted_and_never_evicts_queued_jobs" {
  command = apply

  assert {
    condition     = tostring(aws_elasticache_replication_group.this.transit_encryption_enabled) == "true" && tostring(aws_elasticache_replication_group.this.at_rest_encryption_enabled) == "true"
    error_message = "Redis must be encrypted in transit and at rest."
  }
  assert {
    condition     = contains([for p in aws_elasticache_parameter_group.this.parameter : "${p.name}=${p.value}"], "maxmemory-policy=noeviction")
    error_message = "BullMQ needs maxmemory-policy noeviction, or queued deliveries can be evicted under memory pressure."
  }
}

run "tls_only_at_the_edge" {
  command = apply

  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "HTTPS listener must use the TLS 1.3 / 1.2-only policy."
  }
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect" && aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
    error_message = "Port 80 must only redirect to HTTPS."
  }
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "The load balancer must drop invalid header fields (request smuggling)."
  }
}

run "containers_are_hardened_and_get_credentials_only_as_secrets" {
  command = apply

  assert {
    condition = alltrue([
      for c in concat(jsondecode(aws_ecs_task_definition.api.container_definitions), jsondecode(aws_ecs_task_definition.worker.container_definitions)) :
      c.readonlyRootFilesystem
    ])
    error_message = "Every container must run with a read-only root filesystem."
  }
  assert {
    condition = alltrue([
      for c in concat(jsondecode(aws_ecs_task_definition.api.container_definitions), jsondecode(aws_ecs_task_definition.worker.container_definitions)) :
      length(setintersection([for e in c.environment : e.name], ["DATABASE_URL", "REDIS_URL", "ADMIN_API_KEY"])) == 0
    ])
    error_message = "Credentials must reach containers through `secrets`, never plain `environment`."
  }
  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c.dependsOn if c.name == "api"
    ]) == [{ containerName = "migrate", condition = "SUCCESS" }]
    error_message = "The API container must start only after migrations exit successfully."
  }
  assert {
    condition = alltrue([
      for c in jsondecode(aws_ecs_task_definition.worker.container_definitions) :
      contains([for e in c.environment : "${e.name}=${e.value}"], "ALLOW_INSECURE_ENDPOINTS=false")
    ])
    error_message = "The worker must never deliver to plain-http or private-address endpoints."
  }
  assert {
    condition     = !aws_ecs_service.api.enable_execute_command && !aws_ecs_service.worker.enable_execute_command
    error_message = "ECS Exec must be off."
  }
}

run "data_stores_are_reachable_only_from_the_tasks" {
  command = apply

  assert {
    condition = alltrue([
      for r in concat(values(aws_vpc_security_group_ingress_rule.db_from_tasks), values(aws_vpc_security_group_ingress_rule.cache_from_tasks), [aws_vpc_security_group_ingress_rule.api_from_alb]) :
      r.cidr_ipv4 == null && r.cidr_ipv6 == null && r.referenced_security_group_id != null
    ])
    error_message = "The database, Redis and the API must accept traffic only from a security group, never a CIDR."
  }
  assert {
    condition     = toset([for r in values(aws_vpc_security_group_ingress_rule.alb_https) : r.from_port]) == toset([443])
    error_message = "The load balancer's public ingress is 443 (and 80 for the redirect), nothing else."
  }
}

run "iam_is_scoped_to_this_deployment" {
  command = apply

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s if s.Resource == "*" || s.Action == "*"]) == 0
    error_message = "Without ECR, no execution-role statement may use a wildcard action or resource."
  }
  assert {
    condition     = toset(one([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadOwnSecrets"])) == toset([aws_secretsmanager_secret.database_url.arn, aws_secretsmanager_secret.redis_url.arn, aws_secretsmanager_secret.admin_api_key.arn])
    error_message = "The execution role reads exactly this deployment's three secrets."
  }
}

run "ecr_pull_permissions_only_when_asked_for" {
  command = apply

  variables {
    ecr_repository_arns = ["arn:aws:ecr:eu-central-1:111122223333:repository/hookrelay"]
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "PullImage"]) == ["arn:aws:ecr:eu-central-1:111122223333:repository/hookrelay"]
    error_message = "ECR pulls are scoped to the listed repositories."
  }
  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Action if s.Resource == "*"] == ["ecr:GetAuthorizationToken"]
    error_message = "The only wildcard resource is ecr:GetAuthorizationToken, which IAM cannot scope."
  }
}

# --- input validation ---------------------------------------------------------

run "rejects_a_latest_tag" {
  command = plan
  variables {
    image = "ghcr.io/sriharifortitude/hookrelay:latest"
  }
  expect_failures = [var.image]
}

run "rejects_an_untagged_image" {
  command = plan
  variables {
    image = "registry.example.com:5000/hookrelay"
  }
  expect_failures = [var.image]
}

run "accepts_a_digest" {
  command = plan
  variables {
    image = "ghcr.io/sriharifortitude/hookrelay@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}

run "rejects_a_single_private_subnet" {
  command = plan
  variables {
    private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }
  expect_failures = [var.private_subnet_ids]
}

run "rejects_turning_backups_off" {
  command = plan
  variables {
    db_backup_retention_days = 0
  }
  expect_failures = [var.db_backup_retention_days]
}
