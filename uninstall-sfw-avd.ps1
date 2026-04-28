# Uninstalls Socket Firewall (sfw) from Windows AVD / multi-user hosts.
#
# Removes the machine-scoped install created by install-sfw-avd.ps1:
#   - removes sfw directories from the machine PATH
#   - removes all-users PowerShell profile shims
#   - removes HKLM cmd.exe AutoRun shims
#   - deletes the Program Files install directory
#
# Run from an elevated PowerShell session.

$ErrorActionPreference = "Stop"

$NativeProgramFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallRoot = Join-Path $NativeProgramFiles "Socket Firewall"
$BinDir = Join-Path $InstallRoot "bin"
$LegacyShimDir = Join-Path $InstallRoot "shims"
$CmdShimPath = Join-Path $BinDir "sfw-shims.cmd"

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

function Get-PathWithoutEntries {
    param(
        [string]$PathValue,
        [string[]]$Dirs
    )

    if (-not $PathValue) { return "" }

    $removeKeys = @{}
    foreach ($dir in $Dirs) {
        $removeKeys[(Normalize-PathEntry $dir)] = $true
    }

    $existing = $PathValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    $filtered = foreach ($entry in $existing) {
        $key = Normalize-PathEntry $entry
        if (-not $removeKeys.ContainsKey($key)) {
            $entry
        }
    }

    return (@($filtered) -join ';')
}

function Remove-FromMachinePath {
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not $current) {
        Write-Info "Machine PATH is empty; nothing to remove."
        return
    }

    $newPath = Get-PathWithoutEntries -PathValue $current -Dirs @($BinDir, $LegacyShimDir)
    if ($newPath -ne $current) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        $env:Path = Get-PathWithoutEntries -PathValue $env:Path -Dirs @($BinDir, $LegacyShimDir)
        Write-Info "Removed sfw directories from machine PATH"
    }
    else {
        Write-Info "sfw directories were not present in machine PATH"
    }
}

function Get-AllUsersPowerShellProfilePaths {
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

function Remove-PowerShellProfileShims {
    $marker = "# >>> socket sfw avd shims >>>"
    $endMarker = "# <<< socket sfw avd shims <<<"

    foreach ($profilePath in Get-AllUsersPowerShellProfilePaths) {
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
            Write-Info "Removed now-empty all-users PowerShell profile: $profilePath"
        }
        else {
            Set-Content -Path $profilePath -Value $updated -Encoding UTF8 -NoNewline
            Write-Info "Removed sfw block from all-users PowerShell profile: $profilePath"
        }
    }
}

function Remove-CommandProcessorAutoRun {
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

        $escaped = [regex]::Escape($CmdShimPath)
        $pattern = "(?i)\s*&?\s*CALL\s+`"$escaped`"\s*&?"
        $newValue = [regex]::Replace($currentAutoRun, $pattern, "").Trim().Trim('&').Trim()

        if ($newValue -eq $currentAutoRun) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($newValue)) {
            $key.DeleteValue($autoRunName, $false)
            Write-Info "Removed sfw entry from machine cmd.exe AutoRun ($RegistryView)"
        }
        else {
            $key.SetValue($autoRunName, $newValue, [Microsoft.Win32.RegistryValueKind]::String)
            Write-Info "Removed sfw entry from machine cmd.exe AutoRun ($RegistryView)"
        }
    }
    finally {
        if ($key) { $key.Close() }
        if ($baseKey) { $baseKey.Close() }
    }
}

function Remove-CmdShims {
    if ([Environment]::Is64BitOperatingSystem) {
        Remove-CommandProcessorAutoRun -RegistryView Registry64
        Remove-CommandProcessorAutoRun -RegistryView Registry32
    }
    else {
        Remove-CommandProcessorAutoRun -RegistryView Registry32
    }
}

function Remove-InstallDirectory {
    if (-not (Test-Path $InstallRoot)) {
        Write-Info "Installation directory does not exist: $InstallRoot"
        return
    }

    $programFilesFull = [System.IO.Path]::GetFullPath($NativeProgramFiles).TrimEnd('\')
    $installRootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedRoot = (Join-Path $programFilesFull "Socket Firewall").TrimEnd('\')

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
    Remove-PowerShellProfileShims
    Remove-CmdShims
    Remove-InstallDirectory

    Write-Info "AVD uninstallation complete."
}

try {
    Uninstall-SfwAvd
}
catch {
    Write-Error-Custom "AVD uninstallation failed: $_"
}
