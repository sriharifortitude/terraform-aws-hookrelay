locals {
  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  secret_arns = [
    aws_secretsmanager_secret.database_url.arn,
    aws_secretsmanager_secret.redis_url.arn,
    aws_secretsmanager_secret.admin_api_key.arn,
  ]
}

# Used by ECS itself, before the container starts: pull the image, fetch the
# three secrets, write logs. Scoped to exactly those resources; the managed
# AmazonECSTaskExecutionRolePolicy is not attached because it grants ECR
# pulls from every repository in the account.
resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = local.ecs_tasks_trust
  tags               = local.tags
}

resource "aws_iam_role_policy" "execution" {
  name = "run-hookrelay"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadOwnSecrets"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = local.secret_arns
        },
        {
          Sid      = "DecryptOwnSecrets"
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = aws_kms_key.this.arn
        },
        {
          Sid      = "WriteOwnLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = [for g in aws_cloudwatch_log_group.this : "${g.arn}:*"]
        },
      ],
      [for s in local.ecr_statements : s if length(var.ecr_repository_arns) > 0],
    )
  })
}

locals {
  ecr_statements = [
    {
      Sid      = "PullImage"
      Effect   = "Allow"
      Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      Resource = var.ecr_repository_arns
    },
    {
      # GetAuthorizationToken has no resource-level permissions in IAM;
      # "*" is the only value AWS accepts for it.
      Sid      = "EcrLogin"
      Effect   = "Allow"
      Action   = "ecr:GetAuthorizationToken"
      Resource = "*"
    },
  ]
}

# The role hookrelay's own code runs as. hookrelay calls no AWS API, so it
# has no permissions at all, and ECS Exec is off (see ecs.tf).
resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = local.ecs_tasks_trust
  tags               = local.tags
}
