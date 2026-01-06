# Flutter Build Script After Clean (PowerShell Version)
# Supports colored output and detailed error handling

param(
    [switch]$Release,  # Whether to build Release version
    [switch]$Run,      # Whether to auto-run after build completion
    [switch]$Verbose   # Whether to show verbose output
)

# Set console encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Color output functions
function Write-ColorText {
    param(
        [string]$Text,
        [string]$Color = "White"
    )
    Write-Host $Text -ForegroundColor $Color
}

function Write-Success {
    param([string]$Text)
    Write-ColorText "✅ $Text" "Green"
}

function Write-Error {
    param([string]$Text)
    Write-ColorText "❌ $Text" "Red"
}

function Write-Info {
    param([string]$Text)
    Write-ColorText "ℹ️  $Text" "Cyan"
}

function Write-Warning {
    param([string]$Text)
    Write-ColorText "⚠️  $Text" "Yellow"
}

# Start script
Write-ColorText "========================================" "Magenta"
Write-ColorText "Flutter Build Script After Clean (PowerShell)" "Magenta"
Write-ColorText "========================================" "Magenta"
Write-Host ""

# Get project path (go up one level from scripts folder to project root)
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectPath = Split-Path -Parent $ScriptPath
Set-Location $ProjectPath

Write-Info "Current project path: $ProjectPath"
Write-Host ""

# Set OpenSSL 3.0.17 environment variables
Write-Info "Setting OpenSSL 3.0.17 environment variables..."
$env:OPENSSL_ROOT_DIR = "C:\tools\openssl\openssl-3.0.17"
$env:OPENSSL_INCLUDE_DIR = "C:\tools\openssl\openssl-3.0.17\include"
$env:OPENSSL_CRYPTO_LIBRARY = "C:\tools\openssl\openssl-3.0.17\libcrypto.lib"
$env:OPENSSL_SSL_LIBRARY = "C:\tools\openssl\openssl-3.0.17\libssl.lib"

Write-Success "OpenSSL environment variables set successfully"
Write-Host "   OPENSSL_ROOT_DIR = $env:OPENSSL_ROOT_DIR"
Write-Host "   OPENSSL_INCLUDE_DIR = $env:OPENSSL_INCLUDE_DIR"
Write-Host ""

# Check if OpenSSL path exists
if (-not (Test-Path $env:OPENSSL_ROOT_DIR)) {
    Write-Error "OpenSSL path does not exist: $env:OPENSSL_ROOT_DIR"
    Write-Warning "Please check if OpenSSL 3.0.17 is properly installed"
    Read-Host "Press any key to exit"
    exit 1
}

# Check required OpenSSL files
$RequiredFiles = @(
    "$env:OPENSSL_ROOT_DIR\libcrypto-3-x64.dll",
    "$env:OPENSSL_ROOT_DIR\libssl-3-x64.dll",
    "$env:OPENSSL_CRYPTO_LIBRARY",
    "$env:OPENSSL_SSL_LIBRARY"
)

foreach ($File in $RequiredFiles) {
    if (Test-Path $File) {
        Write-Success "Found: $(Split-Path -Leaf $File)"
    } else {
        Write-Error "Missing: $File"
    }
}
Write-Host ""

# Execute Flutter Clean
# Write-Info "Executing Flutter Clean..."
# try {
#     flutter clean
#     if ($LASTEXITCODE -eq 0) {
#         Write-Success "Flutter Clean completed"
#     } else {
#         throw "Flutter Clean failed, exit code: $LASTEXITCODE"
#     }
# } catch {
#     Write-Error "Flutter Clean failed: $_"
#     Read-Host "Press any key to exit"
#     exit 1
# }
# Write-Host ""

# Get Flutter package dependencies
Write-Info "Getting Flutter package dependencies..."
try {
    if ($Verbose) {
        flutter pub get --verbose
    } else {
        flutter pub get
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Flutter package dependencies retrieved successfully"
    } else {
        throw "Flutter pub get failed, exit code: $LASTEXITCODE"
    }
} catch {
    Write-Error "Flutter pub get failed: $_"
    Read-Host "Press any key to exit"
    exit 1
}
Write-Host ""

# Determine build mode
$BuildMode = "release"
$BuildModeDisplay = "Release"

# Build Windows application
Write-Info "Building Windows application ($BuildModeDisplay mode)..."
Write-Warning "This may take a few minutes, please be patient..."
Write-Host ""

$StartTime = Get-Date
try {
    if ($Verbose) {
        flutter build windows --$BuildMode --verbose
    } else {
        flutter build windows --$BuildMode
    }
    if ($LASTEXITCODE -eq 0) {
        $EndTime = Get-Date
        $Duration = $EndTime - $StartTime
        Write-Success "Flutter Windows application build completed (Duration: $($Duration.ToString('mm\:ss')))"
    } else {
        throw "Flutter build failed, exit code: $LASTEXITCODE"
    }
} catch {
    Write-Error "Flutter build failed: $_"
    Read-Host "Press any key to exit"
    exit 1
}
Write-Host ""

# Set build directory
$BuildDir = "$ProjectPath\build\windows\x64\runner\Release"

# Copy OpenSSL DLLs to build directory
Write-Info "Copying OpenSSL DLLs to build directory..."
$OpenSSLDlls = @(
    "libcrypto-3-x64.dll",
    "libssl-3-x64.dll"
)

foreach ($Dll in $OpenSSLDlls) {
    $SourcePath = Join-Path $env:OPENSSL_ROOT_DIR $Dll
    $DestPath = Join-Path $BuildDir $Dll
    if (Test-Path $SourcePath) {
        Copy-Item $SourcePath $DestPath -Force
        Write-Success "Copied: $Dll"
    } else {
        Write-Warning "OpenSSL DLL not found: $SourcePath"
    }
}
Write-Host ""

# Copy VC++ Runtime DLLs to build directory
Write-Info "Copying VC++ Runtime DLLs to build directory..."
$VCRuntimeDlls = @(
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
)

# Try to find VC++ runtime DLLs from System32
$System32Path = "$env:SystemRoot\System32"

foreach ($Dll in $VCRuntimeDlls) {
    $SourcePath = Join-Path $System32Path $Dll
    $DestPath = Join-Path $BuildDir $Dll
    if (Test-Path $SourcePath) {
        Copy-Item $SourcePath $DestPath -Force
        Write-Success "Copied: $Dll"
    } else {
        Write-Warning "VC++ Runtime DLL not found: $SourcePath"
    }
}
Write-Host ""

# Copy uninstaller to build directory
Write-Info "Copying uninstaller to build directory..."
$UninstallerPath = Join-Path $ProjectPath "卸载.exe"
$UninstallerDest = Join-Path $BuildDir "卸载.exe"
if (Test-Path $UninstallerPath) {
    Copy-Item $UninstallerPath $UninstallerDest -Force
    Write-Success "Copied: 卸载.exe"
} else {
    Write-Warning "Uninstaller not found: $UninstallerPath"
}
Write-Host ""

# Check generated key files
Write-Info "Checking generated key files..."

$KeyFiles = @{
    "youdu.exe" = "Main executable"
    "sqlite3.dll" = "SQLCipher library"
    "sqlcipher_flutter_libs_plugin.dll" = "SQLCipher plugin"
    "flutter_windows.dll" = "Flutter runtime"
    "libcrypto-3-x64.dll" = "OpenSSL Crypto library"
    "msvcp140.dll" = "VC++ Runtime (msvcp)"
    "vcruntime140.dll" = "VC++ Runtime (vcruntime)"
    "vcruntime140_1.dll" = "VC++ Runtime (vcruntime_1)"
    "卸载.exe" = "Uninstaller"
}

$AllFilesExist = $true
foreach ($File in $KeyFiles.Keys) {
    $FilePath = Join-Path $BuildDir $File
    if (Test-Path $FilePath) {
        $FileSize = (Get-Item $FilePath).Length
        $FileSizeMB = [math]::Round($FileSize / 1MB, 2)
        Write-Success "$($KeyFiles[$File]): $File ($FileSizeMB MB)"
    } else {
        Write-Error "$($KeyFiles[$File]) not found: $File"
        $AllFilesExist = $false
    }
}

Write-Host ""
if ($AllFilesExist) {
    Write-Success "Build completed! All key files have been generated"
} else {
    Write-Warning "Build completed, but some files are missing"
}

Write-Info "Output directory: $BuildDir"
Write-Host ""

# Show run command tip
Write-ColorText "💡 Tip: You can now run the following command to start the application:" "Yellow"
Write-Host "   flutter run -d windows --$BuildMode"
Write-Host ""

# Auto-run application if -Run parameter is specified
if ($Run -and $AllFilesExist) {
    Write-Info "Auto-starting application..."
    flutter run -d windows --$BuildMode
} else {
    Read-Host "Press any key to exit"
}
