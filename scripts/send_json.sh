#!/bin/bash
# Test script for JSON payload

if [ -z "$API_URL" ]; then
    echo "Error: API_URL environment variable not set"
    echo "Usage: export API_URL=https://your-api-endpoint.com && ./send_json.sh"
    exit 1
fi

echo "Sending JSON payload to: $API_URL/ingest"
echo "========================================"

curl -X POST "$API_URL/ingest" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "acme",
    "log_id": "log-001",
    "text": "User 555-0199 accessed /api/login at 2023-10-27"
  }' \
  -w "\n\nHTTP Status: %{http_code}\n" \
  -v

echo ""
echo "✅ JSON request sent"
