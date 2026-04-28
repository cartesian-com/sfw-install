# Uninstalls Socket Firewall (sfw) from Windows AVD / multi-user hosts.
#
# Removes the machine-scoped install created by install-sfw-avd.ps1:
#   - removes sfw shim and binary directories from the machine PATH
#   - deletes the Program Files install directory
#
# It also removes legacy all-users PowerShell and HKLM cmd.exe AutoRun shims
# created by earlier AVD installer drafts.
#
# Run from an elevated PowerShell session.

$ErrorActionPreference = "Stop"

$NativeProgramFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallRoot = Join-Path $NativeProgramFiles "Socket Firewall"
$BinDir = Join-Path $InstallRoot "bin"
$ShimDir = Join-Path $InstallRoot "shims"
$LegacyCmdShim = Join-Path $BinDir "sfw-shims.cmd"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Assert-Windows {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        Write-Error-Custom "This AVD uninstaller supports Windows only."
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($adminRole)) {
        Write-Error-Custom "This AVD uninstaller must be run from an elevated PowerShell session."
    }
}

function Normalize-PathEntry {
    param([string]$PathEntry)

    return $PathEntry.Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
}

function Remove-FromMachinePath {
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not $current) {
        Write-Info "Machine PATH is empty; nothing to remove."
        return
    }

    $remove = @($ShimDir, $BinDir)
    $removeKeys = @{}
    foreach ($path in $remove) {
        $removeKeys[(Normalize-PathEntry $path)] = $true
    }

    $existing = $current.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    $filtered = foreach ($entry in $existing) {
        $key = Normalize-PathEntry $entry
        if (-not $removeKeys.ContainsKey($key)) {
            $entry
        }
    }

    $newPath = @($filtered) -join ';'
    if ($newPath -ne $current) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        $env:Path = $newPath
        Write-Info "Removed sfw shim and binary directories from machine PATH"
    }
    else {
        Write-Info "sfw shim and binary directories were not present in machine PATH"
    }
}

function Get-LegacyAllUsersPowerShellProfilePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    if ($PROFILE.AllUsersAllHosts) {
        $paths.Add($PROFILE.AllUsersAllHosts)
    }

    $nativeWindowsPowerShellRoot = if (Test-Path (Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0")) {
        Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0"
    }
    else {
        Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0"
    }

    $knownProfileRoots = @(
        $nativeWindowsPowerShellRoot,
        (Join-Path $env:WINDIR "SysWOW64\WindowsPowerShell\v1.0"),
        (Join-Path $NativeProgramFiles "PowerShell\7")
    )

    foreach ($root in $knownProfileRoots) {
        $paths.Add((Join-Path $root "profile.ps1"))
    }

    $seen = @{}
    foreach ($path in $paths) {
        $key = $path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $path
        }
    }
}

function Remove-LegacyPowerShellProfileShims {
    $marker = "# >>> socket sfw avd shims >>>"
    $endMarker = "# <<< socket sfw avd shims <<<"

    foreach ($profilePath in Get-LegacyAllUsersPowerShellProfilePaths) {
        if (-not (Test-Path $profilePath)) {
            continue
        }

        $existing = Get-Content $profilePath -Raw
        if ($existing -notmatch [regex]::Escape($marker)) {
            continue
        }

        $pattern = "(?s)\r?\n?\s*" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMarker) + "\s*\r?\n?"
        $updated = [regex]::Replace($existing, $pattern, "`r`n").TrimEnd() + "`r`n"

        if ([string]::IsNullOrWhiteSpace($updated)) {
            Remove-Item -Path $profilePath -Force
            Write-Info "Removed now-empty legacy all-users PowerShell profile: $profilePath"
        }
        else {
            Set-Content -Path $profilePath -Value $updated -Encoding UTF8 -NoNewline
            Write-Info "Removed legacy sfw block from all-users PowerShell profile: $profilePath"
        }
    }
}

function Remove-LegacyCommandProcessorAutoRun {
    param([Microsoft.Win32.RegistryView]$RegistryView)

    $autoRunName = "AutoRun"
    $baseKey = $null
    $key = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $RegistryView
        )
        $key = $baseKey.OpenSubKey("Software\Microsoft\Command Processor", $true)
        if (-not $key) {
            return
        }

        $currentAutoRun = [string]$key.GetValue(
            $autoRunName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        if (-not $currentAutoRun) {
            return
        }

        $escaped = [regex]::Escape($LegacyCmdShim)
        $pattern = "(?i)\s*&?\s*CALL\s+`"$escaped`"\s*&?"
        $newValue = [regex]::Replace($currentAutoRun, $pattern, "").Trim().Trim('&').Trim()

        if ($newValue -eq $currentAutoRun) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($newValue)) {
            $key.DeleteValue($autoRunName, $false)
            Write-Info "Removed legacy sfw entry from machine cmd.exe AutoRun ($RegistryView)"
        }
        else {
            $key.SetValue($autoRunName, $newValue, [Microsoft.Win32.RegistryValueKind]::String)
            Write-Info "Removed legacy sfw entry from machine cmd.exe AutoRun ($RegistryView)"
        }
    }
    finally {
        if ($key) { $key.Close() }
        if ($baseKey) { $baseKey.Close() }
    }
}

function Remove-LegacyCmdShims {
    if ([Environment]::Is64BitOperatingSystem) {
        Remove-LegacyCommandProcessorAutoRun -RegistryView Registry64
        Remove-LegacyCommandProcessorAutoRun -RegistryView Registry32
    }
    else {
        Remove-LegacyCommandProcessorAutoRun -RegistryView Registry32
    }
}

function Remove-InstallDirectory {
    if (-not (Test-Path $InstallRoot)) {
        Write-Info "Installation directory does not exist: $InstallRoot"
        return
    }

    $programFilesFull = [System.IO.Path]::GetFullPath($NativeProgramFiles).TrimEnd('\')
    $installRootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedRoot = Join-Path $programFilesFull "Socket Firewall"

    if ($installRootFull -ne $expectedRoot) {
        Write-Error-Custom "Refusing to remove unexpected install path: $installRootFull"
    }

    Remove-Item -Path $InstallRoot -Recurse -Force
    Write-Info "Removed installation directory: $InstallRoot"
}

function Uninstall-SfwAvd {
    Assert-Windows
    Assert-Administrator

    Remove-FromMachinePath

    try {
        Remove-LegacyPowerShellProfileShims
        Remove-LegacyCmdShims
    }
    catch {
        Write-Warn "Legacy shim cleanup encountered issues: $_"
        Write-Warn "Continuing with PATH-wrapper uninstallation."
    }

    Remove-InstallDirectory
    Write-Info "AVD uninstallation complete."
}

try {
    Uninstall-SfwAvd
}
catch {
    Write-Error-Custom "AVD uninstallation failed: $_"
}
