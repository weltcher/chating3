# Server deployment script
# Delete old packages, archive server and server2 directories, and upload to remote servers

# Stop execution on error
$ErrorActionPreference = "Stop"

# Get script directory (project root)
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

Write-Host "Starting deployment process..." -ForegroundColor Green

# 1. Delete old archives
Write-Host "`nDeleting old archives..." -ForegroundColor Yellow
if (Test-Path "server.tar.gz") {
    Remove-Item "server.tar.gz" -Force
    Write-Host "Deleted server.tar.gz" -ForegroundColor Gray
} else {
    Write-Host "server.tar.gz does not exist, skipping" -ForegroundColor Gray
}

if (Test-Path "server2.tar.gz") {
    Remove-Item "server2.tar.gz" -Force
    Write-Host "Deleted server2.tar.gz" -ForegroundColor Gray
} else {
    Write-Host "server2.tar.gz does not exist, skipping" -ForegroundColor Gray
}

# 2. Check if directories exist
if (-not (Test-Path "server")) {
    Write-Host "Error: server directory does not exist!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "server2")) {
    Write-Host "Error: server2 directory does not exist!" -ForegroundColor Red
    exit 1
}

# 3. Archive server directory
Write-Host "`nArchiving server directory..." -ForegroundColor Yellow
tar zcf server.tar.gz server
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to archive server directory!" -ForegroundColor Red
    exit 1
}
Write-Host "server.tar.gz archive completed" -ForegroundColor Green

# 4. Archive server2 directory
Write-Host "`nArchiving server2 directory..." -ForegroundColor Yellow
tar zcf server2.tar.gz server2
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to archive server2 directory!" -ForegroundColor Red
    exit 1
}
Write-Host "server2.tar.gz archive completed" -ForegroundColor Green

# 5. Upload to remote servers
Write-Host "`nStarting upload to remote servers..." -ForegroundColor Yellow

# Upload server.tar.gz
Write-Host "`nUploading server.tar.gz to 31.57.65.73..." -ForegroundColor Cyan
scp -P 19014 server.tar.gz root@31.57.65.73:/www/chat/pc
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to upload server.tar.gz!" -ForegroundColor Red
    exit 1
}
Write-Host "server.tar.gz uploaded successfully" -ForegroundColor Green

# Upload server2.tar.gz
Write-Host "`nUploading server2.tar.gz to 31.57.65.81..." -ForegroundColor Cyan
scp -P 11337 server2.tar.gz root@31.57.65.81:/www/chat/pc
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to upload server2.tar.gz!" -ForegroundColor Red
    exit 1
}
Write-Host "server2.tar.gz uploaded successfully" -ForegroundColor Green

Write-Host "`nDeployment completed!" -ForegroundColor Green

