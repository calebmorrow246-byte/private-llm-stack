# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Deploy the local inference stack (Ollama + Docker/Qdrant/LiteLLM/Open WebUI) to an
    LLM pilot blade over SSH.

.DESCRIPTION
    Idempotent end-to-end deploy for the ai0x LLM pilot hosts:
      1. Installs Docker Engine + Compose plugin (official apt repo) if missing.
      2. Installs Ollama (official install script) if missing; pulls the chat + embedding
         models; adds a systemd NUMA override (numactl --interleave=all) for CPU-inference
         throughput across both NUMA nodes.
      3. Generates the LiteLLM master key + Open WebUI secret key, writes them to
         /opt/llm/.env on the host (0600) and mirrors working copies into Windows
         Credential Manager. Secrets are generated fresh unless -KeepSecrets and an
         existing /opt/llm/.env is found.
      4. Copies stack/compose.yaml + stack/litellm-config.yaml + rag-proxy/ source to
         the host and runs `docker compose up -d --build`.
      5. Disables Open WebUI's built-in agentic tool-injection (see
         openwebui-builtin-tools-gotcha memory) so the general-purpose chat models work.
      6. Registers rag-proxy as a second OpenAI-compatible connection (the
         FreshService KB agent - see rag-proxy/app.py and README.md for why it exists
         instead of using Open WebUI's own RAG).

    No secret is ever committed to the repo or printed in full to the transcript.
    Destructive/mutating steps honor -WhatIf / -Confirm.

.PARAMETER HostName
    Target host / profile name, e.g. ai02. Used to resolve the SSH key and
    Credential Manager targets created by New-LlmBladeSecrets.ps1.

.PARAMETER IpAddress
    IP address to SSH to. Defaults to the known ai02 address.

.PARAMETER SshUser
    Dedicated SSH admin username. Default 'llmadmin'.

.PARAMETER ChatModels
    Ollama chat model tags to pull. Defaults to the three currently registered in
    stack/litellm-config.yaml (llama-3.1-8b, qwen2.5-7b, granite3.2-8b).

.PARAMETER EmbedModel
    Ollama embedding model tag to pull. Default 'nomic-embed-text'.

.PARAMETER KeepSecrets
    Reuse the existing /opt/llm/.env on the host instead of regenerating LiteLLM/WebUI keys.

.PARAMETER GpuHost
    Target host has NVIDIA GPUs. Skips the numactl NUMA-interleave ExecStart override in
    the Ollama systemd unit (Ollama auto-detects CUDA and GPU-offloads natively). Use for
    ai04 (2x L4) and any future GPU-equipped hosts.

.EXAMPLE
    .\Deploy-LlmStack.ps1 -HostName ai02 -WhatIf

.EXAMPLE
    .\Deploy-LlmStack.ps1 -HostName ai02

.EXAMPLE
    .\Deploy-LlmStack.ps1 -HostName ai04 -IpAddress 192.0.2.9 -SshUser admin -GpuHost -WhatIf
    .\Deploy-LlmStack.ps1 -HostName ai04 -IpAddress 192.0.2.9 -SshUser admin -GpuHost
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string]$HostName,
    [string]$IpAddress = '192.0.2.49',
    [string]$SshUser = 'llmadmin',
    [string[]]$ChatModels = @('llama3.1:8b-instruct-q4_K_M', 'qwen2.5:7b-instruct-q4_K_M', 'granite3.2:8b-instruct-q4_K_M'),
    [string]$EmbedModel = 'nomic-embed-text',
    [string]$RagProxyModelId = 'freshservice-kb-rag',
    [switch]$KeepSecrets,
    [switch]$GpuHost
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop
Import-Module Posh-SSH -ErrorAction Stop

$stackDir = Join-Path $PSScriptRoot 'stack'
$composeFile = Join-Path $stackDir 'compose.yaml'
$litellmConfigFile = Join-Path $stackDir 'litellm-config.yaml'
foreach ($f in @($composeFile, $litellmConfigFile)) {
    if (-not (Test-Path $f)) { throw "Required stack file not found: $f" }
}

# --- resolve the SSH key created by New-LlmBladeSecrets.ps1 ---
$sshTarget = "${HostName}:${SshUser}-ssh"
$cred = Get-StoredCredential -Target $sshTarget
if (-not $cred) { throw "No stored SSH credential '$sshTarget'. Run New-LlmBladeSecrets.ps1 first." }
$keyPath = [System.Net.NetworkCredential]::new('', $cred.Password).Password
if (-not (Test-Path $keyPath)) { throw "SSH key not found at '$keyPath' (from credential '$sshTarget')." }

function Invoke-Remote {
    param([Parameter(Mandatory)][string]$Command, [switch]$Quiet)
    $result = Invoke-SSHCommand -SSHSession $script:sshSession -Command $Command -TimeOut 600
    if (-not $Quiet) { Write-Verbose "`$ $Command`n$($result.Output -join "`n")" }
    if ($result.ExitStatus -ne 0) {
        throw "Remote command failed (exit $($result.ExitStatus)): $Command`n$($result.Output -join "`n")$($result.Error -join "`n")"
    }
    return $result.Output
}

Write-Host "=== Deploying LLM stack to $HostName ($IpAddress) ===" -ForegroundColor Cyan
if ($WhatIfPreference) { Write-Host "** DRY-RUN (-WhatIf): no changes will be sent **" -ForegroundColor Yellow }

$script:sshSession = New-SSHSession -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential($SshUser, (New-Object System.Security.SecureString))) -KeyFile $keyPath -AcceptKey -ConnectionTimeout 15
try {
    # --- 1. Docker Engine + Compose plugin ---
    $dockerPresent = $true
    try { Invoke-Remote -Command 'docker --version' -Quiet | Out-Null } catch { $dockerPresent = $false }
    if (-not $dockerPresent) {
        if ($PSCmdlet.ShouldProcess($HostName, 'Install Docker Engine + Compose plugin')) {
            Write-Host "Installing Docker..." -ForegroundColor DarkGray
            Invoke-Remote -Command 'curl -fsSL https://get.docker.com | sudo sh' | Out-Null
            Invoke-Remote -Command "sudo usermod -aG docker $SshUser" | Out-Null
            Write-Host "Docker installed. (New group membership takes effect on next SSH session.)"
        }
    } else {
        Write-Host "Docker already present - skipping install."
    }

    # --- 2. Ollama + models + NUMA override ---
    $ollamaPresent = $true
    try { Invoke-Remote -Command 'ollama --version' -Quiet | Out-Null } catch { $ollamaPresent = $false }
    if (-not $ollamaPresent) {
        if ($PSCmdlet.ShouldProcess($HostName, 'Install Ollama')) {
            Write-Host "Installing Ollama..." -ForegroundColor DarkGray
            Invoke-Remote -Command 'curl -fsSL https://ollama.com/install.sh | sh' | Out-Null
        }
    } else {
        Write-Host "Ollama already present - skipping install."
    }

    if ($PSCmdlet.ShouldProcess($HostName, "Configure ollama.service systemd override")) {
        $overrideDir = '/etc/systemd/system/ollama.service.d'
        Invoke-Remote -Command "sudo mkdir -p $overrideDir" | Out-Null
        # OLLAMA_HOST=0.0.0.0 is required so the Docker-network containers (LiteLLM/Open
        # WebUI, reaching it via host.docker.internal) can connect - plain 127.0.0.1 only
        # answers the host itself. ufw (active, default-deny) is opened only for the
        # compose bridge subnet below, so it stays unreachable from the wider LAN.
        #
        # CPU hosts (ai02): wrap ExecStart with numactl --interleave=all to spread memory
        # allocations across both NUMA nodes, maximising DDR4 bandwidth for inference.
        # GPU hosts (ai04+): omit numactl entirely — Ollama auto-detects CUDA and offloads
        # inference to the GPU; NUMA interleaving of system RAM is irrelevant.
        if ($GpuHost) {
            $overrideConf = "[Service]`nEnvironment=OLLAMA_HOST=0.0.0.0:11434"
            Write-Host "GPU mode: Ollama systemd override sets OLLAMA_HOST only (no numactl)." -ForegroundColor DarkGray
        } else {
            $ollamaBin = (Invoke-Remote -Command 'which ollama' -Quiet | Select-Object -Last 1).Trim()
            $overrideConf = "[Service]`nExecStart=`nEnvironment=OLLAMA_HOST=0.0.0.0:11434`nExecStart=numactl --interleave=all $ollamaBin serve"
            Write-Host "CPU mode: Ollama systemd override uses numactl --interleave=all for NUMA bandwidth." -ForegroundColor DarkGray
        }
        Invoke-Remote -Command "printf '%s\n' '$overrideConf' | sudo tee $overrideDir/override.conf > /dev/null" | Out-Null
        Invoke-Remote -Command 'sudo systemctl daemon-reload && sudo systemctl enable --now ollama' | Out-Null
        Invoke-Remote -Command 'sudo systemctl restart ollama' | Out-Null

        # Discover the compose bridge subnet (created on first `docker compose up`) and
        # scope a ufw allow rule to it, so 11434 stays LAN-unreachable.
        $bridgeSubnet = $null
        try {
            $bridgeSubnet = (Invoke-Remote -Command "docker network inspect llm_llm-net --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null" -Quiet | Select-Object -Last 1).Trim()
        } catch { }
        $ufwPresent = $false
        try { Invoke-Remote -Command 'which ufw' -Quiet | Out-Null; $ufwPresent = $true } catch { }
        if ($bridgeSubnet -and $ufwPresent) {
            Invoke-Remote -Command "sudo ufw allow from $bridgeSubnet to any port 11434 proto tcp" | Out-Null
            Write-Host "ufw: allowed $bridgeSubnet -> 11434/tcp (Ollama stays LAN-unreachable otherwise)." -ForegroundColor DarkGray
        } elseif (-not $ufwPresent) {
            Write-Host "ufw not installed - skipping firewall rule for port 11434 (no default-deny on this host)." -ForegroundColor DarkGray
        } else {
            Write-Warning "Could not determine the compose bridge subnet yet (network not created). Rerun after 'docker compose up' to add the ufw rule for port 11434."
        }
    }

    if ($PSCmdlet.ShouldProcess($HostName, "Pull models: $($ChatModels -join ', '), $EmbedModel")) {
        foreach ($m in $ChatModels) {
            Write-Host "Pulling $m (this can take a while)..." -ForegroundColor DarkGray
            Invoke-Remote -Command "ollama pull $m" | Out-Null
        }
        Write-Host "Pulling $EmbedModel..." -ForegroundColor DarkGray
        Invoke-Remote -Command "ollama pull $EmbedModel" | Out-Null
    }

    # --- 3. Secrets ---
    Invoke-Remote -Command "sudo mkdir -p /opt/llm && sudo chown ${SshUser}:${SshUser} /opt/llm" | Out-Null
    $envExists = $false
    try { Invoke-Remote -Command 'test -f /opt/llm/.env' -Quiet | Out-Null; $envExists = $true } catch { $envExists = $false }

    if ($KeepSecrets -and $envExists) {
        Write-Host "Reusing existing /opt/llm/.env on host (-KeepSecrets)."
    } elseif ($PSCmdlet.ShouldProcess($HostName, 'Generate LiteLLM/WebUI secrets and write /opt/llm/.env')) {
        function New-HexSecret {
            $bytes = [byte[]]::new(32)
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            -join ($bytes | ForEach-Object { $_.ToString('x2') })
        }
        $litellmKey = New-HexSecret
        $webuiKey = New-HexSecret
        $ragProxyKey = New-HexSecret

        # KB_TENANT_ID (the FreshService KB's Qdrant tenant/collection id) is set to a
        # placeholder here - Ingest-KbCorpus.ps1 patches it in after the Knowledge
        # collection actually exists (chicken-and-egg: rag-proxy needs the id, but the
        # id is only assigned when the collection is first created).
        $envContent = "LITELLM_MASTER_KEY=sk-$litellmKey`nWEBUI_SECRET_KEY=$webuiKey`nRAG_PROXY_API_KEY=sk-$ragProxyKey`nKB_TENANT_ID=unset`n"
        Invoke-Remote -Command "cat <<'EOF' | sudo tee /opt/llm/.env > /dev/null`n$envContent`nEOF" | Out-Null
        Invoke-Remote -Command "sudo chmod 600 /opt/llm/.env && sudo chown ${SshUser}:${SshUser} /opt/llm/.env" | Out-Null

        & cmdkey "/generic:${HostName}:litellm-key" "/user:litellm" "/pass:sk-$litellmKey" | Out-Null
        & cmdkey "/generic:${HostName}:webui-key" "/user:openwebui" "/pass:$webuiKey" | Out-Null
        & cmdkey "/generic:${HostName}:rag-proxy-key" "/user:rag-proxy" "/pass:sk-$ragProxyKey" | Out-Null
        Write-Host "Secrets generated and mirrored into Windows Credential Manager (targets '${HostName}:litellm-key', '${HostName}:webui-key', '${HostName}:rag-proxy-key')." -ForegroundColor DarkGray
    }

    # --- 4. Ship compose files + rag-proxy source + bring up the stack ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Copy stack files and run docker compose up -d')) {
        Set-SCPItem -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential($SshUser, (New-Object System.Security.SecureString))) -KeyFile $keyPath -AcceptKey -Path $composeFile -Destination /opt/llm
        Set-SCPItem -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential($SshUser, (New-Object System.Security.SecureString))) -KeyFile $keyPath -AcceptKey -Path $litellmConfigFile -Destination /opt/llm

        # rag-proxy is built on the host from source (compose.yaml's `build: ../rag-proxy`
        # is relative to /opt/llm/compose.yaml, i.e. /opt/rag-proxy).
        Invoke-Remote -Command "sudo mkdir -p /opt/rag-proxy && sudo chown ${SshUser}:${SshUser} /opt/rag-proxy" | Out-Null
        $ragProxyDir = Join-Path $PSScriptRoot 'rag-proxy'
        foreach ($f in Get-ChildItem -Path $ragProxyDir -File) {
            Set-SCPItem -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential($SshUser, (New-Object System.Security.SecureString))) -KeyFile $keyPath -AcceptKey -Path $f.FullName -Destination /opt/rag-proxy
        }

        Invoke-Remote -Command 'cd /opt/llm && docker compose --env-file /opt/llm/.env -f compose.yaml up -d --build' | Out-Null
        Start-Sleep -Seconds 5
        $status = Invoke-Remote -Command 'cd /opt/llm && docker compose ps'
        Write-Host "--- docker compose ps ---" -ForegroundColor Green
        $status | ForEach-Object { Write-Host $_ }
    }

    # --- 5. Open WebUI has several built-in agentic features enabled by default that
    # break small/quantized chat models: Automations, Calendar, Code Interpreter, Code
    # Execution, and Memories all auto-attach tool schemas to every request regardless
    # of per-chat settings (confirmed via LiteLLM's raw request log - none of this is
    # exposed as an env var, so it's patched directly in Open WebUI's SQLite config).
    # Separately, Open WebUI's own "Builtin Tools" toolkit (knowledge-base search,
    # notes, task tracking, chat search, timestamp math - ~18 tools) is gated per-model
    # by meta.capabilities.builtin_tools, which defaults to true if unset - confirmed
    # against Open WebUI's own source (backend/open_webui/utils/middleware.py). Both
    # fixes are applied idempotently here so a fresh deploy doesn't regress into the
    # same "garbage instead of an answer" symptom on first chat.
    if ($PSCmdlet.ShouldProcess($HostName, 'Disable Open WebUI built-in tool auto-injection for the chat model')) {
        $fixScript = @'
import sqlite3, json, time, sys
c = sqlite3.connect("/app/backend/data/webui.db")
for k in ("automations.enable","calendar.enable","code_interpreter.enable","code_execution.enable","memories.enable"):
    c.execute("UPDATE config SET value=? WHERE key=?", ("false", k))
# Default is "pending" (new signups blocked until an admin manually approves them) -
# set to "user" so regular users get immediate access, not just admins. Models
# themselves have no access_control set, which Open WebUI treats as public-read to any
# logged-in user by default, so this is the actual gate for non-admin access.
c.execute("UPDATE config SET value=? WHERE key=?", ('"user"', "ui.default_user_role"))
c.commit()

# Open WebUI only creates a model's row in this table once it's actually been touched
# (chatted with) in the UI - it doesn't auto-populate from the connection's live model
# list on its own. So insert the row directly if it doesn't exist yet, rather than
# waiting on a browser interaction that may never happen before this script exits.
meta = {"profile_image_url": None, "description": None,
        "capabilities": {"builtin_tools": False, "vision": False, "citations": True},
        "knowledge": None}
now = int(time.time())
any_user = c.execute("SELECT id FROM user LIMIT 1").fetchone()
user_id = any_user[0] if any_user else None
for model_id in sys.argv[1:]:
    existing = c.execute("SELECT id FROM model WHERE id=?", (model_id,)).fetchone()
    if existing:
        c.execute("UPDATE model SET meta=?, is_active=1 WHERE id=?", (json.dumps(meta), model_id))
        print(f"Updated: {model_id} -> builtin_tools=false, is_active=1")
    elif user_id:
        c.execute(
            "INSERT INTO model (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active) VALUES (?,?,?,?,?,?,?,?,?)",
            (model_id, user_id, None, model_id, "{}", json.dumps(meta), now, now, 1)
        )
        print(f"Inserted: {model_id} -> builtin_tools=false, is_active=1")
    else:
        print(f"WARNING: no admin user exists yet (create the admin account in-browser first) - skipping {model_id}.")

    # Non-admin ("user" role) visibility is gated by the access_grant table, NOT by
    # meta.access_control - a model with no grant row is invisible to anyone but its
    # owner (confirmed in backend/open_webui/utils/models.py:get_filtered_models).
    # Grant public read to every user so regular accounts (not just admins) see these
    # models in the picker.
    try:
        import uuid
        c.execute(
            "INSERT INTO access_grant (id, resource_type, resource_id, principal_type, principal_id, permission, created_at) VALUES (?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), "model", model_id, "user", "*", "read", now)
        )
    except sqlite3.IntegrityError:
        pass  # already granted
c.commit()
'@
        # Derive the LiteLLM model aliases straight from litellm-config.yaml (model_name:
        # entries) rather than hardcoding them here, so adding a model there is enough.
        $litellmModelAliases = @(Select-String -Path $litellmConfigFile -Pattern '^\s*-\s*model_name:\s*(\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }) + @($RagProxyModelId)
        $heredocCmd = "cat > /tmp/fix_openwebui_tools.py <<'PYEOF'`n$fixScript`nPYEOF"
        Invoke-Remote -Command $heredocCmd | Out-Null
        Invoke-Remote -Command "docker cp /tmp/fix_openwebui_tools.py llm-open-webui:/tmp/fix_openwebui_tools.py && docker exec llm-open-webui python3 /tmp/fix_openwebui_tools.py $($litellmModelAliases -join ' ')"
        Invoke-Remote -Command 'docker restart llm-open-webui' | Out-Null
        Start-Sleep -Seconds 5
        Invoke-Remote -Command 'rm -f /tmp/fix_openwebui_tools.py' | Out-Null
    }

    # --- 6. Wire rag-proxy in as a second OpenAI-compatible connection ---
    # OPENAI_API_BASE_URLS/OPENAI_API_KEYS env vars only seed Open WebUI's INITIAL
    # config - once it's booted once, the connection list persists in its own SQLite
    # config table and further env changes are silently ignored (same
    # PersistentConfig gotcha as ENABLE_OLLAMA_API earlier in this file). So patch it
    # directly, matching what's actually in /opt/llm/.env, on every deploy.
    if ($PSCmdlet.ShouldProcess($HostName, 'Register rag-proxy as a second Open WebUI OpenAI connection')) {
        $envLines = Invoke-Remote -Command 'cat /opt/llm/.env' -Quiet
        $envMap = @{}
        $envLines | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $envMap[$Matches[1]] = $Matches[2] } }

        $connScript = @"
import sqlite3, json
c = sqlite3.connect("/app/backend/data/webui.db")
c.execute("UPDATE config SET value=? WHERE key=?", (json.dumps(["http://litellm:4000/v1", "http://rag-proxy:8010/v1"]), "openai.api_base_urls"))
c.execute("UPDATE config SET value=? WHERE key=?", (json.dumps(["$($envMap['LITELLM_MASTER_KEY'])", "$($envMap['RAG_PROXY_API_KEY'])"]), "openai.api_keys"))
c.commit()
print("Registered LiteLLM + rag-proxy as Open WebUI OpenAI connections.")
"@
        $heredocCmd2 = "cat > /tmp/add_connection.py <<'PYEOF'`n$connScript`nPYEOF"
        Invoke-Remote -Command $heredocCmd2 | Out-Null
        Invoke-Remote -Command "docker cp /tmp/add_connection.py llm-open-webui:/tmp/add_connection.py && docker exec llm-open-webui python3 /tmp/add_connection.py"
        Invoke-Remote -Command 'docker restart llm-open-webui' | Out-Null
        Start-Sleep -Seconds 5
        Invoke-Remote -Command 'rm -f /tmp/add_connection.py' | Out-Null
    }

    Write-Host "Deploy of $HostName complete." -ForegroundColor Green
}
finally {
    Remove-SSHSession -SSHSession $script:sshSession | Out-Null
}
# Authored by Caleb A. Morrow
