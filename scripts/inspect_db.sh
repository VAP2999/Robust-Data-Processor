#!/bin/bash
# Script to inspect DynamoDB table and verify tenant isolation

if [ -z "$TABLE_NAME" ]; then
    TABLE_NAME="robust-data-processor-processed-logs"
fi

if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-east-1"
fi

echo "Inspecting DynamoDB table: $TABLE_NAME"
echo "Region: $AWS_REGION"
echo "========================================"
echo ""

# Function to query logs for a specific tenant
query_tenant() {
    local tenant_id=$1
    echo "📊 Querying logs for tenant: $tenant_id"
    echo "---"
    
    aws dynamodb query \
        --table-name "$TABLE_NAME" \
        --region "$AWS_REGION" \
        --key-condition-expression "tenant_id = :tid" \
        --expression-attribute-values "{\":tid\":{\"S\":\"$tenant_id\"}}" \
        --max-items 10 \
        --output json | jq -r '.Items[] | {
            tenant_id: .tenant_id.S,
            log_id: .log_id.S,
            source: .source.S,
            processed_at: .processed_at.S,
            original_text: .original_text.S[0:50] + "...",
            modified_data: .modified_data.S[0:50] + "..."
        }'
    
    echo ""
}

# Query for different tenants
echo "🔍 Tenant Isolation Check"
echo "=========================="
echo ""

query_tenant "acme"
query_tenant "beta_inc"
query_tenant "load_test"
query_tenant "healthcheck"

echo ""
echo "📈 Table Statistics"
echo "==================="
aws dynamodb describe-table \
    --table-name "$TABLE_NAME" \
    --region "$AWS_REGION" \
    --output json | jq -r '{
        ItemCount: .Table.ItemCount,
        TableSizeBytes: .Table.TableSizeBytes,
        BillingMode: .Table.BillingModeSummary.BillingMode
    }'

echo ""
echo "✅ Inspection complete"
echo ""
echo "To verify tenant isolation:"
echo "  - Each tenant's data should be physically separated by partition key"
echo "  - acme data should not appear when querying beta_inc"
