#!/bin/bash
# Quick deployment script for Robust Data Processor

set -e  # Exit on error

echo "🚀 Robust Data Processor - Quick Deploy"
echo "========================================"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found. Install from: https://aws.amazon.com/cli/"
    exit 1
fi
echo "✅ AWS CLI found"

# Check Terraform
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform not found. Install from: https://www.terraform.io/downloads"
    exit 1
fi
echo "✅ Terraform found"

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured. Run: aws configure"
    exit 1
fi
echo "✅ AWS credentials configured"

# Get AWS account info
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_DEFAULT_REGION:-us-east-1}
echo "   Account: $AWS_ACCOUNT"
echo "   Region: $AWS_REGION"
echo ""

# Confirm deployment
read -p "🔧 Deploy to AWS account $AWS_ACCOUNT in $AWS_REGION? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi
echo ""

# Deploy with Terraform
echo "🏗️  Deploying infrastructure..."
cd infra

# Initialize Terraform
echo "   Initializing Terraform..."
terraform init

# Plan deployment
echo "   Planning deployment..."
terraform plan -out=tfplan

# Apply deployment
echo "   Applying changes..."
terraform apply -auto-approve tfplan

# Get outputs
echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Deployment Summary"
echo "===================="
API_URL=$(terraform output -raw api_invoke_url)
TABLE_NAME=$(terraform output -raw dynamodb_table_name)
QUEUE_URL=$(terraform output -raw sqs_queue_url)

echo "API Endpoint: $API_URL"
echo "DynamoDB Table: $TABLE_NAME"
echo "SQS Queue: $QUEUE_URL"
echo ""

# Test endpoint
echo "🧪 Testing endpoint..."
cd ..
export API_URL

# Run health check
if bash scripts/healthcheck.sh; then
    echo ""
    echo "🎉 Success! Your API is live and ready."
    echo ""
    echo "📚 Next Steps:"
    echo "   1. Test with JSON: ./scripts/send_json.sh"
    echo "   2. Test with text: ./scripts/send_text.sh"
    echo "   3. Run load test: ./scripts/load_test.sh"
    echo "   4. Inspect data: ./scripts/inspect_db.sh"
    echo ""
    echo "🔗 Save this API endpoint:"
    echo "   export API_URL=\"$API_URL\""
else
    echo "⚠️  Deployment succeeded but health check failed."
    echo "Check CloudWatch logs for errors."
fi

echo ""
echo "📖 Documentation: See README.md for full guide"
echo "🗑️  To destroy: cd infra && terraform destroy"
