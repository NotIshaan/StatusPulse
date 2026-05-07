#!/bin/bash
set -e

echo "Pulling latest Docker image..."
docker compose -f docker-compose.prod.yml pull

echo "Starting up the server..."
docker compose -f docker-compose.prod.yml up -d

echo "Deploy complete!"
