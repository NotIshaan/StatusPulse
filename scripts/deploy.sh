#!/bin/bash
set -e
# StatusPulse Zero-Downtime Deploy & Rollback Script

LOGFILE="/home/deploy/StatusPulse/deploy.log"
IMAGE="ghcr.io/notishaan/statuspulse:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

log "========================================"
log " Starting deployment process..."

# 1. Pull the latest image
log "Pulling latest image ($IMAGE)..."
docker pull $IMAGE

# 2. Check Idempotency (Are we already running the latest?)
OLD_IMAGE_ID=$(docker inspect -f '{{.Image}}' statuspulse-app-1 2>/dev/null)
NEW_IMAGE_ID=$(docker inspect -f '{{.Id}}' $IMAGE 2>/dev/null)

if [ "$OLD_IMAGE_ID" == "$NEW_IMAGE_ID" ] && [ -n "$OLD_IMAGE_ID" ]; then
    log " Image is already up to date. No deployment needed. (Idempotent)"
    exit 0
fi

# 3. ZERO-DOWNTIME PRE-CHECK: Start new image temporarily
log "🧪 Starting temporary container for pre-deployment health check..."
# Find the network the DB is currently running on so our test container can reach it
DB_NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' statuspulse-db-1 | head -n 1)
if [ -z "$DB_NETWORK" ]; then
    DB_NETWORK="statuspulse_net"
fi
log "Using network: $DB_NETWORK for test container..."

# We run it on the DB network so it can talk to the DB/Redis
docker run -d --name app-test-container --network "$DB_NETWORK" --env-file .env $IMAGE

# Wait for it to boot up
log "Waiting 5 seconds for application to start..."
sleep 5

# Check if container is actually still running
if [ "$(docker inspect -f '{{.State.Running}}' app-test-container 2>/dev/null)" != "true" ]; then
    log "Container crashed on startup. Logs:"
    docker logs app-test-container | tail -n 10 | tee -a "$LOGFILE"
fi

# Get the internal IP of the test container
TEST_IP=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{if eq .NetworkID \"$(docker network inspect -f '{{.Id}}' $DB_NETWORK)\"}}{{.IPAddress}}{{end}}{{end}}" app-test-container)
if [ -z "$TEST_IP" ]; then
    TEST_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app-test-container | head -n 1)
fi

log "Checking health of new image at internal IP: $TEST_IP:8000/health..."
# We test the new container directly before touching production
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$TEST_IP:8000/health")

# 4. ROLLBACK OR PROCEED
if [ "$HTTP_CODE" -eq 200 ]; then
    log " Pre-check PASSED (HTTP 200). Image is healthy!"
    log " Removing temporary test container..."
    docker rm -f app-test-container
    
    log " Upgrading production service (Stop Old -> Start New)..."
    # Self-healing: Remove the manually created network from our previous bug if it has no containers
    docker network rm statuspulse_net 2>/dev/null || true
    docker compose -f docker-compose.prod.yml up -d app
    log "Deployment successful!"
else
    log " Pre-check FAILED (HTTP $HTTP_CODE). The new image is broken!"
    log " Initiating AUTO-ROLLBACK..."
    
    # Cleanup the broken test container
    docker rm -f app-test-container
    
    # Tag the old working image back to latest so the server stays stable
    log "Tagging previous stable image ($OLD_IMAGE_ID) back to $IMAGE..."
    docker tag $OLD_IMAGE_ID $IMAGE
    
    log " Rollback complete. Production was never touched and remains online."
    exit 1
fi
