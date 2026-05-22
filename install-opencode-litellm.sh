#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR_GLOBAL="/usr/local/share/opencode"
OPENCODE_BIN="${OPENCODE_BIN:-$OPENCODE_DIR_GLOBAL/bin/opencode}"
CONFIG_DIR="/root/.config/opencode"
JSON_CONF="$CONFIG_DIR/opencode.json"
JSONC_CONF="$CONFIG_DIR/opencode.jsonc"
SERVICE_NAME="opencode-web.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
REFRESH_SERVICE="opencode-refresh-models.service"
REFRESH_TIMER="opencode-refresh-models.timer"
REFRESH_SERVICE_PATH="/etc/systemd/system/$REFRESH_SERVICE"
REFRESH_TIMER_PATH="/etc/systemd/system/$REFRESH_TIMER"
TTY_IN="${TTY:-/dev/tty}"

REFRESH_MODE="${1:-}"
if [[ "$REFRESH_MODE" == "--refresh" || "$REFRESH_MODE" == "-r" ]]; then
  REFRESH_MODE="1"
else
  REFRESH_MODE=""
fi

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
    echo "[ERROR] Este instalador necesita entrada interactiva (TTY)."
    exit 1
  fi
}

read_tty() {
  local prompt="$1"
  local default="$2"
  local varname="$3"
  local val=""

  # Abrir /dev/tty como fd 3 para lectura interactiva sin subshell
  if ! exec 3<>/dev/tty 2>/dev/null; then
    echo "[ERROR] No hay TTY disponible para entrada interactiva."
    exit 1
  fi

  if [[ -n "$default" ]]; then
    echo -n "$prompt[$default] " >&3
    read -u 3 -r val || true
    if [[ -z "$val" ]]; then
      val="$default"
    fi
  else
    echo -n "$prompt" >&3
    read -u 3 -r val || true
  fi

  exec 3<&- 2>/dev/null || true
  printf -v "$varname" '%s' "$val"
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

  local detected_bin=""
  if [[ -x "/root/.opencode/bin/opencode" ]]; then
    detected_bin="/root/.opencode/bin/opencode"
  elif [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    detected_bin="$HOME/.opencode/bin/opencode"
  elif command -v opencode >/dev/null 2>&1; then
    detected_bin="$(command -v opencode)"
  fi

  if [[ -z "$detected_bin" ]]; then
    echo "[ERROR] opencode no quedó instalado o no está en PATH."
    exit 1
  fi

  local global_link="/usr/local/bin/opencode"
  if [[ -L "$global_link" ]] && [[ ! -e "$global_link" ]]; then
    rm -f "$global_link"
  fi

  rm -rf "$OPENCODE_DIR_GLOBAL"
  mkdir -p "$(dirname "$OPENCODE_DIR_GLOBAL")"
  local src_dir
  src_dir="$(dirname "$(dirname "$detected_bin")")"
  cp -a "$src_dir" "$OPENCODE_DIR_GLOBAL"

  chmod -R a+rX "$OPENCODE_DIR_GLOBAL"
  chmod +x "$OPENCODE_DIR_GLOBAL/bin/opencode" 2>/dev/null || true
  OPENCODE_BIN="$OPENCODE_DIR_GLOBAL/bin/opencode"

  echo "[OK] opencode instalado en $OPENCODE_BIN"
}

expose_opencode_command() {
  if [[ ! -x "$OPENCODE_BIN" ]]; then
    echo "[ERROR] opencode no es ejecutable en $OPENCODE_BIN"
    exit 1
  fi

  # Siempre copiar a ruta global para evitar depender de /root/.opencode
  if [[ "$OPENCODE_BIN" != "$OPENCODE_DIR_GLOBAL/bin/opencode" ]]; then
    echo "[INFO] Copiando opencode a $OPENCODE_DIR_GLOBAL ..."
    rm -rf "$OPENCODE_DIR_GLOBAL"
    mkdir -p "$OPENCODE_DIR_GLOBAL"
    local src_dir
    src_dir="$(dirname "$(dirname "$OPENCODE_BIN")")"
    cp -a "$src_dir"/* "$OPENCODE_DIR_GLOBAL/"
    chmod -R a+rX "$OPENCODE_DIR_GLOBAL"
    chmod +x "$OPENCODE_DIR_GLOBAL/bin/opencode" 2>/dev/null || true
    OPENCODE_BIN="$OPENCODE_DIR_GLOBAL/bin/opencode"
    echo "[OK] opencode copiado a $OPENCODE_BIN"
  fi

  # Eliminar cualquier symlink o archivo viejo y crear wrapper script fresco
  local target="/usr/local/bin/opencode"
  rm -f "$target"

  cat > "$target" <<'EOF_OPENCODE'
#!/usr/bin/env bash
export NODE_TLS_REJECT_UNAUTHORIZED=0
exec /usr/local/share/opencode/bin/opencode "$@"
EOF_OPENCODE
  chmod +x "$target"

  if ! command -v opencode >/dev/null 2>&1; then
    echo "[ERROR] No pude dejar opencode disponible en PATH."
    echo "        Binario detectado: $OPENCODE_BIN"
    echo "        Wrapper esperado: $target"
    exit 1
  fi

  OPENCODE_CMD="$(command -v opencode)"
  echo "[OK] Comando opencode disponible en $OPENCODE_CMD"

  rm -f /usr/local/bin/opencode-yolo /usr/local/bin/opencode-web

  cat > /usr/local/bin/oc-yolo <<'EOF_YOLO'
#!/usr/bin/env bash
export NODE_TLS_REJECT_UNAUTHORIZED=0
exec opencode --dangerously-skip-permissions "$@"
EOF_YOLO
  chmod +x /usr/local/bin/oc-yolo
  echo "[OK] Alias YOLO disponible en /usr/local/bin/oc-yolo"

  cat > /usr/local/bin/oc-web <<'EOF_WEB'
#!/usr/bin/env bash
export NODE_TLS_REJECT_UNAUTHORIZED=0
exec opencode web --hostname 0.0.0.0 --port "${OPENCODE_WEB_PORT:-4000}" "$@"
EOF_WEB
  chmod +x /usr/local/bin/oc-web
  echo "[OK] Alias web disponible en /usr/local/bin/oc-web"
}

existing_opencode_config_summary() {
  EXISTING_CONFIG_ITEMS=""
  EXISTING_BASE_URL=""

  if [[ -s "$JSON_CONF" ]]; then
    EXISTING_CONFIG_ITEMS="${EXISTING_CONFIG_ITEMS}${JSON_CONF} "
    EXISTING_BASE_URL="$(jq -r '.provider.litellm.options.baseURL // empty' "$JSON_CONF" 2>/dev/null || true)"
  fi

  if [[ -s "$JSONC_CONF" ]]; then
    EXISTING_CONFIG_ITEMS="${EXISTING_CONFIG_ITEMS}${JSONC_CONF} "
    if [[ -z "$EXISTING_BASE_URL" ]]; then
      EXISTING_BASE_URL="$(jq -r '.provider.litellm.options.baseURL // empty' "$JSONC_CONF" 2>/dev/null || true)"
    fi
  fi

  if systemctl list-unit-files "$SERVICE_NAME" --no-legend 2>/dev/null | grep -q "^$SERVICE_NAME"; then
    EXISTING_CONFIG_ITEMS="${EXISTING_CONFIG_ITEMS}${SERVICE_NAME} "
  fi
}

is_opencode_configured() {
  existing_opencode_config_summary
  [[ -n "$EXISTING_CONFIG_ITEMS" ]]
}

resolve_host_ip() {
  local host="$1"
  local ip=""

  if command -v getent >/dev/null 2>&1; then
    ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -n 1)"
  fi

  if [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1; then
    ip="$(dig +short "$host" 2>/dev/null | head -n 1)"
  fi

  if [[ -z "$ip" ]] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
  fi

  if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
    ip="$(nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1)"
  fi

  printf '%s' "$ip"
}

repair_known_certificate_baseurl() {
  local file
  local current_base
  local tmp_file

  for file in "$JSON_CONF" "$JSONC_CONF"; do
    if [[ ! -s "$file" ]]; then
      continue
    fi

    current_base="$(jq -r '.provider.litellm.options.baseURL // empty' "$file" 2>/dev/null || true)"
    if [[ "$current_base" != *"lllm.cpd.local"* ]]; then
      continue
    fi

    local fallback_url=""

    if curl -sSL --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${EXISTING_API_KEY:-fake}" "http://lllm.cpd.local:4000/v1/models" 2>/dev/null | grep -q '^200$'; then
      fallback_url="http://lllm.cpd.local:4000/v1"
    else
      local resolved_ip
      resolved_ip="$(resolve_host_ip "lllm.cpd.local")"
      if [[ -n "$resolved_ip" ]]; then
        for port in 4000 8000 8080 3000 80; do
          local test_url="http://${resolved_ip}:${port}/v1"
          if curl -sSL --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${EXISTING_API_KEY:-fake}" "$test_url/models" 2>/dev/null | grep -q '^200$'; then
            fallback_url="$test_url"
            break
          fi
        done
      fi
    fi

    if [[ -n "$fallback_url" ]]; then
      echo "[WARN] Detectado $current_base en $file; el proxy usa certificado self-signed."
      echo "[INFO] Corrigiendo a $fallback_url (HTTP directo)."
      tmp_file="$(mktemp)"
      jq --arg url "$fallback_url" '.provider.litellm.options.baseURL = $url' "$file" > "$tmp_file"
      cp "$tmp_file" "$file"
      rm -f "$tmp_file"
    else
      echo "[WARN] Detectado $current_base en $file; no encontré backend HTTP directo. Deja la URL tal cual."
    fi
  done
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

try_http_fallback() {
  local host="$1"
  local key="$2"

  local status
  status="$(curl -sSL --max-time 10 -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $key" \
    "http://${host}:4000/v1/models" 2>/dev/null || true)"
  if [[ "$status" == "200" ]]; then
    printf '%s' "http://${host}:4000/v1"
    return 0
  fi

  local resolved_ip
  resolved_ip="$(resolve_host_ip "$host")"
  if [[ -z "$resolved_ip" ]]; then
    return 1
  fi

  local port
  for port in 4000 8000 8080 3000 80; do
    local fallback_url="http://${resolved_ip}:${port}/v1/models"
    status="$(curl -sSL --max-time 10 -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $key" \
      "$fallback_url" 2>/dev/null || true)"
    if [[ "$status" == "200" ]]; then
      printf '%s' "http://${resolved_ip}:${port}/v1"
      return 0
    fi
  done

  return 1
}

copy_config_to_sudo_user() {
  local target_user="${SUDO_USER:-}"
  if [[ -z "$target_user" ]]; then
    return
  fi

  local target_home
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  if [[ -z "$target_home" || ! -d "$target_home" ]]; then
    return
  fi

  local target_config_dir="$target_home/.config/opencode"
  mkdir -p "$target_config_dir"
  cp -a "$JSON_CONF" "$JSONC_CONF" "$target_config_dir/" 2>/dev/null || true
  chown -R "$target_user:$(id -gn "$target_user" 2>/dev/null || echo "$target_user")" "$target_config_dir" 2>/dev/null || true
  echo "[INFO] Configuración copiada a $target_config_dir para el usuario $target_user."
}

fetch_and_update_models() {
  local baseurl="$1"
  local apikey="$2"
  local models_url="$baseurl/models"
  local tmp_json="/tmp/opencode_litellm_refresh.$$"

  echo "[INFO] Refrescando lista de modelos desde $models_url ..."

  local status
  status="$(curl -sSLk --max-time 20 -o "$tmp_json" -w "%{http_code}" \
    -H "Authorization: Bearer $apikey" \
    "$models_url" 2>/dev/null || true)"

  if [[ "$status" != "200" ]]; then
    echo "[ERROR] No pude conectar al endpoint para refrescar modelos. HTTP=$status"
    rm -f "$tmp_json"
    return 1
  fi

  if ! jq empty "$tmp_json" >/dev/null 2>&1; then
    echo "[ERROR] La respuesta del endpoint no es JSON válido."
    rm -f "$tmp_json"
    return 1
  fi

  local model_ids_raw
  model_ids_raw="$(jq -r 'if has("data") then .data[].id elif has("models") then .models[].id else .[]?.id end' "$tmp_json" | sed '/^null$/d' | sort -u)"
  rm -f "$tmp_json"

  if [[ -z "$model_ids_raw" ]]; then
    echo "[ERROR] No encontré modelos en la respuesta de /v1/models."
    return 1
  fi

  local models_json
  models_json="$(printf '%s\n' "$model_ids_raw" | jq -Rsc 'split("\n") | map(select(length>0)) | map({(.): {name: .}}) | add')"
  local default_model
  default_model="$(printf '%s\n' "$model_ids_raw" | head -n 1)"

  mkdir -p "$CONFIG_DIR"

  for file in "$JSON_CONF" "$JSONC_CONF"; do
    if [[ ! -s "$file" ]]; then
      continue
    fi
    local tmp_file
    tmp_file="$(mktemp)"
    jq --argjson models "$models_json" --arg default_model "$default_model" \
      '.provider.litellm.models = $models | .model = ("litellm/" + $default_model)' \
      "$file" > "$tmp_file"
    cp "$tmp_file" "$file"
    rm -f "$tmp_file"
  done

  copy_config_to_sudo_user

  echo "[OK] Modelos actualizados. Modelo por defecto: litellm/$default_model"
  printf '%s\n' "$model_ids_raw" | sed 's/^/  - /'
  return 0
}

refresh_models() {
  if [[ ! -s "$JSON_CONF" ]]; then
    echo "[ERROR] No existe configuración de opencode en $JSON_CONF. Ejecuta el instalador primero."
    exit 1
  fi

  local baseurl apikey
  baseurl="$(jq -r '.provider.litellm.options.baseURL // empty' "$JSON_CONF" 2>/dev/null || true)"
  apikey="$(jq -r '.provider.litellm.options.apiKey // empty' "$JSON_CONF" 2>/dev/null || true)"

  if [[ -z "$baseurl" || -z "$apikey" ]]; then
    echo "[ERROR] No pude extraer baseURL o apiKey de la configuración existente."
    exit 1
  fi

  fetch_and_update_models "$baseurl" "$apikey"
}

install_refresh_timer() {
  echo "[INFO] Instalando refresco automático de modelos (diario a las 03:00)..."

  cat > "$REFRESH_SERVICE_PATH" <<EOF_REFRESH_SVC
[Unit]
Description=Refrescar modelos de opencode desde LiteLLM
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/install-opencode-litellm.sh --refresh
EOF_REFRESH_SVC

  cat > "$REFRESH_TIMER_PATH" <<EOF_REFRESH_TIMER
[Unit]
Description=Timer diario para refrescar modelos de opencode

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF_REFRESH_TIMER

  systemctl daemon-reload
  systemctl enable --now "$REFRESH_TIMER"

  if systemctl is-active --quiet "$REFRESH_TIMER"; then
    echo "[OK] Timer de refresco activo: $REFRESH_TIMER"
  else
    echo "[WARN] El timer no quedó activo inmediatamente, pero está habilitado."
  fi
}

main() {
  if [[ -n "$REFRESH_MODE" ]]; then
    refresh_models
    exit 0
  fi

  ensure_root
  need_tty
  check_cpu

  ensure_dependency curl
  ensure_dependency jq
  ensure_dependency systemctl
  configure_internal_dns

  local global_link="/usr/local/bin/opencode"
  if [[ -L "$global_link" ]] && [[ ! -e "$global_link" ]]; then
    rm -f "$global_link"
  fi

  if [[ ! -x "$OPENCODE_BIN" ]]; then
    local path_bin=""
    if command -v opencode >/dev/null 2>&1; then
      path_bin="$(command -v opencode)"
      if [[ -x "$path_bin" ]]; then
        OPENCODE_BIN="$path_bin"
      else
        rm -f "$path_bin" 2>/dev/null || true
      fi
    fi
    if [[ ! -x "$OPENCODE_BIN" ]]; then
      install_opencode
    fi
  fi
  expose_opencode_command
  repair_known_certificate_baseurl

  if is_opencode_configured; then
    echo "[INFO] Ya existe una instalación/configuración de opencode:"
    printf '       %s\n' "$EXISTING_CONFIG_ITEMS"
    if [[ -n "$EXISTING_BASE_URL" ]]; then
      echo "[INFO] Base URL actual: $EXISTING_BASE_URL"
    fi
    read_tty "¿Refrescar modelos [r], modificar config [s], o salir [N]? " "n" MODIFY_EXISTING_CONFIG
    MODIFY_EXISTING_CONFIG="${MODIFY_EXISTING_CONFIG:-n}"
    if [[ "$MODIFY_EXISTING_CONFIG" =~ ^([rR])$ ]]; then
      refresh_models
      echo "[INFO] Refresco completado."
      exit 0
    elif [[ ! "$MODIFY_EXISTING_CONFIG" =~ ^([sS]|[sS][iI]|[yY]|[yY][eE][sS])$ ]]; then
      echo "[INFO] Configuración intacta. Solo se aplicaron DNS, binario global y alias."
      echo
      printf '[FINAL] Arreglos aplicados sin modificar config:\n'
      printf '  - Config/servicio existente: %s\n' "$EXISTING_CONFIG_ITEMS"
      if [[ -n "$EXISTING_BASE_URL" ]]; then
        printf '  - API actual: %s\n' "$EXISTING_BASE_URL"
      fi
      printf '  - Comando opencode: %s\n' "$OPENCODE_CMD"
      printf '  - Comando YOLO: %s\n' "/usr/local/bin/oc-yolo"
      printf '  - Comando web: %s\n' "/usr/local/bin/oc-web"
      printf '  - Recarga shell si tu terminal cacheo comandos: hash -r\n'
      echo
      exit 0
    fi
  fi

  read_tty "Base URL de LiteLLM [https://lllm.cpd.local/v1]: " "https://lllm.cpd.local/v1" LITELLM_BASE_URL
  LITELLM_BASE_URL="${LITELLM_BASE_URL:-https://lllm.cpd.local/v1}"
  parse_base_url "$LITELLM_BASE_URL"

  RESOLVED_IP="$(resolve_host_ip "$LITELLM_HOST")"
  if [[ -n "$RESOLVED_IP" ]]; then
    echo "[INFO] $LITELLM_HOST resuelve a $RESOLVED_IP"
  fi

  OPENCODE_PORT="4000"
  LITELLM_DOMAIN="$LITELLM_HOST"
  INSTALL_SERVICE="n"

  read_tty "API Key de LiteLLM: " "" API_KEY

  if [[ -z "$API_KEY" ]]; then
    echo "[ERROR] La clave API no puede quedar vacía."
    exit 1
  fi

  local masked_key="${API_KEY:0:4}****${API_KEY: -4}"
  echo "[INFO] API Key capturada: $masked_key"

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

  HTTP_STATUS="$(curl -sSL --max-time 20 -o "$TMP_JSON" -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    "$MODELS_URL" 2>/dev/null || true)"

  # Si falla, comprobar si es por certificado SSL self-signed
  if [[ "$HTTP_STATUS" != "200" ]]; then
    local curl_exit=0
    curl -sSL --max-time 20 -o /dev/null \
      -H "Authorization: Bearer $API_KEY" \
      "$MODELS_URL" 2>/dev/null || curl_exit=$?

    # Exit codes comunes de error SSL en curl: 35, 51, 58, 60, 77, 80, 82
    if [[ "$curl_exit" -eq 35 || "$curl_exit" -eq 51 || "$curl_exit" -eq 58 || "$curl_exit" -eq 60 || "$curl_exit" -eq 77 || "$curl_exit" -eq 80 || "$curl_exit" -eq 82 ]]; then
      echo "[WARN] Certificado SSL no válido/self-signed detectado."
      local insecure_status
      insecure_status="$(curl -sSLk --max-time 20 -o "$TMP_JSON" -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        "$MODELS_URL" 2>/dev/null || true)"
      if [[ "$insecure_status" == "200" ]]; then
        HTTP_STATUS="200"
        echo "[OK] Conexión verificada ignorando certificado (solo para prueba)."
        if [[ "$API_BASE_URL" == http://* ]]; then
          API_BASE_URL="${API_BASE_URL/http:/https:}"
          MODELS_URL="$API_BASE_URL/models"
          echo "[INFO] El proxy redirige a HTTPS. Actualizando Base URL a $API_BASE_URL"
        fi
      fi
    fi
  fi

  # Si aun asi no es 200, probar fallback HTTP directo al backend
  if [[ "$HTTP_STATUS" != "200" ]]; then
    local fallback
    if fallback="$(try_http_fallback "$LITELLM_HOST" "$API_KEY")"; then
      API_BASE_URL="$fallback"
      MODELS_URL="$API_BASE_URL/models"
      echo "[OK] Backend HTTP directo encontrado: $API_BASE_URL"
      HTTP_STATUS="$(curl -sSL --max-time 20 -o "$TMP_JSON" -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        "$MODELS_URL" 2>/dev/null || true)"
    fi
  fi

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

  copy_config_to_sudo_user

  SERVICE_SUMMARY="no configurado"
  if [[ "$INSTALL_SERVICE" =~ ^([sS]|[sS][iI]|[yY]|[yY][eE][sS])$ ]]; then
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
Environment=NODE_TLS_REJECT_UNAUTHORIZED=0
Environment=PATH=/usr/local/share/opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
    SERVICE_SUMMARY="$SERVICE_NAME activo"
  else
    if systemctl list-unit-files "$SERVICE_NAME" --no-legend 2>/dev/null | grep -q "^$SERVICE_NAME"; then
      systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
      systemctl daemon-reload
    fi
    echo "[INFO] Servicio persistente omitido. Puedes levantarlo manualmente con: oc-web"
  fi

  # Copiar el propio script a /usr/local/bin para que el timer de refresco lo encuentre
  if [[ -f "$0" ]] && [[ "$0" != "/usr/local/bin/install-opencode-litellm.sh" ]]; then
    cp -f "$0" /usr/local/bin/install-opencode-litellm.sh
    chmod +x /usr/local/bin/install-opencode-litellm.sh
    echo "[INFO] Script copiado a /usr/local/bin/install-opencode-litellm.sh"
  fi

  install_refresh_timer

  echo
  printf '[FINAL] Instalado y activo con:\n'
  printf '  - Config: %s\n  - Configc: %s\n' "$JSON_CONF" "$JSONC_CONF"
  printf '  - Servicio: %s\n' "$SERVICE_SUMMARY"
  printf '  - Comando opencode: %s\n' "$OPENCODE_CMD"
  printf '  - Comando YOLO: %s\n' "/usr/local/bin/oc-yolo"
  printf '  - Comando web: %s\n' "/usr/local/bin/oc-web"
  printf '  - URL base: %s\n' "http://$LITELLM_DOMAIN:$OPENCODE_PORT/ui/"
  printf '  - API usada: %s\n' "$API_BASE_URL"
  printf '  - Modelo por defecto: litellm/%s\n' "$DEFAULT_MODEL"
  printf '  - Recarga shell si tu terminal cacheo comandos: hash -r\n'
  echo
}

main "$@"
