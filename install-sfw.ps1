# Downloads and installs Socket Firewall (sfw) for Windows.
#
# detect arch -> remove existing npm/Volta installs -> download prebuilt binary ->
# run post-install "setup". sfw has no `sfw setup` equivalent, so this script
# creates the shell integration itself (PowerShell profile + cmd.exe doskey).
#
# Usage: iex (iwr https://raw.githubusercontent.com/.../install-sfw.ps1 -UseBasicParsing)

param(
    [switch]$ci
)

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force


$Version = $env:SFW_VERSION  # Will be fetched from latest release if not set
$InstallDir = Join-Path $env:USERPROFILE ".sfw\bin"
$RepoUrl = "https://github.com/SocketDev/sfw-free"
$ApiUrl = "https://api.github.com/repos/SocketDev/sfw-free/releases/latest"

# Ensure TLS 1.2 is enabled for downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Helper functions
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

# Get currently installed version of the sfw binary managed by this installer.
# Deliberately checks $InstallDir\sfw.exe rather than `Get-Command sfw` so an
# unrelated sfw on PATH (e.g. the npm-installed wrapper) doesn't shadow the
# version probe.
function Get-InstalledVersion {
    $managedBinary = Join-Path $InstallDir "sfw.exe"
    if (-not (Test-Path $managedBinary)) {
        return $null
    }

    try {
        $output = & $managedBinary --version 2>&1 | Out-String

        # Accept any X.Y.Z token in the output
        if ($output -match "(\d+\.\d+\.\d+)") {
            return $matches[1].Trim()
        }

        return $null
    }
    catch {
        return $null
    }
}

# Check if the requested version is already installed
function Test-VersionInstalled {
    param([string]$RequestedVersion)

    $installedVersion = Get-InstalledVersion

    if ([string]::IsNullOrWhiteSpace($installedVersion)) {
        return $false
    }

    # Strip leading 'v' from versions if present for comparison
    $requestedClean = $RequestedVersion -replace '^v', ''
    $installedClean = $installedVersion -replace '^v', ''

    return $requestedClean -eq $installedClean
}

# Fetch latest release version tag from GitHub
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

# Detect architecture (Socket publishes x86_64 only for Windows)
function Get-Architecture {
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        "AMD64" { return "x86_64" }
        "ARM64" {
            Write-Warn "No prebuilt sfw Windows ARM64 binary is published; falling back to x86_64 (runs under x64 emulation)."
            return "x86_64"
        }
        default { Write-Error-Custom "Unsupported architecture: $arch" }
    }
}

# Check and uninstall npm global package if present
function Remove-NpmInstallation {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        return
    }

    npm list -g sfw 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Detected npm global installation of sfw"
        Write-Info "Uninstalling npm version before installing binary version..."

        npm uninstall -g sfw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Successfully uninstalled npm version"
        }
        else {
            Write-Warn "Failed to uninstall npm version automatically"
            Write-Warn "Please run: npm uninstall -g sfw"
        }
    }
}

# Check and uninstall Volta-managed package if present
function Remove-VoltaInstallation {
    if (-not (Get-Command volta -ErrorAction SilentlyContinue)) {
        return
    }

    volta list sfw 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Detected Volta installation of sfw"
        Write-Info "Uninstalling Volta version before installing binary version..."

        volta uninstall sfw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Successfully uninstalled Volta version"
        }
        else {
            Write-Warn "Failed to uninstall Volta version automatically"
            Write-Warn "Please run: volta uninstall sfw"
        }
    }
}

# Add a directory to the persistent user PATH (and current session PATH)
function Add-ToUserPath {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $current) { $current = "" }

    $parts = $current.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts -notcontains $Dir) {
        $new = if ($current) { "$current;$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable("Path", $new, "User")
        Write-Info "Added $Dir to user PATH"
    }
    else {
        Write-Info "$Dir already on user PATH"
    }

    if (($env:Path -split ';') -notcontains $Dir) {
        $env:Path = "$env:Path;$Dir"
    }
}

# Create shell integration so plain "npm install" routes through sfw.
#
# Strategy: shell-level aliases rather than PATH shims.
#   - PowerShell: functions defined in the CurrentUserAllHosts profile.
#   - cmd.exe: doskey macros registered via HKCU Command Processor AutoRun.
# Shell aliases live only in the shell; child processes spawned by sfw (via
# CreateProcess) bypass them and see the real npm/yarn/pnpm/pip/uv/cargo, so
# there's no wrapper recursion.
function Install-Shims {
    param([string]$SfwPath)

    $managers = @("npm", "yarn", "pnpm", "pip", "uv", "cargo")

    # --- PowerShell profile ---
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $marker = "# >>> socket sfw shims >>>"
    $endMarker = "# <<< socket sfw shims <<<"
    $funcLines = foreach ($m in $managers) {
        "function $m { & '$SfwPath' $m @args }"
    }
    $block = @"
$marker
# Routes package manager commands through Socket Firewall (sfw).
# Managed by install-sfw.ps1. To disable, delete this block.
$($funcLines -join "`n")
$endMarker
"@

    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { "" }
    if ($existing -match [regex]::Escape($marker)) {
        $pattern = "(?s)" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMarker)
        $updated = [regex]::Replace($existing, $pattern, $block)
        Set-Content -Path $profilePath -Value $updated -Encoding UTF8
        Write-Info "Updated sfw shims in PowerShell profile: $profilePath"
    }
    else {
        Add-Content -Path $profilePath -Value "`r`n$block`r`n"
        Write-Info "Added sfw shims to PowerShell profile: $profilePath"
    }

    # --- cmd.exe doskey macros via AutoRun ---
    $doskeyFile = Join-Path (Split-Path $SfwPath -Parent) "sfw-shims.cmd"
    $doskeyLines = @("@echo off")
    foreach ($m in $managers) {
        $doskeyLines += "doskey $m=`"$SfwPath`" $m `$*"
    }
    Set-Content -Path $doskeyFile -Value ($doskeyLines -join "`r`n") -Encoding Ascii
    Write-Info "Wrote cmd.exe shim script: $doskeyFile"

    $autoRunKey = "HKCU:\Software\Microsoft\Command Processor"
    $autoRunName = "AutoRun"
    if (-not (Test-Path $autoRunKey)) {
        New-Item -Path $autoRunKey -Force | Out-Null
    }
    $currentAutoRun = (Get-ItemProperty -Path $autoRunKey -Name $autoRunName -ErrorAction SilentlyContinue).$autoRunName
    $callLine = "CALL `"$doskeyFile`""
    if ($currentAutoRun) {
        if ($currentAutoRun -notmatch [regex]::Escape($doskeyFile)) {
            Set-ItemProperty -Path $autoRunKey -Name $autoRunName -Value "$currentAutoRun & $callLine"
            Write-Info "Appended sfw doskey macros to cmd.exe AutoRun"
        }
        else {
            Write-Info "cmd.exe AutoRun already registers sfw doskey macros"
        }
    }
    else {
        Set-ItemProperty -Path $autoRunKey -Name $autoRunName -Value $callLine
        Write-Info "Registered sfw doskey macros for cmd.exe"
    }
}

# Main installation
function Install-Sfw {
    if (-not [string]::IsNullOrWhiteSpace($env:SFW_VERSION)) {
        Write-Warn "SFW_VERSION environment variable is set: $env:SFW_VERSION"
        Write-Warn "Pinning to that version. Unset SFW_VERSION to always install the latest."
    }

    # Fetch latest version if VERSION is not set
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Info "Fetching latest release version..."
        $Version = Get-LatestVersion
    }

    # Check if the requested version is already installed
    if (Test-VersionInstalled -RequestedVersion $Version) {
        Write-Info "sfw $Version is already installed"
        return
    }

    # Build installation message
    $installMsg = "Installing sfw $Version"
    if ($ci) {
        $installMsg += " in ci"
    }

    Write-Info $installMsg

    # Check for existing sfw installation through npm or Volta
    Remove-NpmInstallation
    Remove-VoltaInstallation

    # Detect platform
    $arch = Get-Architecture
    $binaryName = "sfw-free-windows-$arch.exe"

    Write-Info "Detected architecture: $($env:PROCESSOR_ARCHITECTURE) -> $arch"

    # Create installation directory
    if (-not (Test-Path $InstallDir)) {
        Write-Info "Creating installation directory: $InstallDir"
        try {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }
        catch {
            Write-Error-Custom "Failed to create directory $InstallDir : $_"
        }
    }

    # Download binary
    $downloadUrl = "$RepoUrl/releases/download/$Version/$binaryName"
    $tempFile = Join-Path $InstallDir $binaryName

    Write-Info "Downloading from: $downloadUrl"

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing
        $ProgressPreference = 'Continue'
    }
    catch {
        Write-Error-Custom "Failed to download from $downloadUrl : $_"
    }

    # Rename to final location
    $finalFile = Join-Path $InstallDir "sfw.exe"
    try {
        if (Test-Path $finalFile) {
            Remove-Item -Path $finalFile -Force
        }
        Move-Item -Path $tempFile -Destination $finalFile -Force
    }
    catch {
        Write-Error-Custom "Failed to move binary to $finalFile : $_"
    }

    Write-Info "Binary installed to: $finalFile"

    # Ensure the binary is on PATH for current and future sessions
    Add-ToUserPath $InstallDir

    # Post-install step analogous to `safe-chain setup`: wire up shell aliases
    # so `npm install` etc. transparently route through sfw. Skipped in CI —
    # CI jobs should call `sfw npm install ...` explicitly.
    if ($ci) {
        Write-Info "CI mode: skipping shell shim setup."
        Write-Info "Invoke sfw explicitly in CI, e.g. 'sfw npm ci'."
    }
    else {
        try {
            Install-Shims -SfwPath $finalFile
            Write-Info "Shell shims installed. Open a new PowerShell or cmd session to use them."
            Write-Info "Smoke test in a new session: 'sfw --version' and 'npm --version'."
        }
        catch {
            Write-Warn "sfw was installed but shim setup failed: $_"
            Write-Warn "You can re-run this script, or call 'sfw <cmd>' directly."
        }
    }
}

# Run installation
try {
    Install-Sfw
}
catch {
    Write-Error-Custom "Installation failed: $_"
}
