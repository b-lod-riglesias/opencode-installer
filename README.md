# opencode-litellm-installer

Instalador interactivo para configurar opencode con LiteLLM, dejarlo levantado con systemd y validar modelos disponibles.

## Uso rápido (Linux)

```bash
sudo /root/install-opencode-litellm.sh
```

## Uso rápido (Windows — Desktop / CLI)

### Un solo comando (recomendado)

Abre **PowerShell** y pega esto directamente:

```powershell
irm "https://raw.githubusercontent.com/IzhanGV/opencode-installer/codex/install-opencode-litellm.ps1" | iex
```

Esto descarga y ejecuta el script al instante. Si OpenCode Desktop no está instalado, **lo descarga e instala automáticamente** desde GitHub.

### Descarga manual

Si prefieres descargar primero:

```powershell
# Descargar
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/IzhanGV/opencode-installer/codex/install-opencode-litellm.ps1" -OutFile "install-opencode-litellm.ps1"

# Ejecutar
powershell -ExecutionPolicy Bypass -File .\install-opencode-litellm.ps1
```

### Refrescar modelos

```powershell
powershell -ExecutionPolicy Bypass -File .\install-opencode-litellm.ps1 -Refresh
```

O en un solo comando:

```powershell
irm "https://raw.githubusercontent.com/IzhanGV/opencode-installer/codex/install-opencode-litellm.ps1" | iex -Refresh
```

## Qué hace (Linux)

- Detecta la IP principal del host y configura el DNS interno equivalente acabado en `.254`.
- Usa por defecto `http://lllm.cpd.local/v1`.
- Corrige `lllm.cpd.local` al backend directo `http://10.20.20.56:4000/v1` si el proxy fuerza HTTPS y rompe opencode.
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

## Qué hace (Windows)

- **Detecta si OpenCode Desktop está instalado**; si no, lo descarga e instala automáticamente desde GitHub Releases.
- Detecta/crea el directorio de configuración de OpenCode Desktop (`%USERPROFILE%\.config\opencode`, `%APPDATA%\opencode`, etc.).
- Instala el certificado CA `*.cpd.local` en el almacén de certificados de Windows (máquina o usuario).
- Configura variables de entorno de usuario para evitar errores de certificado SSL self-signed:
  - `NODE_TLS_REJECT_UNAUTHORIZED=0`
  - `NODE_EXTRA_CA_CERTS` apuntando al certificado CA descargado.
- Pide la Base URL de LiteLLM y la API Key, valida `/v1/models`.
- Si falla HTTPS por certificado inválido, reintenta vía HTTP como fallback.
- Detecta automáticamente los modelos disponibles y genera:
  - `opencode.json`
  - `opencode.jsonc`
- Permite refrescar la lista de modelos con el parámetro `-Refresh`.
- Soporta ejecución en un único comando con `irm ... | iex`.

## Requisitos

### Linux
- Linux con `systemd`.
- `curl`, `jq`, `git`.
- `opencode` instalado en `/root/.opencode/bin/opencode` o en PATH.

### Windows
- Windows 10/11.
- PowerShell 5.1 o superior.
- Conexión a Internet (para descargar OpenCode Desktop si no está instalado).

## Parámetros del script Windows

| Parámetro | Descripción |
|-----------|-------------|
| `-Refresh` | Refresca la lista de modelos desde la API configurada |
| `-BaseUrl` | URL base de LiteLLM (ej: `https://lllm.cpd.local/v1`) |
| `-ApiKey` | API Key de LiteLLM |
| `-SkipDesktopCheck` | Omite la comprobación e instalación automática de OpenCode Desktop |
