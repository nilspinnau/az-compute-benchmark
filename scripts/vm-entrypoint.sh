#!/usr/bin/env bash
#
# vm-entrypoint.sh - CustomScript Extension entrypoint
#
# Called automatically by the Azure CustomScript extension after VM provision.
# 1. Waits for cloud-init to finish (package installation)
# 2. Downloads benchmark scripts from GitHub
# 3. Runs benchmarks
# 4. Uploads results to blob storage
# 5. Writes a DONE marker blob for the orchestrator to poll
#
set -euo pipefail

LOG_FILE="/var/log/benchmark-entrypoint.log"

echo "=============================================="
echo " VM Entrypoint - $(hostname)"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

# --- Load config written by cloud-init ---
CONFIG_FILE="/etc/benchmark-config"
MAX_CONFIG_WAIT=300  # 5 minutes
WAITED=0
while [[ ! -f "$CONFIG_FILE" ]]; do
    if (( WAITED >= MAX_CONFIG_WAIT )); then
        echo "ERROR: $CONFIG_FILE not found after ${MAX_CONFIG_WAIT}s"
        exit 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done
source "$CONFIG_FILE"

ADMIN_USER=$(ls /home/ | head -1)
BENCH_DIR="/home/${ADMIN_USER}/benchmark"

# --- Wait for cloud-init to finish ---
echo ">>> Waiting for cloud-init..."
MAX_WAIT=1800  # 30 minutes
WAITED=0
while [[ ! -f "${BENCH_DIR}/.cloud-init-done" ]]; do
    if (( WAITED >= MAX_WAIT )); then
        echo "ERROR: cloud-init did not complete within ${MAX_WAIT}s"
        exit 1
    fi
    sleep 10
    WAITED=$((WAITED + 10))
    if (( WAITED % 60 == 0 )); then
        echo "    Still waiting for cloud-init... (${WAITED}s)"
    fi
done
echo "    cloud-init complete."

# --- Download scripts from GitHub ---
echo ">>> Downloading scripts from GitHub..."
echo "    Repo: ${GITHUB_REPO_URL}"
echo "    Ref:  ${GITHUB_REF}"

TARBALL_URL="${GITHUB_REPO_URL}/archive/refs/heads/${GITHUB_REF}.tar.gz"
TEMP_DIR=$(mktemp -d)

curl -sL "$TARBALL_URL" -o "${TEMP_DIR}/repo.tar.gz"
tar -xzf "${TEMP_DIR}/repo.tar.gz" -C "$TEMP_DIR"

# GitHub tarball extracts to <repo-name>-<branch>/
EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name '*-*' | head -1)
if [[ -z "$EXTRACTED_DIR" || ! -d "$EXTRACTED_DIR/scripts" ]]; then
    echo "ERROR: Could not find scripts directory in downloaded tarball"
    ls -la "$TEMP_DIR"
    exit 1
fi

# Copy scripts into place
SCRIPTS_DIR="${BENCH_DIR}/scripts"
mkdir -p "$SCRIPTS_DIR"
cp -r "$EXTRACTED_DIR/scripts/"* "$SCRIPTS_DIR/"
chmod -R +x "$SCRIPTS_DIR/"
rm -rf "$TEMP_DIR"

echo "    Scripts installed to ${SCRIPTS_DIR}"

# --- Run benchmarks ---
echo ">>> Running benchmarks (suites: ${BENCHMARK_SUITES})..."
cd "$BENCH_DIR"
bash "${SCRIPTS_DIR}/run-benchmarks.sh" --suites "$BENCHMARK_SUITES"
BENCH_EXIT=$?

if [[ $BENCH_EXIT -ne 0 ]]; then
    echo "WARNING: Benchmarks exited with code $BENCH_EXIT"
fi

# --- Upload results to blob storage ---
echo ">>> Uploading results..."
bash "${SCRIPTS_DIR}/upload-results.sh"

# --- Write DONE marker ---
echo ">>> Writing completion marker..."
TOKEN=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/" \
    | jq -r '.access_token')

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
    BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}"
    VM_NAME=$(hostname)

    # Write a marker blob with timestamp and exit code
    MARKER_CONTENT="{\"hostname\":\"${VM_NAME}\",\"completed\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"benchmark_exit_code\":${BENCH_EXIT}}"

    curl -s -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "x-ms-blob-type: BlockBlob" \
        -H "x-ms-version: 2020-10-02" \
        -H "Content-Type: application/json" \
        --data "$MARKER_CONTENT" \
        "${BLOB_URL}/${VM_NAME}/DONE"

    echo "    Completion marker uploaded: ${VM_NAME}/DONE"
else
    echo "WARNING: Could not get token for DONE marker upload"
fi

echo ""
echo "=============================================="
echo " VM Entrypoint complete - $(hostname)"
echo " Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
