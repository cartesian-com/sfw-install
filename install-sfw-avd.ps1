# Downloads and installs Socket Firewall (sfw) for Windows AVD / multi-user hosts.
#
# This installer is machine-scoped:
#   - installs sfw.exe under Program Files
#   - adds sfw.exe's directory to the machine PATH
#   - installs PowerShell shims in all-users profiles
#   - registers cmd.exe doskey shims through HKLM Command Processor AutoRun
#
# Run from an elevated PowerShell session.
# Usage: iex (iwr https://raw.githubusercontent.com/.../install-sfw-avd.ps1 -UseBasicParsing)

$ErrorActionPreference = "Stop"

$Version = $env:SFW_VERSION  # Will be fetched from latest release if not set.
$NativeProgramFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallRoot = Join-Path $NativeProgramFiles "Socket Firewall"
$BinDir = Join-Path $InstallRoot "bin"
$LegacyShimDir = Join-Path $InstallRoot "shims"
$SfwPath = Join-Path $BinDir "sfw.exe"
$CmdShimPath = Join-Path $BinDir "sfw-shims.cmd"
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

function Get-PathWithBinFirst {
    param([string]$PathValue)

    $withoutSfw = Get-PathWithoutEntries -PathValue $PathValue -Dirs @($BinDir, $LegacyShimDir)
    $parts = @($BinDir)
    if (-not [string]::IsNullOrWhiteSpace($withoutSfw)) {
        $parts += $withoutSfw.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    }

    return ($parts -join ';')
}

function Set-MachinePathForSfw {
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $newPath = Get-PathWithBinFirst $current

    if ($newPath -ne $current) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Info "Added $BinDir to machine PATH and removed legacy wrapper PATH entries"
    }
    else {
        Write-Info "$BinDir is already first on machine PATH"
    }

    $env:Path = Get-PathWithBinFirst $env:Path
}

function Remove-LegacyPathWrappers {
    if (Test-Path $LegacyShimDir) {
        Remove-Item -Path $LegacyShimDir -Recurse -Force
        Write-Info "Removed legacy PATH wrapper directory: $LegacyShimDir"
    }
}

function New-InstallDirectory {
    if (-not (Test-Path $BinDir)) {
        Write-Info "Creating installation directory: $BinDir"
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
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
        if (Test-Path $root) {
            $paths.Add((Join-Path $root "profile.ps1"))
        }
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

function Install-AllUsersPowerShellShims {
    $marker = "# >>> socket sfw avd shims >>>"
    $endMarker = "# <<< socket sfw avd shims <<<"
    $funcLines = foreach ($manager in $Managers) {
        "function $manager { & '$SfwPath' $manager @args }"
    }
    $block = @"
$marker
# Routes package manager commands through Socket Firewall (sfw).
# Managed by install-sfw-avd.ps1. To disable, delete this block.
$($funcLines -join "`n")
$endMarker
"@

    foreach ($profilePath in Get-AllUsersPowerShellProfilePaths) {
        $profileDir = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }

        $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { "" }
        if ($existing -match [regex]::Escape($marker)) {
            $pattern = "(?s)" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMarker)
            $updated = [regex]::Replace($existing, $pattern, $block)
            Set-Content -Path $profilePath -Value $updated -Encoding UTF8
            Write-Info "Updated sfw shims in all-users PowerShell profile: $profilePath"
        }
        else {
            Add-Content -Path $profilePath -Value "`r`n$block`r`n"
            Write-Info "Added sfw shims to all-users PowerShell profile: $profilePath"
        }
    }
}

function Install-CmdShimScript {
    $doskeyLines = @("@echo off")
    foreach ($manager in $Managers) {
        $doskeyLines += "doskey $manager=`"$SfwPath`" $manager `$*"
    }

    Set-Content -Path $CmdShimPath -Value ($doskeyLines -join "`r`n") -Encoding Ascii
    Write-Info "Wrote cmd.exe shim script: $CmdShimPath"
}

function Set-CommandProcessorAutoRun {
    param([Microsoft.Win32.RegistryView]$RegistryView)

    $autoRunName = "AutoRun"
    $baseKey = $null
    $key = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $RegistryView
        )
        $key = $baseKey.CreateSubKey("Software\Microsoft\Command Processor")
        $currentAutoRun = [string]$key.GetValue(
            $autoRunName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )

        $callLine = "CALL `"$CmdShimPath`""
        if ($currentAutoRun) {
            if ($currentAutoRun -notmatch [regex]::Escape($CmdShimPath)) {
                $key.SetValue($autoRunName, "$currentAutoRun & $callLine", [Microsoft.Win32.RegistryValueKind]::String)
                Write-Info "Appended sfw doskey macros to machine cmd.exe AutoRun ($RegistryView)"
            }
            else {
                Write-Info "Machine cmd.exe AutoRun already registers sfw doskey macros ($RegistryView)"
            }
        }
        else {
            $key.SetValue($autoRunName, $callLine, [Microsoft.Win32.RegistryValueKind]::String)
            Write-Info "Registered sfw doskey macros for machine cmd.exe AutoRun ($RegistryView)"
        }
    }
    finally {
        if ($key) { $key.Close() }
        if ($baseKey) { $baseKey.Close() }
    }
}

function Install-MachineCmdShims {
    Install-CmdShimScript

    if ([Environment]::Is64BitOperatingSystem) {
        Set-CommandProcessorAutoRun -RegistryView Registry64
        Set-CommandProcessorAutoRun -RegistryView Registry32
    }
    else {
        Set-CommandProcessorAutoRun -RegistryView Registry32
    }
}

function Install-SfwAvd {
    Assert-Windows
    Assert-Administrator
    New-InstallDirectory
    Install-SfwBinary
    Set-MachinePathForSfw
    Remove-LegacyPathWrappers
    Install-AllUsersPowerShellShims
    Install-MachineCmdShims

    Write-Info "AVD installation complete. Open a new PowerShell or cmd session to use the shims."
    Write-Info "Smoke test in a new user session: 'sfw --version', 'npm --version', and 'pip --version'."
}

try {
    Install-SfwAvd
}
catch {
    Write-Error-Custom "AVD installation failed: $_"
}
