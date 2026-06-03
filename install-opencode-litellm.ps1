#Requires -Version 5.1

<#
.SYNOPSIS
    Configurador de OpenCode (Desktop/CLI) para LiteLLM en Windows.
.DESCRIPTION
    Adaptación del instalador Linux de opencode-litellm para Windows.
    - Detecta/crea la configuración de OpenCode Desktop/CLI
    - Instala certificado CA *.cpd.local en el almacén de Windows
    - Establece variables de entorno para bypass de certificados SSL self-signed
    - Configura el provider LiteLLM con modelos detectados automáticamente
    - Permite refrescar la lista de modelos periódicamente
.PARAMETER Refresh
    Refresca la lista de modelos desde la API configurada actualmente.
.PARAMETER BaseUrl
    URL base de LiteLLM. Por defecto en interactivo: https://lllm.cpd.local/v1
.PARAMETER ApiKey
    API Key de LiteLLM.
#>
[CmdletBinding()]
param(
    [switch]$Refresh,
    [string]$BaseUrl = "",
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================================================================
# CONSTANTES Y RUTAS
# =============================================================================
$script:ConfigCandidates = @(
    "$env:USERPROFILE\.config\opencode"
    "$env:APPDATA\opencode"
    "$env:LOCALAPPDATA\opencode"
    "$env:USERPROFILE\.opencode"
)

$script:JsonFile  = "opencode.json"
$script:JsoncFile = "opencode.jsonc"

$script:CaCertPem = @"
-----BEGIN CERTIFICATE-----
MIIF+zCCA+OgAwIBAgIUcAPMXT1A5hflZIxPKSFkzvoh5+cwDQYJKoZIhvcNAQEL
BQAwczELMAkGA1UEBhMCRVMxDzANBgNVBAgMBk1hZHJpZDEPMA0GA1UEBwwGTWFk
cmlkMQ4wDAYDVQQKDAVMb2NhbDEcMBoGA1UECwwTTmdpbnggUHJveHkgTWFuYWdl
cjEUMBIGA1UEAwwLKi5jcGQubG9jYWwwHhcNMjYwNDIxMTEzMjA1WhcNMjgwNzI0
MTEzMjA1WjBzMQswCQYDVQQGEwJFUzEPMA0GA1UECAwGTWFkcmlkMQ8wDQYDVQQH
DAZNYWRyaWQxDjAMBgNVBAoMBUxvY2FsMRwwGgYDVQQLDBNOZ2lueCBQcm94eSBN
YW5hZ2VyMRQwEgYDVQQDDAsqLmNwZC5sb2NhbDCCAiIwDQYJKoZIhvcNAQEBBQAD
ggIPADCCAgoCggIBAODedcpWedByS/qS7te1/zfB2wksiRIj2XlEqCbCrabMG5WI
odv0jRdr+IWWYm4rLcbbjFFwrWD02V9mUyOdbkSskXRCMwuiCbUq/WN9z2OH4ZWQ
ux8kXfRDDXnYBLR//lqaaN7pr6Ih2XXJ/9Oel7cInyMCXg6kBU4TxFewKZh8fGfg
coN1P9J5UqJWbgXqH03m2FdSwjNLtI3os/SvluEAar0d5RgMA8sfA9qAcSISKP5i
nbFcW8vfthJOBkAeNEEQgpyg6H2ySQ0uToAaXFHeMhSqlpp9aP5RFSXE3sPNyxAS
P8CFvw2f/b3I1F6AYe4Q6Rdz9e0YjG/UCh0xME613ljhwSXhGhUO4DlqlCc6RdwR
lv60rW1wM+9DMvpwSVjUVcyloN/bNuq0cFSHZG7dvEOS0kmXnX5e6zp+gCBVXeEf
swK6InQRGz10AoNSX5ESAU1867XidZW7hGrmn4Wzo/UArRXSWxWUYIOoCO9E8/u4
ZK225C1zbtJyXNXtWCbkbZ396SBqZsyLph/Pt2gHkNzK1TXQLno/BpdPilinZgVM
/RUdn9zkfDhicDMY0bK8Lx2pXyim/KXzRCzANo3m5t7jYEVtU2mhCshsberVGxsE
Vix2yio0yerUNnva8ixV0sGHhl+GuwbjoopqEIoDd6+g/tFBOfkSMaCo97R5AgMB
AAGjgYYwgYMwMgYDVR0RBCswKYILKi5jcGQubG9jYWyCCWNwZC5sb2NhbIIPbG90
ZXMuY3BkLmxvY2FsMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcD
ATAJBgNVHRMEAjAAMB0GA1UdDgQWBBSOICNs/qbeHgc+pdO+5NEopQunnzANBgkq
hkiG9w0BAQsFAAOCAgEADE2s9r/s1YZrECpmPaEjBU6oS/mAbRHNpYdT1UxP8GDF
4A2aSyiyWTu7l8CY17RGv/UjOm1zT4QxK1AInJlQ8Our3b0qFce8obbPlmxH2WSF
l2b7RdJ9XMBFhVYwo6p0uPjr43f0M7fEVCbPRPg6hJrA+qMb6yIjHSqKtY/gcXgl
MHxAJYKJGNnqajvHvKPEhBHR4UuwJ8hsKwC2ojreDGTic6fzvmCoRu1r9dTexDMK
H0+jgJhgQ3CfYRuid/AITy4He+6taSaSuoFy0HFetPnNK73k4d5vYpfz0vH9OFHj
WLbA7vE0InQEG1a5k5CdznIRirz3U4ogCo/wehH0gauKYvcZltIv9R3Wvaa6y0kZ
cz/sH0L23yIzVoHTqfz2MFXDK+7DqUSpc9sslPWewY5Lt+xSRmgOW5Q/IwJQuAf+
4Llti9KCqGQ37yHh2VAVIWYLPYvCUpAJeK9AGqJKurBkrjjdYFXB148MyjDebL72
QolPqaKrFLEaqHjdtUqKvzUBi6HVAREHOof+bRHTeolpne/Fs6Y4oKTBIR2XxgVd
Vnrck0KGT4+RqbW6K7J+YNJEAsdBNrW1ii/5u8z9R19n8dH0/UET+CyeJMCzyQms
abYKkbCK8SjTphWpFbHNosZQcnbLTeo2LSB5oXbgTVmfR4YJV7eFw0ylQFpwPpE=
-----END CERTIFICATE-----
"@

# =============================================================================
# FUNCIONES DE LOG
# =============================================================================
function Write-Info  { param([string]$m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Warn  { param([string]$m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Ok    { param([string]$m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Err   { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-Plain { param([string]$m) Write-Host $m }

# =============================================================================
# UTILIDADES
# =============================================================================
function Get-ConfigDir {
    foreach ($d in $script:ConfigCandidates) {
        if (Test-Path $d) { return $d }
    }
    $d = $script:ConfigCandidates[0]
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    return $d
}

function Find-ExistingConfig {
    foreach ($d in $script:ConfigCandidates) {
        $j = Join-Path $d $script:JsonFile
        if (Test-Path $j) { return $d }
    }
    return $null
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserInput {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    if ($Default) {
        $full = "$Prompt [$Default] "
    } else {
        $full = "$Prompt "
    }
    $val = Read-Host -Prompt $full
    if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
    return $val
}

# =============================================================================
# CERTIFICADO CA
# =============================================================================
function Install-CaCertificate {
    Write-Info "Instalando certificado CA *.cpd.local ..."
    $tmp = Join-Path $env:TEMP "cpd-local-wildcard.crt"
    $script:CaCertPem | Out-File -Encoding ascii -FilePath $tmp -Force

    try {
        # Intentar almacén de máquina (requiere admin)
        $proc = Start-Process certutil -ArgumentList "-addstore","-f","Root",$tmp -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
        if ($proc.ExitCode -eq 0) {
            Write-Ok "Certificado CA instalado en el almacén de confianza del sistema (Root)."
        } else {
            Write-Warn "No se pudo instalar a nivel de sistema (código $($proc.ExitCode)). Intentando almacén de usuario ..."
            $proc2 = Start-Process certutil -ArgumentList "-addstore","-f","-user","Root",$tmp -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
            if ($proc2.ExitCode -eq 0) {
                Write-Ok "Certificado CA instalado en el almacén de usuario (Root)."
            } else {
                Write-Warn "No se pudo instalar automáticamente. Instálalo manualmente desde: $tmp"
                Write-Plain "        Doble clic en el archivo → Instalar certificado → Equipo/Usuario → Colocar en Raíz de confianza."
            }
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# VARIABLES DE ENTORNO (SSL BYPASS)
# =============================================================================
function Set-SslBypassEnvironment {
    Write-Info "Configurando variables de entorno para bypass de verificación SSL ..."

    # NODE_TLS_REJECT_UNAUTHORIZED=0 (menos intrusivo que LD_PRELOAD)
    [Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED", "0", "User")
    $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"
    Write-Ok "NODE_TLS_REJECT_UNAUTHORIZED=0 establecido para el usuario."

    # Guardar certificado en perfil para NODE_EXTRA_CA_CERTS (más seguro)
    $certDir = "$env:USERPROFILE\.config\opencode"
    if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Force -Path $certDir | Out-Null }
    $certPath = Join-Path $certDir "cpd-local-wildcard.crt"
    $script:CaCertPem | Out-File -Encoding ascii -FilePath $certPath -Force
    [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $certPath, "User")
    $env:NODE_EXTRA_CA_CERTS = $certPath
    Write-Ok "NODE_EXTRA_CA_CERTS apuntando a $certPath"

    Write-Warn "Si OpenCode Desktop ya está en ejecución, ciérralo y vuelve a abrirlo para que herede las variables."
}

# =============================================================================
# CONECTIVIDAD LITELLM
# =============================================================================
function Invoke-LiteLLMModels {
    param([string]$Url, [string]$Key)
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $resp = Invoke-RestMethod -Uri "$Url/models" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
        return @{ Success = $true; Response = $resp }
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "SSL|certificate|trust|chain|remote") {
            Write-Warn "Error de certificado SSL detectado. Reintentando con verificación deshabilitada ..."
            try {
                if ($PSVersionTable.PSVersion.Major -ge 6) {
                    $resp = Invoke-RestMethod -Uri "$Url/models" -Headers $headers -TimeoutSec 20 -SkipCertificateCheck -ErrorAction Stop
                    return @{ Success = $true; Response = $resp }
                } else {
                    # PowerShell 5.1 no tiene -SkipCertificateCheck nativo
                    # Usar System.Net.WebClient con cert bypass via callback
                    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class InsecureWebClient : WebClient {
    protected override WebRequest GetWebRequest(System.Uri address) {
        HttpWebRequest req = (HttpWebRequest)base.GetWebRequest(address);
        req.ServerCertificateValidationCallback = (sender, cert, chain, errors) => true;
        return req;
    }
}
"@
                    $wc = New-Object InsecureWebClient
                    $wc.Headers.Add("Authorization", "Bearer $Key")
                    $raw = $wc.DownloadString("$Url/models")
                    $resp = $raw | ConvertFrom-Json
                    return @{ Success = $true; Response = $resp }
                }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Try-HttpFallback {
    param([string]$HostName, [string]$Key)
    $ports = @(4000, 8000, 8080, 3000, 80)
    foreach ($port in $ports) {
        $url = "http://${HostName}:${port}/v1/models"
        try {
            $headers = @{ Authorization = "Bearer $Key" }
            $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            return @{ Success = $true; Url = "http://${HostName}:${port}/v1" }
        } catch { continue }
    }
    return @{ Success = $false }
}

# =============================================================================
# JSON / CONFIG
# =============================================================================
function ConvertTo-ModelsHash {
    param([string[]]$ModelIds)
    $h = [ordered]@{}
    foreach ($id in ($ModelIds | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $h[$id] = @{ name = $id }
    }
    return $h
}

function Write-OpencodeConfig {
    param(
        [string]$ConfigDir,
        [string]$BaseUrl,
        [string]$ApiKey,
        [hashtable]$Models,
        [string]$DefaultModel
    )
    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        server = @{ hostname = "0.0.0.0" }
        provider = [ordered]@{
            litellm = [ordered]@{
                npm = "@ai-sdk/openai-compatible"
                name = "LiteLLM"
                options = [ordered]@{
                    baseURL = $BaseUrl
                    apiKey = $ApiKey
                }
                models = $Models
            }
        }
        model = "litellm/$DefaultModel"
    }

    $json = $config | ConvertTo-Json -Depth 10 -Compress:$false
    $jsonPath  = Join-Path $ConfigDir $script:JsonFile
    $jsoncPath = Join-Path $ConfigDir $script:JsoncFile

    $json | Out-File -Encoding utf8 -FilePath $jsonPath -Force
    $json | Out-File -Encoding utf8 -FilePath $jsoncPath -Force

    Write-Ok "Configuración escrita en:`n       $jsonPath`n       $jsoncPath"
}

function Update-ModelsInConfig {
    param([string]$ConfigDir, [string[]]$ModelIds, [string]$DefaultModel)
    $jsonPath  = Join-Path $ConfigDir $script:JsonFile
    $jsoncPath = Join-Path $ConfigDir $script:JsoncFile

    if (-not (Test-Path $jsonPath)) { return }

    $modelsHash = ConvertTo-ModelsHash -ModelIds $ModelIds
    $jsonText = Get-Content $jsonPath -Raw -Encoding UTF8
    $cfg = $jsonText | ConvertFrom-Json

    # Reconstruir con [ordered] para preservar estructura aproximada
    $newCfg = [ordered]@{}
    foreach ($prop in $cfg.PSObject.Properties.Name) {
        if ($prop -eq 'provider') {
            $newProvider = [ordered]@{}
            foreach ($p2 in $cfg.provider.PSObject.Properties.Name) {
                if ($p2 -eq 'litellm') {
                    $newLitellm = [ordered]@{}
                    foreach ($p3 in $cfg.provider.litellm.PSObject.Properties.Name) {
                        if ($p3 -eq 'models') {
                            $newLitellm['models'] = $modelsHash
                        } else {
                            $newLitellm[$p3] = $cfg.provider.litellm.$p3
                        }
                    }
                    $newProvider['litellm'] = $newLitellm
                } else {
                    $newProvider[$p2] = $cfg.provider.$p2
                }
            }
            $newCfg['provider'] = $newProvider
        } elseif ($prop -eq 'model') {
            $newCfg['model'] = "litellm/$DefaultModel"
        } else {
            $newCfg[$prop] = $cfg.$prop
        }
    }

    $json = $newCfg | ConvertTo-Json -Depth 10 -Compress:$false
    $json | Out-File -Encoding utf8 -FilePath $jsonPath -Force
    $json | Out-File -Encoding utf8 -FilePath $jsoncPath -Force
    Write-Ok "Modelos actualizados en configuración existente."
}

# =============================================================================
# REFRESH DE MODELOS
# =============================================================================
function Start-ModelRefresh {
    $cfgDir = Find-ExistingConfig
    if (-not $cfgDir) {
        Write-Err "No se encontró configuración existente de opencode. Ejecuta el script sin -Refresh primero."
        exit 1
    }
    $jsonPath = Join-Path $cfgDir $script:JsonFile
    $cfg = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $base = $cfg.provider.litellm.options.baseURL
    $key  = $cfg.provider.litellm.options.apiKey
    if (-not $base -or -not $key) {
        Write-Err "No se pudo extraer baseURL o apiKey de la configuración existente."
        exit 1
    }

    Write-Info "Refrescando modelos desde $base/models ..."
    $result = Invoke-LiteLLMModels -Url $base -Key $key
    if (-not $result.Success) {
        Write-Err "No se pudo conectar al endpoint de modelos. $($result.Error)"
        exit 1
    }

    $resp = $result.Response
    $ids = @()
    if ($resp.data) { $ids = $resp.data | ForEach-Object { $_.id } }
    elseif ($resp.models) { $ids = $resp.models | ForEach-Object { $_.id } }
    else { $ids = $resp | ForEach-Object { $_.id } }
    $ids = $ids | Sort-Object -Unique

    if (-not $ids) {
        Write-Err "No se encontraron modelos en la respuesta."
        exit 1
    }

    $default = $ids | Where-Object { $_ -match 'qwen3\.[6-9]|qwen3\.5:cloud|qwen3-next|qwen3-coder|qwen2\.5vl' } | Select-Object -First 1
    if (-not $default) { $default = $ids | Where-Object { $_ -match 'gpt-4|claude|gemini|qwen.*vl|vision|multimodal' } | Select-Object -First 1 }
    if (-not $default) { $default = $ids | Where-Object { $_ -match 'coder|cloud|large|pro|flash' } | Select-Object -First 1 }
    if (-not $default) { $default = $ids | Select-Object -First 1 }

    Update-ModelsInConfig -ConfigDir $cfgDir -ModelIds $ids -DefaultModel $default
    Write-Ok "Modelo por defecto: litellm/$default"
    Write-Plain "Modelos disponibles:"
    $ids | ForEach-Object { Write-Plain "  - $_" }
}

# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================
function Start-Main {
    if ($Refresh) {
        Start-ModelRefresh
        exit 0
    }

    Write-Plain ""
    Write-Plain "========================================"
    Write-Plain "  OpenCode LiteLLM Configurator (Win)  "
    Write-Plain "========================================"
    Write-Plain ""

    $cfgDir = Get-ConfigDir
    Write-Info "Directorio de configuración: $cfgDir"

    # --- Certificado y entorno ---
    Install-CaCertificate
    Set-SslBypassEnvironment

    # --- Inputs ---
    $url = $BaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = Get-UserInput -Prompt "Base URL de LiteLLM" -Default "https://lllm.cpd.local/v1"
    }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "https://lllm.cpd.local/v1" }
    $url = $url.TrimEnd('/')
    if (-not $url.EndsWith('/v1')) { $url += '/v1' }

    $key = $ApiKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        $secure = Read-Host -Prompt "API Key de LiteLLM" -AsSecureString
        $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Err "La API Key no puede estar vacía."
        exit 1
    }
    $masked = $key.Substring(0, [Math]::Min(4, $key.Length)) + "****" + $key.Substring([Math]::Max(0, $key.Length - 4))
    Write-Info "API Key capturada: $masked"

    # --- Parse URL ---
    if ($url -notmatch '^https?://') {
        Write-Err "La Base URL debe empezar por http:// o https://"
        exit 1
    }
    $scheme = ($url -split '://')[0]
    $rest   = ($url -split '://')[1]
    $hostPort = ($rest -split '/')[0]
    $litellmHost = ($hostPort -split ':')[0]
    $litellmPort = if ($hostPort -match ':') { ($hostPort -split ':')[1] } else { if ($scheme -eq 'https') { '443' } else { '80' } }

    # --- Probar conexión ---
    Write-Info "Probando conectividad contra $url/models ..."
    $result = Invoke-LiteLLMModels -Url $url -Key $key

    if (-not $result.Success) {
        Write-Warn "La conexión HTTPS falló. $($result.Error)"
        Write-Info "Buscando backend HTTP directo como fallback ..."
        $fallback = Try-HttpFallback -HostName $litellmHost -Key $key
        if ($fallback.Success) {
            $url = $fallback.Url
            Write-Ok "Backend HTTP encontrado: $url"
            $result = Invoke-LiteLLMModels -Url $url -Key $key
        } else {
            Write-Err "No se pudo conectar al endpoint. Comprueba IP/puerto/dominio y API key."
            exit 1
        }
    }

    $resp = $result.Response
    $ids = @()
    if ($resp.data) { $ids = $resp.data | ForEach-Object { $_.id } }
    elseif ($resp.models) { $ids = $resp.models | ForEach-Object { $_.id } }
    else { $ids = $resp | ForEach-Object { $_.id } }
    $ids = $ids | Sort-Object -Unique

    if (-not $ids) {
        Write-Err "No se encontraron modelos en la respuesta de /v1/models."
        exit 1
    }

    Write-Ok "Conexión correcta. Modelos detectados:"
    $ids | ForEach-Object { Write-Plain "  - $_" }

    # --- Seleccionar default ---
    $default = $ids | Where-Object { $_ -match 'qwen3\.[6-9]|qwen3\.5:cloud|qwen3-next|qwen3-coder|qwen2\.5vl' } | Select-Object -First 1
    if (-not $default) { $default = $ids | Where-Object { $_ -match 'gpt-4|claude|gemini|qwen.*vl|vision|multimodal' } | Select-Object -First 1 }
    if (-not $default) { $default = $ids | Where-Object { $_ -match 'coder|cloud|large|pro|flash' } | Select-Object -First 1 }
    if (-not $default) { $default = $ids | Select-Object -First 1 }

    $modelsHash = ConvertTo-ModelsHash -ModelIds $ids
    Write-OpencodeConfig -ConfigDir $cfgDir -BaseUrl $url -ApiKey $key -Models $modelsHash -DefaultModel $default

    # --- Resumen final ---
    Write-Plain ""
    Write-Plain "========================================"
    Write-Plain "[FINAL] Configurado y listo con:"
    Write-Plain "  - Config:   $cfgDir\opencode.json"
    Write-Plain "  - Configc:  $cfgDir\opencode.jsonc"
    Write-Plain "  - API:      $url"
    Write-Plain "  - Default:  litellm/$default"
    Write-Plain ""
    Write-Warn "IMPORTANTE: Cierra y vuelve a abrir OpenCode Desktop para que cargue la nueva configuración y las variables de entorno."
    Write-Plain ""
    Write-Plain "Para refrescar modelos más tarde, ejecuta:"
    Write-Plain "   .\install-opencode-litellm.ps1 -Refresh"
    Write-Plain "========================================"
}

Start-Main
