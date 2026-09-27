# Default deny. Terraform removes the allow-all egress rule AWS adds to a
# new security group, and every rule below is its own resource (the shape
# the AWS provider recommends), so each allowed path is one reviewable
# block. The database and Redis only accept traffic from the task security
# groups, never from a CIDR. docs/adr/0003.

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "hookrelay load balancer"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "api" {
  name_prefix = "${var.name}-api-"
  description = "hookrelay API tasks"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "worker" {
  name_prefix = "${var.name}-worker-"
  description = "hookrelay delivery worker tasks"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "hookrelay PostgreSQL"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "cache" {
  name_prefix = "${var.name}-cache-"
  description = "hookrelay Redis"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # The two task security groups, for the rules both of them need.
  task_security_groups = {
    api    = aws_security_group.api.id
    worker = aws_security_group.worker.id
  }
  # 443 is always open for the worker: Fargate pulls the image and fetches
  # secrets through the task's own network interface.
  worker_egress_ports = toset([for p in distinct(concat([443], var.worker_egress_ports)) : tostring(p)])
}

# --- load balancer: the only thing reachable from outside the VPC ---------

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}, redirected to HTTPS by the listener"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "to the API tasks"
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 4000
  to_port                      = 4000
}

# --- API ------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 4000
  to_port                      = 4000
}

resource "aws_vpc_security_group_egress_rule" "api_https" {
  security_group_id = aws_security_group.api.id
  description       = "image pull, Secrets Manager, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- worker: reaches customer webhook endpoints, so the internet on 443 ---

resource "aws_vpc_security_group_egress_rule" "worker_internet" {
  for_each          = local.worker_egress_ports
  security_group_id = aws_security_group.worker.id
  description       = "webhook deliveries (and image pull, secrets, logs on 443)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

# --- tasks -> database and Redis -------------------------------------------

resource "aws_vpc_security_group_egress_rule" "tasks_to_db" {
  for_each                     = local.task_security_groups
  security_group_id            = each.value
  description                  = "to PostgreSQL"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_cache" {
  for_each                     = local.task_security_groups
  security_group_id            = each.value
  description                  = "to Redis"
  referenced_security_group_id = aws_security_group.cache.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  for_each                     = local.task_security_groups
  security_group_id            = aws_security_group.db.id
  description                  = "from the ${each.key} tasks"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_tasks" {
  for_each                     = local.task_security_groups
  security_group_id            = aws_security_group.cache.id
  description                  = "from the ${each.key} tasks"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}
