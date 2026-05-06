#!/bin/bash
set -e # Exit immediately if a test fails

BASE_URL="http://127.0.0.1:8000"
echo "Starting Integration Tests..."

# Helper functions
pass() { echo " $1: PASS"; }
fail() { echo " $1: FAIL"; exit 1; }

# 1. GET /health
echo "Testing GET /health..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/health")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"status":"healthy"' response.json; then
    pass "GET /health"
else
    fail "GET /health"
fi

# 2. POST /services
echo "Testing POST /services..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "$BASE_URL/services" -H "Content-Type: application/json" -d '{"name": "test-service", "url": "http://example.com"}')
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"id"' response.json; then
    pass "POST /services (Create)"
else
    fail "POST /services (Create)"
fi

# 3. POST /services (Duplicate - Must be 409)
echo "Testing POST /services (Duplicate)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/services" -H "Content-Type: application/json" -d '{"name": "test-service", "url": "http://example.com"}')
if [ "$HTTP_CODE" -eq 409 ]; then
    pass "POST /services (Duplicate 409 Conflict)"
else
    fail "POST /services (Duplicate)"
fi

# 4. GET /services
echo "Testing GET /services..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/services")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"name":"test-service"' response.json; then
    pass "GET /services"
else
    fail "GET /services"
fi

# 5. POST /incidents
echo "Testing POST /incidents..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "$BASE_URL/incidents" -H "Content-Type: application/json" -d '{"service_name": "test-service", "title": "Server down", "severity": "major"}')
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"status":"investigating"' response.json; then
    pass "POST /incidents"
else
    fail "POST /incidents"
fi

# 6. GET /incidents
echo "Testing GET /incidents..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/incidents")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"title":"Server down"' response.json; then
    pass "GET /incidents"
else
    fail "GET /incidents"
fi

# Cleanup
rm -f response.json

echo "All tests passed."
