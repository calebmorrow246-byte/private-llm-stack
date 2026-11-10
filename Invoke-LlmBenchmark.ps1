# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Benchmark the LLM stack on an AI host — measures prefill speed, decode speed,
    TTFT, and total response time, with GPU power and thermal capture.

.DESCRIPTION
    Sends the standard Freshservice ticket-triage benchmark question to the
    freshservice-kb-rag model via the Open WebUI streaming API. Runs the prompt
    N times (default 3), averages the results, and emits a PSCustomObject
    suitable for piping into Build-ExecReport.ps1 or for manual review.

    GPU telemetry (temperature, power draw, utilisation) is sampled every 2
    seconds during each inference pass via SSH + nvidia-smi on the target host.

.PARAMETER HostName
    Credential Manager prefix. Used to look up 'HostName:webui-api-key'.
    Default 'ai04'.

.PARAMETER BaseUrl
    Open WebUI base URL. Default 'http://192.0.2.9:8080'.

.PARAMETER Model
    Model name to benchmark. Default 'freshservice-kb-rag'.

.PARAMETER Runs
    Number of timed runs to average. Default 3.

.PARAMETER GpuHost
    If set, samples GPU telemetry during each run via SSH.

.PARAMETER HostIp
    IP for SSH (GPU telemetry only). Default '192.0.2.9'.

.PARAMETER SshUser
    SSH user for GPU telemetry. Default 'admin'.

.EXAMPLE
    .\Invoke-LlmBenchmark.ps1 -GpuHost -Verbose
#>
[CmdletBinding()]
param(
    [string]$HostName = 'ai04',
    [string]$BaseUrl  = 'http://192.0.2.9:8080',
    [string]$Model    = 'freshservice-kb-rag',
    [int]$Runs        = 3,
    [switch]$GpuHost,
    [string]$HostIp   = '192.0.2.9',
    [string]$SshUser  = 'admin'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop
if ($GpuHost) { Import-Module Posh-SSH -ErrorAction Stop }

# --- API key ---
$apiKeyCred = Get-StoredCredential -Target "${HostName}:webui-api-key"
if (-not $apiKeyCred) { throw "Credential '${HostName}:webui-api-key' not found." }
$apiKey = [System.Net.NetworkCredential]::new('', $apiKeyCred.Password).Password

# --- Benchmark question (same scenario used in ai02/ai03 comparison) ---
$BenchmarkQuestion = @"
I cannot connect to the company VPN. I have tried restarting my computer and reinstalling the Cisco AnyConnect client but I am still getting the error "Unable to connect to server". I am working from home today and need access urgently. Can you help me resolve this?
"@.Trim()

# --- SSH for GPU telemetry ---
$sshSession = $null
function Start-GpuSample {
    if (-not $script:GpuHost) { return }
    $keyCred = Get-StoredCredential -Target "${HostName}:${SshUser}-ssh"
    if (-not $keyCred) { Write-Warning "No SSH key cred — GPU telemetry skipped."; return }
    $keyPath = [System.Net.NetworkCredential]::new('', $keyCred.Password).Password
    $emptySS = New-Object System.Security.SecureString
    $creds   = New-Object System.Management.Automation.PSCredential($SshUser, $emptySS)
    $script:sshSession = New-SSHSession -ComputerName $HostIp -Credential $creds -KeyFile $keyPath -AcceptKey -Force
    # Start background sampler on server
    Invoke-SSHCommand -SSHSession $script:sshSession -Command `
        'bash -c "nvidia-smi dmon -s pu -d 2 > /tmp/bmark_gpu.log 2>&1 &; echo $!"' -TimeOut 10 | Out-Null
}

function Stop-GpuSample {
    if (-not $script:sshSession) { return [pscustomobject]@{
        PeakTempC=0; PeakPowerW=0; AvgPowerW=0; AvgUtilPct=0 } }
    # Kill the sampler
    Invoke-SSHCommand -SSHSession $script:sshSession -Command 'pkill -f "nvidia-smi dmon" 2>/dev/null; true' -TimeOut 5 | Out-Null
    # Parse the log
    $raw = (Invoke-SSHCommand -SSHSession $script:sshSession -Command `
        'awk "NR>2 && /^ *0/" /tmp/bmark_gpu.log 2>/dev/null' -TimeOut 10).Output
    Remove-SSHSession -SSHSession $script:sshSession | Out-Null
    $script:sshSession = $null

    $temps = @(); $powers = @(); $utils = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*0\s+(\d+)\s+([\d.]+)\s+(\d+)') {
            $temps  += [int]$Matches[1]
            $powers += [double]$Matches[2]
            $utils  += [int]$Matches[3]
        }
    }
    if ($temps.Count -eq 0) { return [pscustomobject]@{PeakTempC=0;PeakPowerW=0;AvgPowerW=0;AvgUtilPct=0} }
    [pscustomobject]@{
        PeakTempC  = ($temps  | Measure-Object -Maximum).Maximum
        PeakPowerW = ($powers | Measure-Object -Maximum).Maximum
        AvgPowerW  = [math]::Round(($powers | Measure-Object -Average).Average, 1)
        AvgUtilPct = [math]::Round(($utils  | Measure-Object -Average).Average, 1)
    }
}

# --- Streaming inference with TTFT timing ---
function Invoke-BenchmarkRun {
    param([int]$RunNum)
    Write-Host "  Run $RunNum/$Runs..." -NoNewline

    $body = @{
        model    = $Model
        messages = @(@{ role = 'user'; content = $BenchmarkQuestion })
        stream   = $true
    } | ConvertTo-Json -Depth 4

    $headers = @{
        Authorization  = "Bearer $apiKey"
        'Content-Type' = 'application/json'
    }

    Start-GpuSample

    $startTime      = [System.Diagnostics.Stopwatch]::StartNew()
    $ttfwMs         = $null    # time to first word (ms)
    $outputWords    = 0
    $promptTokens   = 0
    $completionTokens = 0

    # Use HttpClient for true streaming
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client  = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(300)
    $client.DefaultRequestHeaders.Add('Authorization', "Bearer $apiKey")

    $reqMsg  = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$BaseUrl/api/chat/completions")
    $reqMsg.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')

    $response = $client.SendAsync($reqMsg, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $stream   = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader   = [System.IO.StreamReader]::new($stream)

    $allContent = [System.Text.StringBuilder]::new()
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line -or -not $line.StartsWith('data: ')) { continue }
        $json = $line.Substring(6).Trim()
        if ($json -eq '[DONE]') { break }
        try {
            $chunk = $json | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        $delta = $chunk.choices[0].delta.content
        if ($delta) {
            if ($null -eq $ttfwMs) { $ttfwMs = $startTime.Elapsed.TotalMilliseconds }
            [void]$allContent.Append($delta)
            $outputWords += ($delta -split '\s+' | Where-Object { $_ }).Count
        }

        # Capture usage if included in final chunk
        if ($chunk.usage) {
            $promptTokens     = $chunk.usage.prompt_tokens
            $completionTokens = $chunk.usage.completion_tokens
        }
    }
    $reader.Dispose(); $client.Dispose()

    $totalMs = $startTime.Elapsed.TotalMilliseconds
    $gpu     = Stop-GpuSample

    # Full assembled prompt word count: rag-proxy injects ~313 sys + 5x248 KB chunks + ~45 question = ~1,598 words
    # Use this as prefill numerator so the metric matches ai02/ai03 methodology (full_prompt_words / TTFW)
    $fullPromptWords = if ($promptTokens -gt 0) { [math]::Round($promptTokens * 0.75) } else { 1598 }
    $ttfwSec     = if ($ttfwMs) { [math]::Round($ttfwMs / 1000, 2) } else { $null }
    $totalSec    = [math]::Round($totalMs / 1000, 1)
    $genSec      = if ($ttfwMs) { ($totalMs - $ttfwMs) / 1000 } else { $totalMs / 1000 }
    $decodeSec   = $genSec
    $decodeWps   = if ($decodeSec -gt 0) { [math]::Round($outputWords / $decodeSec, 1) } else { 0 }
    $prefillSec  = if ($ttfwMs) { $ttfwMs / 1000 } else { 0 }
    $prefillWps  = if ($prefillSec -gt 0) { [math]::Round($fullPromptWords / $prefillSec, 0) } else { 0 }

    Write-Host " ${totalSec}s total | TTFW ${ttfwSec}s | decode ${decodeWps} w/s | GPU0 peak $($gpu.PeakTempC)C $($gpu.PeakPowerW)W"

    [pscustomobject]@{
        Run             = $RunNum
        TtfwSec         = $ttfwSec
        TotalSec        = $totalSec
        PrefillWps      = $prefillWps
        DecodeWps       = $decodeWps
        OutputWords     = $outputWords
        PromptTokens    = $promptTokens
        CompletionTokens = $completionTokens
        GpuPeakTempC    = $gpu.PeakTempC
        GpuPeakPowerW   = $gpu.PeakPowerW
        GpuAvgPowerW    = $gpu.AvgPowerW
        GpuAvgUtilPct   = $gpu.AvgUtilPct
    }
}

# --- Run the benchmark ---
Write-Host ""
Write-Host "=== LLM Benchmark: $Model on $HostName ===" -ForegroundColor Cyan
Write-Host "Question: $($BenchmarkQuestion.Substring(0, [math]::Min(80, $BenchmarkQuestion.Length)))..."
Write-Host "Runs: $Runs  |  GPU telemetry: $GpuHost"
Write-Host ""

# Warm-up run (not counted)
Write-Host "Warm-up (not counted)..."
try { Invoke-BenchmarkRun -RunNum 0 | Out-Null } catch { Write-Warning "Warm-up failed: $_" }
Start-Sleep -Seconds 5

$results = @()
for ($r = 1; $r -le $Runs; $r++) {
    $results += Invoke-BenchmarkRun -RunNum $r
    if ($r -lt $Runs) { Start-Sleep -Seconds 10 }
}

# --- Averages ---
$avg = [pscustomobject]@{
    TtfwSec       = [math]::Round(($results.TtfwSec    | Measure-Object -Average).Average, 2)
    TotalSec      = [math]::Round(($results.TotalSec   | Measure-Object -Average).Average, 1)
    PrefillWps    = [math]::Round(($results.PrefillWps | Measure-Object -Average).Average, 0)
    DecodeWps     = [math]::Round(($results.DecodeWps  | Measure-Object -Average).Average, 1)
    GpuPeakTempC  = ($results.GpuPeakTempC  | Measure-Object -Maximum).Maximum
    GpuPeakPowerW = ($results.GpuPeakPowerW | Measure-Object -Maximum).Maximum
    GpuAvgPowerW  = [math]::Round(($results.GpuAvgPowerW | Measure-Object -Average).Average, 1)
}

Write-Host ""
Write-Host "=== AVERAGED RESULTS ($Runs runs) ===" -ForegroundColor Green
Write-Host "  Prefill speed (reading the question) : $($avg.PrefillWps) words/sec"
Write-Host "  Decode speed  (writing the answer)   : $($avg.DecodeWps) words/sec"
Write-Host "  Time to first word (TTFW)             : $($avg.TtfwSec) sec"
Write-Host "  Total response time                   : $($avg.TotalSec) sec"
if ($GpuHost) {
    Write-Host "  GPU 0 peak temperature                : $($avg.GpuPeakTempC) C"
    Write-Host "  GPU 0 peak power draw                 : $($avg.GpuPeakPowerW) W  (TDP: 72W)"
    Write-Host "  GPU 0 avg power during inference      : $($avg.GpuAvgPowerW) W"
}
Write-Host ""
Write-Host "--- Comparison context ---"
Write-Host "  ai02 CPU  : prefill 144.7 w/s | decode 13.8 w/s | TTFW 11.1s | total ~18s"
Write-Host "  ai03 A400 : prefill 729.4 w/s | decode 16.9 w/s | TTFW  2.2s | total  ~8s"
Write-Host "  ai04 L4   : prefill $($avg.PrefillWps) w/s | decode $($avg.DecodeWps) w/s | TTFW $($avg.TtfwSec)s | total $($avg.TotalSec)s"
Write-Host "  Freshservice 20s budget: $(if ($avg.TotalSec -lt 20) { 'PASS' } else { 'FAIL' })"
Write-Host ""

$results | Format-Table -AutoSize
# Authored by Caleb A. Morrow
