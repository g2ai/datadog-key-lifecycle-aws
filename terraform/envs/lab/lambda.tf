# Step 2.6: Lambda consumer. The Datadog extension reads the key from Secrets Manager at
# start and reloads it on a timer. Extension >= v99 extracts "apiKey" from a JSON secret
# (v98 only knew "dd_api_key"), which is the format of the managed DatadogApiKey secret.

data "archive_file" "fn" {
  type        = "zip"
  output_path = "${path.module}/build/fn.zip"
  source {
    filename = "index.py"
    content  = <<-PY
      import time

      def handler(event, context):
          # A tiny bit of work so each invocation has a duration.
          time.sleep(0.05)
          return {"ok": True}
    PY
  }
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/poc-02-dd-fn"
  retention_in_days = 3
}

resource "aws_lambda_function" "dd" {
  function_name    = "poc-02-dd-fn"
  role             = module.consumer_access.lambda_role_arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 10
  memory_size      = 256

  layers = ["arn:aws:lambda:${var.region}:464622532012:layer:Datadog-Extension:${var.dd_extension_version}"]

  environment {
    variables = {
      DD_SITE                           = "datadoghq.eu"
      DD_API_KEY_SECRET_ARN             = module.datadog_secrets.api_key_secret_arn
      DD_API_KEY_SECRET_RELOAD_INTERVAL = tostring(var.dd_secret_reload_seconds)
      DD_SERVICE                        = "poc-02-dd-fn"
      DD_ENV                            = "lab"
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

# Invoke every minute while consumers are on, so the extension keeps sending and
# a dead key shows up quickly.
resource "aws_cloudwatch_event_rule" "fn_tick" {
  name                = "poc-02-dd-fn-tick"
  schedule_expression = "rate(1 minute)"
  state               = var.hosts_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "fn_tick" {
  rule = aws_cloudwatch_event_rule.fn_tick.name
  arn  = aws_lambda_function.dd.arn
}

resource "aws_lambda_permission" "fn_tick" {
  statement_id  = "AllowEventBridgeTick"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dd.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fn_tick.arn
}
