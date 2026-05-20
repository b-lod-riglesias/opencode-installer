#!/usr/bin/env bash
set -euo pipefail

OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
CONFIG_DIR="/root/.config/opencode"
JSON_CONF="$CONFIG_DIR/opencode.json"
JSONC_CONF="$CONFIG_DIR/opencode.jsonc"
SERVICE_NAME="opencode-web.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TTY_IN="${TTY:-/dev/tty}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] Ejecuta este script como root (o con sudo)."
    exit 1
  fi
}

need_tty() {
  if [[ ! -r "$TTY_IN" || ! -w "$TTY_IN" ]]; then
    echo "[ERROR] Este instalador necesita entrada interactiva (TTY) para pedir Base URL y API key."
    exit 1
  fi
}

read_input() {
  local prompt="$1"
  local varname="$2"
  local value=""
  IFS= read -r -p "$prompt" value < "$TTY_IN"
  printf -v "$varname" '%s' "$value"
}

read_secret() {
  local prompt="$1"
  local varname="$2"
  local value=""
  IFS= read -r -s -p "$prompt" value < "$TTY_IN"
  echo
  printf -v "$varname" '%s' "$value"
}

install_dependency() {
  local dep="$1"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y "$dep"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$dep"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$dep"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm "$dep"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$dep"
  else
    echo "[ERROR] No hay gestor de paquetes compatible para instalar '$dep'."
    exit 1
  fi
}

ensure_dependency() {
  local dep="$1"
  if need_cmd "$dep"; then
    return
  fi

  echo "[WARN] Falta dependencia: $dep"
  if [[ "$dep" == "curl" || "$dep" == "jq" ]]; then
    echo "[INFO] Intentando instalar $dep..."
    install_dependency "$dep"
    if need_cmd "$dep"; then
      echo "[OK] Dependencia instalada: $dep"
      return
    fi
  fi

  echo "[ERROR] No pude instalar '$dep'. Instálala y vuelve a ejecutar."
  exit 1
}

check_cpu() {
  local os
  local cpu
  os="$(uname -s)"
  cpu="$(uname -m)"

  if [[ "$os" != "Linux" ]]; then
    echo "[ERROR] Instalador soportado solo en Linux. Detectado: $os"
    exit 1
  fi

  case "$cpu" in
    x86_64|amd64|aarch64|arm64)
      echo "[OK] CPU compatible: $cpu"
      ;;
    *)
      echo "[ERROR] Arquitectura no soportada para este instalador: $cpu"
      echo "[INFO] Arquitecturas probadas: x86_64 o aarch64/arm64"
      exit 1
      ;;
  esac
}

detect_primary_network() {
  PRIMARY_IFACE=""
  PRIMARY_IP=""

  if command -v ip >/dev/null 2>&1; then
    PRIMARY_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
    PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  fi

  if [[ -z "$PRIMARY_IP" ]] && command -v hostname >/dev/null 2>&1; then
    PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
}

configure_internal_dns() {
  detect_primary_network

  if [[ ! "$PRIMARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[WARN] No pude detectar la IP principal del host; no configuro DNS interno automáticamente."
    return
  fi

  INTERNAL_DNS="${PRIMARY_IP%.*}.254"
  echo "[INFO] IP principal detectada: $PRIMARY_IP"
  echo "[INFO] DNS interno derivado: $INTERNAL_DNS"

  if systemctl list-unit-files systemd-resolved.service --no-legend 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/opencode-litellm-dns.conf <<EOF_DNS
[Resolve]
DNS=$INTERNAL_DNS
Domains=~cpd.local
EOF_DNS
    systemctl restart systemd-resolved.service || true

    if [[ -n "$PRIMARY_IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns "$PRIMARY_IFACE" "$INTERNAL_DNS" || true
      resolvectl domain "$PRIMARY_IFACE" "~cpd.local" || true
    fi

    echo "[OK] DNS interno configurado para cpd.local con systemd-resolved."
    return
  fi

  if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
    cp /etc/resolv.conf "/etc/resolv.conf.opencode-litellm.bak.$(date +%s)"
    if ! grep -qE "^[[:space:]]*nameserver[[:space:]]+$INTERNAL_DNS([[:space:]]|$)" /etc/resolv.conf; then
      {
        echo "nameserver $INTERNAL_DNS"
        cat /etc/resolv.conf
      } > /tmp/opencode-litellm-resolv.conf
      cp /tmp/opencode-litellm-resolv.conf /etc/resolv.conf
      rm -f /tmp/opencode-litellm-resolv.conf
    fi
    echo "[OK] DNS interno añadido a /etc/resolv.conf."
    return
  fi

  echo "[WARN] No pude dejar DNS persistente automáticamente. Usa DNS $INTERNAL_DNS para resolver cpd.local."
}

install_opencode() {
  echo "[WARN] No encuentro opencode en $OPENCODE_BIN ni en PATH."
  echo "[INFO] Instalando opencode con el instalador oficial..."
  curl -fsSL https://opencode.ai/install | bash

  if [[ -x "/root/.opencode/bin/opencode" ]]; then
    OPENCODE_BIN="/root/.opencode/bin/opencode"
  elif command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN="$(command -v opencode)"
  else
    echo "[ERROR] opencode no quedó instalado o no está en PATH."
    exit 1
  fi

  echo "[OK] opencode instalado en $OPENCODE_BIN"
}

expose_opencode_command() {
  if [[ ! -x "$OPENCODE_BIN" ]]; then
    echo "[ERROR] opencode no es ejecutable en $OPENCODE_BIN"
    exit 1
  fi

  if [[ "$OPENCODE_BIN" != "/usr/local/bin/opencode" ]]; then
    ln -sf "$OPENCODE_BIN" /usr/local/bin/opencode
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    echo "[ERROR] No pude dejar opencode disponible en PATH."
    echo "        Binario detectado: $OPENCODE_BIN"
    echo "        Enlace esperado: /usr/local/bin/opencode"
    exit 1
  fi

  OPENCODE_CMD="$(command -v opencode)"
  echo "[OK] Comando opencode disponible en $OPENCODE_CMD"
}

parse_base_url() {
  local base="$1"
  BASE_URL_RAW="$base"

  if [[ "$BASE_URL_RAW" != http://* && "$BASE_URL_RAW" != https://* ]]; then
    echo "[ERROR] La Base URL debe empezar por http:// o https://"
    exit 1
  fi

  BASE_URL_RAW="${BASE_URL_RAW%/}"
  if [[ "$BASE_URL_RAW" != */v1 ]]; then
    BASE_URL_RAW="${BASE_URL_RAW}/v1"
  fi

  SCHEME="${BASE_URL_RAW%%://*}"
  REST="${BASE_URL_RAW#*://}"
  HOSTPORT="${REST%%/*}"
  LITELLM_HOST="${HOSTPORT%%:*}"
  LITELLM_PORT="${HOSTPORT##*:}"

  if [[ "$LITELLM_HOST" == "$LITELLM_PORT" ]]; then
    LITELLM_PORT=""
  fi

  if [[ -z "$LITELLM_PORT" ]]; then
    if [[ "$SCHEME" == "https" ]]; then
      LITELLM_PORT="443"
    else
      LITELLM_PORT="80"
    fi
  fi
}

main() {
  ensure_root
  need_tty
  check_cpu

  ensure_dependency curl
  ensure_dependency jq
  ensure_dependency systemctl
  configure_internal_dns

  if [[ ! -x "$OPENCODE_BIN" ]]; then
    if command -v opencode >/dev/null 2>&1; then
      OPENCODE_BIN="$(command -v opencode)"
    else
      install_opencode
    fi
  fi
  expose_opencode_command

  read_input "[1/5] Base URL de LiteLLM [http://lllm.cpd.local/v1]: " LITELLM_BASE_URL
  LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://lllm.cpd.local/v1}"
  parse_base_url "$LITELLM_BASE_URL"

  read_input "[2/5] IP opcional para forzar ${LITELLM_HOST} en /etc/hosts (normalmente vacío): " LITELLM_IP
  read_input "[3/5] Puerto donde publicar opencode web [4000]: " OPENCODE_PORT
  OPENCODE_PORT="${OPENCODE_PORT:-4000}"
  read_input "[4/5] Dominio a usar en la config [${LITELLM_HOST}]: " LITELLM_DOMAIN
  LITELLM_DOMAIN="${LITELLM_DOMAIN:-$LITELLM_HOST}"
  read_secret "[5/5] API Key de LiteLLM: " API_KEY

  if [[ -z "$API_KEY" ]]; then
    echo "[ERROR] La clave API no puede quedar vacía."
    exit 1
  fi

  if [[ -n "${LITELLM_IP:-}" ]]; then
    echo "[INFO] Configurando resolución local de $LITELLM_DOMAIN -> $LITELLM_IP en /etc/hosts"
    sed -i "/[[:space:]]\b${LITELLM_DOMAIN}\b/d" /etc/hosts
    echo "$LITELLM_IP $LITELLM_DOMAIN" >> /etc/hosts
  else
    if getent hosts "$LITELLM_HOST" >/dev/null 2>&1; then
      RESOLVED_IP="$(getent hosts "$LITELLM_HOST" | awk '{print $1}' | head -n 1)"
      echo "[OK] $LITELLM_HOST resuelve por DNS a $RESOLVED_IP"
    else
      echo "[WARN] $LITELLM_HOST no resuelve por DNS. Si falla la prueba, repite indicando una IP para /etc/hosts."
    fi
  fi

  if [[ "$SCHEME" == "http" && "$LITELLM_PORT" == "80" ]]; then
    API_BASE_URL="$SCHEME://$LITELLM_DOMAIN/v1"
  elif [[ "$SCHEME" == "https" && "$LITELLM_PORT" == "443" ]]; then
    API_BASE_URL="$SCHEME://$LITELLM_DOMAIN/v1"
  else
    API_BASE_URL="$SCHEME://$LITELLM_DOMAIN:$LITELLM_PORT/v1"
  fi
  MODELS_URL="$API_BASE_URL/models"

  echo "[CHECK] Probando conectividad y clave API contra $MODELS_URL ..."
  TMP_JSON="/tmp/opencode_litellm_models.$$"
  HTTP_STATUS="$(curl -sS --max-time 20 -o "$TMP_JSON" -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    "$MODELS_URL")"

  if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "[ERROR] No pude conectar al endpoint. HTTP=$HTTP_STATUS"
    echo "        Comprueba IP/puerto/dominio y API key."
    if [[ -s "$TMP_JSON" ]]; then
      cat "$TMP_JSON"
    fi
    rm -f "$TMP_JSON"
    exit 1
  fi

  if ! jq empty "$TMP_JSON" >/dev/null 2>&1; then
    echo "[ERROR] La respuesta del endpoint no es JSON válido."
    cat "$TMP_JSON"
    rm -f "$TMP_JSON"
    exit 1
  fi

  MODEL_IDS_RAW="$(jq -r 'if has("data") then .data[].id elif has("models") then .models[].id else .[]?.id end' "$TMP_JSON" | sed '/^null$/d' | sort -u)"
  if [[ -z "$MODEL_IDS_RAW" ]]; then
    echo "[ERROR] No encontré modelos en la respuesta de /v1/models."
    cat "$TMP_JSON"
    rm -f "$TMP_JSON"
    exit 1
  fi
  rm -f "$TMP_JSON"

  MODELS_JSON="$(printf '%s\n' "$MODEL_IDS_RAW" | jq -Rsc 'split("\n") | map(select(length>0)) | map({(.): {name: .}}) | add')"
  DEFAULT_MODEL="$(printf '%s\n' "$MODEL_IDS_RAW" | head -n 1)"

  echo "[OK] Conexión correcta. Modelos detectados:"
  printf '%s\n' "$MODEL_IDS_RAW" | sed 's/^/  - /'

  echo "[INFO] Escribiendo configuración en $JSON_CONF y $JSONC_CONF"
  mkdir -p "$CONFIG_DIR"

  jq -n \
    --arg schema "https://opencode.ai/config.json" \
    --arg hostname "0.0.0.0" \
    --arg baseurl "$API_BASE_URL" \
    --arg apikey "$API_KEY" \
    --argjson models "$MODELS_JSON" \
    --arg default_model "$DEFAULT_MODEL" \
    '{
      "$schema": $schema,
      "server": {"hostname": $hostname},
      "provider": {
        "litellm": {
          "npm": "@ai-sdk/openai-compatible",
          "name": "LiteLLM",
          "options": {
            "baseURL": $baseurl,
            "apiKey": $apikey
          },
          "models": $models
        }
      },
      "model": ("litellm/" + $default_model)
    }' > "$JSON_CONF"
  cp "$JSON_CONF" "$JSONC_CONF"

  echo "[INFO] Generando servicio systemd: $SERVICE_PATH"
  cat > "$SERVICE_PATH" <<EOF_SERVICE
[Unit]
Description=opencode web
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root
Environment=HOME=/root
Environment=PATH=/root/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${OPENCODE_BIN} web --hostname 0.0.0.0 --port ${OPENCODE_PORT}
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "[ERROR] El servicio no quedó activo. Revisa: journalctl -u $SERVICE_NAME -n 60"
    exit 1
  fi

  if ! curl -sS --max-time 10 "http://127.0.0.1:$OPENCODE_PORT/ui/" >/dev/null; then
    echo "[ADVERTENCIA] El servicio está activo, pero no respondió en http://127.0.0.1:$OPENCODE_PORT/ui/."
  else
    echo "[OK] opencode web responde en http://127.0.0.1:$OPENCODE_PORT/ui/"
  fi

  echo
  printf '[FINAL] Instalado y activo con:\n'
  printf '  - Config: %s\n  - Configc: %s\n' "$JSON_CONF" "$JSONC_CONF"
  printf '  - Servicio: %s\n' "$SERVICE_NAME"
  printf '  - Comando opencode: %s\n' "$OPENCODE_CMD"
  printf '  - URL base: %s\n' "http://$LITELLM_DOMAIN:$OPENCODE_PORT/ui/"
  printf '  - API usada: %s\n' "$API_BASE_URL"
  printf '  - Modelo por defecto: litellm/%s\n' "$DEFAULT_MODEL"
  printf '  - Recarga shell si tu terminal cacheo comandos: hash -r\n'
  echo
}

main "$@"
