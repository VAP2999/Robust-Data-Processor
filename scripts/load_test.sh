#!/bin/bash
# Load test script - sends mixed JSON and text payloads
# Simulates ~1000 RPM

if [ -z "$API_URL" ]; then
    echo "Error: API_URL environment variable not set"
    echo "Usage: export API_URL=https://your-api-endpoint.com && ./load_test.sh"
    exit 1
fi

# Check if hey is installed
if ! command -v hey &> /dev/null; then
    echo "Installing 'hey' load testing tool..."
    go install github.com/rakyll/hey@latest
    export PATH=$PATH:$(go env GOPATH)/bin
fi

echo "Running load test against: $API_URL/ingest"
echo "==========================================="
echo "Target: 1000 requests per minute (~17 RPS)"
echo "Duration: 60 seconds"
echo ""

# Create test payloads
cat > /tmp/json_payload.json << 'EOF'
{"tenant_id":"load_test","log_id":"load-{{.RequestNumber}}","text":"Load test message {{.RequestNumber}} with phone 555-0199"}
EOF

# Test with JSON payloads
echo "🚀 Starting load test with JSON payloads..."
hey -z 60s -q 17 -m POST \
  -H "Content-Type: application/json" \
  -D /tmp/json_payload.json \
  "$API_URL/ingest"

echo ""
echo "✅ Load test completed"
echo ""
echo "Expected result: Most requests should return 202 Accepted"
echo "Check CloudWatch Logs and DynamoDB for processed results"

# Cleanup
rm -f /tmp/json_payload.json
