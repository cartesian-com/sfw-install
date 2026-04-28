# Downloads and installs Socket Firewall (sfw) for Windows AVD / multi-user hosts.
#
# This installer is machine-scoped and uses PATH wrappers only:
#   - installs sfw.exe under Program Files
#   - writes package-manager wrappers under Program Files
#   - prepends the wrapper and sfw directories to the machine PATH
#
# The wrappers locate the real package-manager command at runtime, skip the
# wrapper itself, and pass the real command's absolute path to sfw.
#
# Run from an elevated PowerShell session.
# Usage: iex (iwr https://raw.githubusercontent.com/.../install-sfw-avd.ps1 -UseBasicParsing)

$ErrorActionPreference = "Stop"

$Version = $env:SFW_VERSION  # Will be fetched from latest release if not set.
$NativeProgramFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallRoot = Join-Path $NativeProgramFiles "Socket Firewall"
$BinDir = Join-Path $InstallRoot "bin"
$ShimDir = Join-Path $InstallRoot "shims"
$SfwPath = Join-Path $BinDir "sfw.exe"
$LegacyCmdShim = Join-Path $BinDir "sfw-shims.cmd"
$RepoUrl = "https://github.com/SocketDev/sfw-free"
$ApiUrl = "https://api.github.com/repos/SocketDev/sfw-free/releases/latest"
$Managers = @("npm", "yarn", "pnpm", "pip", "uv", "cargo")

# Ensure TLS 1.2 is enabled for downloads.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
        Write-Error-Custom "This AVD installer supports Windows only."
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($adminRole)) {
        Write-Error-Custom "This AVD installer must be run from an elevated PowerShell session."
    }
}

function Get-ProcessorArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) {
        return $env:PROCESSOR_ARCHITEW6432
    }

    return $env:PROCESSOR_ARCHITECTURE
}

function Get-Architecture {
    $arch = Get-ProcessorArchitecture
    switch ($arch) {
        "AMD64" { return "x86_64" }
        "ARM64" {
            Write-Warn "No prebuilt sfw Windows ARM64 binary is published; falling back to x86_64 (runs under x64 emulation)."
            return "x86_64"
        }
        default { Write-Error-Custom "Unsupported architecture: $arch" }
    }
}

function Get-LatestVersion {
    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $latestVersion = $response.tag_name

        if ([string]::IsNullOrWhiteSpace($latestVersion)) {
            Write-Error-Custom "Failed to fetch latest version from GitHub API. Please set SFW_VERSION environment variable."
        }

        return $latestVersion
    }
    catch {
        Write-Error-Custom "Failed to fetch latest version from GitHub API: $($_.Exception.Message). Please set SFW_VERSION environment variable."
    }
}

function Get-InstalledVersion {
    if (-not (Test-Path $SfwPath)) {
        return $null
    }

    try {
        $output = & $SfwPath --version 2>&1 | Out-String

        if ($output -match "(\d+\.\d+\.\d+)") {
            return $matches[1].Trim()
        }

        return $null
    }
    catch {
        return $null
    }
}

function Test-VersionInstalled {
    param([string]$RequestedVersion)

    $installedVersion = Get-InstalledVersion

    if ([string]::IsNullOrWhiteSpace($installedVersion)) {
        return $false
    }

    $requestedClean = $RequestedVersion -replace '^v', ''
    $installedClean = $installedVersion -replace '^v', ''

    return $requestedClean -eq $installedClean
}

function New-InstallDirectories {
    foreach ($dir in @($BinDir, $ShimDir)) {
        if (-not (Test-Path $dir)) {
            Write-Info "Creating directory: $dir"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Normalize-PathEntry {
    param([string]$PathEntry)

    return $PathEntry.Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
}

function Get-PathWithSfwFirst {
    param([string]$PathValue)

    if (-not $PathValue) { $PathValue = "" }

    $preferred = @($ShimDir, $BinDir)
    $preferredKeys = @{}
    foreach ($path in $preferred) {
        $preferredKeys[(Normalize-PathEntry $path)] = $true
    }

    $existing = $PathValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    $filtered = foreach ($entry in $existing) {
        $key = Normalize-PathEntry $entry
        if (-not $preferredKeys.ContainsKey($key)) {
            $entry
        }
    }

    $newParts = @($ShimDir, $BinDir) + @($filtered)
    return ($newParts -join ';')
}

function Set-MachinePathForSfw {
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $newPath = Get-PathWithSfwFirst $current

    if ($newPath -ne $current) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Info "Prepended sfw shim and binary directories to machine PATH"
    }
    else {
        Write-Info "sfw shim and binary directories are already first on machine PATH"
    }

    $env:Path = Get-PathWithSfwFirst $env:Path
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

function Remove-LegacyAvdShims {
    try {
        Remove-LegacyPowerShellProfileShims
        Remove-LegacyCmdShims

        if (Test-Path $LegacyCmdShim) {
            Remove-Item -Path $LegacyCmdShim -Force
            Write-Info "Removed legacy cmd.exe shim script: $LegacyCmdShim"
        }
    }
    catch {
        Write-Warn "Legacy AVD shim cleanup encountered issues: $_"
        Write-Warn "Continuing with PATH-wrapper installation."
    }
}

function Install-SfwBinary {
    if (-not [string]::IsNullOrWhiteSpace($env:SFW_VERSION)) {
        Write-Warn "SFW_VERSION environment variable is set: $env:SFW_VERSION"
        Write-Warn "Pinning to that version. Unset SFW_VERSION to always install the latest."
    }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Info "Fetching latest release version..."
        $Version = Get-LatestVersion
    }

    if (Test-VersionInstalled -RequestedVersion $Version) {
        Write-Info "sfw $Version is already installed at $SfwPath"
        return
    }

    $arch = Get-Architecture
    $binaryName = "sfw-free-windows-$arch.exe"
    $downloadUrl = "$RepoUrl/releases/download/$Version/$binaryName"
    $tempFile = Join-Path $BinDir "$binaryName.download"

    Write-Info "Installing sfw $Version for all users"
    Write-Info "Detected architecture: $(Get-ProcessorArchitecture) -> $arch"
    Write-Info "Downloading from: $downloadUrl"

    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing
    }
    catch {
        Write-Error-Custom "Failed to download from $downloadUrl : $_"
    }
    finally {
        $ProgressPreference = $oldProgressPreference
    }

    try {
        [System.IO.File]::Copy($tempFile, $SfwPath, $true)
        Remove-Item -Path $tempFile -Force
        Write-Info "Binary installed to: $SfwPath"
    }
    catch {
        Write-Error-Custom "Failed to install binary to $SfwPath : $_"
    }
}

function New-WrapperContent {
    param([string]$Manager)

    $template = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SFW_EXE=__SFW_EXE__"
set "SHIM_DIR=__SHIM_DIR__"
set "TARGET_NAME=__TARGET_NAME__"
set "SELF=%~f0"
set "SELF_SHORT=%~fs0"
set "TARGET_EXE="
set "FALLBACK_EXE="

if not exist "%SFW_EXE%" (
    echo [ERROR] Socket Firewall executable not found: %SFW_EXE% 1>&2
    exit /b 1
)

if "%SFW_SHIM_DEBUG%"=="1" (
    echo [DEBUG] PATH=%PATH% 1>&2
    echo [DEBUG] where %TARGET_NAME%: 1>&2
    "%SystemRoot%\System32\where.exe" "%TARGET_NAME%" 1>&2
)

for /f "usebackq delims=" %%I in (`"%SystemRoot%\System32\where.exe" "%TARGET_NAME%" 2^>nul`) do (
    set "CANDIDATE=%%~fI"
    set "CANDIDATE_SHORT=%%~fsI"
    set "CANDIDATE_DIR=%%~dpI"
    set "CANDIDATE_EXT=%%~xI"
    if /I not "!CANDIDATE_DIR!"=="!SHIM_DIR!\" if /I not "!CANDIDATE!"=="!SELF!" if /I not "!CANDIDATE_SHORT!"=="!SELF_SHORT!" (
        if /I "!CANDIDATE_EXT!"==".exe" (
            set "TARGET_EXE=!CANDIDATE!"
            goto :found
        )
        if /I "!CANDIDATE_EXT!"==".cmd" (
            set "TARGET_EXE=!CANDIDATE!"
            goto :found
        )
        if /I "!CANDIDATE_EXT!"==".bat" (
            set "TARGET_EXE=!CANDIDATE!"
            goto :found
        )
        if /I "!CANDIDATE_EXT!"==".com" (
            set "TARGET_EXE=!CANDIDATE!"
            goto :found
        )
        if not defined FALLBACK_EXE set "FALLBACK_EXE=!CANDIDATE!"
    )
)

if defined FALLBACK_EXE (
    set "TARGET_EXE=%FALLBACK_EXE%"
    goto :found
)

echo [ERROR] Could not find the real %TARGET_NAME% command on PATH after the Socket Firewall shim. 1>&2
echo [ERROR] Expected another %TARGET_NAME% executable, .cmd, .bat, or .com outside %SHIM_DIR%. 1>&2
echo [ERROR] Set SFW_SHIM_DEBUG=1 and run %TARGET_NAME% again to print PATH and where.exe output. 1>&2
exit /b 9009

:found
if "%SFW_SHIM_DEBUG%"=="1" echo [DEBUG] selected %TARGET_EXE% 1>&2
"%SFW_EXE%" "%TARGET_EXE%" %*
exit /b %ERRORLEVEL%
'@

    return $template.Replace('__SFW_EXE__', $SfwPath).Replace('__SHIM_DIR__', $ShimDir).Replace('__TARGET_NAME__', $Manager)
}

function Install-PathWrappers {
    foreach ($manager in $Managers) {
        $wrapperPath = Join-Path $ShimDir "$manager.cmd"
        Set-Content -Path $wrapperPath -Value (New-WrapperContent -Manager $manager) -Encoding Ascii
        Write-Info "Wrote PATH wrapper: $wrapperPath"
    }
}

function Install-SfwAvd {
    Assert-Windows
    Assert-Administrator
    New-InstallDirectories
    Install-SfwBinary
    Install-PathWrappers
    Set-MachinePathForSfw
    Remove-LegacyAvdShims

    Write-Info "AVD installation complete."
    Write-Info "Open a new user session or terminal, then smoke test: 'sfw --version' and 'npm --version'."
}

try {
    Install-SfwAvd
}
catch {
    Write-Error-Custom "AVD installation failed: $_"
}
