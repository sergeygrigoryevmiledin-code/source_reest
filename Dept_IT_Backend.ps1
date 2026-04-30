param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [string]$ProductName = "ESET Management Agent",
    [string]$BasePath = "HKLM\SOFTWARE\Classes\Installer\Products",
    [string]$CredentialUser = "",
    [string]$CredentialPassword = "",
    [string]$CredentialDomain = ""
)

function Parse-IPv4 {
    param([string]$IP)
    $parts = $IP.Split(".")
    if ($parts.Count -ne 4) { return $null }
    try {
        $bytes = [int[]]($parts | ForEach-Object { [int]$_ })
        foreach ($b in $bytes) {
            if ($b -lt 0 -or $b -gt 255) { return $null }
        }
        return $bytes
    } catch {
        return $null
    }
}

function IPv4-ToInt {
    param([string]$IP)
    $o = Parse-IPv4 $IP
    if (-not $o) { return -1L }
    return [int64](($o[0] * 16777216) + ($o[1] * 65536) + ($o[2] * 256) + $o[3])
}

function Int-ToIPv4 {
    param([int64]$n)
    return "{0}.{1}.{2}.{3}" -f (
        [math]::Floor($n / 16777216),
        [math]::Floor(($n % 16777216) / 65536),
        [math]::Floor(($n % 65536) / 256),
        ($n % 256)
    )
}

function Resolve-Targets {
    param([string]$InputTarget)
    $list = @()

    if ($InputTarget -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
        $ip = $Matches[1]
        $cidr = [int]$Matches[2]
        if ($cidr -lt 0 -or $cidr -gt 32) {
            Write-Host "[ERROR] Invalid CIDR: /$cidr"
            return @()
        }

        $ipInt = IPv4-ToInt $ip
        if ($ipInt -lt 0) {
            Write-Host "[ERROR] Invalid network IP: $ip"
            return @()
        }

        $mask = [uint32](([math]::Pow(2, 32) - [math]::Pow(2, 32 - $cidr)))
        $network = [uint32]$ipInt -band $mask
        $broadcast = [uint32]$network + [uint32]([math]::Pow(2, 32 - $cidr) - 1)

        if ($broadcast -le ($network + 1)) {
            Write-Host "[INFO] CIDR has no host range: $InputTarget"
            return @()
        }

        for ($i = [int64]$network + 1; $i -lt [int64]$broadcast; $i++) {
            $list += Int-ToIPv4 $i
        }
        Write-Host "[INFO] CIDR $InputTarget -> hosts: $($list.Count)"
        return $list
    }

    if ($InputTarget -match '^(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)$') {
        $start = IPv4-ToInt $Matches[1]
        $finish = IPv4-ToInt $Matches[2]
        if ($start -lt 0 -or $finish -lt 0) {
            Write-Host "[ERROR] Invalid range format: $InputTarget"
            return @()
        }
        if ($start -gt $finish) {
            Write-Host "[ERROR] Range start is greater than end."
            return @()
        }
        for ($i = $start; $i -le $finish; $i++) {
            $list += Int-ToIPv4 $i
        }
        Write-Host "[INFO] Range $InputTarget -> hosts: $($list.Count)"
        return $list
    }

    if (Parse-IPv4 $InputTarget) {
        Write-Host "[INFO] Single host: $InputTarget"
        return @($InputTarget)
    }

    Write-Host "[ERROR] Invalid target format: $InputTarget"
    return @()
}

function Get-RemoteSubKeys {
    param(
        [string]$ComputerIP,
        [string]$Path
    )
    $queryPath = "\\$ComputerIP\$Path"
    $raw = reg query $queryPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[QUERY_ERROR] $ComputerIP -> $Path"
        return @()
    }

    $keys = @()
    foreach ($line in $raw) {
        $v = ($line | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        # reg query может вернуть путь как с \\HOST\..., так и просто HKLM\.../HKEY_LOCAL_MACHINE\...
        if ($v -like "\\$ComputerIP\*") {
            $sub = $v.Substring(("\\$ComputerIP\").Length)
            $keys += $sub
            continue
        }
        if ($v -match '^(HKLM|HKEY_LOCAL_MACHINE)\\') {
            $keys += $v
            continue
        }
    }
    return $keys
}

function Try-DeleteProductEntries {
    param(
        [string]$ComputerIP,
        [string]$Path,
        [string]$NameToFind
    )
    $deleted = @()
    $matchedCount = 0
    $keys = Get-RemoteSubKeys -ComputerIP $ComputerIP -Path $Path
    foreach ($k in $keys) {
        $q = reg query "\\$ComputerIP\$k" /v ProductName 2>&1
        if ($LASTEXITCODE -ne 0) { continue }

        $matched = $false
        foreach ($line in $q) {
            if ($line -match 'ProductName\s+REG_SZ\s+(.+)$') {
                $product = $Matches[1].Trim()
                if ($product -eq $NameToFind) {
                    $matched = $true
                }
            }
        }
        if (-not $matched) { continue }
        $matchedCount++

        Write-Host "[FOUND] $ComputerIP -> $k"
        $null = reg delete "\\$ComputerIP\$k" /f 2>&1
        Start-Sleep -Milliseconds 300
        $chk = reg query "\\$ComputerIP\$k" 2>&1
        if ($LASTEXITCODE -ne 0 -or ($chk -join "`n") -match "ERROR") {
            Write-Host "[DELETED] $ComputerIP -> $k"
            $deleted += $k
        } else {
            Write-Host "[WARN] Could not delete key: $k"
        }
    }
    return @{
        Deleted = $deleted
        Matched = $matchedCount
    }
}

function Exists-ProductEntry {
    param(
        [string]$ComputerIP,
        [string]$Path,
        [string]$NameToFind
    )
    $keys = Get-RemoteSubKeys -ComputerIP $ComputerIP -Path $Path
    foreach ($k in $keys) {
        $q = reg query "\\$ComputerIP\$k" /v ProductName 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($line in $q) {
            if ($line -match 'ProductName\s+REG_SZ\s+(.+)$') {
                if ($Matches[1].Trim() -eq $NameToFind) {
                    return $k
                }
            }
        }
    }
    return $null
}

function Test-HostAliveFast {
    param([string]$ComputerIP)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $reply = $p.Send($ComputerIP, 900)
        return ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    }
}

function Resolve-FullUsername {
    param(
        [string]$User,
        [string]$Domain
    )
    if ([string]::IsNullOrWhiteSpace($User)) { return "" }
    if ([string]::IsNullOrWhiteSpace($Domain)) { return $User }
    return "$Domain\$User"
}

function Connect-RemoteIPC {
    param(
        [string]$ComputerIP,
        [string]$User,
        [string]$Password,
        [string]$Domain
    )
    if ([string]::IsNullOrWhiteSpace($User)) { return $true }

    $fullUser = Resolve-FullUsername -User $User -Domain $Domain
    $target = "\\$ComputerIP\IPC$"
    $null = & net.exe use $target /delete /y 2>&1
    $null = & net.exe use $target $Password /user:$fullUser 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Disconnect-RemoteIPC {
    param([string]$ComputerIP)
    $target = "\\$ComputerIP\IPC$"
    $null = & net.exe use $target /delete /y 2>&1
}

function Normalize-RegistryPath {
    param([string]$Path)
    $p = $Path.Trim()
    $p = $p -replace '/', '\'
    while ($p.StartsWith("\")) { $p = $p.Substring(1) }
    # если ввели полный hive, оставляем как есть; если нет HKLM-префикса — добавим
    if ($p -notmatch '^(HKLM|HKEY_LOCAL_MACHINE)\\') {
        $p = "HKLM\$p"
    }
    return $p
}

Write-Host "============================================================"
Write-Host " Dept_IT backend started"
Write-Host " Target     : $Target"
$BasePath = Normalize-RegistryPath -Path $BasePath
Write-Host " BasePath   : $BasePath"
Write-Host " ProductName: $ProductName"
Write-Host "============================================================"

$hosts = Resolve-Targets -InputTarget $Target
if ($hosts.Count -eq 0) {
    Write-Host "[ERROR] No valid hosts resolved."
    exit 1
}

$finalRemains = 0
$foundAnyTotal = 0

foreach ($pass in 1, 2) {
    Write-Host ""
    Write-Host "---------------- PASS $pass ----------------"
    $foundThisPass = 0
    foreach ($h in $hosts) {
        if (-not (Test-HostAliveFast -ComputerIP $h)) {
            Write-Host "[UNREACHABLE] $h"
            continue
        }
        $connected = Connect-RemoteIPC -ComputerIP $h -User $CredentialUser -Password $CredentialPassword -Domain $CredentialDomain
        if (-not $connected) {
            Write-Host "[AUTH_ERROR] $h"
            continue
        }
        try {
            $result = Try-DeleteProductEntries -ComputerIP $h -Path $BasePath -NameToFind $ProductName
            $foundThisPass += [int]$result.Matched
            if ($result.Matched -eq 0) {
                Write-Host "[NOT_FOUND] $h"
            }
        } finally {
            Disconnect-RemoteIPC -ComputerIP $h
        }
    }
    $foundAnyTotal += $foundThisPass

    if ($foundThisPass -eq 0) {
        Write-Host ""
        Write-Host "[NOT_FOUND] No matching keys found on pass $pass. Stopping."
        exit 0
    }

    if ($pass -eq 1) { Start-Sleep -Seconds 2 }
}

Write-Host ""
Write-Host "---------------- FINAL CHECK ----------------"
foreach ($h in $hosts) {
    if (-not (Test-HostAliveFast -ComputerIP $h)) {
        Write-Host "[UNREACHABLE] $h"
        continue
    }
    $connected = Connect-RemoteIPC -ComputerIP $h -User $CredentialUser -Password $CredentialPassword -Domain $CredentialDomain
    if (-not $connected) {
        Write-Host "[AUTH_ERROR] $h"
        continue
    }
    try {
        $left = Exists-ProductEntry -ComputerIP $h -Path $BasePath -NameToFind $ProductName
        if ($left) {
            Write-Host "[REMAIN] $h -> $left"
            $finalRemains++
        } else {
            Write-Host "[OK] $h"
        }
    } finally {
        Disconnect-RemoteIPC -ComputerIP $h
    }
}

Write-Host ""
Write-Host "Done. Remaining hosts with entry: $finalRemains"
if ($finalRemains -gt 0) { exit 1 } else { exit 0 }
