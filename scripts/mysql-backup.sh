#!/bin/bash

source /scripts/network-blocker.sh

# Initialize success and failure counters
SUCCESS_COUNT=0
FAILURE_COUNT=0

# Initialize dbtype
DBTYPE="mysql"

# Check if BUCKET_NAME environment variable is set
BUCKET_NAME=$(printenv BUCKET_NAME)
if [ -z "$BUCKET_NAME" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: BUCKET_NAME environment variable is not set"
    exit 1
fi

COS_APIKEY=$(printenv COS_APIKEY)
if [ -z "$COS_APIKEY" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: COS_APIKEY environment variable is not set"
    exit 1
else
    ibmcloud login --apikey $COS_APIKEY -r "eu-de"  > /dev/null 2>&1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚡ Initiating database backup process for MySQL in $BUCKET_NAME bucket..."

# Read YAML entries into an array
readarray -t db_array < <(yq -r ".${DBTYPE}[] | @json" /configs/databases.yaml)

# MySQL-specific backup logic
for db in "${db_array[@]}"; do
    HOSTNAME=$(echo "$db" | jq -r '.hostname')
    NAMESPACE=$(echo "$db" | jq -r '.namespace')
    
    echo "===================================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📢 Preparing database backup process for MySQL in $NAMESPACE namespace on $HOSTNAME..."

    # Generate backup filename
    FILENAME="${HOSTNAME//-/_}_${NAMESPACE//-/_}_$(date +"%d_%m_%Y_%H%M%S")"

    # Prepare the label selector
    LABEL_SELECTOR=$(kubectl get svc "$HOSTNAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
    if [ -z "$LABEL_SELECTOR" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ No selector found for service $HOSTNAME in namespace $NAMESPACE"
        continue
    fi

    # Get the pod name using the selector
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath="{.items[0].metadata.name}")
    if [ -z "$POD_NAME" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ No pods found matching selector: $LABEL_SELECTOR"
        continue
    fi

    # Get database credentials from the running pod environment variables
    CONTAINER_NAME=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -i ${DBTYPE})
    export USER=root
    export PASSWORD=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c $CONTAINER_NAME -- printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
    if [[ -n "$USER" && -n "$PASSWORD" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 MySQL credentials retrieved successfully"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Missing MySQL credentials, skipping this instance..."
        ((FAILURE_COUNT++))
        continue 
    fi

    # Backup MySQL database
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📦 Starting backup process..."
    START_TIME=$(date +%s)
    mysqldump -u $USER -p$PASSWORD -h $HOSTNAME.$NAMESPACE --single-transaction --quick --all-databases | gzip > /backups/${DBTYPE}/$FILENAME.gz
    BACKUP_STATUS=$?
    END_TIME=$(date +%s)
    gunzip -t "/backups/${DBTYPE}/$FILENAME.gz"
    BACKUP_INTEGRITY=$?

    # Check backup status
    if [ $BACKUP_STATUS -eq 0 ] && [ $BACKUP_INTEGRITY -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ MySQL backup completed successfully"
        DURATION=$((END_TIME - START_TIME))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ Backup duration: $DURATION seconds"
        ((SUCCESS_COUNT++))

        # Upload the backup to IBM COS
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚀 Uploading backup to IBM Cloud Object Storage..."
        ibmcloud cos upload --bucket $BUCKET_NAME --key $FILENAME.gz --file /backups/${DBTYPE}/$FILENAME.gz --output text --region eu-geo
        UPLOAD_STATUS=$?
        
        if [ $UPLOAD_STATUS -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ☁️ Backup uploaded to IBM Cloud Object Storage successfully."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: Failed to upload backup to IBM Cloud Object Storage. Status code: $UPLOAD_STATUS. Error message: $(ibmcloud cos upload --bucket $BUCKET_NAME --key $FILENAME.gz --file /backups/${DBTYPE}/$FILENAME.gz --output text --region eu-geo)"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: MySQL backup failed for $HOSTNAME in $NAMESPACE namespace with status $BACKUP_STATUS. Please check the logs for more information."
        ((FAILURE_COUNT++))
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💯 Backup process completed for $HOSTNAME."
done

# Print final counts
echo "┌─────────────────────────────────────────────────────┐"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🙆 Total Successful Backups: $SUCCESS_COUNT"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🙅 Total Failed Backups: $FAILURE_COUNT"
echo "└─────────────────────────────────────────────────────┘"

# Upload log files to IBM Cloud Object Storage
ibmcloud cos upload --bucket $BUCKET_NAME --key ${DBTYPE}_backup_$(date +%F).log --file /logs/${DBTYPE}/${DBTYPE}_backup_$(date +%F).log --output text --region eu-geo
UPLOAD_STATUS=$?
if [ $UPLOAD_STATUS -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📝 Logs uploaded to IBM Cloud Object Storage successfully."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: Failed to upload log file to IBM Cloud Object Storage. Status code: $UPLOAD_STATUS. Error message: $(ibmcloud cos upload --bucket $BUCKET_NAME --key ${DBTYPE}_backup_$(date +%F).log --file /logs/${DBTYPE}/${DBTYPE}_backup_$(date +%F).log --output text --region eu-geo)"
fi

# Cleanup
rm -rf /backups/${DBTYPE}/* 2>/dev/null
rm -rf /logs/${DBTYPE}/* 2>/dev/null
