# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Install NVIDIA drivers, CUDA toolkit, Docker Engine, and NVIDIA Container Toolkit
    on an Ubuntu 24.04 LLM host over SSH.

.DESCRIPTION
    Prepares ai04 (or any Ubuntu 24.04 host with NVIDIA GPUs) for GPU inference:
      1. Full OS update (apt update + full-upgrade + autoremove).
      2. NVIDIA driver install via ubuntu-drivers autoinstall. Reboots the host and
         waits for SSH to come back before continuing.
      3. CUDA toolkit (cuda-toolkit-12-6) via NVIDIA's official apt repo.
      4. Docker Engine + Compose plugin (get.docker.com) if not already present.
      5. NVIDIA Container Toolkit (NCT) - lets Docker containers access the GPU.
         Runs nvidia-ctk to configure Docker's default runtime.
      6. Verifies: nvidia-smi (both GPUs), nvcc --version, Docker GPU passthrough.

    Uses the SSH key stored by New-Ai04SshKey.ps1 (Credential Manager target
    '${HostName}:${SshUser}-ssh'). Reboots are handled automatically with a
    reconnect wait loop. No interaction required after launch.

.PARAMETER HostName
    Host profile name. Used to look up the SSH key credential. Default 'ai04'.

.PARAMETER HostIp
    IP address to SSH to. Default '192.0.2.9'.

.PARAMETER SshUser
    SSH user on the target host. Default 'admin'.

.PARAMETER RebootWaitSeconds
    How long to wait after issuing a reboot before polling for SSH. Default 60.

.EXAMPLE
    .\Install-NvidiaStack.ps1 -WhatIf
    .\Install-NvidiaStack.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$HostName           = 'ai04',
    [string]$HostIp             = '192.0.2.9',
    [string]$SshUser            = 'admin',
    [int]$RebootWaitSeconds     = 60
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop
Import-Module Posh-SSH -ErrorAction Stop

# --- resolve SSH key ---
$sshTarget = "${HostName}:${SshUser}-ssh"
$keyCred   = Get-StoredCredential -Target $sshTarget
if (-not $keyCred) { throw "SSH key credential '$sshTarget' not found. Run New-Ai04SshKey.ps1 first." }
$keyPath   = [System.Net.NetworkCredential]::new('', $keyCred.Password).Password
if (-not (Test-Path $keyPath)) { throw "SSH key file not found: $keyPath" }

$emptySS   = New-Object System.Security.SecureString
$keyCreds  = New-Object System.Management.Automation.PSCredential($SshUser, $emptySS)

function Connect-Ai04 {
    New-SSHSession -ComputerName $HostIp -Credential $keyCreds -KeyFile $keyPath -AcceptKey -ConnectionTimeout 15
}

function Invoke-Remote {
    param([Parameter(Mandatory)][string]$Command, [int]$TimeoutSec = 600, [switch]$Quiet)
    $r = Invoke-SSHCommand -SSHSession $script:ssh -Command $Command -TimeOut $TimeoutSec
    if (-not $Quiet) { Write-Verbose "`$ $Command`n$($r.Output -join "`n")" }
    if ($r.ExitStatus -ne 0) {
        throw "Remote command failed (exit $($r.ExitStatus)): $Command`n$($r.Output -join "`n")$($r.Error -join "`n")"
    }
    $r.Output
}

function Wait-SshReady {
    param([int]$MaxWaitSeconds = 300)
    Write-Host "Waiting $RebootWaitSeconds s for reboot to start..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $RebootWaitSeconds
    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $s = New-SSHSession -ComputerName $HostIp -Credential $keyCreds -KeyFile $keyPath -AcceptKey -ConnectionTimeout 5 -ErrorAction Stop
            Write-Host "SSH is back." -ForegroundColor Green
            return $s
        } catch {
            Write-Host "  ...still waiting ($(([int](($deadline - (Get-Date)).TotalSeconds)))s left)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }
    throw "Host did not come back within $MaxWaitSeconds seconds after reboot."
}

Write-Host "=== NVIDIA Stack Install: $HostName ($HostIp) ===" -ForegroundColor Cyan
if ($WhatIfPreference) { Write-Host "** DRY-RUN (-WhatIf): no changes will be sent **" -ForegroundColor Yellow; return }

$script:ssh = Connect-Ai04

try {
    # --- 1. OS update ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Full OS update (apt update + full-upgrade + autoremove)')) {
        Write-Host "Step 1/5 — OS update..." -ForegroundColor Cyan
        Invoke-Remote -Command 'sudo apt-get update -qq' -TimeoutSec 300 | Out-Null
        Invoke-Remote -Command 'sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq' -TimeoutSec 600 | Out-Null
        Invoke-Remote -Command 'sudo apt-get autoremove -y -qq' | Out-Null
        Write-Host "OS updated."
    }

    # --- 2. NVIDIA driver ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Install NVIDIA driver via ubuntu-drivers autoinstall + reboot')) {
        Write-Host "Step 2/5 — NVIDIA driver install..." -ForegroundColor Cyan
        $driverPresent = $false
        try { Invoke-Remote -Command 'nvidia-smi' -Quiet | Out-Null; $driverPresent = $true } catch { }
        if ($driverPresent) {
            Write-Host "NVIDIA driver already present - skipping."
        } else {
            Invoke-Remote -Command 'sudo apt-get install -y ubuntu-drivers-common -qq' -TimeoutSec 120 | Out-Null
            Invoke-Remote -Command 'sudo ubuntu-drivers autoinstall' -TimeoutSec 300 | Out-Null
            Write-Host "NVIDIA driver installed. Rebooting..." -ForegroundColor DarkGray
            try { Invoke-Remote -Command 'sudo reboot' -Quiet | Out-Null } catch { }
            Remove-SSHSession -SSHSession $script:ssh | Out-Null
            $script:ssh = Wait-SshReady
        }
    }

    # --- 3. CUDA toolkit ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Install CUDA toolkit 12.6 via NVIDIA apt repo')) {
        Write-Host "Step 3/5 — CUDA toolkit..." -ForegroundColor Cyan
        $cudaPresent = $false
        try { Invoke-Remote -Command 'nvcc --version' -Quiet | Out-Null; $cudaPresent = $true } catch { }
        if ($cudaPresent) {
            Write-Host "CUDA toolkit already present - skipping."
        } else {
            # Add NVIDIA's official CUDA apt repo for Ubuntu 24.04 (x86_64)
            $repoSetup = @'
wget -qO /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i /tmp/cuda-keyring.deb
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
rm -f /tmp/cuda-keyring.deb
'@
            foreach ($line in ($repoSetup -split "`n" | Where-Object { $_.Trim() })) {
                Invoke-Remote -Command $line -TimeoutSec 600 | Out-Null
            }
            # Add CUDA to PATH for the session
            Invoke-Remote -Command 'echo "export PATH=/usr/local/cuda/bin:\$PATH" | sudo tee /etc/profile.d/cuda.sh > /dev/null' | Out-Null
            Write-Host "CUDA toolkit installed."
        }
    }

    # --- 4. Docker Engine + Compose plugin ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Install Docker Engine + Compose plugin')) {
        Write-Host "Step 4/5 — Docker..." -ForegroundColor Cyan
        $dockerPresent = $false
        try { Invoke-Remote -Command 'docker --version' -Quiet | Out-Null; $dockerPresent = $true } catch { }
        if ($dockerPresent) {
            Write-Host "Docker already present - skipping."
        } else {
            Invoke-Remote -Command 'curl -fsSL https://get.docker.com | sudo sh' -TimeoutSec 300 | Out-Null
            Invoke-Remote -Command "sudo usermod -aG docker $SshUser" | Out-Null
            Write-Host "Docker installed."
        }
    }

    # --- 5. NVIDIA Container Toolkit ---
    if ($PSCmdlet.ShouldProcess($HostName, 'Install NVIDIA Container Toolkit and configure Docker runtime')) {
        Write-Host "Step 5/5 — NVIDIA Container Toolkit..." -ForegroundColor Cyan
        $nctPresent = $false
        try { Invoke-Remote -Command 'nvidia-ctk --version' -Quiet | Out-Null; $nctPresent = $true } catch { }
        if ($nctPresent) {
            Write-Host "NVIDIA Container Toolkit already present - skipping."
        } else {
            # Each step is sent individually to avoid shell-continuation line issues
            # and /dev/tty problems with gpg. The gpg key is downloaded to a temp file
            # first (rather than piped directly) so --batch dearmor never needs a TTY.
            Invoke-Remote -Command 'sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg' | Out-Null
            Invoke-Remote -Command 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /tmp/nct.gpg' | Out-Null
            Invoke-Remote -Command 'sudo gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg /tmp/nct.gpg' | Out-Null
            Invoke-Remote -Command 'rm -f /tmp/nct.gpg' | Out-Null
            Invoke-Remote -Command 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o /tmp/nct.list' | Out-Null
            Invoke-Remote -Command "sudo sed -i 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' /tmp/nct.list" | Out-Null
            Invoke-Remote -Command 'sudo cp /tmp/nct.list /etc/apt/sources.list.d/nvidia-container-toolkit.list && rm -f /tmp/nct.list' | Out-Null
            Invoke-Remote -Command 'sudo apt-get update -qq' -TimeoutSec 180 | Out-Null
            Invoke-Remote -Command 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit' -TimeoutSec 300 | Out-Null
            Invoke-Remote -Command 'sudo nvidia-ctk runtime configure --runtime=docker' | Out-Null
            Invoke-Remote -Command 'sudo systemctl restart docker' | Out-Null
            Write-Host "NVIDIA Container Toolkit installed and Docker runtime configured."
        }
    }

    # --- Verify ---
    Write-Host ""
    Write-Host "=== Verification ===" -ForegroundColor Cyan

    Write-Host "nvidia-smi:" -ForegroundColor DarkGray
    Invoke-Remote -Command 'nvidia-smi' | ForEach-Object { Write-Host "  $_" }

    Write-Host "nvcc:" -ForegroundColor DarkGray
    try {
        Invoke-Remote -Command 'nvcc --version' | ForEach-Object { Write-Host "  $_" }
    } catch {
        Write-Warning "nvcc not in PATH yet (session needs logout/login for /etc/profile.d/cuda.sh to take effect). Verify manually: nvcc --version"
    }

    Write-Host "Docker GPU passthrough:" -ForegroundColor DarkGray
    try {
        $gpuCheck = Invoke-Remote -Command 'docker run --rm --gpus all ubuntu:22.04 echo "GPU_OK"' -TimeoutSec 120
        Write-Host "  $($gpuCheck -join ' ')" -ForegroundColor Green
    } catch {
        Write-Warning "Docker GPU passthrough test failed - may need a new SSH session for docker group membership. Retry manually: docker run --rm --gpus all ubuntu:22.04 echo OK"
    }

    Write-Host ""
    Write-Host "NVIDIA stack install complete on $HostName." -ForegroundColor Green
    Write-Host "Next step: .\Deploy-LlmStack.ps1 -HostName $HostName -IpAddress $HostIp -SshUser $SshUser -GpuHost -WhatIf"

} finally {
    Remove-SSHSession -SSHSession $script:ssh | Out-Null
}
# Authored by Caleb A. Morrow
