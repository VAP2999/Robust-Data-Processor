"""
API Lambda Handler - POST /ingest endpoint
Handles JSON and text/plain payloads, normalizes, and publishes to SQS
"""
import json
import uuid
import boto3
import logging
import re
from datetime import datetime
from typing import Dict, Any, Tuple, Optional

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
sqs = boto3.client('sqs')
QUEUE_URL = None  # Will be set via environment variable

def get_queue_url():
    """Get SQS queue URL from environment"""
    import os
    global QUEUE_URL
    if QUEUE_URL is None:
        QUEUE_URL = os.environ.get('SQS_QUEUE_URL')
        if not QUEUE_URL:
            raise ValueError("SQS_QUEUE_URL environment variable not set")
    return QUEUE_URL


def validate_and_normalize(event: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    """
    Validate and normalize incoming request
    Returns: (normalized_message, error_response)
    """
    headers = event.get('headers', {})
    
    # Normalize header keys to lowercase
    headers = {k.lower(): v for k, v in headers.items()}
    
    content_type = headers.get('content-type', '')
    body = event.get('body', '')
    
    # Validation: check if body is empty
    if not body or body.strip() == '':
        return None, {
            'statusCode': 400,
            'body': json.dumps({
                'error': 'Bad Request',
                'message': 'Request body cannot be empty'
            }),
            'headers': {'Content-Type': 'application/json'}
        }
    
    tenant_id = None
    log_id = None
    normalized_text = None
    source = None
    
    # Handle JSON payload
    if 'application/json' in content_type:
        try:
            payload = json.loads(body)
            tenant_id = payload.get('tenant_id')
            log_id = payload.get('log_id')
            normalized_text = payload.get('text')
            source = 'json_upload'
            
            if not tenant_id:
                return None, {
                    'statusCode': 400,
                    'body': json.dumps({
                        'error': 'Bad Request',
                        'message': 'tenant_id is required in JSON payload'
                    }),
                    'headers': {'Content-Type': 'application/json'}
                }
            
            if not normalized_text:
                return None, {
                    'statusCode': 400,
                    'body': json.dumps({
                        'error': 'Bad Request',
                        'message': 'text field is required in JSON payload'
                    }),
                    'headers': {'Content-Type': 'application/json'}
                }
                
        except json.JSONDecodeError as e:
            return None, {
                'statusCode': 400,
                'body': json.dumps({
                    'error': 'Bad Request',
                    'message': f'Invalid JSON: {str(e)}'
                }),
                'headers': {'Content-Type': 'application/json'}
            }
    
    # Handle text/plain payload
    elif 'text/plain' in content_type:
        tenant_id = headers.get('x-tenant-id')
        if not tenant_id:
            return None, {
                'statusCode': 400,
                'body': json.dumps({
                    'error': 'Bad Request',
                    'message': 'X-Tenant-ID header is required for text/plain requests'
                }),
                'headers': {'Content-Type': 'application/json'}
            }
        
        normalized_text = body
        source = 'text_upload'
    
    else:
        return None, {
            'statusCode': 400,
            'body': json.dumps({
                'error': 'Bad Request',
                'message': 'Content-Type must be application/json or text/plain'
            }),
            'headers': {'Content-Type': 'application/json'}
        }
    
    # Generate IDs if missing
    if not log_id:
        log_id = str(uuid.uuid4())
    
    request_id = headers.get('x-request-id', str(uuid.uuid4()))
    
    # Create normalized message
    message = {
        'tenant_id': tenant_id,
        'log_id': log_id,
        'normalized_text': normalized_text,
        'source': source,
        'received_at': datetime.utcnow().isoformat() + 'Z',
        'request_id': request_id
    }
    
    return message, None


def publish_to_sqs(message: Dict[str, Any]) -> bool:
    """Publish normalized message to SQS queue"""
    try:
        queue_url = get_queue_url()
        response = sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(message),
            MessageAttributes={
                'tenant_id': {
                    'StringValue': message['tenant_id'],
                    'DataType': 'String'
                },
                'log_id': {
                    'StringValue': message['log_id'],
                    'DataType': 'String'
                }
            }
        )
        
        logger.info(json.dumps({
            'event': 'message_published',
            'tenant_id': message['tenant_id'],
            'log_id': message['log_id'],
            'request_id': message['request_id'],
            'message_id': response.get('MessageId')
        }))
        
        return True
        
    except Exception as e:
        logger.error(json.dumps({
            'event': 'publish_failed',
            'tenant_id': message.get('tenant_id'),
            'log_id': message.get('log_id'),
            'error': str(e)
        }))
        return False


def lambda_handler(event, context):
    """
    Lambda handler for API Gateway HTTP API
    """
    logger.info(json.dumps({
        'event': 'request_received',
        'path': event.get('rawPath'),
        'method': event.get('requestContext', {}).get('http', {}).get('method')
    }))
    
    # Only handle POST /ingest
    http_method = event.get('requestContext', {}).get('http', {}).get('method')
    path = event.get('rawPath', '')
    
    if http_method != 'POST' or path != '/ingest':
        return {
            'statusCode': 404,
            'body': json.dumps({'error': 'Not Found'}),
            'headers': {'Content-Type': 'application/json'}
        }
    
    # Validate and normalize
    message, error_response = validate_and_normalize(event)
    
    if error_response:
        logger.warning(json.dumps({
            'event': 'validation_failed',
            'status_code': error_response['statusCode']
        }))
        return error_response
    
    # Publish to SQS
    success = publish_to_sqs(message)
    
    if not success:
        logger.error(json.dumps({
            'event': 'ingest_rejected',
            'tenant_id': message['tenant_id'],
            'log_id': message['log_id']
        }))
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Internal Server Error',
                'message': 'Failed to publish message to queue'
            }),
            'headers': {'Content-Type': 'application/json'}
        }
    
    # Return 202 Accepted
    logger.info(json.dumps({
        'event': 'ingest_accepted',
        'tenant_id': message['tenant_id'],
        'log_id': message['log_id'],
        'request_id': message['request_id']
    }))
    
    return {
        'statusCode': 202,
        'body': json.dumps({
            'status': 'accepted',
            'log_id': message['log_id'],
            'request_id': message['request_id']
        }),
        'headers': {'Content-Type': 'application/json'}
    }
