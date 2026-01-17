# PowerShell脚本：应用OSS前缀域名配置表迁移
# 用法: .\apply_oss_prefix_config_migration.ps1

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "应用OSS前缀域名配置表迁移" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 加载.env文件
if (Test-Path ".env") {
    Write-Host "✅ 找到.env文件，正在加载配置..." -ForegroundColor Green
    Get-Content .env | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
} else {
    Write-Host "❌ 未找到.env文件" -ForegroundColor Red
    exit 1
}

# 获取数据库配置
$DB_HOST = $env:DB_HOST
$DB_PORT = $env:DB_PORT
$DB_USER = $env:DB_USER
$DB_PASSWORD = $env:DB_PASSWORD
$DB_NAME = $env:DB_NAME

Write-Host "数据库配置:" -ForegroundColor Yellow
Write-Host "  Host: $DB_HOST" -ForegroundColor Yellow
Write-Host "  Port: $DB_PORT" -ForegroundColor Yellow
Write-Host "  User: $DB_USER" -ForegroundColor Yellow
Write-Host "  Database: $DB_NAME" -ForegroundColor Yellow
Write-Host ""

# 设置PGPASSWORD环境变量
$env:PGPASSWORD = $DB_PASSWORD

# 迁移文件路径
$MIGRATION_FILE = "migrations/create_oss_prefix_config.sql"

if (-not (Test-Path $MIGRATION_FILE)) {
    Write-Host "❌ 迁移文件不存在: $MIGRATION_FILE" -ForegroundColor Red
    exit 1
}

Write-Host "📄 应用迁移文件: $MIGRATION_FILE" -ForegroundColor Cyan
Write-Host ""

# 执行迁移
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f $MIGRATION_FILE

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "✅ 迁移应用成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "已创建表: oss_prefix_config" -ForegroundColor Green
    Write-Host "已插入默认配置（ID=1）:" -ForegroundColor Green
    Write-Host "  old_prefix_domain: https://xn--wxtp0q.cc" -ForegroundColor Green
    Write-Host "  new_prefix_domain: https://yoududown.cc" -ForegroundColor Green
    Write-Host ""
    Write-Host "API接口:" -ForegroundColor Cyan
    Write-Host "  GET  /api/oss/prefix-config        - 获取OSS前缀域名配置" -ForegroundColor Cyan
    Write-Host "  PUT  /api/oss/prefix-config/:id    - 更新OSS前缀域名配置" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "❌ 迁移应用失败" -ForegroundColor Red
    exit 1
}

# 清除PGPASSWORD
Remove-Item Env:\PGPASSWORD
