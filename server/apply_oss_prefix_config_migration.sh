#!/bin/bash
# Bash脚本：应用OSS前缀域名配置表迁移
# 用法: ./apply_oss_prefix_config_migration.sh

echo "========================================"
echo "应用OSS前缀域名配置表迁移"
echo "========================================"
echo ""

# 加载.env文件
if [ -f .env ]; then
    echo "✅ 找到.env文件，正在加载配置..."
    export $(grep -v '^#' .env | xargs)
else
    echo "❌ 未找到.env文件"
    exit 1
fi

# 获取数据库配置
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}

echo "数据库配置:"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  User: $DB_USER"
echo "  Database: $DB_NAME"
echo ""

# 设置PGPASSWORD环境变量
export PGPASSWORD=$DB_PASSWORD

# 迁移文件路径
MIGRATION_FILE="migrations/create_oss_prefix_config.sql"

if [ ! -f "$MIGRATION_FILE" ]; then
    echo "❌ 迁移文件不存在: $MIGRATION_FILE"
    exit 1
fi

echo "📄 应用迁移文件: $MIGRATION_FILE"
echo ""

# 执行迁移
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f $MIGRATION_FILE

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 迁移应用成功！"
    echo ""
    echo "已创建表: oss_prefix_config"
    echo "已插入默认配置（ID=1）:"
    echo "  old_prefix_domain: https://xn--wxtp0q.cc"
    echo "  new_prefix_domain: https://yoududown.cc"
    echo ""
    echo "API接口:"
    echo "  GET  /api/oss/prefix-config        - 获取OSS前缀域名配置"
    echo "  PUT  /api/oss/prefix-config/:id    - 更新OSS前缀域名配置"
else
    echo ""
    echo "❌ 迁移应用失败"
    exit 1
fi

# 清除PGPASSWORD
unset PGPASSWORD
