# Step 2.7: two Fargate tasks that run only the Datadog Agent. Same image, same network.
# The only difference is how the Agent gets its API key:
#
#   A (deploy-time): ECS "secrets" injects the key as DD_API_KEY when the task starts.
#                    The value never changes while the task runs (AWS docs: rotation is not
#                    picked up; launch a new task or force a new deployment).
#   B (runtime):     DD_API_KEY=ENC[...] and the Agent's aws.secrets backend reads the key
#                    itself with the task role, and re-reads it on a timer and after a 403.
#
# Turn on for a test session:  -var ecs_enabled=true   (desired count 1 per service, else 0)

locals {
  dd_agent_common_env = [
    { name = "DD_SITE", value = "datadoghq.eu" },
    { name = "ECS_FARGATE", value = "true" },
    { name = "DD_ENV", value = "lab" },
  ]

  ecs_variants = {
    a = {
      task_role_arn = null # the Agent never calls AWS APIs itself
      secrets = [
        # Format: <secret ARN>:<json key>:<version stage>:<version id>. Empty = AWSCURRENT.
        { name = "DD_API_KEY", valueFrom = "${module.datadog_secrets.api_key_secret_arn}:apiKey::" },
      ]
      env = [
        { name = "DD_TAGS", value = "poc:poc-02 variant:ecs-a" },
      ]
    }
    b = {
      task_role_arn = module.consumer_access.ecs_task_role_arn
      secrets       = []
      env = [
        { name = "DD_TAGS", value = "poc:poc-02 variant:ecs-b" },
        # Secret NAME, not ARN: the same task definition works in every account.
        { name = "DD_API_KEY", value = "ENC[poc-02/datadog-api-key;apiKey]" },
        { name = "DD_SECRET_BACKEND_TYPE", value = "aws.secrets" },
        { name = "DD_SECRET_BACKEND_CONFIG", value = jsonencode({ aws_session = { aws_region = var.region } }) },
        # Seconds (Agent 7.67+). Lab: short so rotation tests move fast. EC2 ref host uses 3600.
        { name = "DD_SECRET_REFRESH_INTERVAL", value = tostring(var.ecs_secret_refresh_seconds) },
        # Minutes (Agent 7.74+): re-read the secret soon after a 403.
        { name = "DD_SECRET_REFRESH_ON_API_KEY_FAILURE_INTERVAL", value = "10" },
      ]
    }
  }
}

resource "aws_ecs_cluster" "lab" {
  name = "poc-02-lab"

  setting {
    name  = "containerInsights"
    value = "disabled" # cost: not needed, the Agent reports task metrics
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/poc-02-dd"
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "dd" {
  for_each = local.ecs_variants

  family                   = "poc-02-dd-ecs-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = module.consumer_access.ecs_execution_role_arn
  task_role_arn            = each.value.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name        = "datadog-agent"
      image       = var.dd_agent_image
      essential   = true
      environment = concat(local.dd_agent_common_env, each.value.env)
      secrets     = each.value.secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs-${each.key}"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "dd" {
  for_each = local.ecs_variants

  name             = "poc-02-dd-ecs-${each.key}"
  cluster          = aws_ecs_cluster.lab.id
  task_definition  = aws_ecs_task_definition.dd[each.key].arn
  desired_count    = var.ecs_enabled ? 1 : 0
  launch_type      = "FARGATE"
  platform_version = "1.4.0" # JSON-key secrets need 1.4.0+; pinned instead of LATEST

  network_configuration {
    subnets          = [aws_subnet.public[0].id]
    security_groups  = [aws_security_group.hosts.id] # egress 443/53 only
    assign_public_ip = true                          # no NAT: public IP to pull the image and reach Datadog
  }

  propagate_tags = "SERVICE"
  tags           = { Variant = "ecs-${each.key}" }
}

output "ecs_services" {
  value = { for k, s in aws_ecs_service.dd : k => { name = s.name, desired = s.desired_count } }
}
