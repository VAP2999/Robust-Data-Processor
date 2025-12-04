#!/bin/bash
# Test script for text/plain payload

if [ -z "$API_URL" ]; then
    echo "Error: API_URL environment variable not set"
    echo "Usage: export API_URL=https://your-api-endpoint.com && ./send_text.sh"
    exit 1
fi

echo "Sending text/plain payload to: $API_URL/ingest"
echo "=============================================="

curl -X POST "$API_URL/ingest" \
  -H "Content-Type: text/plain" \
  -H "X-Tenant-ID: beta_inc" \
  --data 'Error - 555-0100 - NullPointerException at module X' \
  -w "\n\nHTTP Status: %{http_code}\n" \
  -v

echo ""
echo "✅ Text request sent"
