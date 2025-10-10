#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
DBTYPE="postgresql"
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

for bin in kubectl aws jq yq pg_dump pg_dumpall gzip; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$LOG_PREFIX ERROR: Required binary '$bin' not found in PATH"
    exit 1
  fi
done

echo "$LOG_PREFIX Starting PostgreSQL backup process to bucket: $BUCKET_NAME"

# === READ CONFIG ===
CONFIG_PATH="/configs/${DBTYPE}.yaml"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "$LOG_PREFIX ERROR: Config file not found at $CONFIG_PATH"
  exit 1
fi

mapfile -t db_array < <(yq -r ".${DBTYPE}[] | @json" "$CONFIG_PATH")

# === MAIN LOOP ===
set +e  # allow loop to continue on failure
for db in "${db_array[@]}"; do
  HOSTNAME=$(echo "$db" | jq -r '.hostname')
  NAMESPACE=$(echo "$db" | jq -r '.namespace')
  DATABASE=$(echo "$db" | jq -r '.database // "postgres"')
  PORT=$(echo "$db" | jq -r '.port // 5432')

  echo "===================================================================="
  echo "$LOG_PREFIX Processing PostgreSQL instance: $HOSTNAME (namespace: $NAMESPACE, db: $DATABASE)"

  # === GET CREDENTIALS ===
  USER=$(kubectl exec -n "$NAMESPACE" svc/"$HOSTNAME" -- printenv POSTGRES_USER 2>/dev/null || echo "postgres")
  PASSWORD=$(kubectl exec -n "$NAMESPACE" svc/"$HOSTNAME" -- sh -c 'if [ -n "$POSTGRES_PASSWORD" ]; then echo "$POSTGRES_PASSWORD"; elif [ -n "$POSTGRES_PASSWORD_FILE" ]; then cat "$POSTGRES_PASSWORD_FILE"; fi' 2>/dev/null || true)

  if [[ -z "$PASSWORD" ]]; then
    echo "$LOG_PREFIX ERROR: Missing PostgreSQL credentials for $HOSTNAME in $NAMESPACE"
    ((FAILURE_COUNT++))
    continue
  fi

  # === BACKUP FILE ===
  FILENAME="${HOSTNAME//-/_}_${NAMESPACE//-/_}_${DATABASE}_$(date +"%d_%m_%Y_%H%M%S").sql.gz"
  BACKUP_FILE="${BACKUP_BASE}/${FILENAME}"
  CLEANUP_ON_EXIT=true  # assume cleanup until success

  echo "$LOG_PREFIX Running pg_dump for $DATABASE ..."
  START_TIME=$(date +%s)
  PGPASSWORD="$PASSWORD" pg_dump \
    -h "${HOSTNAME}.${NAMESPACE}" \
    -p "$PORT" \
    -U "$USER" \
    -d "$DATABASE" \
    -F p \
    | gzip > "$BACKUP_FILE"
  DUMP_STATUS=$?

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  if [ $DUMP_STATUS -eq 0 ] && gunzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "$LOG_PREFIX Backup successful (duration: ${DURATION}s)"
    CLEANUP_ON_EXIT=false  # Verified dump created, keep it

    # === UPLOAD TO S3 ===
    S3_PATH="s3://${BUCKET_NAME}/${S3_PREFIX:+$S3_PREFIX/}${FILENAME}"
    echo "$LOG_PREFIX Uploading backup to $S3_PATH ..."
    if aws --endpoint-url "https://${S3_ENDPOINT}" s3 cp "$BACKUP_FILE" "$S3_PATH" >/dev/null 2>&1; then
      echo "$LOG_PREFIX Upload successful"
      ((SUCCESS_COUNT++))
    else
      echo "$LOG_PREFIX WARNING: Upload failed for $HOSTNAME. Keeping local copy for recovery."
      ((FAILURE_COUNT++))
    fi
  else
    echo "$LOG_PREFIX ERROR: pg_dump failed for $HOSTNAME in $NAMESPACE"
    ((FAILURE_COUNT++))
    rm -f "$BACKUP_FILE"
  fi
done
set -e  # restore strict mode

# === RETENTION POLICY ===
echo "$LOG_PREFIX Applying 7-day local retention policy..."
find "$BACKUP_BASE" -type f -name "*.gz" -mtime +7 -delete
echo "$LOG_PREFIX Retention cleanup complete."

# === SUMMARY ===
echo "┌─────────────────────────────────────────────────────┐"
echo "$LOG_PREFIX Total Successful Backups: $SUCCESS_COUNT"
echo "$LOG_PREFIX Total Failed Backups: $FAILURE_COUNT"
echo "└─────────────────────────────────────────────────────┘"
