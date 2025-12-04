# Robust Data Processor

A production-grade, multi-tenant, event-driven data ingestion pipeline built on AWS serverless architecture.

## 🏗️ Architecture

```
┌─────────────────┐
│   Client/Curl   │
└────────┬────────┘
         │ POST /ingest
         ▼
┌─────────────────────────────────────────┐
│  API Gateway (HTTP API)                  │
│  - Public endpoint                       │
│  - Routes to API Lambda                  │
└────────┬────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  API Lambda (Python 3.11)               │
│  - Validates JSON/TXT payloads          │
│  - Normalizes to flat format            │
│  - Publishes to SQS                     │
│  - Returns 202 Accepted immediately     │
└────────┬────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  SQS Queue                              │
│  - Message broker                        │
│  - Visibility timeout: 15 min           │
│  - Max retry: 5 attempts                │
│  - Dead Letter Queue enabled            │
└────────┬────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  Worker Lambda (Python 3.11)            │
│  - Triggered by SQS                     │
│  - Simulates heavy processing           │
│  - Redacts phone numbers                │
│  - Stores in DynamoDB                   │
└────────┬────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  DynamoDB                               │
│  - Partition Key: tenant_id             │
│  - Sort Key: log_id                     │
│  - Pay-per-request billing              │
│  - Tenant isolation enforced            │
└─────────────────────────────────────────┘
```

## 🎯 Key Features

- **Multi-Tenant Isolation**: Physical separation via DynamoDB partition keys
- **Event-Driven**: Asynchronous processing via SQS
- **Fault Tolerant**: Automatic retries with Dead Letter Queue
- **Idempotent**: Safe retries using log_id as primary key
- **Scalable**: Auto-scales to 1000+ RPM
- **Serverless**: Pay-per-use, scales to zero
- **Observable**: Structured JSON logging, CloudWatch metrics

## 📋 Requirements

- AWS Account with CLI configured
- Terraform >= 1.0
- Python 3.11
- curl (for testing)
- jq (for JSON parsing)

## 🚀 Deployment

### Option 1: Terraform (Recommended)

```bash
# Navigate to infrastructure directory
cd infra

# Initialize Terraform
terraform init

# Review planned changes
terraform plan

# Deploy infrastructure
terraform apply

# Get the API endpoint
terraform output api_invoke_url
```

### Option 2: Manual AWS Console Setup

See [docs/manual-deployment.md](docs/manual-deployment.md) for step-by-step console instructions.

## 🧪 Testing

### 1. Health Check

```bash
export API_URL="https://your-api-id.execute-api.us-east-1.amazonaws.com"
./scripts/healthcheck.sh
```

### 2. Send JSON Payload

```bash
curl -X POST "$API_URL/ingest" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "acme",
    "log_id": "log-001",
    "text": "User 555-0199 accessed /api/login at 2023-10-27"
  }'
```

Expected response:
```json
{
  "status": "accepted",
  "log_id": "log-001",
  "request_id": "uuid-here"
}
```

### 3. Send Text Payload

```bash
curl -X POST "$API_URL/ingest" \
  -H "Content-Type: text/plain" \
  -H "X-Tenant-ID: beta_inc" \
  --data 'Error - 555-0100 - NullPointerException at module X'
```

### 4. Load Test (~1000 RPM)

```bash
./scripts/load_test.sh
```

### 5. Inspect Database

```bash
export TABLE_NAME="robust-data-processor-processed-logs"
export AWS_REGION="us-east-1"
./scripts/inspect_db.sh
```

## 🔍 Observability

### View API Logs

```bash
aws logs tail /aws/lambda/robust-data-processor-api --follow
```

### View Worker Logs

```bash
aws logs tail /aws/lambda/robust-data-processor-worker --follow
```

### View SQS Queue

```bash
# Main queue
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages

# Dead letter queue
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --attribute-names ApproximateNumberOfMessages
```

### Query DynamoDB by Tenant

```bash
# Query logs for tenant "acme"
aws dynamodb query \
  --table-name robust-data-processor-processed-logs \
  --key-condition-expression "tenant_id = :tid" \
  --expression-attribute-values '{":tid":{"S":"acme"}}'
```

## 🛡️ Tenant Isolation

Tenant isolation is enforced at the database level:

- **Partition Key**: `tenant_id` ensures physical separation
- **Sort Key**: `log_id` enables efficient querying per tenant
- **Schema**: `tenants/{tenant_id}/processed_logs/{log_id}`

Example:
```
acme/log-001        → Partition: acme
acme/log-002        → Partition: acme
beta_inc/log-001    → Partition: beta_inc (completely separate)
```

To verify isolation:
```bash
# Query tenant A
aws dynamodb query --table-name <table> \
  --key-condition-expression "tenant_id = :tid" \
  --expression-attribute-values '{":tid":{"S":"acme"}}'

# Query tenant B - will NOT see tenant A's data
aws dynamodb query --table-name <table> \
  --key-condition-expression "tenant_id = :tid" \
  --expression-attribute-values '{":tid":{"S":"beta_inc"}}'
```

## 🔄 Retry & Fault Tolerance

### How Retries Work

1. **Worker Processing Fails**: Lambda throws exception
2. **SQS Retry**: Message becomes visible again (visibility timeout)
3. **Attempt Count**: SQS tracks `ApproximateReceiveCount`
4. **Max Attempts**: After 5 failed attempts, message → DLQ
5. **Idempotency**: Same `log_id` overwrites previous attempt

### Dead Letter Queue

Failed messages (after 5 retries) move to DLQ for investigation:

```bash
# Check DLQ
aws sqs receive-message \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --max-number-of-messages 10
```

### Simulating Worker Crash

See [docs/chaos_demo.md](docs/chaos_demo.md) for instructions on:
- Forcing worker failures
- Observing retry behavior
- Verifying DLQ handling

## 📊 API Contract

### Endpoint

```
POST /ingest
```

### Scenario 1: JSON Payload

**Headers:**
```
Content-Type: application/json
```

**Body:**
```json
{
  "tenant_id": "acme",
  "log_id": "123",
  "text": "User 555-0199 accessed /api/..."
}
```

### Scenario 2: Text Payload

**Headers:**
```
Content-Type: text/plain
X-Tenant-ID: acme
```

**Body:**
```
User 555-0199 accessed /api/...
```

### Success Response (202 Accepted)

```json
{
  "status": "accepted",
  "log_id": "uuid-or-provided-id",
  "request_id": "uuid"
}
```

### Error Responses

**400 Bad Request:**
```json
{
  "error": "Bad Request",
  "message": "tenant_id is required"
}
```

**500 Internal Server Error:**
```json
{
  "error": "Internal Server Error",
  "message": "Failed to publish message to queue"
}
```

## 🧩 Database Schema

### DynamoDB Table: `processed_logs`

| Field | Type | Description |
|-------|------|-------------|
| `tenant_id` | String (PK) | Partition key for tenant isolation |
| `log_id` | String (SK) | Sort key, unique per tenant |
| `source` | String | `json_upload` or `text_upload` |
| `original_text` | String | Original normalized text |
| `modified_data` | String | Text with phone numbers redacted |
| `processed_at` | String | ISO8601 UTC timestamp |
| `received_at` | String | When API received request |
| `request_id` | String | Request tracking ID |
| `worker_id` | String | Lambda function name |
| `attempt` | Number | Processing attempt count |

### Example Document

```json
{
  "tenant_id": "acme",
  "log_id": "log-001",
  "source": "json_upload",
  "original_text": "User 555-0199 accessed /api/login",
  "modified_data": "User [REDACTED] accessed /api/login",
  "processed_at": "2023-10-27T10:00:00Z",
  "received_at": "2023-10-27T09:59:58Z",
  "request_id": "uuid-here",
  "worker_id": "robust-data-processor-worker",
  "attempt": 1
}
```

## 🧪 Unit Tests

Run unit tests for normalization and redaction:

```bash
cd tests
pip install -r requirements.txt
pytest test_handlers.py -v
```

Tests cover:
- Phone number redaction (multiple formats)
- Payload normalization
- Idempotency logic
- Tenant isolation

## 📈 Performance

### Capacity

- **API**: Handles 1000+ RPM (Lambda concurrent executions: 1000)
- **Worker**: Max 100 concurrent executions (configurable)
- **SQS**: Virtually unlimited throughput
- **DynamoDB**: Auto-scales with on-demand billing

### Latency

- **API Response**: <100ms (returns 202 immediately)
- **Processing Time**: 0.05s per character + DynamoDB write
- **End-to-End**: Varies by message size (100 chars = ~5s processing)

## 🔒 Security Considerations

⚠️ **Note**: This deployment has **NO AUTHENTICATION** as per spec requirements.

**Production Recommendations:**
- Enable API Gateway authentication (API keys, JWT, IAM)
- Use VPC endpoints for private access
- Enable AWS WAF for DDoS protection
- Implement rate limiting per tenant
- Encrypt data at rest (DynamoDB encryption enabled by default)
- Use AWS Secrets Manager for sensitive configuration

## 🗑️ Cleanup

To destroy all AWS resources:

```bash
cd infra
terraform destroy
```

## 📚 Additional Documentation

- [Manual Deployment Guide](docs/manual-deployment.md)
- [Chaos Testing Instructions](docs/chaos_demo.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

## 🏷️ Project Structure

```
robust-data-processor/
├── api/
│   ├── handler.py          # API Lambda function
│   └── requirements.txt
├── worker/
│   ├── handler.py          # Worker Lambda function
│   └── requirements.txt
├── infra/
│   └── main.tf             # Terraform configuration
├── scripts/
│   ├── healthcheck.sh      # Test endpoint health
│   ├── send_json.sh        # Send JSON payload
│   ├── send_text.sh        # Send text payload
│   ├── load_test.sh        # Load testing
│   └── inspect_db.sh       # Query DynamoDB
├── tests/
│   ├── test_handlers.py    # Unit tests
│   └── requirements.txt
├── docs/
│   ├── manual-deployment.md
│   ├── chaos_demo.md
│   └── troubleshooting.md
└── README.md
```

## 📝 License

MIT License - See LICENSE file for details

## 👥 Author

Built as a take-home assignment for Memory Machines Backend Engineer position.
