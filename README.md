# opencode-litellm-installer

Instalador interactivo para configurar opencode con LiteLLM, dejarlo levantado con systemd y validar modelos disponibles.

## Uso rápido

```bash
sudo /root/install-opencode-litellm.sh
```

## Qué hace

- Detecta la IP principal del host y configura el DNS interno equivalente acabado en `.254`.
- Usa por defecto `http://lllm.cpd.local/v1`.
- Corrige `https://lllm.cpd.local/v1` a HTTP para evitar errores de certificado self-signed en opencode.
- Pide la clave API y valida `/v1/models`.
- Crea/actualiza:
  - `/root/.config/opencode/opencode.json`
  - `/root/.config/opencode/opencode.jsonc`
  - `/etc/systemd/resolved.conf.d/opencode-litellm-dns.conf` cuando usa `systemd-resolved`
  - `/etc/hosts` solo si indicas una IP manual de fallback
- Expone el comando `opencode` en `/usr/local/bin/opencode`.
- Crea el alias `oc-yolo` para ejecutar `opencode --dangerously-skip-permissions`.
- Crea el alias `oc-web` para ejecutar `opencode web --hostname 0.0.0.0 --port 4000`.
- Si ya hay configuración de opencode o servicio existente, pregunta si quieres modificarla. Si respondes que no, solo aplica DNS, binario global y alias.
- Pregunta si quieres crear y habilitar el servicio systemd persistente:
  - `opencode-web.service`

## Requisitos

- Linux con `systemd`.
- `curl`, `jq`, `git`.
- `opencode` instalado en `/root/.opencode/bin/opencode` o en PATH.
