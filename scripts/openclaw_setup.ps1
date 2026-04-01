$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ContainerName = if ($env:CONTAINER_NAME) { $env:CONTAINER_NAME } else { "openclaw" }
$Image = if ($env:IMAGE) { $env:IMAGE } else { "alpine/openclaw:latest" }
$HostPortGateway = if ($env:HOST_PORT_GATEWAY) { [int]$env:HOST_PORT_GATEWAY } else { 18789 }
$HostPortBrowser = if ($env:HOST_PORT_BROWSER) { [int]$env:HOST_PORT_BROWSER } else { 18791 }
$DataDir = if ($env:DATA_DIR) { $env:DATA_DIR } else { Join-Path $HOME "openclaw-data" }
$AutoApproveDevice = if ($env:AUTO_APPROVE_DEVICE) { $env:AUTO_APPROVE_DEVICE } else { "true" }
$SetupCodexAuth = if ($env:SETUP_CODEX_AUTH) { $env:SETUP_CODEX_AUTH } else { "ask" }
$CodexAuthMethod = if ($env:CODEX_AUTH_METHOD) { $env:CODEX_AUTH_METHOD } else { "ask" }
$CodexApiKey = if ($env:CODEX_API_KEY) { $env:CODEX_API_KEY } elseif ($env:OPENAI_API_KEY) { $env:OPENAI_API_KEY } else { "" }
$WaitTimeoutSeconds = if ($env:WAIT_TIMEOUT_SECONDS) { [int]$env:WAIT_TIMEOUT_SECONDS } else { 120 }
$PullImageIfMissing = if ($env:PULL_IMAGE_IF_MISSING) { $env:PULL_IMAGE_IF_MISSING } else { "true" }

$LocalhostUrl = "http://localhost:$HostPortGateway"
$LoopbackUrl = "http://127.0.0.1:$HostPortGateway"
$ConfigPathInContainer = "/home/node/.openclaw/openclaw.json"

function Write-Info([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Fail([string]$Message) {
    throw $Message
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$IgnoreErrors
    )

    $output = & docker @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreErrors -and $exitCode -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    return ,$output
}

function Test-IsTrue([string]$Value) {
    return $Value -match '^(?i:1|true|yes|y|on)$'
}

function Test-IsFalse([string]$Value) {
    return $Value -match '^(?i:0|false|no|n|off|skip)$'
}

function Test-IsTty {
    return [Environment]::UserInteractive
}

function Test-ContainerExists {
    & docker container inspect $ContainerName *> $null
    return $LASTEXITCODE -eq 0
}

function Test-ContainerRunning {
    $running = (& docker inspect -f '{{.State.Running}}' $ContainerName 2>$null)
    return $LASTEXITCODE -eq 0 -and $running -eq "true"
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = $WaitTimeoutSeconds,
        [int]$IntervalSeconds = 2
    )

    Write-Info "Waiting for $Description"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Missing required command: $Name"
    }
}

function Validate-Port([int]$Port) {
    if ($Port -lt 1 -or $Port -gt 65535) {
        Fail "Port out of range: $Port"
    }
}

function Validate-Inputs {
    if ([string]::IsNullOrWhiteSpace($ContainerName)) { Fail "CONTAINER_NAME cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($Image)) { Fail "IMAGE cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($DataDir)) { Fail "DATA_DIR cannot be empty" }
    Validate-Port $HostPortGateway
    Validate-Port $HostPortBrowser
    if ($HostPortGateway -eq $HostPortBrowser) { Fail "Gateway and browser ports must differ" }
    if ($WaitTimeoutSeconds -lt 1) { Fail "WAIT_TIMEOUT_SECONDS must be greater than zero" }
}

function Ensure-DockerReady {
    Write-Info "Checking Docker daemon"
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker daemon is not reachable"
    }
}

function Ensure-ImageAvailable {
    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    if (Test-IsFalse $PullImageIfMissing) {
        Fail "Docker image not found locally: $Image"
    }

    Write-Info "Pulling Docker image: $Image"
    Invoke-Docker -Arguments @("pull", $Image) | Out-Null
}

function Install-CodexIfNeeded {
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        return $true
    }

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "Codex CLI not installed and npm is unavailable."
        Write-Warning "Skipping Codex setup. Install later with: npm i -g @openai/codex"
        return $false
    }

    Write-Info "Installing Codex CLI"
    & npm i -g @openai/codex
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to install Codex CLI"
    }
    return $true
}

function Normalize-CodexAuthMethod([string]$Value) {
    switch -Regex ($Value.ToLowerInvariant()) {
        '^(1|login|browser|chatgpt|codex)$' { return "1" }
        '^(2|api|api-key|apikey|key|token)$' { return "2" }
        '^(3|skip|none|no)$' { return "3" }
        default { return $Value }
    }
}

function Setup-CodexAuth {
    $setupChoice = $SetupCodexAuth
    $authChoice = Normalize-CodexAuthMethod $CodexAuthMethod

    switch -Regex ($setupChoice.ToLowerInvariant()) {
        '^ask$' { }
        '^(1|yes|true|y|on)$' { $setupChoice = "yes" }
        '^(2|no|false|n|off|skip)$' { return }
        default { Fail "Invalid SETUP_CODEX_AUTH value: $SetupCodexAuth" }
    }

    if ($setupChoice -eq "ask") {
        if (-not (Test-IsTty)) {
            Write-Info "Skipping Codex auth because no interactive terminal is attached"
            return
        }

        Write-Host ""
        Write-Host "Set up Codex CLI auth?"
        Write-Host "  1) Yes"
        Write-Host "  2) No"
        $setupChoice = Read-Host "Choose 1 or 2"
    }

    if ($setupChoice.ToLowerInvariant() -notmatch '^(1|yes|true|y|on)$') {
        return
    }

    if (-not (Install-CodexIfNeeded)) {
        return
    }

    if ($authChoice -eq "ask") {
        if (-not (Test-IsTty)) {
            Write-Warning "Codex auth requested but no interactive terminal is attached"
            return
        }

        Write-Host ""
        Write-Host "Choose Codex auth method:"
        Write-Host "  1) ChatGPT / Codex account login"
        Write-Host "  2) API key"
        Write-Host "  3) Skip"
        $authChoice = Read-Host "Choose 1, 2, or 3"
    }

    $authChoice = Normalize-CodexAuthMethod $authChoice

    switch ($authChoice) {
        "1" {
            Write-Info "Starting browser-based Codex login"
            & codex login
            if ($LASTEXITCODE -ne 0) { Fail "Codex login failed" }
        }
        "2" {
            if ([string]::IsNullOrWhiteSpace($CodexApiKey)) {
                if (-not (Test-IsTty)) {
                    Fail "CODEX_API_KEY is empty and no interactive terminal is attached"
                }
                $secure = Read-Host "Paste your API key for Codex CLI" -AsSecureString
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                try {
                    $script:CodexApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
            if ([string]::IsNullOrWhiteSpace($CodexApiKey)) { Fail "CODEX_API_KEY is empty" }
            Write-Info "Logging Codex CLI in with API key"
            $CodexApiKey | & codex login --with-api-key
            if ($LASTEXITCODE -ne 0) { Fail "Codex API-key login failed" }
        }
        "3" {
            Write-Info "Skipping Codex auth"
        }
        default {
            Fail "Invalid Codex auth choice"
        }
    }

    if ($authChoice -ne "3") {
        Write-Info "Codex login status"
        & codex login status
    }
}

function Prepare-DataDir {
    Write-Info "Preparing data directory: $DataDir"
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
}

function Remove-OldContainer {
    if (Test-ContainerExists) {
        Write-Info "Removing existing container: $ContainerName"
        Invoke-Docker -Arguments @("rm", "-f", $ContainerName) | Out-Null
    }
}

function Start-Container {
    Write-Info "Starting OpenClaw container"
    Invoke-Docker -Arguments @(
        "run", "-d",
        "--restart", "unless-stopped",
        "--name", $ContainerName,
        "-p", "${HostPortGateway}:18789",
        "-p", "${HostPortBrowser}:18791",
        "-v", "${DataDir}:/home/node/.openclaw",
        $Image
    ) | Out-Null
}

function Wait-ForCli {
    $ok = Wait-Until -Description "OpenClaw CLI to become ready" -Condition {
        & docker exec $ContainerName sh -lc 'openclaw --help >/dev/null 2>&1'
        return $LASTEXITCODE -eq 0
    }
    if (-not $ok) { Fail "OpenClaw CLI did not become ready in time" }
}

function Configure-OpenClaw {
    Write-Info "Configuring OpenClaw gateway and Control UI"
    $command = @"
set -e
openclaw config set gateway.bind '"lan"'
openclaw config set gateway.auth.mode '"token"'
openclaw config set gateway.controlUi.allowedOrigins '["$LocalhostUrl","$LoopbackUrl"]'
openclaw config set gateway.controlUi.allowInsecureAuth true
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true
"@
    Invoke-Docker -Arguments @("exec", $ContainerName, "sh", "-lc", $command) | Out-Null
    Write-Info "Waiting for config writes and internal reload"
    Start-Sleep -Seconds 5
}

function Restart-Container {
    Write-Info "Restarting OpenClaw container"
    Invoke-Docker -Arguments @("restart", $ContainerName) | Out-Null
}

function Wait-ForGatewayBind {
    $ok = Wait-Until -Description "gateway bind on 0.0.0.0:$HostPortGateway" -Condition {
        $logs = Invoke-Docker -Arguments @("logs", $ContainerName) -IgnoreErrors
        return (($logs -join [Environment]::NewLine) -match [regex]::Escape("listening on ws://0.0.0.0:$HostPortGateway"))
    }
    if (-not $ok) {
        Write-Warning "Did not detect explicit 0.0.0.0 bind yet"
    }
}

function Show-BindingStatus {
    Write-Info "Binding status"
    $logs = Invoke-Docker -Arguments @("logs", $ContainerName) -IgnoreErrors
    $logs | Select-String -Pattern 'canvas|listening on ws://|Browser control listening on http://' | Select-Object -Last 12
}

function Get-GatewayToken {
    $command = "grep -o '""token"": ""[^""]*""' '$ConfigPathInContainer' 2>/dev/null | head -n1 | sed 's/""token"": ""//; s/""$//'"
    $result = Invoke-Docker -Arguments @("exec", $ContainerName, "sh", "-lc", $command) -IgnoreErrors
    if ($result.Count -gt 0) {
        return $result[0].ToString().Trim()
    }
    return ""
}

function Wait-ForToken {
    Write-Info "Waiting for gateway token"
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $token = Get-GatewayToken
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
        Start-Sleep -Seconds 2
    }
    return ""
}

function Show-Devices {
    Write-Info "Current device list"
    Invoke-Docker -Arguments @("exec", $ContainerName, "sh", "-lc", "openclaw devices list") -IgnoreErrors
}

function Find-FirstPendingDevice {
    $output = Invoke-Docker -Arguments @("exec", $ContainerName, "sh", "-lc", "openclaw devices list") -IgnoreErrors
    $pending = $false
    foreach ($line in $output) {
        if ($line -match 'Pending \([1-9][0-9]*\)') {
            $pending = $true
            continue
        }
        if ($pending -and $line -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') {
            return $Matches[0]
        }
    }
    return ""
}

function Wait-ForAndApproveDevice {
    $approve = $AutoApproveDevice.ToLowerInvariant()
    if ($approve -notmatch '^(1|true|yes|y|on|ask)$') {
        return
    }

    if ($approve -eq "ask") {
        if (-not (Test-IsTty)) {
            return
        }
        $decision = Read-Host "Approve the first pending device automatically? (y/N)"
        if ($decision.ToLowerInvariant() -notmatch '^(y|yes)$') {
            return
        }
    } else {
        Write-Info "Waiting for a pending device request to auto-approve"
    }

    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $requestId = Find-FirstPendingDevice
        if (-not [string]::IsNullOrWhiteSpace($requestId)) {
            Write-Info "Approving pending device: $requestId"
            Invoke-Docker -Arguments @("exec", $ContainerName, "sh", "-lc", "openclaw devices approve $requestId") -IgnoreErrors | Out-Null
            return
        }
        Start-Sleep -Seconds 2
    }

    Write-Warning "No pending device request appeared during the auto-approve window"
}

function Print-Logs {
    Write-Info "Recent logs"
    Invoke-Docker -Arguments @("logs", "--tail", "60", $ContainerName) -IgnoreErrors
}

function Print-Summary([string]$Token) {
    Write-Host ""
    Write-Host "OpenClaw setup complete."
    Write-Host ""
    Write-Host "Binding:"
    Write-Host "  Gateway URL: $LocalhostUrl"
    Write-Host "  Loopback URL: $LoopbackUrl"
    Write-Host "  Gateway WS:  ws://localhost:$HostPortGateway"
    Write-Host "  Browser control port published: $HostPortBrowser"
    Write-Host "  Device auto-approve: $AutoApproveDevice"
    Write-Host ""
    Write-Host "Open this exact URL in a fresh Incognito / Private window:"
    Write-Host "  $LocalhostUrl/#token=$Token"
    Write-Host ""
    Write-Host "Use only one host consistently."
    Write-Host "Recommended:"
    Write-Host "  $LocalhostUrl"
    Write-Host ""
    Write-Host "If the UI says 'pairing required':"
    Write-Host "  docker exec $ContainerName sh -lc 'openclaw devices list'"
    Write-Host "  docker exec $ContainerName sh -lc 'openclaw devices approve <REQUEST_ID>'"
    Write-Host ""
    Write-Host "Useful commands:"
    Write-Host "  docker logs -f $ContainerName"
    Write-Host "  docker exec -it $ContainerName sh"
    Write-Host "  docker exec $ContainerName sh -lc 'openclaw dashboard --no-open'"
    Write-Host "  docker exec $ContainerName sh -lc 'openclaw devices list'"
    Write-Host ""
}

try {
    Require-Command "docker"
    Validate-Inputs
    Ensure-DockerReady
    Ensure-ImageAvailable
    Prepare-DataDir
    Setup-CodexAuth
    Remove-OldContainer
    Start-Container
    if (-not (Wait-Until -Description "container to report running" -Condition { Test-ContainerRunning })) {
        Fail "Container did not reach a running state"
    }
    Wait-ForCli
    Configure-OpenClaw
    Restart-Container
    if (-not (Wait-Until -Description "container to report running after restart" -Condition { Test-ContainerRunning })) {
        Fail "Container did not reach a running state after restart"
    }
    Wait-ForCli
    Wait-ForGatewayBind
    Show-BindingStatus
    Print-Logs

    $token = Wait-ForToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warning "Could not extract token automatically."
        Write-Warning "Run this to get a tokenized URL:"
        Write-Warning "  docker exec $ContainerName sh -lc 'openclaw dashboard --no-open'"
    } else {
        Print-Summary $token
    }

    Show-Devices
    Wait-ForAndApproveDevice
    Show-Devices
    Write-Host ""
    Write-Host "Done."
} catch {
    Write-Warning "Script failed: $($_.Exception.Message)"
    if (Test-ContainerExists) {
        Write-Warning "Recent logs:"
        Invoke-Docker -Arguments @("logs", "--tail", "120", $ContainerName) -IgnoreErrors
    }
    exit 1
}
