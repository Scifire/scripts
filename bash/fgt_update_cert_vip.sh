#!/usr/bin/env bash
#
# fgt_update_cert_vip.sh - FortiGate Certificate Comparison and Rotation Script
#
# This script automates the process of comparing SSL certificates used by a FortiGate (7.6.5)
# Virtual Server (VIP) with a local certificate file. If the certificates differ, it
# uploads the new certificate to the FortiGate and updates the VIP to use it.
# It will also try to upload the chain cause it is required by Fortigate to present the chain to users.
# Chain files must be cleaned up manually.
#
# Key Features:
# - Fetches the current certificate from FortiGate via API
# - Compares SHA256 fingerprints of the leaf certificates
# - Uploads new certificate and private key if mismatch detected
# - Uploads the new chain if it changed
# - Updates the specified VIP to use the new certificate
# - Cleans up old certificates older than 90 days (based on date in name)
#
# Prerequisites:
# - jq, openssl, and curl must be installed
# - API token with appropriate permissions for FortiGate
# - Local certificated, private key and chain files
#
# Usage: See the usage() function or run with --help
#
# Exit Codes:
# 0 - Certificates match or was sucessful renewed
# 1 - Something didn´t work as expected
#
#
# This script was written with help of AI.
#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 2
}

usage() {
  cat <<EOF
Usage:
  compare-cert.sh \\
    --host <fortigate-ip> \\
    --vdom <vdom> \\
    --name <cert-name> \\
    --cert_base <cert-base-name> \\
    --cert_file <local-cert.pem> \\
    --cert_chain <local-chain.pem> \\
    --privkey <local-privkey.pem> \\
    --token <api-token>

Options:
  --host  FortiGate IP or Hostname
  --vdom  VDOM (default root)
  --name  Certificate name on the FortiGate
  --cert_base  Base name for new certificate uploads
  --cert_file  Local certificate (e.g. fullchain.pem)
  --cert_chain  Local certificate chain (e.g. chain.pem)
  --privkey  Local private key file (e.g. privkey.pem)
  --token API Token
  --vip_name  Virtual Server (VIP) name to update
Example:
  ./compare-cert.sh \\
    --host 10.30.1.254 \\
    --vdom root \\
    --name domain.example.date \\
    --cert_base domain.example \\
    --cert_file /etc/ssl/fullchain.pem \\
    --cert_chain /etc/ssl/chain.pem \\
    --privkey /etc/ssl/privkey.pem \\
    --token ABCDEFG123456
    --vip_name Virtual Server name
Exit Codes:
  0  Works as expected
  1  Somehting did not work
EOF
}

# ------------------------
# Defaults / ENV
# ------------------------
FGT_HOST=""
VDOM=""
CERT_NAME=""
CERT_BASE=""
LOCAL_FULLCHAIN=""
PRIVKEY=""
CHAIN=""
TOKEN=""
VIP_NAME=""
DATASOURCE="1"

# ------------------------
# Argument parsing
# ------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      FGT_HOST="${2:-}"; shift 2 ;;
    --vdom)
      VDOM="${2:-}"; shift 2 ;;
    --name)
      CERT_NAME="${2:-}"; shift 2 ;;
    --cert_base)
      CERT_BASE="${2:-}"; shift 2 ;;
    --cert_file)
      LOCAL_FULLCHAIN="${2:-}"; shift 2 ;;
    --privkey)
      PRIVKEY="${2:-}"; shift 2 ;;
    --cert_chain)
      CHAIN="${2:-}"; shift 2 ;;
    --token)
      TOKEN="${2:-}"; shift 2 ;;
    --vip_name)
      VIP_NAME="${2:-}"; shift 2 ;;
    --help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

# ------------------------
# Validation
# ------------------------
[[ -n "$FGT_HOST" ]]          || die "--host is required"
[[ -n "$VDOM" ]]          || die "--vdom is required"
[[ -n "$CERT_BASE" ]]     || die "--cert_base is required"
[[ -n "$LOCAL_FULLCHAIN" ]] || die "--cert_file is required"
[[ -f "$LOCAL_FULLCHAIN" ]] || die "File not found: $LOCAL_FULLCHAIN"
[[ -n "$PRIVKEY" ]]         || die "--privkey is required"
[[ -f "$PRIVKEY" ]]         || die "File not found: $PRIVKEY"
[[ -n "$CHAIN" ]]         || die "--cert_chain is required"
[[ -f "$CHAIN" ]]         || die "File not found: $CHAIN"
[[ -n "$TOKEN" ]]         || die "--token is required"
[[ -n "$VIP_NAME" ]]         || die "--Virtual Server name is required"

command -v jq >/dev/null 2>&1       || die "jq is required"
command -v openssl >/dev/null 2>&1  || die "openssl is required"
command -v curl >/dev/null 2>&1     || die "curl is required"

# ------------------------
# Get currently used Certificate on Virtual Server (VIP)
# ------------------------
CERT_NAME="$(curl -sk \
  "https://${FGT_HOST}/api/v2/cmdb/firewall/vip/${VIP_NAME}?vdom=${VDOM}" \
  -H "Authorization: Bearer ${TOKEN}" \
| jq -r '.results[0]["ssl-certificate"][0].name')"

  if [[ -z "$CERT_NAME" || "$CERT_NAME" == "null" ]]; then
    echo "ERROR: Could not determine certificate name from VIP ${VIP_NAME}"
    exit 1
  fi

echo "==> FortiGate: ${FGT_HOST}"
echo "==> VDOM: ${VDOM}"
echo "==> Using certificate from VIP '${VIP_NAME}'"

# ------------------------
# Prepare
# ------------------------
URL="https://${FGT_HOST}/api/v2/cmdb/vpn.certificate/local/${CERT_NAME}?vdom=${VDOM}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fgt_json="${tmpdir}/fgt.json"
fgt_pem="${tmpdir}/fgt.pem"
fgt_leaf="${tmpdir}/fgt_leaf.pem"
local_leaf="${tmpdir}/local_leaf.pem"


echo "==> Certname:  ${CERT_NAME}"
echo "==> Local Certificate: ${LOCAL_FULLCHAIN}"
echo

# ------------------------
# Fetch certificate metadata from FortiGate
# ------------------------
echo "==> Read certificate from FortiGate API"
curl -sk \
  "$URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json" > "$fgt_json"

status="$(jq -r '.status // empty' "$fgt_json")"
if [[ "$status" != "success" ]]; then
  echo "ERROR: FortiGate API response:"
  jq . "$fgt_json"
  exit 1
fi

# ------------------------
# Extract local leaf certificate
# ------------------------
cert_blob="$(jq -r '
  .results[0].certificate //
  .results[0].cert //
  .results[0]["local-cert"] //
  empty
' "$fgt_json")"

if [[ -z "$cert_blob" || "$cert_blob" == "null" ]]; then
  echo "ERROR: No certificate field found."
  echo "Available Keys:"
  jq '.results[0] | keys' "$fgt_json"
  exit 1
fi

if echo "$cert_blob" | grep -q "BEGIN CERTIFICATE"; then
  printf "%b" "$cert_blob" > "$fgt_pem"
else
  echo "$cert_blob" | tr -d '\n' | base64 -d > "$fgt_pem" \
    || { echo "ERROR: Certificate is not a valid PEM/Base64"; exit 1; }
fi

# ------------------------
# Extract Leaf certificates
# ------------------------
awk '
  /-----BEGIN CERTIFICATE-----/ {inside=1}
  inside {print}
  /-----END CERTIFICATE-----/ {exit}
' "$fgt_pem" > "$fgt_leaf"

awk '
  /-----BEGIN CERTIFICATE-----/ {inside=1}
  inside {print}
  /-----END CERTIFICATE-----/ {exit}
' "$LOCAL_FULLCHAIN" > "$local_leaf"

# ------------------------
# Compare fingerprints
# ------------------------
fgt_fp="$(openssl x509 -in "$fgt_leaf" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
loc_fp="$(openssl x509 -in "$local_leaf" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"

echo "==> FortiGate SHA256: $fgt_fp"
echo "==> Local     SHA256: $loc_fp"

if [[ "$fgt_fp" == "$loc_fp" ]]; then
  echo "✅ MATCH: Certificates are identical"
  exit 0
else
  echo "❌ MISMATCH: Certificates differ"
  echo "==> Certificates not match. Rotation needed."

# ------------------------
# Generate unique cert name for each new upload
# ------------------------  
stamp="$(date +%Y%m%d-%H%M%S)"
NEW_CERT_NAME="${CERT_BASE}.${stamp}"

echo "==> New cert name: $NEW_CERT_NAME"

# ------------------------
# Upload new certificate to FortiGate
# ------------------------
IMPORT_URL="https://${FGT_HOST}/api/v2/monitor/vpn-certificate/local/import?vdom=${VDOM}"

upload_resp="$(
curl -k -X POST \
  "$IMPORT_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
        "type": "regular",
        "certname": "'"${NEW_CERT_NAME}"'",
        "file_content": "'"$(base64 -w 0 "$LOCAL_FULLCHAIN")"'",
        "key_file_content": "'"$(base64 -w 0 "$PRIVKEY")"'",
        "scope": "vdom"
      }'
)"

# Pretty print response
echo "$upload_resp" | jq .

# Fail hard unless status == success
if [[ "$(echo "$upload_resp" | jq -r '.status // empty')" != "success" ]]; then
  echo "ERROR: FortiGate certificate import failed." >&2
  #echo "$upload_resp" | jq . >&2
  exit 1
fi

echo "✅ Certificate upload succeeded."

# ------------------------
# Upload certificate chain to FortiGate
# ------------------------
IMPORT_URL="https://${FGT_HOST}/api/v2/monitor/vpn-certificate/ca/import?vdom=${VDOM}"

upload_chain_resp="$(
curl -k -X POST \
  "$IMPORT_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
        "import_method": "file",
        "scope": "vdom",
        "file_content": "'"$(base64 -w 0 "$CHAIN")"'"
      }'
)"  
# Pretty print response
echo "$upload_chain_resp" | jq .  

# Fail hard unless status == success or http_status == 500 and error -328 (already exists)
cert_status="$(jq -r '.status // empty' <<<"$upload_chain_resp")"
http_status="$(jq -r '.http_status // empty' <<<"$upload_chain_resp")"
error_code="$(jq -r '.error // .error_code // empty' <<<"$upload_chain_resp")"

if [[ "$cert_status" == "success" ]]; then
  echo "✅ Certificate chain upload succeeded."
elif [[ "$cert_status" == "error" && "$http_status" == "500" && "$error_code" == "-328" ]]; then
  echo "⚠️ Certificate chain already exists on FortiGate, continuing..."
else
  echo "ERROR: FortiGate certificate chain import failed." >&2
  echo "$upload_chain_resp" | jq . >&2
  exit 1
fi

# ------------------------
# Update Virtual Server (VIP) to use new certificate
# ------------------------
VIP_URL="https://${FGT_HOST}/api/v2/cmdb/firewall/vip/${VIP_NAME}?vdom=${VDOM}&datasource=${DATASOURCE}"

update_resp="$(
curl -k -X PUT \
  "$VIP_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
        "ssl-certificate": [
          {
            "name": "'"${NEW_CERT_NAME}"'"
          }
         ]
      }'
)"

# Pretty print response
echo "$update_resp" | jq .

# Fail hard unless status == success
if [[ "$(echo "$update_resp" | jq -r '.status // empty')" == "success" ]]; then
  echo "✅ Certificate update for ${VIP_NAME} succeeded."

else
  echo "❌ERROR: FortiGate certificate update failed." >&2
  exit 1
fi

#------------------------
# Cleanup ceritifcates older than 90 days
#------------------------
echo "==> Cleaning up certificates older than 90 days (by date in name)"

# Safety options:
# 1) Do NOT delete the currently active certificate (CERT_NAME must be set)
# 2) Only delete certificates with $CERT_BASE prefix

CERT_LIST_URL="https://${FGT_HOST}/api/v2/cmdb/vpn.certificate/local?vdom=${VDOM}"
NOW_EPOCH="$(date +%s)"
MAX_AGE_DAYS=90
MAX_AGE_SECONDS=$((MAX_AGE_DAYS * 86400))

curl -sk "$CERT_LIST_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
| jq -r '.results[].name' \
| while read -r cert_name; do

    # Restrict deletions by prefix
    [[ "$cert_name" != ${CERT_BASE}* ]] && continue

    # Never delete the currently active certificate
    [[ -n "${CERT_NAME:-}" && "$cert_name" == "$CERT_NAME" ]] && continue

    # Extract YYYYMMDD from cert name (e.g. int.giata.de.20240123-141530)
    if [[ "$cert_name" =~ ([0-9]{8}) ]]; then
      cert_date="${BASH_REMATCH[1]}"
    else
      # No date in name → skip
      continue
    fi

    # Convert YYYYMMDD → epoch seconds
    cert_epoch="$(date -d "${cert_date}" +%s 2>/dev/null || true)"
    [[ -z "$cert_epoch" ]] && continue

    age_seconds=$((NOW_EPOCH - cert_epoch))

    if (( age_seconds < MAX_AGE_SECONDS )); then
      # Not old enough
      echo "==> Keeping recent certificate: $cert_name (date ${cert_date})"
    fi
    if (( age_seconds > MAX_AGE_SECONDS )); then
      echo "==> Deleting old certificate: $cert_name (date ${cert_date})"

      curl -sk -X DELETE \
        "https://${FGT_HOST}/api/v2/cmdb/vpn.certificate/local/${cert_name}?vdom=${VDOM}" \
        -H "Authorization: Bearer ${TOKEN}" \
      | jq .
    fi
done
fi
exit 0
