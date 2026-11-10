# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Generate an ed25519 SSH key for ai04 (admin user) and install it on the host
    using password authentication, then verify key-only login.

.DESCRIPTION
    One-shot setup for ai04 SSH key auth:
      1. Generates an ed25519 keypair at ~/.ssh/ai04_admin_ed (reuses if present).
      2. Stores the private key path in Windows Credential Manager target 'ai04:admin-ssh'.
      3. Uses Posh-SSH with the current password credential ('ai03') to push the
         public key to /home/admin/.ssh/authorized_keys on the host.
      4. Verifies that key-only login succeeds before exiting.

    After this script runs, Deploy-LlmStack.ps1 can use the stored key credential.
    No secret is printed or committed to the repo.

.PARAMETER HostIp
    IP address of ai04. Default '192.0.2.9'.

.PARAMETER PasswordCredTarget
    Windows Credential Manager target for the current password credential.
    Default 'ai03' (decommissioned host, cred reused for ai04).

.EXAMPLE
    .\New-Ai04SshKey.ps1
    .\New-Ai04SshKey.ps1 -HostIp 192.0.2.9
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$HostIp             = '192.0.2.9',
    [string]$SshUser            = 'admin',
    [string]$HostName           = 'ai04',
    [string]$PasswordCredTarget = 'ai03',
    [string]$KeyDir             = (Join-Path $env:USERPROFILE '.ssh')
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop
Import-Module Posh-SSH -ErrorAction Stop

# --- 1. Generate ed25519 keypair ---
if (-not (Test-Path $KeyDir)) { New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null }
$keyPath = Join-Path $KeyDir "${HostName}_${SshUser}_ed"
$pubPath = "$keyPath.pub"

if (Test-Path $keyPath) {
    Write-Host "SSH key already exists at $keyPath - reusing."
} else {
    if ($PSCmdlet.ShouldProcess($keyPath, 'Generate ed25519 SSH keypair')) {
        # Use WSL ssh-keygen to avoid the Windows OpenSSH -N '' passphrase quirk.
        # WSL path: convert C:\Users\...\key to /mnt/c/Users/.../key
        $wslKeyPath = ($keyPath -replace '^([A-Za-z]):\\', { "/mnt/$($_.Groups[1].Value.ToLower())/" }) -replace '\\', '/'
        wsl -e ssh-keygen -t ed25519 -f $wslKeyPath -N "" -C "${SshUser}@${HostName}" 2>&1 | Out-Null
        if (-not (Test-Path $pubPath)) { throw "ssh-keygen did not produce $pubPath" }
        Write-Host "Keypair generated: $keyPath"
    }
}
$pubKey = (Get-Content $pubPath -Raw).Trim()

# --- 2. Store key path in Credential Manager ---
$sshTarget = "${HostName}:${SshUser}-ssh"
if ($PSCmdlet.ShouldProcess($sshTarget, "Store SSH key pointer in Windows Credential Manager")) {
    & cmdkey "/generic:$sshTarget" "/user:$SshUser" "/pass:$keyPath" | Out-Null
    Write-Host "Credential Manager: '$sshTarget' -> $keyPath"
}

# --- 3. Push public key to authorized_keys using password auth ---
$pwdCred = Get-StoredCredential -Target $PasswordCredTarget
if (-not $pwdCred) { throw "Password credential '$PasswordCredTarget' not found in Credential Manager." }

if ($PSCmdlet.ShouldProcess($HostIp, "Install public key to /home/$SshUser/.ssh/authorized_keys")) {
    Write-Host "Connecting with password to push public key..." -ForegroundColor DarkGray
    $session = New-SSHSession -ComputerName $HostIp -Credential $pwdCred -AcceptKey -ConnectionTimeout 15
    try {
        $commands = @(
            "mkdir -p /home/$SshUser/.ssh && chmod 700 /home/$SshUser/.ssh",
            "echo '$pubKey' >> /home/$SshUser/.ssh/authorized_keys",
            "sort -u /home/$SshUser/.ssh/authorized_keys -o /home/$SshUser/.ssh/authorized_keys",
            "chmod 600 /home/$SshUser/.ssh/authorized_keys"
        )
        foreach ($cmd in $commands) {
            $r = Invoke-SSHCommand -SSHSession $session -Command $cmd
            if ($r.ExitStatus -ne 0) { throw "Remote command failed: $cmd`n$($r.Output)" }
        }
        Write-Host "Public key installed on $HostIp."
    } finally {
        Remove-SSHSession -SSHSession $session | Out-Null
    }
}

# --- 4. Verify key-only login ---
Write-Host "Verifying key-only login..." -ForegroundColor DarkGray
$keySession = New-SSHSession -ComputerName $HostIp `
    -Credential (New-Object System.Management.Automation.PSCredential($SshUser, (New-Object System.Security.SecureString))) `
    -KeyFile $keyPath -AcceptKey -ConnectionTimeout 10
try {
    $result = Invoke-SSHCommand -SSHSession $keySession -Command 'hostname && whoami'
    Write-Host "Key login verified: $($result.Output -join ', ')" -ForegroundColor Green
} finally {
    Remove-SSHSession -SSHSession $keySession | Out-Null
}

Write-Host ""
Write-Host "Done. SSH key setup complete for $HostName." -ForegroundColor Green
Write-Host "  Key: $keyPath"
Write-Host "  Credential target: $sshTarget"
Write-Host "  Next step: .\Install-NvidiaStack.ps1 -HostName $HostName -HostIp $HostIp"
# Authored by Caleb A. Morrow
