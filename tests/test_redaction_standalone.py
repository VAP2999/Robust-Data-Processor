#!/usr/bin/env python3
"""
Standalone test for phone number redaction logic
No dependencies required - pure Python
"""
import re

def redact_phone_numbers(text: str) -> str:
    """
    Redact phone numbers from text
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

# Test cases
test_cases = [
    ("User 555-0199 accessed system", "User [REDACTED] accessed system"),
    ("Call 555-555-1234", "Call [REDACTED]"),
    ("Contact (555) 555-1234", "Contact [REDACTED]"),
    ("Error 555-0100 occurred", "Error [REDACTED] occurred"),
    ("Multiple: 555-0199 and 555-0100", "Multiple: [REDACTED] and [REDACTED]"),
]

print("Testing Phone Number Redaction")
print("=" * 50)

passed = 0
failed = 0

for i, (input_text, expected) in enumerate(test_cases, 1):
    result = redact_phone_numbers(input_text)
    status = "✅ PASS" if result == expected else "❌ FAIL"
    
    print(f"\nTest {i}: {status}")
    print(f"  Input:    {input_text}")
    print(f"  Expected: {expected}")
    print(f"  Got:      {result}")
    
    if result == expected:
        passed += 1
    else:
        failed += 1

print("\n" + "=" * 50)
print(f"Results: {passed} passed, {failed} failed")

if failed == 0:
    print("✅ All tests passed!")
    exit(0)
else:
    print("❌ Some tests failed")
    exit(1)
