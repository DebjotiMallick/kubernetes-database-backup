#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
DBTYPE="mongodb"
BACKUP_BASE="/backups/${DBTYPE}"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"
SUCCESS_COUNT=0
FAILURE_COUNT=0
CLEANUP_ON_EXIT=true
BACKUP_FILE=""

# Ensure backup directory exists
mkdir -p "$BACKUP_BASE"

# === CLEANUP HANDLER ===
trap 'if [ "${CLEANUP_ON_EXIT}" = true ] && [ -f "$BACKUP_FILE" ]; then rm -f "$BACKUP_FILE"; fi' EXIT

# === VALIDATION ===
required_envs=(BUCKET_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_ENDPOINT)
for var in "${required_envs[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "$LOG_PREFIX ERROR: $var environment variable is not set"
    exit 1
  fi
done

for bin in kubectl aws jq yq mongodump; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$LOG_PREFIX ERROR: Required binary '$bin' not found in PATH"
    exit 1
  fi
done

echo "$LOG_PREFIX Starting MongoDB backup process to bucket: $BUCKET_NAME"

# === READ CONFIG ===
CONFIG_PATH="/configs/${DBTYPE}.yaml"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "$LOG_PREFIX ERROR: Config file not found at $CONFIG_PATH"
  exit 1
fi

mapfile -t db_array < <(yq -r ".${DBTYPE}[] | @json" "$CONFIG_PATH")

# === MAIN LOOP ===
set +e
for db in "${db_array[@]}"; do
  HOSTNAME=$(echo "$db" | jq -r '.hostname')
  NAMESPACE=$(echo "$db" | jq -r '.namespace')
  PORT=$(echo "$db" | jq -r '.port // 27017')
  S3_PREFIX=$(echo "$db" | jq -r '.s3_prefix // ""')

  echo "===================================================================="
  echo "$LOG_PREFIX Processing MongoDB instance: $HOSTNAME (namespace: $NAMESPACE)"

  # === GET CREDENTIALS ===
  USER=$(kubectl exec -n "$NAMESPACE" svc/"$HOSTNAME" -- printenv MONGODB_ROOT_USER 2>/dev/null || echo "root")
  PASSWORD=$(kubectl exec -n "$NAMESPACE" svc/"$HOSTNAME" -- sh -c 'if [ -n "$MONGODB_ROOT_PASSWORD" ]; then echo "$MONGODB_ROOT_PASSWORD"; elif [ -n "$MONGODB_ROOT_PASSWORD_FILE" ]; then cat "$MONGODB_ROOT_PASSWORD_FILE"; fi' 2>/dev/null || true)

  if [[ -z "$PASSWORD" ]]; then
    echo "$LOG_PREFIX ERROR: Missing MongoDB credentials for $HOSTNAME in $NAMESPACE"
    ((FAILURE_COUNT++))
    continue
  fi

  # === BACKUP ===
  FILENAME="${HOSTNAME//-/_}_${NAMESPACE//-/_}_$(date +"%d_%m_%Y_%H%M%S").gz"
  BACKUP_FILE="${BACKUP_BASE}/${FILENAME}"
  CLEANUP_ON_EXIT=true  # assume cleanup until success

  echo "$LOG_PREFIX Running mongodump..."
  START_TIME=$(date +%s)
  if mongodump \
    --host "${HOSTNAME}.${NAMESPACE}" \
    --port "$PORT" \
    --username "$USER" \
    --password "$PASSWORD" \
    --authenticationDatabase admin \
    --gzip \
    --archive="$BACKUP_FILE" >/dev/null 2>&1; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo "$LOG_PREFIX Backup successful (duration: ${DURATION}s)"

    # === VERIFY BACKUP INTEGRITY ===
    if gunzip -t "$BACKUP_FILE" 2>/dev/null; then
      # === UPLOAD TO S3 ===
      S3_PATH="s3://${BUCKET_NAME}/${S3_PREFIX:+$S3_PREFIX/}${FILENAME}"
      echo "$LOG_PREFIX Uploading backup to $S3_PATH ..."
      if aws --endpoint-url "https://${S3_ENDPOINT}" s3 cp "$BACKUP_FILE" "$S3_PATH" >/dev/null 2>&1; then
        echo "$LOG_PREFIX Upload successful"
        CLEANUP_ON_EXIT=false  # don't delete local backup
        ((SUCCESS_COUNT++))
      else
        echo "$LOG_PREFIX ERROR: Upload failed for $HOSTNAME"
        ((FAILURE_COUNT++))
      fi
    else
      echo "$LOG_PREFIX ERROR: Backup integrity check failed for $HOSTNAME"
      ((FAILURE_COUNT++))
    fi
  else
    echo "$LOG_PREFIX ERROR: mongodump failed for $HOSTNAME in $NAMESPACE"
    ((FAILURE_COUNT++))
  fi
done
set -e

# === LOCAL RETENTION POLICY ===
echo "$LOG_PREFIX Applying 7-day local retention policy..."
find "$BACKUP_BASE" -type f -name "*.gz" -mtime +7 -delete
echo "$LOG_PREFIX Retention cleanup complete."

# === SUMMARY ===
echo "┌─────────────────────────────────────────────────────┐"
echo "$LOG_PREFIX Total Successful Backups: $SUCCESS_COUNT"
echo "$LOG_PREFIX Total Failed Backups: $FAILURE_COUNT"
echo "└─────────────────────────────────────────────────────┘"