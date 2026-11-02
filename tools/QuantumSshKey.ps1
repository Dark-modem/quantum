<#
.SYNOPSIS
    Quantum SSH key workflow for the owner's Windows workstation.

.DESCRIPTION
    The client half of the Quantum SSH bootstrap (Session 6). Generates an
    Ed25519 keypair locally, provisions ONLY the public key to the server
    through the operator's existing access, tests the new access through the
    new port, and - only after that test succeeds - optionally finalizes the
    server (disable password login and the old SSH port).

    Private keys never leave this workstation. They are stored under
    $HOME\.quantum\ssh with a locked-down ACL and are never uploaded,
    printed or stored in Git, controller state, agent state or logs.

    Requires Windows 10+ (OpenSSH client) and PowerShell 5.1+.

.EXAMPLE
    .\QuantumSshKey.ps1 New-QuantumSshKey -Label controller-1
    .\QuantumSshKey.ps1 Add-QuantumSshKey  -Label controller-1 -HostName 1.2.3.4 -User root
    .\QuantumSshKey.ps1 Test-QuantumSsh    -Label controller-1 -HostName 1.2.3.4 -User qadmin -Port 2222
    .\QuantumSshKey.ps1 Complete-QuantumSsh -Label controller-1 -HostName 1.2.3.4 -User qadmin -Port 2222
    .\QuantumSshKey.ps1 Show-QuantumSshCommand -Label controller-1 -HostName 1.2.3.4 -User qadmin -Port 2222
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('New-QuantumSshKey', 'Add-QuantumSshKey', 'Test-QuantumSsh',
             'Complete-QuantumSsh', 'Show-QuantumSshCommand', 'Repair-QuantumSshClient')]
    [string]$Command,

    [string]$Label,

    [string]$HostName,

    [string]$User,

    [int]$Port = 22,

    [switch]$Passphrase,

    [switch]$Force,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$KeyDir = Join-Path $HOME '.quantum\ssh'

function Get-QsshTool([string]$Name) {
    $p = Join-Path $env:WINDIR "System32\OpenSSH\$Name.exe"
    if (Test-Path $p) { return $p }
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    throw "$Name not found. Install the Windows OpenSSH client (Settings > Apps > Optional features)."
}

function Get-QsshKeyPath([string]$Label) {
    if (-not $Label) { throw "-Label is required." }
    # Session 4 review (SSH-1): the label becomes a filename here and a key
    # comment that is later transported to the server — both are safe only
    # for a strict character set. No path separators, no quotes, no shell
    # metacharacters.
    if ($Label -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "-Label must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ (letters, digits, dot, dash, underscore; max 64)."
    }
    Join-Path $KeyDir ("{0}_ed25519" -f $Label)
}

function Assert-QsshKey([string]$KeyPath) {
    if (-not (Test-Path $KeyPath)) {
        throw "Private key not found: $KeyPath — run 'New-QuantumSshKey -Label <name>' first."
    }
    if (-not (Test-Path "$KeyPath.pub")) {
        throw "Public key not found: $KeyPath.pub — regenerate the pair."
    }
}

function New-QuantumSshKey {
    $keyPath = Get-QsshKeyPath $Label
    if ((Test-Path $keyPath) -and -not $Force) {
        throw "Key already exists: $keyPath (use -Force to replace)."
    }
    if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
    if (Test-Path "$keyPath.pub") { Remove-Item "$keyPath.pub" -Force }
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    $keygen = Get-QsshTool 'ssh-keygen'
    $genArgs = @('-t', 'ed25519', '-f', $keyPath, '-C', "quantum-$Label")
    if (-not $Passphrase) { $genArgs += @('-N', '""') }   # automation default: no passphrase (documented tradeoff)
    & $keygen @genArgs
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
    # Lock the private key down to the current user only. icacls with a
    # SID-based grant (*S-1-...): immune to account names that start with a
    # dash and to .NET ACL privilege quirks in Windows PowerShell 5.1.
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $keyPath '/inheritance:r' '/grant:r' "*${sid}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not restrict the private key ACL." }
    Write-Host ""
    Write-Host "[ok] Key pair generated." -ForegroundColor Green
    Write-Host ("     Private key (NEVER share, never upload): {0}" -f $keyPath)
    Write-Host ("     کلید خصوصی: هرگز آن را آپلود یا ارسال نکنید — {0}" -f $keyPath)
    Write-Host ("     Public key (install this on the server):  {0}.pub" -f $keyPath)
    if ($Passphrase) { Write-Host "     Protected with a passphrase (you chose this)." }
    else { Write-Host "     No passphrase (automation default). Re-run with -Passphrase to protect it." }
    Write-Host ""
    Write-Host "Public key content:"
    Get-Content "$keyPath.pub"
}

function Add-QuantumSshKey {
    Assert-QsshKey (Get-QsshKeyPath $Label)
    if (-not $HostName -or -not $User) { throw "-HostName and -User are required." }
    $ssh = Get-QsshTool 'ssh'
    $pub = (Get-Content (Get-QsshKeyPath $Label + '.pub') -Raw).Trim()
    # Session 4 review (SSH-1): the public key is transported base64-encoded
    # and decoded on the server — the key text (including its comment) never
    # passes through remote shell quoting, so a crafted comment cannot break
    # out into server-side command execution. The remote script itself is a
    # fixed string.
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pub))
    # The owner's EXISTING access is used here; ssh prompts for the password
    # itself and nothing is stored. The remote append is idempotent. Base64 is
    # shell-safe ([A-Za-z0-9+/=]), so the key text is decoded once into a
    # remote variable and always used double-quoted — nothing interpolatable
    # ever reaches the remote shell.
    $remote = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && " +
              "chmod 600 ~/.ssh/authorized_keys && " +
              "decoded=`$(printf %s $b64 | base64 -d) && " +
              "grep -qxF `"`$decoded`" ~/.ssh/authorized_keys 2>/dev/null || " +
              "printf '%s\n' `"`$decoded`" >> ~/.ssh/authorized_keys"
    & $ssh -o ConnectTimeout=10 -p $Port "$User@$HostName" $remote
    if ($LASTEXITCODE -ne 0) { throw "Provisioning failed (existing access rejected?)." }
    Write-Host "[ok] Public key installed on $HostName for $User." -ForegroundColor Green
    Write-Host "     کلید عمومی روی سرور نصب شد."
}

function Test-QuantumSsh {
    $keyPath = Get-QsshKeyPath $Label
    Assert-QsshKey $keyPath
    if (-not $HostName -or -not $User) { throw "-HostName and -User are required." }
    $ssh = Get-QsshTool 'ssh'
    # BatchMode: key authentication ONLY — no password fallback. This proves
    # exactly what the owner needs proven: new key + new port.
    & $ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new `
           -i $keyPath -p $Port "$User@$HostName" "echo quantum-ssh-ok" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] New access (key + port $Port) does not work yet." -ForegroundColor Red
        Write-Host "       آزمون دسترسی جدید ناموفق بود؛ پورت و رمز قبلی هنوز فعال‌اند."
        Write-Host "       If the output mentions 'Bad permissions' on a local file, run:"
        Write-Host "         .\QuantumSshKey.ps1 Repair-QuantumSshClient"
        return $false
    }
    Write-Host "[ok] New access verified: key + port $Port." -ForegroundColor Green
    Write-Host "     دسترسی جدید تأیید شد."
    return $true
}

function Repair-QuantumSshClient {
    # Windows OpenSSH refuses to run when client files are owned by an
    # orphaned SID or inherit too-wide ACLs. This repairs the common local
    # files ONLY (config, known_hosts) on the owner's own workstation.
    $sshDir = Join-Path $HOME '.ssh'
    if (-not (Test-Path $sshDir)) { Write-Host "No $sshDir — nothing to repair."; return }
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($f in @('config', 'known_hosts')) {
        $path = Join-Path $sshDir $f
        if (Test-Path $path) {
            takeown /f $path | Out-Null
            icacls $path '/inheritance:r' '/grant:r' "*${sid}:F" | Out-Null
            Write-Host "[ok] Repaired ACL: $path"
        }
    }
    Write-Host "فایل‌های کلاینت ssh اصلاح شدند — دوباره تلاش کنید."
}

function Complete-QuantumSsh {
    if (-not $Yes) {
        Write-Warning "This disables password login and the old SSH port on $HostName."
        Write-Host "Keep the private key safe — it becomes the only SSH access."
        Write-Host "ورود با رمز غیرفعال می‌شود؛ کلید خصوصی تنها راه ورود خواهد بود. مطمئنید؟"
        $answer = Read-Host "Type FINALIZE to continue"
        if ($answer -cne 'FINALIZE') { Write-Host "Aborted — nothing changed."; return }
    }
    if (-not (Test-QuantumSsh)) {
        throw "Finalize refused: the new access did not pass its test. Nothing was changed."
    }
    $keyPath = Get-QsshKeyPath $Label
    $ssh = Get-QsshTool 'ssh'
    & $ssh -o BatchMode=yes -i $keyPath -p $Port "$User@$HostName" "sudo /usr/local/sbin/quantum-ssh-finalize --yes"
    if ($LASTEXITCODE -ne 0) { throw "Server-side finalize failed; the old access is still available." }
}

function Show-QuantumSshCommand {
    $keyPath = Get-QsshKeyPath $Label
    Assert-QsshKey $keyPath
    if (-not $HostName -or -not $User) { throw "-HostName and -User are required." }
    Write-Host ""
    Write-Host ("ssh -i {0} -p {1} {2}@{3}" -f $keyPath, $Port, $User, $HostName) -ForegroundColor Cyan
    Write-Host ""
}

switch ($Command) {
    'New-QuantumSshKey'        { New-QuantumSshKey }
    'Add-QuantumSshKey'        { Add-QuantumSshKey }
    'Test-QuantumSsh'          { Test-QuantumSsh | Out-Null }
    'Complete-QuantumSsh'      { Complete-QuantumSsh }
    'Show-QuantumSshCommand'   { Show-QuantumSshCommand }
    'Repair-QuantumSshClient'  { Repair-QuantumSshClient }
    default {
        Get-Help $MyInvocation.MyCommand.ScriptBlock.File -Detailed 2>$null
        Write-Host "Usage examples are listed in the comment-based help above."
    }
}
