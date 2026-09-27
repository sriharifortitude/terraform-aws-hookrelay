resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset(["api", "worker", "migrate"])
  name              = "/ecs/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

locals {
  secrets = [
    { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
    { name = "REDIS_URL", valueFrom = aws_secretsmanager_secret.redis_url.arn },
    # env.ts validates ADMIN_API_KEY at startup in every process, so the
    # worker needs it too even though it never uses it.
    { name = "ADMIN_API_KEY", valueFrom = aws_secretsmanager_secret.admin_api_key.arn },
  ]

  environment = [
    { name = "NODE_ENV", value = "production" },
    { name = "PORT", value = "4000" },
    # Never configurable here: in production, webhook endpoints must be
    # https and must not resolve to private address space.
    { name = "ALLOW_INSECURE_ENDPOINTS", value = "false" },
  ]

  # The image runs as a non-root user; the root filesystem is read-only and
  # /tmp is the only writable path, backed by task ephemeral storage
  # (Fargate has no tmpfs).
  hardening = {
    readonlyRootFilesystem = true
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
  }

  log_config = { for k, g in aws_cloudwatch_log_group.this : k => {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = g.name
      "awslogs-region"        = data.aws_region.current.region
      "awslogs-stream-prefix" = k
    }
  } }
}

data "aws_region" "current" {}

# Migrations run as a non-essential container ahead of the API in the same
# task: the API container starts only once migrate exits 0. Tasks starting
# together race, and Prisma's migrate deploy takes a Postgres advisory lock
# so only one applies anything. docs/adr/0002.
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    merge(local.hardening, {
      name             = "migrate"
      image            = var.image
      essential        = false
      command          = ["node_modules/.bin/prisma", "migrate", "deploy"]
      secrets          = [local.secrets[0]]
      environment      = []
      logConfiguration = local.log_config["migrate"]
    }),
    merge(local.hardening, {
      name             = "api"
      image            = var.image
      essential        = true
      portMappings     = [{ containerPort = 4000, protocol = "tcp" }]
      dependsOn        = [{ containerName = "migrate", condition = "SUCCESS" }]
      secrets          = local.secrets
      environment      = local.environment
      stopTimeout      = 30
      logConfiguration = local.log_config["api"]
    }),
  ])

  tags = local.tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    merge(local.hardening, {
      name             = "worker"
      image            = var.image
      essential        = true
      command          = ["node", "dist/worker/main.js"]
      secrets          = local.secrets
      environment      = local.environment
      stopTimeout      = 60 # let in-flight deliveries finish; the worker closes on SIGTERM
      logConfiguration = local.log_config["worker"]
    }),
  ])

  tags = local.tags
}

resource "aws_ecs_service" "api" {
  name                              = "api"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = var.api_desired_count
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 120 # includes running migrations
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 4000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = local.tags

  depends_on = [aws_lb_listener.https]
}

resource "aws_ecs_service" "worker" {
  name                   = "worker"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.worker.arn
  desired_count          = var.worker_desired_count
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = false
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = local.tags
}
