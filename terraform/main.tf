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

# S3 Bucket for Video Inputs
resource "aws_s3_bucket" "video_input" {
  bucket = "video-input-gvill005-devops"

  tags = {
    Name        = "Video Input Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for JSON Outputs
resource "aws_s3_bucket" "json_output" {
  bucket = "json-output-gvill005-devops"

  tags = {
    Name        = "JSON Output Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for Logs
resource "aws_s3_bucket" "logs" {
  bucket = "logs-gvill005-devops"

  tags = {
    Name        = "Processing Logs Bucket"
    Project     = "DevOps Video Pipeline"
  }
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

# Lambda Function
resource "aws_lambda_function" "video_processor" {
  function_name = "video-processor"
  role          = aws_iam_role.lambda_execution.arn
  package_type  = "Image"
  image_uri     = "602600555553.dkr.ecr.us-west-2.amazonaws.com/video-processor:v4"
  timeout       = 900  # 15 minutes (max for Lambda)
  memory_size   = 3008  # 10GB (max for Lambda)

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

# Outputs
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