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

# Get an access token via managed identity
TOKEN=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/" \
    | jq -r '.access_token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Could not obtain managed identity token"
    exit 1
fi

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
curl -s -X PUT \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "x-ms-version: 2020-10-02" \
    -H "Content-Type: application/gzip" \
    --data-binary "@$TAR_FILE" \
    "${BLOB_URL}/${BLOB_PATH}"

echo "Uploaded: ${BLOB_URL}/${BLOB_PATH}"
rm -f "$TAR_FILE"
