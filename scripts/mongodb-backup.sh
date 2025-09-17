#!/bin/bash

source /scripts/network-blocker.sh

# Initialize success and failure counters
SUCCESS_COUNT=0
FAILURE_COUNT=0

# Initialize DBTYPE
DBTYPE="mongodb"

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚡ Initiating database backup process for MongoDB in $BUCKET_NAME bucket..."

# Read YAML entries into an array
readarray -t db_array < <(yq -r ".${DBTYPE}[] | @json" /configs/databases.yaml)

# MongoDB-specific backup logic
for db in "${db_array[@]}"; do
    HOSTNAME=$(echo "$db" | jq -r '.hostname')
    NAMESPACE=$(echo "$db" | jq -r '.namespace')
    TLS_ENABLED=$(echo "$db" | jq -r '.tls? | .enabled // false')
    CERT_DIR=$(echo "$db" | jq -r '.tls? | .cert_dir // ""')
    
    echo "===================================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📢 Preparing database backup process for MongoDB in $NAMESPACE namespace on $HOSTNAME..."

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
    export USER=$(kubectl exec -n $NAMESPACE $POD_NAME -c $CONTAINER_NAME -- printenv MONGODB_ROOT_USER 2>/dev/null || echo "")
    export USER=${USER:-root}
    export PASSWORD=$(kubectl exec -n $NAMESPACE $POD_NAME -c $CONTAINER_NAME -- printenv MONGODB_ROOT_PASSWORD)
    if [[ -n "$USER" && -n "$PASSWORD" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 MongoDB credentials retrieved successfully"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Missing MongoDB credentials, skipping this instance..."
        ((FAILURE_COUNT++))
        continue 
    fi

    # Perform backup with TLS if needed
    TLS_OPTIONS=""
    if [ "$TLS_ENABLED" == "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔒 TLS connection detected, copying certs before backup..."
        # Copy TLS certificates to the pod
        kubectl cp $NAMESPACE/$POD_NAME:$CERT_DIR/mongodb-ca-cert /backups/${DBTYPE}/mongodb-ca-cert -c $CONTAINER_NAME
        kubectl cp $NAMESPACE/$POD_NAME:$CERT_DIR/mongodb.pem /backups/${DBTYPE}/mongodb.pem -c $CONTAINER_NAME
        TLS_OPTIONS="--ssl --tlsInsecure --sslCAFile /backups/${DBTYPE}/mongodb-ca-cert --sslPEMKeyFile /backups/${DBTYPE}/mongodb.pem"
    fi

    # Backup MongoDB database
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📦 Starting backup process..."
    START_TIME=$(date +%s)
    mongodump $TLS_OPTIONS \
        --host "$HOSTNAME.$NAMESPACE" \
        --username "$USER" \
        --password "$PASSWORD" \
        --authenticationDatabase "admin" \
        --gzip \
        --archive="/backups/${DBTYPE}/$FILENAME.gz"
    BACKUP_STATUS=$?
    END_TIME=$(date +%s)
    gunzip -t "/backups/${DBTYPE}/$FILENAME.gz"
    BACKUP_INTEGRITY=$?

    # Check backup status
    if [ $BACKUP_STATUS -eq 0 ] && [ $BACKUP_INTEGRITY -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ MongoDB backup completed successfully"
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
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Error: MongoDB backup failed for $HOSTNAME in $NAMESPACE namespace with status $BACKUP_STATUS. Please check the logs for more information."
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
