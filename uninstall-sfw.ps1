# Uninstalls Socket Firewall (sfw) from Windows.
#
# Ported from AikidoSec/safe-chain's uninstall-safe-chain.ps1. sfw has no
# `sfw teardown` subcommand, so this script removes the shell integration
# that install-sfw.ps1 added (PowerShell profile block + cmd.exe AutoRun
# doskey macros) and deletes the install directory.
#
# Usage: iex (iwr https://raw.githubusercontent.com/.../uninstall-sfw.ps1 -UseBasicParsing)

# Use HOME on Unix, USERPROFILE on Windows (PowerShell Core is cross-platform)
$HomeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$DotSfw = Join-Path $HomeDir ".sfw"
$InstallDir = Join-Path $DotSfw "bin"

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

# Check and uninstall npm global package if present
function Remove-NpmInstallation {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        return
    }

    npm list -g sfw 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Detected npm global installation of sfw"
        Write-Info "Uninstalling npm version..."

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
        Write-Info "Uninstalling Volta version..."

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

# Strip the install directory from the persistent user PATH (and current session)
function Remove-FromUserPath {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $current) { return }

    $parts = $current.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    $filtered = $parts | Where-Object { $_ -ne $Dir }

    if ($filtered.Count -ne $parts.Count) {
        $new = ($filtered -join ';')
        [Environment]::SetEnvironmentVariable("Path", $new, "User")
        Write-Info "Removed $Dir from user PATH"
    }

    $sessionParts = $env:Path.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    $env:Path = (($sessionParts | Where-Object { $_ -ne $Dir }) -join ';')
}

# Remove shell integration installed by install-sfw.ps1:
#   - marker-fenced block in PowerShell CurrentUserAllHosts profile
#   - CALL "sfw-shims.cmd" entry in cmd.exe AutoRun registry value
function Remove-Shims {
    # --- PowerShell profile ---
    $profilePath = $PROFILE.CurrentUserAllHosts
    $marker = "# >>> socket sfw shims >>>"
    $endMarker = "# <<< socket sfw shims <<<"

    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw
        if ($existing -match [regex]::Escape($marker)) {
            # Strip marker block plus any immediately-adjacent blank lines
            $pattern = "(?s)\r?\n?\s*" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMarker) + "\s*\r?\n?"
            $updated = [regex]::Replace($existing, $pattern, "`r`n")
            # Collapse trailing whitespace
            $updated = $updated.TrimEnd() + "`r`n"
            if ([string]::IsNullOrWhiteSpace($updated)) {
                Remove-Item -Path $profilePath -Force
                Write-Info "Removed now-empty PowerShell profile: $profilePath"
            }
            else {
                Set-Content -Path $profilePath -Value $updated -Encoding UTF8 -NoNewline
                Write-Info "Removed sfw shims from PowerShell profile: $profilePath"
            }
        }
        else {
            Write-Info "No sfw shim block found in PowerShell profile."
        }
    }
    else {
        Write-Info "PowerShell profile does not exist; nothing to clean there."
    }

    # --- cmd.exe doskey macros via AutoRun ---
    $autoRunKey = "HKCU:\Software\Microsoft\Command Processor"
    $autoRunName = "AutoRun"
    $doskeyFile = Join-Path $InstallDir "sfw-shims.cmd"

    if (Test-Path $autoRunKey) {
        $currentAutoRun = (Get-ItemProperty -Path $autoRunKey -Name $autoRunName -ErrorAction SilentlyContinue).$autoRunName
        if ($currentAutoRun) {
            # Drop our CALL entry whether it's standalone or joined by "&"
            $escaped = [regex]::Escape($doskeyFile)
            $pattern = "(?i)\s*&?\s*CALL\s+`"$escaped`"\s*&?"
            $new = [regex]::Replace($currentAutoRun, $pattern, "")
            $new = $new.Trim().Trim('&').Trim()

            if ($new -ne $currentAutoRun) {
                if ([string]::IsNullOrWhiteSpace($new)) {
                    Remove-ItemProperty -Path $autoRunKey -Name $autoRunName -ErrorAction SilentlyContinue
                    Write-Info "Removed sfw entry from cmd.exe AutoRun (value was otherwise empty)"
                }
                else {
                    Set-ItemProperty -Path $autoRunKey -Name $autoRunName -Value $new
                    Write-Info "Removed sfw entry from cmd.exe AutoRun"
                }
            }
            else {
                Write-Info "No sfw entry found in cmd.exe AutoRun."
            }
        }
    }
}

# Main uninstallation
function Uninstall-Sfw {
    Write-Info "Uninstalling sfw..."

    # Remove shell integration (analogue of `safe-chain teardown`)
    try {
        Remove-Shims
    }
    catch {
        Write-Warn "Shim removal encountered issues: $_"
        Write-Warn "Continuing with uninstallation..."
    }

    # Remove npm and Volta installations
    Remove-NpmInstallation
    Remove-VoltaInstallation

    # Drop install dir from user PATH before deleting the directory
    Remove-FromUserPath $InstallDir

    # Remove .sfw directory
    if (Test-Path $DotSfw) {
        Write-Info "Removing installation directory: $DotSfw"
        try {
            Remove-Item -Path $DotSfw -Recurse -Force
            Write-Info "Successfully removed installation directory"
        }
        catch {
            Write-Error-Custom "Failed to remove $DotSfw : $_"
        }
    }
    else {
        Write-Info "Installation directory $DotSfw does not exist. Nothing to remove."
    }

    Write-Info "sfw has been uninstalled successfully!"
}

# Run uninstallation
try {
    Uninstall-Sfw
    # npm/volta list commands leak non-zero $LASTEXITCODE when packages are
    # absent; that's expected, not a failure. Force a clean exit so callers
    # can rely on 0 = success.
    exit 0
}
catch {
    Write-Error-Custom "Uninstallation failed: $_"
}
