# Android APK Build Script (PowerShell)
# Usage: .\deploy\build.ps1 [options]

param(
    [switch]$Clean,
    [switch]$AppBundle,
    [switch]$Universal,
    [switch]$Help
)

if ($Help) {
    Write-Host "Android Build Script"
    Write-Host ""
    Write-Host "Usage: .\deploy\build.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Clean          Clean before build"
    Write-Host "  -AppBundle      Build App Bundle (AAB) instead of APK"
    Write-Host "  -Universal      Build universal APK (all architectures, larger size)"
    Write-Host "  -Help           Show this help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\deploy\build.ps1                    # Build single arch APK (arm64-v8a)"
    Write-Host "  .\deploy\build.ps1 -Clean             # Clean and build"
    Write-Host "  .\deploy\build.ps1 -AppBundle         # Build App Bundle"
    Write-Host "  .\deploy\build.ps1 -Universal         # Build universal APK"
    exit 0
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Android Release Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Flutter installation
try {
    $null = flutter --version 2>&1
    Write-Host "[OK] Flutter is installed" -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] Flutter not found, please install Flutter SDK first" -ForegroundColor Red
    exit 1
}

# Clean build cache
# if ($Clean) {
#     Write-Host ""
#     Write-Host "Cleaning build cache..." -ForegroundColor Yellow
#     flutter clean
#     if ($LASTEXITCODE -ne 0) {
#         Write-Host "[ERROR] Clean failed" -ForegroundColor Red
#         exit 1
#     }
#     Write-Host "[OK] Clean completed" -ForegroundColor Green
# }

# Get dependencies
Write-Host ""
Write-Host "Getting dependencies..." -ForegroundColor Yellow
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to get dependencies" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Dependencies ready" -ForegroundColor Green

# Build
Write-Host ""
if ($AppBundle) {
    Write-Host "Building App Bundle (AAB)..." -ForegroundColor Yellow
    Write-Host "Command: flutter build appbundle --release" -ForegroundColor Gray
    flutter build appbundle --release
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "[SUCCESS] App Bundle built successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Output: build\app\outputs\bundle\release\app-release.aab" -ForegroundColor Cyan
        
        $aabFile = "build\app\outputs\bundle\release\app-release.aab"
        if (Test-Path $aabFile) {
            $size = (Get-Item $aabFile).Length / 1MB
            Write-Host "Size: $([math]::Round($size, 2)) MB" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host ""
        Write-Host "[ERROR] App Bundle build failed" -ForegroundColor Red
        exit 1
    }
}
elseif ($Universal) {
    Write-Host "Building universal APK (all architectures)..." -ForegroundColor Yellow
    Write-Host "Warning: Universal APK is larger (about 200-300MB)" -ForegroundColor Yellow
    Write-Host "Command: flutter build apk --release" -ForegroundColor Gray
    flutter build apk --release
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "[SUCCESS] Universal APK built successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Output: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Cyan
        
        $apkFile = "build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkFile) {
            $size = (Get-Item $apkFile).Length / 1MB
            Write-Host "Size: $([math]::Round($size, 2)) MB" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host ""
        Write-Host "[ERROR] Universal APK build failed" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "Building single architecture APK (arm64-v8a)..." -ForegroundColor Yellow
    Write-Host "Command: flutter build apk --release --target-platform android-arm64" -ForegroundColor Gray
    flutter build apk --release --target-platform android-arm64
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "[SUCCESS] APK built successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Output: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Cyan
        
        $apkFile = "build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkFile) {
            $size = (Get-Item $apkFile).Length / 1MB
            Write-Host "Size: $([math]::Round($size, 2)) MB" -ForegroundColor Cyan
        }
        
        Write-Host ""
        Write-Host "Note: This APK only supports 64-bit ARM devices (modern phones)" -ForegroundColor Yellow
        Write-Host "      For older devices, use -Universal parameter" -ForegroundColor Yellow
    }
    else {
        Write-Host ""
        Write-Host "[ERROR] APK build failed" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "Build completed at: $timestamp" -ForegroundColor Gray
