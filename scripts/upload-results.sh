#!/usr/bin/env bash
#
# upload-results.sh — Upload benchmark results to Azure Blob Storage
#
# Uses VM managed identity for authentication. Called automatically
# by the orchestration script after benchmarks complete.
#
set -euo pipefail

RESULTS_BASE="${1:-/home/$(whoami)/benchmark/results}"

# Read storage config written by cloud-init
if [[ -f /etc/benchmark-config ]]; then
    source /etc/benchmark-config
else
    echo "ERROR: /etc/benchmark-config not found. Was cloud-init configured?"
    exit 1
fi

VM_NAME=$(hostname)

BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}"

# Find the latest result directory
RESULT_DIR=$(find "$RESULTS_BASE" -maxdepth 1 -type d | sort | tail -1)
if [[ "$RESULT_DIR" == "$RESULTS_BASE" ]]; then
    echo "ERROR: No result directories found in $RESULTS_BASE"
    exit 1
fi

echo "Uploading results from $RESULT_DIR to $BLOB_URL/$VM_NAME/..."

# Tar the results and upload as a single blob
TAR_FILE="/tmp/benchmark-results-${VM_NAME}.tar.gz"
tar -czf "$TAR_FILE" -C "$RESULT_DIR" .

BLOB_PATH="${VM_NAME}/results.tar.gz"
FILE_SIZE=$(stat -c%s "$TAR_FILE")
echo "Tar file size: $FILE_SIZE bytes"

# Retry upload up to 3 times
for attempt in 1 2 3; do
    echo "Upload attempt $attempt..."

    # Get fresh token each attempt (tokens can expire)
    # Use MI_CLIENT_ID if set (user-assigned managed identity)
    IMDS_URL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/"
    if [[ -n "${MI_CLIENT_ID:-}" ]]; then
        IMDS_URL="${IMDS_URL}&client_id=${MI_CLIENT_ID}"
    fi
    TOKEN=$(curl -s -H "Metadata:true" "$IMDS_URL" | jq -r '.access_token')

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo "WARNING: Could not get token on attempt $attempt"
        sleep 10
        continue
    fi

    HTTP_CODE=$(curl -w "%{http_code}" -o /tmp/upload-response.txt \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "x-ms-blob-type: BlockBlob" \
        -H "x-ms-version: 2020-10-02" \
        -H "Content-Type: application/gzip" \
        -H "Content-Length: $FILE_SIZE" \
        --data-binary "@$TAR_FILE" \
        "${BLOB_URL}/${BLOB_PATH}" 2>/tmp/upload-curl-stderr.txt)

    echo "HTTP response code: $HTTP_CODE"
    if [[ "$HTTP_CODE" == "201" ]]; then
        echo "Uploaded successfully: ${BLOB_URL}/${BLOB_PATH}"
        rm -f "$TAR_FILE" /tmp/upload-response.txt /tmp/upload-curl-stderr.txt
        break
    else
        echo "Upload failed (HTTP $HTTP_CODE). Response:"
        cat /tmp/upload-response.txt 2>/dev/null || true
        cat /tmp/upload-curl-stderr.txt 2>/dev/null || true
        if [[ $attempt -lt 3 ]]; then
            echo "Retrying in 15 seconds..."
            sleep 15
        else
            echo "ERROR: Upload failed after 3 attempts"
            rm -f /tmp/upload-response.txt /tmp/upload-curl-stderr.txt
        fi
    fi
done
