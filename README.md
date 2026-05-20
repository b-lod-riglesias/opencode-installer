# opencode-litellm-installer

Instalador interactivo para configurar opencode con LiteLLM, dejarlo levantado con systemd y validar modelos disponibles.

## Uso rápido

```bash
sudo /root/install-opencode-litellm.sh
```

## Qué hace

- Detecta la IP principal del host y configura el DNS interno equivalente acabado en `.254`.
- Usa por defecto `http://lllm.cpd.local/v1`.
- Pide la clave API y valida `/v1/models`.
- Crea/actualiza:
  - `/root/.config/opencode/opencode.json`
  - `/root/.config/opencode/opencode.jsonc`
  - `/etc/systemd/resolved.conf.d/opencode-litellm-dns.conf` cuando usa `systemd-resolved`
  - `/etc/hosts` solo si indicas una IP manual de fallback
- Crea y habilita el servicio systemd:
  - `opencode-web.service`

## Requisitos

- Linux con `systemd`.
- `curl`, `jq`, `git`.
- `opencode` instalado en `/root/.opencode/bin/opencode` o en PATH.
