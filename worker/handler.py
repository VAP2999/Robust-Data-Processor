"""
Worker Lambda Handler - Processes messages from SQS
Simulates heavy processing, redacts phone numbers, and stores in DynamoDB
"""
import json
import boto3
import logging
import re
import time
from datetime import datetime
from typing import Dict, Any

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
dynamodb = boto3.resource('dynamodb')
TABLE_NAME = None
table = None

def get_dynamodb_table():
    """Get DynamoDB table from environment"""
    import os
    global TABLE_NAME, table
    if TABLE_NAME is None:
        TABLE_NAME = os.environ.get('DYNAMODB_TABLE_NAME')
        if not TABLE_NAME:
            raise ValueError("DYNAMODB_TABLE_NAME environment variable not set")
        table = dynamodb.Table(TABLE_NAME)
    return table


def redact_phone_numbers(text: str) -> str:
    """
    Redact phone numbers from text
    Matches common phone number patterns:
    - 555-0199 (7 digits)
    - 555-555-1234 (10 digits)
    - (555) 555-1234 (10 digits with parentheses)
    """
    # Order matters - match longer patterns first
    patterns = [
        r'\(\d{3}\)\s?\d{3}[-.]?\d{4}',  # (555) 555-1234
        r'\b\d{3}[-.\s]\d{3}[-.\s]\d{4}\b',  # 555-555-1234
        r'\b\d{3}[-.]?\d{4}\b',  # 555-0199
    ]
    
    redacted = text
    for pattern in patterns:
        redacted = re.sub(pattern, '[REDACTED]', redacted)
    
    return redacted


def simulate_heavy_processing(text: str) -> None:
    """
    Simulate CPU-bound work: sleep 0.05s per character
    """
    processing_time = len(text) * 0.05
    logger.info(json.dumps({
        'event': 'processing_started',
        'text_length': len(text),
        'estimated_time': processing_time
    }))
    time.sleep(processing_time)


def store_processed_log(message: Dict[str, Any], modified_data: str, attempt: int, worker_id: str) -> bool:
    """
    Store processed log in DynamoDB with tenant isolation
    """
    try:
        table = get_dynamodb_table()
        
        item = {
            'tenant_id': message['tenant_id'],  # Partition key
            'log_id': message['log_id'],  # Sort key
            'source': message['source'],
            'original_text': message['normalized_text'],
            'modified_data': modified_data,
            'processed_at': datetime.utcnow().isoformat() + 'Z',
            'received_at': message['received_at'],
            'request_id': message['request_id'],
            'worker_id': worker_id,
            'attempt': attempt
        }
        
        # Idempotent write - DynamoDB will overwrite if same PK+SK exists
        table.put_item(Item=item)
        
        logger.info(json.dumps({
            'event': 'log_stored',
            'tenant_id': message['tenant_id'],
            'log_id': message['log_id'],
            'attempt': attempt
        }))
        
        return True
        
    except Exception as e:
        logger.error(json.dumps({
            'event': 'storage_failed',
            'tenant_id': message.get('tenant_id'),
            'log_id': message.get('log_id'),
            'error': str(e),
            'error_type': type(e).__name__
        }))
        return False


def process_message(message_body: Dict[str, Any], receipt_handle: str, worker_id: str, attempt: int) -> bool:
    """
    Process a single message from SQS
    Returns True if successful, False if should retry
    """
    try:
        tenant_id = message_body.get('tenant_id')
        log_id = message_body.get('log_id')
        normalized_text = message_body.get('normalized_text')
        
        logger.info(json.dumps({
            'event': 'processing_message',
            'tenant_id': tenant_id,
            'log_id': log_id,
            'attempt': attempt
        }))
        
        # Simulate heavy processing
        simulate_heavy_processing(normalized_text)
        
        # Redact phone numbers
        modified_data = redact_phone_numbers(normalized_text)
        
        # Store in DynamoDB
        success = store_processed_log(message_body, modified_data, attempt, worker_id)
        
        if success:
            logger.info(json.dumps({
                'event': 'message_processed',
                'tenant_id': tenant_id,
                'log_id': log_id
            }))
            return True
        else:
            return False
            
    except Exception as e:
        logger.error(json.dumps({
            'event': 'processing_error',
            'tenant_id': message_body.get('tenant_id'),
            'log_id': message_body.get('log_id'),
            'error': str(e),
            'error_type': type(e).__name__
        }))
        return False


def lambda_handler(event, context):
    """
    Lambda handler for SQS trigger
    Processes batch of messages from SQS
    """
    worker_id = context.function_name if context else 'local-worker'
    
    logger.info(json.dumps({
        'event': 'batch_received',
        'record_count': len(event.get('Records', []))
    }))
    
    # Track success/failure for batch processing
    batch_item_failures = []
    
    for record in event.get('Records', []):
        try:
            # Parse message body
            message_body = json.loads(record['body'])
            receipt_handle = record['receiptHandle']
            
            # Get approximate receive count (attempt number)
            attributes = record.get('attributes', {})
            attempt = int(attributes.get('ApproximateReceiveCount', 1))
            
            # Process message
            success = process_message(message_body, receipt_handle, worker_id, attempt)
            
            # If failed, add to batch failures for retry
            if not success:
                batch_item_failures.append({
                    'itemIdentifier': record['messageId']
                })
                
        except Exception as e:
            logger.error(json.dumps({
                'event': 'record_processing_error',
                'error': str(e),
                'error_type': type(e).__name__,
                'message_id': record.get('messageId')
            }))
            # Add to failures for retry
            batch_item_failures.append({
                'itemIdentifier': record['messageId']
            })
    
    # Return batch item failures for partial batch responses
    # SQS will retry only the failed messages
    return {
        'batchItemFailures': batch_item_failures
    }
