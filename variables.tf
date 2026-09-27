variable "name" {
  description = "Prefix for every resource name. Short, because ALB and target group names are capped at 32 characters."
  type        = string
  default     = "hookrelay"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.name))
    error_message = "name must be 2-20 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for the tasks, the database and Redis. No route to an internet gateway; outbound through NAT."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets in different availability zones: Multi-AZ RDS and ElastiCache failover both need them."
  }
}

variable "public_subnet_ids" {
  description = "Subnets for the load balancer."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An application load balancer needs subnets in at least two availability zones."
  }
}

variable "image" {
  description = "hookrelay container image, pinned to a version tag or a digest, e.g. ghcr.io/sriharifortitude/hookrelay:0.2.0."
  type        = string

  validation {
    # A moving tag means two tasks in the same service can run different
    # code, and a rollback redeploys whatever the tag points at today.
    condition     = can(regex("(@sha256:[0-9a-f]{64}|:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$", var.image)) && !endswith(var.image, ":latest")
    error_message = "image must be pinned to a version tag or an @sha256 digest, and not :latest."
  }
}

variable "ecr_repository_arns" {
  description = "ECR repositories the image may be pulled from. Leave empty for a public registry such as ghcr.io; ECR pull permissions are only granted when this is set."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener."
  type        = string
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 ranges allowed to reach the load balancer on 80 and 443. The default is the internet: webhook publishers call this API from wherever they run."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "api_desired_count" {
  description = "API tasks. Two or more keeps the API up through a task replacement or an AZ outage."
  type        = number
  default     = 2
}

variable "worker_desired_count" {
  description = "Delivery worker tasks. Each runs 16 deliveries concurrently."
  type        = number
  default     = 1
}

variable "api_cpu" {
  type    = number
  default = 512
}

variable "api_memory" {
  type    = number
  default = 1024
}

variable "worker_cpu" {
  type    = number
  default = 512
}

variable "worker_memory" {
  type    = number
  default = 1024
}

variable "worker_egress_ports" {
  description = "Ports the worker may connect out to on the internet. Webhook endpoints must be https; one on a port not listed here is unreachable."
  type        = list(number)
  default     = [443]
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB; storage autoscaling grows it up to db_max_allocated_storage."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Automated backups cannot be turned off here: a delivery log nobody can restore is not a delivery log."
  }
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "deletion_protection" {
  description = "Deletion protection on the database and the load balancer. Turn off only to tear down a non-production copy."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "credentials_version" {
  description = "Bump to rotate the database password, the Redis auth token and the admin API key together, in one apply. See docs/adr/0001."
  type        = number
  default     = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
