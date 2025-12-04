terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "robust-data-processor"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "robust-data-processor"
}

# DynamoDB Table for processed logs
resource "aws_dynamodb_table" "processed_logs" {
  name           = "${var.project_name}-processed-logs"
  billing_mode   = "PAY_PER_REQUEST"  # On-demand pricing for auto-scaling
  hash_key       = "tenant_id"
  range_key      = "log_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "log_id"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-processed-logs"
  }
}

# SQS Queue for message processing
resource "aws_sqs_queue" "processing_queue" {
  name                       = "${var.project_name}-processing-queue"
  visibility_timeout_seconds = 900  # 15 minutes (6x max processing time)
  message_retention_seconds  = 1209600  # 14 days
  receive_wait_time_seconds  = 20  # Long polling
  
  # Enable DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter_queue.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "${var.project_name}-processing-queue"
  }
}

# Dead Letter Queue
resource "aws_sqs_queue" "dead_letter_queue" {
  name                      = "${var.project_name}-dlq"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name = "${var.project_name}-dlq"
  }
}

# IAM Role for API Lambda
resource "aws_iam_role" "api_lambda_role" {
  name = "${var.project_name}-api-lambda-role"

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
}

# IAM Policy for API Lambda - SQS publish
resource "aws_iam_role_policy" "api_lambda_sqs_policy" {
  name = "${var.project_name}-api-lambda-sqs-policy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.processing_queue.arn
      }
    ]
  })
}

# Attach basic Lambda execution policy to API Lambda
resource "aws_iam_role_policy_attachment" "api_lambda_basic" {
  role       = aws_iam_role.api_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# IAM Role for Worker Lambda
resource "aws_iam_role" "worker_lambda_role" {
  name = "${var.project_name}-worker-lambda-role"

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
}

# IAM Policy for Worker Lambda - SQS + DynamoDB
resource "aws_iam_role_policy" "worker_lambda_policy" {
  name = "${var.project_name}-worker-lambda-policy"
  role = aws_iam_role.worker_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.processing_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.processed_logs.arn
      }
    ]
  })
}

# Attach basic Lambda execution policy to Worker Lambda
resource "aws_iam_role_policy_attachment" "worker_lambda_basic" {
  role       = aws_iam_role.worker_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Archive API Lambda code
data "archive_file" "api_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../api"
  output_path = "${path.module}/api_lambda.zip"
}

# API Lambda Function
resource "aws_lambda_function" "api_lambda" {
  filename         = data.archive_file.api_lambda_zip.output_path
  function_name    = "${var.project_name}-api"
  role            = aws_iam_role.api_lambda_role.arn
  handler         = "handler.lambda_handler"
  source_code_hash = data.archive_file.api_lambda_zip.output_base64sha256
  runtime         = "python3.11"
  timeout         = 30
  memory_size     = 512

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.processing_queue.url
    }
  }

  tags = {
    Name = "${var.project_name}-api"
  }
}

# CloudWatch Log Group for API Lambda
resource "aws_cloudwatch_log_group" "api_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.api_lambda.function_name}"
  retention_in_days = 7
}

# Archive Worker Lambda code
data "archive_file" "worker_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../worker"
  output_path = "${path.module}/worker_lambda.zip"
}

# Worker Lambda Function
resource "aws_lambda_function" "worker_lambda" {
  filename         = data.archive_file.worker_lambda_zip.output_path
  function_name    = "${var.project_name}-worker"
  role            = aws_iam_role.worker_lambda_role.arn
  handler         = "handler.lambda_handler"
  source_code_hash = data.archive_file.worker_lambda_zip.output_base64sha256
  runtime         = "python3.11"
  timeout         = 900  # 15 minutes max
  memory_size     = 1024


  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.processed_logs.name
    }
  }

  tags = {
    Name = "${var.project_name}-worker"
  }
}

# CloudWatch Log Group for Worker Lambda
resource "aws_cloudwatch_log_group" "worker_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.worker_lambda.function_name}"
  retention_in_days = 7
}

# SQS Event Source Mapping for Worker Lambda
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.processing_queue.arn
  function_name    = aws_lambda_function.worker_lambda.arn
  batch_size       = 10
  
  # Enable partial batch response
  function_response_types = ["ReportBatchItemFailures"]
  
  # Scale configuration
  scaling_config {
    maximum_concurrency = 100
  }
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["*"]
  }
}

# API Gateway Integration with Lambda
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_lambda.invoke_arn
  payload_format_version = "2.0"
}

# API Gateway Route
resource "aws_apigatewayv2_route" "ingest_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /ingest"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# API Gateway Stage
resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "/aws/apigateway/${var.project_name}-api"
  retention_in_days = 7
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# Outputs
output "api_endpoint" {
  description = "Public API endpoint URL"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

output "api_invoke_url" {
  description = "Full invoke URL for the API"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/ingest"
}

output "sqs_queue_url" {
  description = "SQS Queue URL"
  value       = aws_sqs_queue.processing_queue.url
}

output "sqs_dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = aws_sqs_queue.dead_letter_queue.url
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.processed_logs.name
}

output "api_lambda_name" {
  description = "API Lambda function name"
  value       = aws_lambda_function.api_lambda.function_name
}

output "worker_lambda_name" {
  description = "Worker Lambda function name"
  value       = aws_lambda_function.worker_lambda.function_name
}
