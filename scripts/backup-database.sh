#!/bin/bash

set -e

# Database Backup Script for Exchange
# This script dumps the PostgreSQL database and uploads it to MinIO

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Configuration - can be overridden by environment variables or .env file
DATABASE_HOST="${DATABASE_HOST:-localhost}"
DATABASE_PORT="${DATABASE_PORT:-5432}"
DATABASE_NAME="${DATABASE_NAME:-exchange}"
DATABASE_USER="${DATABASE_USER:-exchange}"
DATABASE_PASSWORD="${DATABASE_PASSWORD:-exchange}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_USE_SSL="${MINIO_USE_SSL:-false}"
MINIO_BUCKET="${MINIO_BUCKET:-database-backups}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Load environment variables from .env file if it exists
if [ -f ".env" ]; then
    log_info "Loading configuration from .env file..."
    export $(grep -v '^#' .env | xargs)
fi

# Create backup directory if it doesn't exist
mkdir -p "${BACKUP_DIR}"

# Generate timestamp for backup file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="exchange_backup_${TIMESTAMP}.sql"
BACKUP_FILE_GZ="${BACKUP_FILE}.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
BACKUP_PATH_GZ="${BACKUP_PATH}.gz"

log_info "Starting database backup..."
log_info "Timestamp: ${TIMESTAMP}"

# Check if pg_dump is available
if ! command -v pg_dump &> /dev/null; then
    log_error "pg_dump is not installed. Please install PostgreSQL client tools."
    exit 1
fi

# Perform database dump
log_info "Dumping database ${DATABASE_NAME} from ${DATABASE_HOST}:${DATABASE_PORT}..."
PGPASSWORD="${DATABASE_PASSWORD}" pg_dump \
    -h "${DATABASE_HOST}" \
    -p "${DATABASE_PORT}" \
    -U "${DATABASE_USER}" \
    -d "${DATABASE_NAME}" \
    --no-owner \
    --no-acl \
    -F p \
    -f "${BACKUP_PATH}"

if [ $? -ne 0 ]; then
    log_error "Database dump failed!"
    exit 1
fi

log_info "Database dump completed: ${BACKUP_PATH}"

# Compress the backup
log_info "Compressing backup..."
gzip "${BACKUP_PATH}"

if [ $? -ne 0 ]; then
    log_error "Compression failed!"
    exit 1
fi

BACKUP_SIZE=$(du -h "${BACKUP_PATH_GZ}" | cut -f1)
log_info "Backup compressed: ${BACKUP_PATH_GZ} (${BACKUP_SIZE})"

# Upload to MinIO
if [ -n "${MINIO_ACCESS_KEY}" ] && [ -n "${MINIO_SECRET_KEY}" ]; then
    log_info "Uploading backup to MinIO..."
    
    # Check if mc (MinIO client) is available
    if ! command -v mc &> /dev/null; then
        log_warn "MinIO client (mc) is not installed. Installing..."
        
        # Determine OS and architecture
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)
        
        if [ "${ARCH}" = "x86_64" ]; then
            ARCH="amd64"
        elif [ "${ARCH}" = "aarch64" ] || [ "${ARCH}" = "arm64" ]; then
            ARCH="arm64"
        fi
        
        # Download mc
        MC_URL="https://dl.min.io/client/mc/release/${OS}-${ARCH}/mc"
        curl -o /tmp/mc "${MC_URL}"
        chmod +x /tmp/mc
        MC_CMD="/tmp/mc"
    else
        MC_CMD="mc"
    fi
    
    # Configure MinIO client
    log_info "Configuring MinIO connection..."
    MINIO_PROTOCOL="http"
    if [ "${MINIO_USE_SSL}" = "true" ]; then
        MINIO_PROTOCOL="https"
    fi
    
    ${MC_CMD} alias set myminio "${MINIO_PROTOCOL}://${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" --api S3v4
    
    # Create bucket if it doesn't exist
    log_info "Ensuring bucket '${MINIO_BUCKET}' exists..."
    ${MC_CMD} mb "myminio/${MINIO_BUCKET}" --ignore-existing
    
    # Upload backup to MinIO
    ${MC_CMD} cp "${BACKUP_PATH_GZ}" "myminio/${MINIO_BUCKET}/${BACKUP_FILE_GZ}"
    
    if [ $? -eq 0 ]; then
        log_info "Backup successfully uploaded to MinIO: ${MINIO_BUCKET}/${BACKUP_FILE_GZ}"
        
        # Clean up old backups from MinIO
        if [ "${RETENTION_DAYS}" -gt 0 ]; then
            log_info "Cleaning up backups older than ${RETENTION_DAYS} days from MinIO..."
            ${MC_CMD} rm --recursive --force --older-than "${RETENTION_DAYS}d" "myminio/${MINIO_BUCKET}/" 2>/dev/null || true
        fi
        
        # Remove temporary mc if we downloaded it
        if [ -f "/tmp/mc" ]; then
            rm -f /tmp/mc
        fi
    else
        log_error "Failed to upload backup to MinIO"
        exit 1
    fi
else
    log_warn "MinIO credentials not provided. Skipping upload to MinIO."
    log_info "Backup saved locally at: ${BACKUP_PATH_GZ}"
fi

# Clean up old local backups
if [ "${RETENTION_DAYS}" -gt 0 ]; then
    log_info "Cleaning up local backups older than ${RETENTION_DAYS} days..."
    find "${BACKUP_DIR}" -name "exchange_backup_*.sql.gz" -type f -mtime +${RETENTION_DAYS} -delete
fi

log_info "Backup completed successfully!"
log_info "Backup file: ${BACKUP_PATH_GZ} (${BACKUP_SIZE})"

exit 0
