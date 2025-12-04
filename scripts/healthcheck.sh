#!/bin/bash
# Health check script - tests if API endpoint is reachable

if [ -z "$API_URL" ]; then
    echo "Error: API_URL environment variable not set"
    echo "Usage: export API_URL=https://your-api-endpoint.com && ./healthcheck.sh"
    exit 1
fi

echo "Testing API endpoint: $API_URL/ingest"
echo "=================================="

# Test with simple JSON payload
response=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/ingest" \
  -H "Content-Type: application/json" \
  -d '{"tenant_id":"healthcheck","log_id":"test-1","text":"Health check test"}')

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

echo "HTTP Status: $http_code"
echo "Response Body: $body"
echo ""

if [ "$http_code" -eq 202 ]; then
    echo "✅ Health check PASSED - API returned 202 Accepted"
    exit 0
else
    echo "❌ Health check FAILED - Expected 202, got $http_code"
    exit 1
fi
