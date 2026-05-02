# Configure AWS Provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# S3 Bucket for Video Inputs (your existing bucket)
resource "aws_s3_bucket" "video_input" {
  bucket = "video-input-gvill005-devops"

  tags = {
    Name        = "Video Input Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for JSON Outputs (your existing bucket)
resource "aws_s3_bucket" "json_output" {
  bucket = "json-output-gvill005-devops"

  tags = {
    Name        = "JSON Output Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for Logs (your existing bucket)
resource "aws_s3_bucket" "logs" {
  bucket = "logs-gvill005-devops"

  tags = {
    Name        = "Processing Logs Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# ECR Repository (you created manually, but adding Terraform config)
resource "aws_ecr_repository" "video_processor" {
  name = "video-processor"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "video-processor-ecr"
    Project = "DevOps Video Pipeline"
  }
}

resource "aws_ecr_repository_policy" "lambda_ecr_access" {
  repository = aws_ecr_repository.video_processor.name

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [
      {
        Sid = "AllowLambdaPull"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_execution" {
  name = "video-processor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "video-processor-lambda-role"
    Project = "DevOps Video Pipeline"
  }
}

# IAM Policy for S3 Access
resource "aws_iam_role_policy" "lambda_s3_access" {
  name = "lambda-s3-access-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.video_input.arn}",
          "${aws_s3_bucket.video_input.arn}/*",
          "${aws_s3_bucket.json_output.arn}",
          "${aws_s3_bucket.json_output.arn}/*",
          "${aws_s3_bucket.logs.arn}",
          "${aws_s3_bucket.logs.arn}/*"
        ]
      }
    ]
  })
}

# Bedrock permission policy (teammate's feature)
resource "aws_iam_role_policy" "lambda_bedrock_access" {
  name = "lambda-bedrock-access-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = "*"
      }
    ]
  })
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/video-processor"
  retention_in_days = 7

  tags = {
    Name    = "video-processor-lambda-logs"
    Project = "DevOps Video Pipeline"
  }
}

# IAM Policy for CloudWatch Logs
resource "aws_iam_role_policy" "lambda_cloudwatch_logs" {
  name = "lambda-cloudwatch-logs-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      }
    ]
  })
}

# Lambda Function (use your v4 image)
resource "aws_lambda_function" "video_processor" {
  function_name = "video-processor"
  role          = aws_iam_role.lambda_execution.arn
  package_type  = "Image"
  image_uri     = "602600555553.dkr.ecr.us-west-2.amazonaws.com/video-processor:v12"
  timeout       = 900  # 15 minutes (max for Lambda)
  memory_size   = 3008  # 3GB (max for Lambda)

  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.json_output.bucket
    }
  }

  tags = {
    Name    = "video-processor-lambda"
    Project = "DevOps Video Pipeline"
  }
}

# Permission for S3 to invoke Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.video_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.video_input.arn
}

# S3 Event Notification to Lambda
resource "aws_s3_bucket_notification" "video_upload_lambda" {
  bucket = aws_s3_bucket.video_input.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.video_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".mp4"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ── Chat Agent ─────────────────────────────────────────────────────────────────

# Zip the chat Lambda source
data "archive_file" "chat_lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/chat_lambda.zip"

  source {
    content  = file("${path.module}/../chat_lambda.py")
    filename = "chat_lambda.py"
  }

  source {
    content  = file("${path.module}/../SYSTEM_PROMPT.md")
    filename = "SYSTEM_PROMPT.md"
  }
}

# Chat Lambda function — reuses the video-processor role (already has Bedrock + S3 access)
resource "aws_lambda_function" "chat_agent" {
  function_name    = "chat-agent"
  role             = aws_iam_role.lambda_execution.arn
  runtime          = "python3.11"
  handler          = "chat_lambda.lambda_handler"
  filename         = data.archive_file.chat_lambda_zip.output_path
  source_code_hash = data.archive_file.chat_lambda_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.json_output.bucket
    }
  }

  tags = {
    Project = "DevOps Video Pipeline"
  }
}

# API Gateway HTTP API → chat Lambda
resource "aws_apigatewayv2_api" "chat" {
  name          = "chat-agent-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_integration" "chat" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chat_agent.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
}

resource "aws_apigatewayv2_stage" "chat" {
  api_id      = aws_apigatewayv2_api.chat.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "chat_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_agent.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

# ── Frontend S3 website ────────────────────────────────────────────────────────

resource "aws_s3_bucket" "frontend" {
  bucket = "chat-frontend-gvill005-devops"

  tags = {
    Project = "DevOps Video Pipeline"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_policy" "frontend_public" {
  bucket = aws_s3_bucket.frontend.id

  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })
}

# Upload index.html with Lambda URL injected
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"

  content = replace(
    file("${path.module}/../templates/index.html"),
    "LAMBDA_FUNCTION_URL_PLACEHOLDER",
    "${aws_apigatewayv2_api.chat.api_endpoint}/chat"
  )
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "lambda_function_name" {
  value       = aws_lambda_function.video_processor.function_name
  description = "Name of the Lambda function"
}

output "lambda_log_group" {
  value       = aws_cloudwatch_log_group.lambda.name
  description = "CloudWatch Log Group for Lambda"
}

output "input_bucket" {
  value       = aws_s3_bucket.video_input.bucket
  description = "S3 input bucket name"
}

output "output_bucket" {
  value       = aws_s3_bucket.json_output.bucket
  description = "S3 output bucket name"
}

output "ecr_repo_url" {
  value       = aws_ecr_repository.video_processor.repository_url
  description = "ECR repository URL"
}

output "chat_url" {
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
  description = "Open this URL to use the chat UI"
}

output "chat_api_endpoint" {
  value       = "${aws_apigatewayv2_api.chat.api_endpoint}/chat"
  description = "API Gateway endpoint for the chat agent"
}