# opencode-litellm-installer

Instalador interactivo para configurar opencode con LiteLLM, dejarlo levantado con systemd y validar modelos disponibles.

## Uso rápido

```bash
sudo /root/install-opencode-litellm.sh
```

## Qué hace

- Pide host/IP y puerto de LiteLLM.
- Pide la clave API y valida `/v1/models`.
- Crea/actualiza:
  - `/root/.config/opencode/opencode.json`
  - `/root/.config/opencode/opencode.jsonc`
  - `/etc/hosts` para `lllm.cpd.local` (si lo indicas)
- Crea y habilita el servicio systemd:
  - `opencode-web.service`

## Requisitos

- Linux con `systemd`.
- `curl`, `jq`, `git`.
- `opencode` instalado en `/root/.opencode/bin/opencode` o en PATH.
