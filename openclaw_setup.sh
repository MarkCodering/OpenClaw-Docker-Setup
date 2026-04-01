#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-openclaw}"
IMAGE="${IMAGE:-alpine/openclaw:latest}"
HOST_PORT_GATEWAY="${HOST_PORT_GATEWAY:-18789}"
HOST_PORT_BROWSER="${HOST_PORT_BROWSER:-18791}"
DATA_DIR="${DATA_DIR:-$HOME/openclaw-data}"
AUTO_APPROVE_DEVICE="${AUTO_APPROVE_DEVICE:-true}"
SETUP_CODEX_AUTH="${SETUP_CODEX_AUTH:-ask}"
CODEX_AUTH_METHOD="${CODEX_AUTH_METHOD:-ask}"
CODEX_API_KEY="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-120}"

LOCALHOST_URL="http://localhost:${HOST_PORT_GATEWAY}"
LOOPBACK_URL="http://127.0.0.1:${HOST_PORT_GATEWAY}"

info() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[warn] %s\n' "$*" >&2; }
err()  { printf '\n[error] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

docker_exec() {
  docker exec "${CONTAINER_NAME}" sh -lc "$1"
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || err "Invalid port: ${port}"
  (( port >= 1 && port <= 65535 )) || err "Port out of range: ${port}"
}

validate_inputs() {
  [[ -n "${CONTAINER_NAME}" ]] || err "CONTAINER_NAME cannot be empty"
  [[ -n "${IMAGE}" ]] || err "IMAGE cannot be empty"
  [[ -n "${DATA_DIR}" ]] || err "DATA_DIR cannot be empty"

  validate_port "${HOST_PORT_GATEWAY}"
  validate_port "${HOST_PORT_BROWSER}"
  [[ "${HOST_PORT_GATEWAY}" != "${HOST_PORT_BROWSER}" ]] || err "Gateway and browser ports must differ"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply=""

  if ! is_tty; then
    [[ "${default}" =~ ^[Yy]$ ]]
    return
  fi

  read -r -p "${prompt} " reply
  reply="${reply:-${default}}"
  [[ "${reply}" =~ ^[Yy]$ ]]
}

wait_until() {
  local description="$1"
  local command="$2"
  local timeout="${3:-${WAIT_TIMEOUT_SECONDS}}"
  local interval="${4:-2}"
  local elapsed=0

  info "Waiting for ${description}"
  while (( elapsed < timeout )); do
    if eval "${command}"; then
      return 0
    fi
    sleep "${interval}"
    ((elapsed += interval))
  done

  return 1
}

cleanup_on_error() {
  warn "Script failed near line $1"
  warn "Recent logs:"
  docker logs --tail 120 "${CONTAINER_NAME}" 2>/dev/null || true
}
trap 'cleanup_on_error $LINENO' ERR

install_codex_if_needed() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    warn "Codex CLI not installed and npm is unavailable."
    warn "Skipping Codex setup. Install later with: npm i -g @openai/codex"
    return 1
  fi

  info "Installing Codex CLI"
  npm i -g @openai/codex
}

normalize_codex_auth_method() {
  case "$(lower "$1")" in
    1|login|browser|chatgpt|codex)
      printf '1'
      ;;
    2|api|api-key|apikey|key|token)
      printf '2'
      ;;
    3|skip|none|no)
      printf '3'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

setup_codex_auth() {
  local setup_choice="${SETUP_CODEX_AUTH}"
  local auth_choice
  auth_choice="$(normalize_codex_auth_method "${CODEX_AUTH_METHOD}")"

  if [[ "${setup_choice}" == "ask" ]]; then
    if ! is_tty; then
      info "Skipping Codex auth because no interactive terminal is attached"
      return 0
    fi

    echo
    echo "Set up Codex CLI auth?"
    echo "  1) Yes"
    echo "  2) No"
    read -r -p "Choose 1 or 2: " setup_choice
  fi

  case "$(lower "${setup_choice}")" in
    1|yes)
      ;;
    *)
      return 0
      ;;
  esac

  install_codex_if_needed || return 0

  if [[ "${auth_choice}" == "ask" ]]; then
    if ! is_tty; then
      warn "Codex auth requested but no interactive terminal is attached"
      return 0
    fi

    echo
    echo "Choose Codex auth method:"
    echo "  1) ChatGPT / Codex account login"
    echo "  2) API key"
    echo "  3) Skip"
    read -r -p "Choose 1, 2, or 3: " auth_choice
  fi

  auth_choice="$(normalize_codex_auth_method "${auth_choice}")"

  case "${auth_choice}" in
    1)
      info "Starting browser-based Codex login"
      codex login
      ;;
    2)
      if [[ -z "${CODEX_API_KEY:-}" ]]; then
        if ! is_tty; then
          err "CODEX_API_KEY is empty and no interactive terminal is attached"
        fi
        read -r -s -p "Paste your API key for Codex CLI: " CODEX_API_KEY
        echo
      fi
      [[ -n "${CODEX_API_KEY:-}" ]] || err "CODEX_API_KEY is empty"
      info "Logging Codex CLI in with API key"
      printf '%s' "${CODEX_API_KEY}" | codex login --with-api-key
      ;;
    3)
      info "Skipping Codex auth"
      ;;
    *)
      err "Invalid Codex auth choice"
      ;;
  esac

  if [[ "${auth_choice}" != "3" ]]; then
    info "Codex login status"
    codex login status || true
  fi
}

prepare_data_dir() {
  info "Preparing data directory: ${DATA_DIR}"
  mkdir -p "${DATA_DIR}"
  chmod 700 "${DATA_DIR}" || true
}

remove_old_container() {
  if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    info "Removing existing container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi
}

start_container() {
  info "Starting OpenClaw container"
  docker run -d \
    --restart unless-stopped \
    --name "${CONTAINER_NAME}" \
    -p "${HOST_PORT_GATEWAY}:18789" \
    -p "${HOST_PORT_BROWSER}:18791" \
    -v "${DATA_DIR}:/home/node/.openclaw" \
    "${IMAGE}" >/dev/null
}

wait_for_cli() {
  wait_until \
    "OpenClaw CLI to become ready" \
    "docker_exec 'openclaw --help >/dev/null 2>&1'" \
    "${WAIT_TIMEOUT_SECONDS}" \
    2 || err "OpenClaw CLI did not become ready in time"
}

configure_openclaw() {
  info "Configuring OpenClaw gateway and Control UI"

  docker_exec "
    set -e
    openclaw config set gateway.bind "\"lan\""
    openclaw config set gateway.auth.mode "\"token\""
    openclaw config set gateway.controlUi.allowedOrigins '[\"${LOCALHOST_URL}\",\"${LOOPBACK_URL}\"]'
    openclaw config set gateway.controlUi.allowInsecureAuth true
    openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true
  "

  info "Waiting for config writes and internal reload"
  sleep 5
}

restart_container() {
  info "Restarting OpenClaw container"
  docker restart "${CONTAINER_NAME}" >/dev/null

  wait_until \
    "OpenClaw to become ready after restart" \
    "docker_exec 'openclaw --help >/dev/null 2>&1'" \
    "${WAIT_TIMEOUT_SECONDS}" \
    2 || err "OpenClaw did not come back after restart"
}

wait_for_gateway_bind() {
  wait_until \
    "gateway bind on 0.0.0.0:${HOST_PORT_GATEWAY}" \
    "docker logs '${CONTAINER_NAME}' 2>&1 | grep -q 'listening on ws://0.0.0.0:${HOST_PORT_GATEWAY}'" \
    "${WAIT_TIMEOUT_SECONDS}" \
    2 || warn "Did not detect explicit 0.0.0.0 bind yet"
}

show_binding_status() {
  info "Binding status"
  docker logs "${CONTAINER_NAME}" 2>&1 \
    | grep -E "canvas|listening on ws://|Browser control listening on http://" \
    | tail -n 12 || true
}

extract_token() {
  docker_exec "grep -o '\"token\": \"[^\"]*\"' /home/node/.openclaw/openclaw.json 2>/dev/null | head -n1 | sed 's/\"token\": \"//; s/\"$//'" \
    || true
}

wait_for_token() {
  local token=""

  info "Waiting for gateway token"
  for ((i = 0; i < WAIT_TIMEOUT_SECONDS; i += 2)); do
    token="$(extract_token)"
    if [[ -n "${token}" ]]; then
      printf '%s' "${token}"
      return 0
    fi
    sleep 2
  done
  return 1
}

show_devices() {
  info "Current device list"
  docker_exec 'openclaw devices list' || true
}

find_first_pending_device() {
  docker_exec 'openclaw devices list' \
    | awk '
        /Pending \([1-9][0-9]*\)/ { pending=1; next }
        pending && match($0, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) {
          print substr($0, RSTART, RLENGTH); exit
        }
      ' || true
}

approve_pending_device_if_requested() {
  local approve="${AUTO_APPROVE_DEVICE}"

  if [[ "${approve}" == "ask" ]]; then
    echo
    ask_yes_no "Approve the first pending device automatically? (y/N):" "N" || return 0
  elif [[ ! "${approve}" =~ ^(1|true|yes|y)$ ]]; then
    return 0
  fi

  local request_id=""
  request_id="$(find_first_pending_device)"

  if [[ -z "${request_id}" ]]; then
    warn "No pending request ID found"
    return 0
  fi

  info "Approving pending device: ${request_id}"
  docker_exec "openclaw devices approve ${request_id}" || true
}

wait_for_and_approve_device() {
  local approve
  local request_id=""
  approve="$(lower "${AUTO_APPROVE_DEVICE}")"

  if [[ ! "${approve}" =~ ^(1|true|yes|y|ask)$ ]]; then
    return 0
  fi

  if [[ "${approve}" == "ask" ]]; then
    approve_pending_device_if_requested
    return 0
  fi

  info "Waiting for a pending device request to auto-approve"
  for ((i = 0; i < WAIT_TIMEOUT_SECONDS; i += 2)); do
    request_id="$(find_first_pending_device)"
    if [[ -n "${request_id}" ]]; then
      info "Approving pending device: ${request_id}"
      docker_exec "openclaw devices approve ${request_id}" || true
      return 0
    fi
    sleep 2
  done

  warn "No pending device request appeared during the auto-approve window"
}

print_logs() {
  info "Recent logs"
  docker logs --tail 60 "${CONTAINER_NAME}" || true
}

print_summary() {
  local token="$1"

  echo
  echo "OpenClaw setup complete."
  echo
  echo "Binding:"
  echo "  Gateway URL: ${LOCALHOST_URL}"
  echo "  Loopback URL: ${LOOPBACK_URL}"
  echo "  Gateway WS:  ws://localhost:${HOST_PORT_GATEWAY}"
  echo "  Browser control port published: ${HOST_PORT_BROWSER}"
  echo "  Device auto-approve: ${AUTO_APPROVE_DEVICE}"
  echo
  echo "Open this exact URL in a fresh Incognito / Private window:"
  echo "  ${LOCALHOST_URL}/#token=${token}"
  echo
  echo "Use only one host consistently."
  echo "Recommended:"
  echo "  ${LOCALHOST_URL}"
  echo
  echo "If the UI says 'pairing required':"
  echo "  docker exec ${CONTAINER_NAME} sh -lc 'openclaw devices list'"
  echo "  docker exec ${CONTAINER_NAME} sh -lc 'openclaw devices approve <REQUEST_ID>'"
  echo
  echo "Useful commands:"
  echo "  docker logs -f ${CONTAINER_NAME}"
  echo "  docker exec -it ${CONTAINER_NAME} sh"
  echo "  docker exec ${CONTAINER_NAME} sh -lc 'openclaw dashboard --no-open'"
  echo "  docker exec ${CONTAINER_NAME} sh -lc 'openclaw devices list'"
  echo
}

main() {
  require_cmd docker
  require_cmd grep
  require_cmd sed
  require_cmd awk
  validate_inputs

  prepare_data_dir
  setup_codex_auth
  remove_old_container
  start_container
  wait_for_cli
  configure_openclaw
  restart_container
  wait_for_gateway_bind
  show_binding_status
  print_logs

  local token=""
  token="$(wait_for_token || true)"

  if [[ -z "${token}" ]]; then
    warn "Could not extract token automatically."
    warn "Run this to get a tokenized URL:"
    warn "  docker exec ${CONTAINER_NAME} sh -lc 'openclaw dashboard --no-open'"
  else
    print_summary "${token}"
  fi

  show_devices
  wait_for_and_approve_device
  show_devices

  echo
  echo "Done."
}

main "$@"
