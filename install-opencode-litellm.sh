#!/usr/bin/env bash
set -euo pipefail

OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
CONFIG_DIR="/root/.config/opencode"
JSON_CONF="$CONFIG_DIR/opencode.json"
JSONC_CONF="$CONFIG_DIR/opencode.jsonc"
SERVICE_NAME="opencode-web.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Falta dependencia: $1"; exit 1; }
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Ejecuta este script como root (o con sudo)."
  exit 1
fi

need_cmd curl
need_cmd jq
need_cmd systemctl

if [[ ! -x "$OPENCODE_BIN" ]]; then
  if command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN="$(command -v opencode)"
  else
    echo "[ERROR] No encuentro opencode. Ajusta OPENCODE_BIN o instala opencode antes."
    exit 1
  fi
fi

read -r -p "[1/6] IP o host de LiteLLM (por defecto lllm.cpd.local): " LITELLM_HOST
LITELLM_HOST="${LITELLM_HOST:-lllm.cpd.local}"

read -r -p "[2/6] IP que resolverá ese host (si es DNS, deja igual): " LITELLM_IP
if [[ -z "$LITELLM_IP" ]]; then
  # Intento mantener lo que ya exista en /etc/hosts para el mismo host
  if getent hosts "$LITELLM_HOST" >/dev/null 2>&1; then
    LITELLM_IP="$(getent hosts "$LITELLM_HOST" | awk '{print $1}' | head -n 1)"
  else
    LITELLM_IP="10.20.20.56"
  fi
fi

read -r -p "[3/6] Puerto de LiteLLM [4000]: " LITELLM_PORT
LITELLM_PORT="${LITELLM_PORT:-4000}"

read -r -p "[4/6] Puerto donde quieres publicar opencode web [4000]: " OPENCODE_PORT
OPENCODE_PORT="${OPENCODE_PORT:-4000}"

read -r -p "[5/6] Dominio opcional que quieras usar en config (por defecto lllm.cpd.local): " LITELLM_DOMAIN
LITELLM_DOMAIN="${LITELLM_DOMAIN:-lllm.cpd.local}"

read -r -s -p "[6/6] API Key de LiteLLM: " API_KEY
echo

if [[ -z "$API_KEY" ]]; then
  echo "[ERROR] La clave API no puede quedar vacía."
  exit 1
fi

BASE_URL="http://$LITELLM_HOST:$LITELLM_PORT/v1"
MODELS_URL="$BASE_URL/models"

if [[ "$LITELLM_HOST" != "$LITELLM_DOMAIN" ]]; then
  echo "[INFO] Se usará el host para tests y config como '$LITELLM_DOMAIN'."
  BASE_URL="http://$LITELLM_DOMAIN:$LITELLM_PORT/v1"
fi
MODELS_URL="http://$LITELLM_DOMAIN:$LITELLM_PORT/v1/models"

if [[ "$LITELLM_IP" != "127.0.0.1" && "$LITELLM_IP" != "localhost" ]]; then
  echo "[INFO] Configurando resolución local de $LITELLM_DOMAIN -> $LITELLM_IP en /etc/hosts"
  sed -i "/[[:space:]]\b${LITELLM_DOMAIN}\b/d" /etc/hosts
  echo "$LITELLM_IP $LITELLM_DOMAIN" >> /etc/hosts
fi

echo "[CHECK] Probando conectividad y clave API contra $MODELS_URL ..."
TMP_JSON="/tmp/opencode_litellm_models.$$"
HTTP_STATUS="$(curl -sS --max-time 20 -o "$TMP_JSON" -w "%{http_code}" \
  -H "Authorization: Bearer $API_KEY" \
  "$MODELS_URL")"

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "[ERROR] No pude conectar al endpoint. HTTP=$HTTP_STATUS"
  echo "        Comprueba IP/puerto/dominio y API key."
  cat "$TMP_JSON" >/tmp/opencode_litellm_models_last.err
  rm -f "$TMP_JSON"
  exit 1
fi

if ! jq empty "$TMP_JSON" >/dev/null 2>&1; then
  echo "[ERROR] La respuesta del endpoint no es JSON válido."
  cat "$TMP_JSON"
  rm -f "$TMP_JSON"
  exit 1
fi

MODEL_IDS_RAW=$(jq -r '
  if has("data") then .data[].id
  elif has("models") then .models[].id
  else .[]?.id
  end
' "$TMP_JSON" | sed '/^null$/d' | sort -u)

if [[ -z "$MODEL_IDS_RAW" ]]; then
  echo "[ERROR] No encontré modelos en la respuesta de /v1/models."
  cat "$TMP_JSON"
  rm -f "$TMP_JSON"
  exit 1
fi

rm -f "$TMP_JSON"

MODELS_JSON=$(printf '%s\n' "$MODEL_IDS_RAW" | jq -Rsc '
  split("\n") | map(select(length>0)) | map({(.): {name: .}}) | add
')

DEFAULT_MODEL="$(printf '%s\n' "$MODEL_IDS_RAW" | head -n 1)"

echo "[OK] Conexión correcta. Modelos detectados:"
echo "$MODEL_IDS_RAW" | sed 's/^/  - /'

echo "[INFO] Escribiendo configuración en $JSON_CONF y $JSONC_CONF"
mkdir -p "$CONFIG_DIR"

jq -n \
  --arg schema "https://opencode.ai/config.json" \
  --arg hostname "0.0.0.0" \
  --arg baseurl "http://$LITELLM_DOMAIN:$LITELLM_PORT/v1" \
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

# validación final de acceso web
if ! curl -sS --max-time 10 "http://127.0.0.1:$OPENCODE_PORT/ui/" >/dev/null; then
  echo "[ADVERTENCIA] El servicio está activo, pero no respondió en http://127.0.0.1:$OPENCODE_PORT/ui/."
else
  echo "[OK] opencode web responde en http://127.0.0.1:$OPENCODE_PORT/ui/"
fi

echo
printf '[FINAL] Instalado y activo con:\n'
printf '  - Config: %s\n  - Configc: %s\n' "$JSON_CONF" "$JSONC_CONF"
printf '  - Servicio: %s\n' "$SERVICE_NAME"
printf '  - URL base: %s\n' "http://$LITELLM_DOMAIN:$OPENCODE_PORT/ui/"
printf '  - API usada: %s\n' "$BASE_URL"
printf '  - Modelo por defecto: litellm/%s\n' "$DEFAULT_MODEL"
echo
