#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
DBTYPE="mysql"
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

for bin in kubectl aws jq yq mysqldump gzip; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$LOG_PREFIX ERROR: Required binary '$bin' not found in PATH"
    exit 1
fi
done

echo "$LOG_PREFIX Starting MySQL backup process to bucket: $BUCKET_NAME"

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
  DATABASES=$(echo "$db" | jq -r '.databases')
  PORT=$(echo "$db" | jq -r '.port // 3306')

  # === VALIDATE PARAMETERS ===
  required_parameters=("$HOSTNAME" "$NAMESPACE" "$DATABASES")
  for param in "${required_parameters[@]}"; do
    if [ -z "$param" ] || [ "$param" == "null" ]; then
      echo "$LOG_PREFIX ERROR: Missing required parameter in config: $param"
      ((FAILURE_COUNT++))
      continue 
    fi
  done
    
  echo "===================================================================="
  echo "$LOG_PREFIX Processing MySQL instance: $HOSTNAME (namespace: $NAMESPACE)"

  # === GET CREDENTIALS ===
  USER=$(kubectl exec -n "$NAMESPACE" svc/"$HOSTNAME" -- printenv MYSQL_USER 2>/dev/null || echo "root")
  PASSWORD=$(kubectl get secret -n $NAMESPACE ${HOSTNAME} -o jsonpath="{.data.mysql-root-password}" 2>/dev/null | base64 -d)

  if [[ -z "$PASSWORD" ]]; then
    echo "$LOG_PREFIX ERROR: Missing MySQL credentials for $HOSTNAME in $NAMESPACE"
        ((FAILURE_COUNT++))
        continue 
    fi

  # === Cluster Backup ===
  if echo "$DATABASES" | grep -q '"\*"' >/dev/null 2>&1; then
    echo "$LOG_PREFIX Detected '*' — running mysqldump for full cluster..."
    FILENAME="${HOSTNAME//-/_}_${NAMESPACE//-/_}_cluster_$(date +"%d_%m_%Y_%H%M%S").sql.gz"
    BACKUP_FILE="${BACKUP_BASE}/${FILENAME}"
    CLEANUP_ON_EXIT=true

    START_TIME=$(date +%s)
    mysqldump \
      -h "${HOSTNAME}.${NAMESPACE}" \
      -P "$PORT" \
      -u "$USER" \
      -p"$PASSWORD" \
      --all-databases \
      --add-drop-database \
      --flush-privileges \
      --single-transaction \
      --routines \
      --events \
      | gzip > "$BACKUP_FILE"
      DUMP_STATUS=$?
      END_TIME=$(date +%s)
      DURATION=$((END_TIME - START_TIME))

    if [ $DUMP_STATUS -eq 0 ] && gunzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
      echo "$LOG_PREFIX Cluster backup successful (duration: ${DURATION}s)"
      CLEANUP_ON_EXIT=false
      S3_PATH="s3://${BUCKET_NAME}/${FILENAME}"
      echo "$LOG_PREFIX Uploading cluster backup to $S3_PATH ..."
      if aws --endpoint-url "https://${S3_ENDPOINT}" s3 cp "$BACKUP_FILE" "$S3_PATH" >/dev/null 2>&1; then
        echo "$LOG_PREFIX Upload successful"
        ((SUCCESS_COUNT++))
      else
        echo "$LOG_PREFIX WARNING: Upload failed for $HOSTNAME cluster. Keeping local copy."
        ((FAILURE_COUNT++))
      fi
    else
      echo "$LOG_PREFIX ERROR: mysqldump failed for $HOSTNAME.$NAMESPACE"
      ((FAILURE_COUNT++))
      rm -f "$BACKUP_FILE"
    fi

  # === Individual Database Backups ===
  else
    mapfile -t DB_LIST < <(echo "$DATABASES" | jq -r '.[]')
    for DATABASE in "${DB_LIST[@]}"; do
      if [ -z "$DATABASE" ] || [ "$DATABASE" == "null" ]; then
        continue
      fi

      echo "$LOG_PREFIX Running mysqldump for database: $DATABASE ..."
      FILENAME="${HOSTNAME//-/_}_${NAMESPACE//-/_}_${DATABASE}_$(date +"%d_%m_%Y_%H%M%S").sql.gz"
      BACKUP_FILE="${BACKUP_BASE}/${FILENAME}"
      CLEANUP_ON_EXIT=true

      START_TIME=$(date +%s)
      mysqldump \
        -h "${HOSTNAME}.${NAMESPACE}" \
        -P "$PORT" \
        -u "$USER" \
        -p"$PASSWORD" \
        "$DATABASE" \
        --routines --events --single-transaction \
        | gzip > "$BACKUP_FILE"
      DUMP_STATUS=$?
      END_TIME=$(date +%s)
      DURATION=$((END_TIME - START_TIME))

      if [ $DUMP_STATUS -eq 0 ] && gunzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
        echo "$LOG_PREFIX Backup successful for $DATABASE (duration: ${DURATION}s)"
        CLEANUP_ON_EXIT=false
        S3_PATH="s3://${BUCKET_NAME}/${FILENAME}"
        echo "$LOG_PREFIX Uploading $DATABASE backup to $S3_PATH ..."
        if aws --endpoint-url "https://${S3_ENDPOINT}" s3 cp "$BACKUP_FILE" "$S3_PATH" >/dev/null 2>&1; then
          echo "$LOG_PREFIX Upload successful"
          ((SUCCESS_COUNT++))
        else
          echo "$LOG_PREFIX WARNING: Upload failed for $DATABASE in $HOSTNAME. Keeping local copy."
          ((FAILURE_COUNT++))
        fi
      else
        echo "$LOG_PREFIX ERROR: mysqldump failed for $DATABASE in $HOSTNAME"
        ((FAILURE_COUNT++))
        rm -f "$BACKUP_FILE"
      fi
    done
  fi
done
set -e

# === RETENTION POLICY ===
echo "$LOG_PREFIX Applying 7-day local retention policy..."
find "$BACKUP_BASE" -type f -name "*.gz" -mtime +7 -delete
echo "$LOG_PREFIX Retention cleanup complete."

# === SUMMARY ===
echo "┌─────────────────────────────────────────────────────┐"
echo "$LOG_PREFIX Total Successful Backups: $SUCCESS_COUNT"
echo "$LOG_PREFIX Total Failed Backups: $FAILURE_COUNT"
echo "└─────────────────────────────────────────────────────┘"
