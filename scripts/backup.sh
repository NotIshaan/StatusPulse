#!/bin/bash
# StatusPulse Database Backup Script

BACKUP_DIR="/home/deploy/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
DB_CONTAINER="statuspulse-db-1"
DB_NAME="statuspulse"
DB_USER="postgres"
FILENAME="statuspulse_db_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "$(date): Starting backup..."

# Run pg_dump inside the container and compress the output
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_DIR/$FILENAME"

if [ $? -eq 0 ]; then
    echo "$(date): Backup successful: $FILENAME"
else
    echo "$(date): Backup FAILED"
    exit 1
fi

# Rotate: Keep only last 7 backups
find "$BACKUP_DIR" -type f -name "statuspulse_db_*.sql.gz" -mtime +7 -delete

echo "$(date): Backup rotation complete."