# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Bulk-load an HTML KB corpus into an Open WebUI Knowledge collection for RAG.

.DESCRIPTION
    Uploads every .html file in -SourceDir to Open WebUI (POST /api/v1/files/), then
    attaches each uploaded file to a named Knowledge collection (creating the collection
    if it doesn't exist). Open WebUI does its own chunking/embedding (configured via
    RAG_EMBEDDING_ENGINE/RAG_EMBEDDING_MODEL in the stack) and stores vectors in the
    Qdrant backend - this script only pushes documents through the API, no custom
    chunk/embed code.

    Requires an Open WebUI API key. Generate one once via Settings > Account > API Keys
    in the browser after the admin account is created, then store it:
        cmdkey /generic:ai02:webui-api-key /user:webui-admin /pass:<the key>

.PARAMETER HostName
    Host/profile name used to resolve the stored API key credential. Default 'ai02'.

.PARAMETER BaseUrl
    Open WebUI base URL. Default 'http://192.0.2.49:8080'.

.PARAMETER SourceDir
    Directory of .html files to ingest. Default the freshservice-kb-work converted corpus.

.PARAMETER KnowledgeName
    Name of the Knowledge collection to create/use. Default 'FreshService KB'.

.PARAMETER IpAddress
    Host IP, used to patch KB_TENANT_ID into /opt/llm/.env for rag-proxy once the
    Knowledge collection's real id is known. Default '192.0.2.49'.

.EXAMPLE
    .\Ingest-KbCorpus.ps1 -Verbose
#>
[CmdletBinding()]
param(
    [string]$HostName = 'ai02',
    [string]$IpAddress = '192.0.2.49',
    [string]$BaseUrl = 'http://192.0.2.49:8080',
    [string]$SourceDir = '.\converted',
    [string]$KnowledgeName = 'FreshService KB'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop
Import-Module Posh-SSH -ErrorAction Stop

if (-not (Test-Path $SourceDir)) { throw "Source directory not found: $SourceDir" }
$files = Get-ChildItem -Path $SourceDir -Filter '*.html' -File
if (-not $files) { throw "No .html files found in $SourceDir" }

$credTarget = "${HostName}:webui-api-key"
$cred = Get-StoredCredential -Target $credTarget
if (-not $cred) { throw "No stored API key credential '$credTarget'. See script help for how to generate/store one." }
$apiKey = [System.Net.NetworkCredential]::new('', $cred.Password).Password
$headers = @{ Authorization = "Bearer $apiKey" }

Write-Host "=== Ingesting $($files.Count) KB articles into Open WebUI Knowledge '$KnowledgeName' ===" -ForegroundColor Cyan

# --- find or create the knowledge collection ---
$existing = Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/" -Headers $headers -Method Get
$kb = $existing.items | Where-Object { $_.name -eq $KnowledgeName } | Select-Object -First 1
if (-not $kb) {
    Write-Verbose "Creating knowledge collection '$KnowledgeName'"
    $kb = Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/create" -Headers $headers -Method Post `
        -ContentType 'application/json' -Body (@{ name = $KnowledgeName; description = 'FreshService KB corpus (RAG pilot)' } | ConvertTo-Json)
}
$kbId = $kb.id
Write-Host "Knowledge collection id: $kbId"

# --- track already-attached files by name to keep this idempotent ---
$kbDetail = Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/$kbId" -Headers $headers -Method Get
$attachedNames = @($kbDetail.files | ForEach-Object { $_.meta.name })

$uploaded = 0
$skipped = 0
$failed = @()
foreach ($file in $files) {
    if ($attachedNames -contains $file.Name) {
        $skipped++
        continue
    }
    Write-Verbose "Uploading $($file.Name)"
    try {
        $uploadResp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/files/" -Headers $headers -Method Post -Form @{ file = Get-Item $file.FullName }

        # Open WebUI extracts text + embeds + upserts to Qdrant asynchronously after
        # upload. Firing all 324 uploads back-to-back overwhelmed Qdrant (hit the OS
        # file-descriptor limit) in an earlier run, so poll each file to completion
        # before moving to the next - much slower, but reliable.
        $processed = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            $status = Invoke-RestMethod -Uri "$BaseUrl/api/v1/files/$($uploadResp.id)" -Headers $headers -Method Get
            if ($status.data.status -ne 'pending') { $processed = $true; break }
        }
        if (-not $processed) {
            throw "processing did not complete within timeout"
        }
        if ($status.data.status -eq 'failed') {
            throw "processing failed: $($status.data.error)"
        }

        Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/$kbId/file/add" -Headers $headers -Method Post `
            -ContentType 'application/json' -Body (@{ file_id = $uploadResp.id } | ConvertTo-Json) | Out-Null
        $uploaded++
    } catch {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "Skipping $($file.Name): $msg"
        $failed += $file.Name
    }
}

Write-Host "--- RESULT ---" -ForegroundColor Green
Write-Host "Uploaded: $uploaded   Skipped (already present): $skipped   Failed: $($failed.Count)   Total in corpus: $($files.Count)"
if ($failed.Count -gt 0) {
    Write-Host "Failed files (likely empty/attachment-only articles):" -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "  $_" }
}

# --- patch KB_TENANT_ID into rag-proxy's env now that the collection id is known ---
$sshCred = Get-StoredCredential -Target "${HostName}:llmadmin-ssh"
if ($sshCred) {
    $keyPath = [System.Net.NetworkCredential]::new('', $sshCred.Password).Password
    $sess = New-SSHSession -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential('llmadmin', (New-Object System.Security.SecureString))) -KeyFile $keyPath -AcceptKey -ConnectionTimeout 15
    try {
        Invoke-SSHCommand -SSHSession $sess -Command "sudo sed -i 's/^KB_TENANT_ID=.*/KB_TENANT_ID=$kbId/' /opt/llm/.env" | Out-Null
        Invoke-SSHCommand -SSHSession $sess -Command 'cd /opt/llm && docker compose --env-file /opt/llm/.env -f compose.yaml up -d rag-proxy' | Out-Null
        Write-Host "rag-proxy KB_TENANT_ID set to $kbId and container restarted." -ForegroundColor DarkGray
    } finally {
        Remove-SSHSession -SSHSession $sess | Out-Null
    }
} else {
    Write-Warning "No stored SSH credential '${HostName}:llmadmin-ssh' - could not patch KB_TENANT_ID into rag-proxy's env. Set it manually: KB_TENANT_ID=$kbId"
}
# Authored by Caleb A. Morrow
