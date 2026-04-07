#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="uton88"
REPO_NAME="dan-binary-releases"

COMPONENT="dan-web"
INSTALL_DIR="$PWD/dan-runtime"
VERSION="latest"
CPA_BASE_URL=""
CPA_TOKEN=""
MAIL_API_URL=""
MAIL_API_KEY=""
UPLOAD_API_URL="https://example.com/v0/management/auth-files"
UPLOAD_API_TOKEN="replace-me"
USE_DOMAINS=".com,.org,.net"
THREADS="68"
OTP_RETRY_COUNT="12"
OTP_RETRY_INTERVAL_SECONDS="5"
WEB_TOKEN="linuxdo"
CLIENT_API_TOKEN="linuxdo"
PORT="25666"
DEFAULT_PROXY=""
DEFAULT_DOMAINS_API_URL="https://gpt-up.icoa.pp.ua/v0/management/domains"
SYSTEMD="0"
SERVICE_NAME="dan-web"

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Options:
  --component dan-web|dan|dan-token-refresh
  --install-dir DIR
  --version latest|vX.Y.Z
  --cpa-base-url URL
  --cpa-token TOKEN
  --mail-api-url URL
  --mail-api-key KEY
  --upload-api-url URL
  --upload-api-token TOKEN
  --use-domains SUFFIXES
  --threads N
  --otp-retry-count N
  --otp-retry-interval-seconds N
  --web-token TOKEN
  --client-api-token TOKEN
  --port N
  --default-proxy URL
  --systemd
  --service-name NAME
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --cpa-base-url) CPA_BASE_URL="${2:-}"; shift 2 ;;
    --cpa-token) CPA_TOKEN="${2:-}"; shift 2 ;;
    --mail-api-url) MAIL_API_URL="${2:-}"; shift 2 ;;
    --mail-api-key) MAIL_API_KEY="${2:-}"; shift 2 ;;
    --upload-api-url) UPLOAD_API_URL="${2:-}"; shift 2 ;;
    --upload-api-token) UPLOAD_API_TOKEN="${2:-}"; shift 2 ;;
    --use-domains) USE_DOMAINS="${2:-}"; shift 2 ;;
    --threads) THREADS="${2:-}"; shift 2 ;;
    --otp-retry-count) OTP_RETRY_COUNT="${2:-}"; shift 2 ;;
    --otp-retry-interval-seconds) OTP_RETRY_INTERVAL_SECONDS="${2:-}"; shift 2 ;;
    --web-token) WEB_TOKEN="${2:-}"; shift 2 ;;
    --client-api-token) CLIENT_API_TOKEN="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --default-proxy) DEFAULT_PROXY="${2:-}"; shift 2 ;;
    --systemd) SYSTEMD="1"; shift ;;
    --service-name) SERVICE_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd curl

json_escape() {
  local value="${1-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

trim() {
  printf '%s' "${1-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

resolve_domains_api_url() {
  local base
  base="$(trim "${CPA_BASE_URL:-}")"
  if [[ -z "$base" ]]; then
    printf '%s' "$DEFAULT_DOMAINS_API_URL"
    return
  fi
  base="${base%/}"
  if [[ "$base" == */v0/management/domains ]]; then
    printf '%s' "$base"
  elif [[ "$base" == */v0/management ]]; then
    printf '%s/domains' "$base"
  else
    printf '%s/v0/management/domains' "$base"
  fi
}

fetch_domains_json() {
  local url raw compact domains
  url="$1"
  raw="$(curl -fsSL "$url")" || {
    echo "Failed to fetch domains from ${url}" >&2
    exit 1
  }
  compact="$(printf '%s' "$raw" | tr -d '\r\n')"
  domains="$(printf '%s' "$compact" | sed -n 's/.*"domains"[[:space:]]*:[[:space:]]*\(\[[^]]*]\).*/\1/p')"
  if [[ -z "$domains" ]]; then
    echo "Domains API returned an invalid payload: $raw" >&2
    exit 1
  fi
  if [[ "$domains" == "[]" ]]; then
    echo "Domains API returned an empty domains list." >&2
    exit 1
  fi
  printf '%s' "$domains"
}

filter_domains_json() {
  local domains suffixes filtered status
  domains="$1"
  suffixes="$2"
  if ! filtered="$(
    printf '%s' "$domains" | awk -v suffixes="$suffixes" '
      BEGIN {
        ORS = ""
        print "["
        first = 1
        count = split(suffixes, raw, ",")
        valid = 0
        for (i = 1; i <= count; i++) {
          suffix = raw[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", suffix)
          suffix = tolower(suffix)
          if (suffix != "") {
            valid++
            allowed[valid] = suffix
          }
        }
        if (valid == 0) {
          exit 2
        }
      }
      {
        while (match($0, /"[^"]+"/)) {
          item = substr($0, RSTART + 1, RLENGTH - 2)
          lower = tolower(item)
          matched = 0
          for (i = 1; i <= valid; i++) {
            suffix = allowed[i]
            if (length(lower) >= length(suffix) && substr(lower, length(lower) - length(suffix) + 1) == suffix) {
              matched = 1
              break
            }
          }
          if (matched) {
            if (!first) {
              print ", "
            }
            printf "\"%s\"", item
            first = 0
          }
          $0 = substr($0, RSTART + RLENGTH)
        }
      }
      END {
        print "]"
      }
    '
  )"; then
    status=$?
  else
    status=0
  fi
  if [[ "$status" -eq 2 ]]; then
    echo "--use-domains must contain at least one suffix." >&2
    exit 1
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "Failed to filter domains." >&2
    exit 1
  fi
  if [[ "$filtered" == "[]" ]]; then
    echo "Domains API returned no domains matching --use-domains=${suffixes}." >&2
    exit 1
  fi
  printf '%s' "$filtered"
}

detect_os() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) echo "Unsupported operating system: $(uname -s)" >&2; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

build_release_base() {
  if [[ "$VERSION" == "latest" ]]; then
    printf 'https://github.com/%s/%s/releases/latest/download' "$REPO_OWNER" "$REPO_NAME"
  else
    printf 'https://github.com/%s/%s/releases/download/%s' "$REPO_OWNER" "$REPO_NAME" "$VERSION"
  fi
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

if [[ "$OS" == "windows" ]]; then
  echo "Use install.ps1 on Windows." >&2
  exit 1
fi

if [[ "$SYSTEMD" == "1" && "$OS" != "linux" ]]; then
  echo "--systemd is only supported on Linux." >&2
  exit 1
fi

if [[ "$SYSTEMD" == "1" && "$INSTALL_DIR" == "$PWD/dan-runtime" ]]; then
  INSTALL_DIR="/opt/dan-runtime"
fi

case "$COMPONENT" in
  dan|dan-web|dan-token-refresh) ;;
  *) echo "Unsupported component: $COMPONENT" >&2; exit 1 ;;
esac

ASSET_NAME="${COMPONENT}-${OS}-${ARCH}"
LOCAL_BINARY="$COMPONENT"
RELEASE_BASE="$(build_release_base)"
DOWNLOAD_URL="https://github.com/uton88/dan-binary-releases/releases/latest/download/${ASSET_NAME}"
CHECKSUM_URL="${RELEASE_BASE}/SHA256SUMS.txt"
TMP_BINARY="$INSTALL_DIR/.${LOCAL_BINARY}.download.$$"

mkdir -p "$INSTALL_DIR/config"

cleanup() {
  rm -f "$TMP_BINARY" "$INSTALL_DIR/SHA256SUMS.unix.txt"
}
trap cleanup EXIT

echo "Downloading ${ASSET_NAME}..."
curl -fL "$DOWNLOAD_URL" -o "$TMP_BINARY"
chmod +x "$TMP_BINARY"

echo "Downloading SHA256SUMS.txt..."
curl -fL "$CHECKSUM_URL" -o "$INSTALL_DIR/SHA256SUMS.txt"
tr -d '\r' < "$INSTALL_DIR/SHA256SUMS.txt" > "$INSTALL_DIR/SHA256SUMS.unix.txt"
expected="$(awk -v name="$ASSET_NAME" '$2 == name { print $1; exit }' "$INSTALL_DIR/SHA256SUMS.unix.txt")"
[[ -n "$expected" ]] || { echo "Missing checksum entry for ${ASSET_NAME}." >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$TMP_BINARY" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || { echo "Checksum verification failed." >&2; exit 1; }
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$TMP_BINARY" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || { echo "Checksum verification failed." >&2; exit 1; }
else
  echo "No checksum tool found; skipped verification."
fi

mv -f "$TMP_BINARY" "$INSTALL_DIR/$LOCAL_BINARY"
chmod +x "$INSTALL_DIR/$LOCAL_BINARY"

DOMAINS_API_URL=$DEFAULT_DOMAINS_API_URL
echo "Fetching domains from ${DOMAINS_API_URL}..."
DOMAINS_JSON="$(fetch_domains_json "$DOMAINS_API_URL")"
FILTERED_DOMAINS_JSON="$(filter_domains_json "$DOMAINS_JSON" "$USE_DOMAINS")"

cat > "$INSTALL_DIR/config.json" <<EOF
{
  "ak_file": "ak.txt",
  "rk_file": "rk.txt",
  "token_json_dir": "codex_tokens",
  "server_config_url": "",
  "server_api_token": "",
  "domain_report_url": "",
  "upload_api_url": "$(json_escape "$UPLOAD_API_URL")",
  "upload_api_token": "$(json_escape "$UPLOAD_API_TOKEN")",
  "oauth_issuer": "https://auth.openai.com",
  "oauth_client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "oauth_redirect_uri": "http://localhost:1455/auth/callback",
  "enable_oauth": true,
  "oauth_required": true
}
EOF

cat > "$INSTALL_DIR/config/web_config.json" <<EOF
{
  "target_min_tokens": 15000,
  "auto_fill_start_gap": 1,
  "check_interval_minutes": 1,
  "manual_default_threads": ${THREADS},
  "manual_register_retries": 3,
  "otp_retry_count": ${OTP_RETRY_COUNT},
  "otp_retry_interval_seconds": ${OTP_RETRY_INTERVAL_SECONDS},
  "web_token": "$(json_escape "$WEB_TOKEN")",
  "client_api_token": "$(json_escape "$CLIENT_API_TOKEN")",
  "client_notice": "",
  "minimum_client_version": "",
  "enabled_email_domains": ${FILTERED_DOMAINS_JSON},
  "mail_domain_options": ${FILTERED_DOMAINS_JSON},
  "default_proxy": "$(json_escape "$DEFAULT_PROXY")",
  "use_registration_proxy": $([[ -n "${DEFAULT_PROXY// }" ]] && printf 'true' || printf 'false'),
  "cpa_base_url": "$(json_escape "$CPA_BASE_URL")",
  "cpa_token": "$(json_escape "$CPA_TOKEN")",
  "mail_api_url": "$(json_escape "$MAIL_API_URL")",
  "mail_api_key": "$(json_escape "$MAIL_API_KEY")",
  "port": ${PORT}
}
EOF

if [[ "$SYSTEMD" == "1" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "--systemd requires root." >&2
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl is not available on this host." >&2
    exit 1
  fi

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${SERVICE_NAME}
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${LOCAL_BINARY}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
fi

echo
echo "Installed to: $INSTALL_DIR"
echo "Binary: $INSTALL_DIR/$LOCAL_BINARY"
echo "Config: $INSTALL_DIR/config/web_config.json"
echo
if [[ "$SYSTEMD" == "1" ]]; then
  echo "Service: ${SERVICE_NAME}.service"
  echo "Start manually:"
  echo "  systemctl enable ${SERVICE_NAME}.service"
  echo "  systemctl start ${SERVICE_NAME}.service"
  echo "Check:"
  echo "  systemctl status ${SERVICE_NAME}.service"
  echo "  journalctl -u ${SERVICE_NAME}.service -f"
else
  echo "Start command:"
  echo "  cd \"$INSTALL_DIR\" && ./${LOCAL_BINARY}"
fi
