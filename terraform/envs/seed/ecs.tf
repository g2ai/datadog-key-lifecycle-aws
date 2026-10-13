# Task definitions only. No cluster, no service, nothing runs.

# ECS needs an execution role when a task definition has secrets. No policies attached.
resource "aws_iam_role" "ecs_execution" {
  name = "${local.prefix}-ecs-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 8. COPY: key in the plain environment block
resource "aws_ecs_task_definition" "copy" {
  family                   = "${local.prefix}-copy"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:latest"
    essential = true
    environment = [
      { name = "DD_API_KEY", value = local.fake["ecs_copy"] },
      { name = "DD_SITE", value = "datadoghq.eu" }
    ]
  }])
}

# 9. REFERENCE: key injected from Secrets Manager at task start
resource "aws_ecs_task_definition" "ref" {
  family                   = "${local.prefix}-ref"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:latest"
    essential = true
    environment = [
      { name = "DD_SITE", value = "datadoghq.eu" }
    ]
    secrets = [
      { name = "DD_API_KEY", valueFrom = local.ref_secret_arn }
    ]
  }])
}
