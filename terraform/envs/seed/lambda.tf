# Lambda functions are never invoked and have no trigger. Only the env variables matter.

data "archive_file" "noop" {
  type        = "zip"
  output_path = "${path.module}/build/noop.zip"

  source {
    filename = "index.py"
    content  = "def handler(event, context):\n    return None\n"
  }
}

resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 6. COPY: key as an env variable
resource "aws_lambda_function" "copy" {
  function_name    = "${local.prefix}-copy"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.noop.output_path
  source_code_hash = data.archive_file.noop.output_base64sha256

  environment {
    variables = {
      DD_API_KEY = local.fake["lambda_copy"]
      DD_SITE    = "datadoghq.eu"
    }
  }
}

# 7. REFERENCE: extension reads the key from Secrets Manager
resource "aws_lambda_function" "ref" {
  function_name    = "${local.prefix}-ref"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.noop.output_path
  source_code_hash = data.archive_file.noop.output_base64sha256

  environment {
    variables = {
      DD_API_KEY_SECRET_ARN = local.ref_secret_arn
      DD_SITE               = "datadoghq.eu"
    }
  }
}
