# Authored by Caleb A. Morrow
#requires -Version 7.0
<#
.SYNOPSIS
    Generate the credentials for a new LLM blade: a strong root password and a
    dedicated key-only SSH admin user, ready for an Ubuntu autoinstall.

.DESCRIPTION
    - Generates a random root password and its SHA-512 crypt hash (for autoinstall).
    - Generates an ed25519 SSH keypair for the dedicated admin user (key-only login).
    - Stores ONLY the SSH key pointer in Windows Credential Manager. The root password is
      NEVER stored locally - it is printed once and must be filed in Delinea Secret Server.
    - Returns the crypt hash + public key (for the autoinstall user-data).

    No secret is ever written to the repo. The private key lands in ~/.ssh (0600).
    Idempotent: reuses an existing keypair; regenerates the root password each run
    unless -KeepRootPassword and a stored copy exists.

.PARAMETER HostName
    Target host / profile name, e.g. ai02. Used in credential targets + key name.

.PARAMETER SshUser
    Dedicated SSH admin username. Default 'llmadmin'.

.EXAMPLE
    $sec = .\New-LlmBladeSecrets.ps1 -HostName ai02
    # then use $sec.RootHash and $sec.PublicKey in the autoinstall user-data
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$HostName,
    [string]$SshUser = 'llmadmin',
    [int]$PasswordLength = 24,
    [string]$KeyDir = (Join-Path $env:USERPROFILE '.ssh')
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module CredentialManager -ErrorAction Stop

function New-StrongPassword {
    param([int]$Length = 24)
    # Unambiguous, shell/YAML-safe set (no quotes, backslash, space, or 0/O/1/l/I).
    $set = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%^*-_=+'.ToCharArray()
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $set[$_ % $set.Length] })
}

# --- root password + SHA-512 crypt hash (via WSL openssl) ---
$rootPw = New-StrongPassword -Length $PasswordLength
$salt   = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
$rootHash = (wsl -e openssl passwd -6 -salt $salt $rootPw).Trim()
if (-not $rootHash.StartsWith('$6$')) { throw "Failed to generate SHA-512 crypt hash (got: $rootHash)" }

# --- ed25519 keypair for the dedicated admin user ---
if (-not (Test-Path $KeyDir)) { New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null }
$keyPath = Join-Path $KeyDir ("{0}_{1}" -f $HostName, $SshUser)
$pubPath = "$keyPath.pub"
if (Test-Path $keyPath) {
    Write-Verbose "Reusing existing key $keyPath"
} else {
    & ssh-keygen -t ed25519 -f $keyPath -N '""' -C ("{0}@{1}" -f $SshUser, $HostName) | Out-Null
    if (-not (Test-Path $pubPath)) { throw "ssh-keygen did not produce $pubPath" }
}
$pubKey = (Get-Content $pubPath -Raw).Trim()

# --- store the dedicated SSH key pointer in Windows Credential Manager ---
# ROOT IS DELIBERATELY NOT STORED HERE - it must live in Delinea Secret Server only
# (privileged/break-glass credential). Only the automation SSH cred is kept locally.
# NB1: CredentialManager's New-StoredCredential is broken under PowerShell 7 (needs
#      System.Web, absent in .NET Core). Use cmdkey (per CLAUDE.md); Get-StoredCredential reads it back.
# NB2: cmdkey REJECTS spaces in the target name - use colon-delimited, space-free targets.
$sshTarget = "${HostName}:${SshUser}-ssh"
& cmdkey "/generic:$sshTarget" "/user:$SshUser" "/pass:$keyPath" | Out-Null

Write-Host ""
Write-Host "================ SECRETS for $HostName ================" -ForegroundColor Cyan
Write-Host "Root password (STORE IN DELINEA SECRET SERVER ONLY - not saved anywhere on this box):" -ForegroundColor Yellow
Write-Host "    $rootPw" -ForegroundColor White
Write-Host ""
Write-Host "SSH admin user : $SshUser  (key-only, sudo)"
Write-Host "Private key     : $keyPath   (use: ssh -i $keyPath $SshUser@<ip>)"
Write-Host "Public key      : $pubKey"
Write-Host ""
Write-Host "Credential Manager entry created: '$sshTarget' (SSH key only; root NOT stored locally)" -ForegroundColor DarkGray
Write-Host "======================================================" -ForegroundColor Cyan

# Return the bits the autoinstall needs (hash + pubkey), not the plaintext.
[pscustomobject]@{
    HostName   = $HostName
    SshUser    = $SshUser
    RootHash   = $rootHash
    PublicKey  = $pubKey
    KeyPath    = $keyPath
}
# Authored by Caleb A. Morrow
