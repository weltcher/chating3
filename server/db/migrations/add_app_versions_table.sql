-- 应用版本管理表
-- 用于存储各平台的应用版本信息，支持版本检查和自动更新

CREATE TABLE IF NOT EXISTS app_versions (
    id SERIAL PRIMARY KEY,
    platform VARCHAR(20) NOT NULL,           -- 平台: windows, macos, linux, android, ios
    version VARCHAR(50) NOT NULL,            -- 版本号: 如 1.0.0
    version_code VARCHAR(50) NOT NULL,       -- 版本代码: 如 100 (用于数字比较)
    download_url VARCHAR(500) NOT NULL,      -- 下载地址
    release_notes TEXT,                      -- 更新说明
    file_size BIGINT DEFAULT 0,              -- 文件大小（字节）
    md5 VARCHAR(32),                         -- MD5校验值
    force_update BOOLEAN DEFAULT FALSE,      -- 是否强制更新
    is_active BOOLEAN DEFAULT TRUE,          -- 是否启用
    release_date TIMESTAMP DEFAULT NOW(),    -- 发布日期
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_app_versions_platform ON app_versions(platform);
CREATE INDEX IF NOT EXISTS idx_app_versions_platform_active ON app_versions(platform, is_active);
CREATE INDEX IF NOT EXISTS idx_app_versions_created_at ON app_versions(created_at DESC);

-- 添加注释
COMMENT ON TABLE app_versions IS '应用版本管理表';
COMMENT ON COLUMN app_versions.platform IS '平台类型: windows, macos, linux, android, ios';
COMMENT ON COLUMN app_versions.version IS '语义化版本号，如 1.0.0';
COMMENT ON COLUMN app_versions.version_code IS '数字版本代码，用于版本比较';
COMMENT ON COLUMN app_versions.download_url IS '安装包下载地址';
COMMENT ON COLUMN app_versions.release_notes IS '版本更新说明';
COMMENT ON COLUMN app_versions.file_size IS '安装包文件大小（字节）';
COMMENT ON COLUMN app_versions.md5 IS '安装包MD5校验值';
COMMENT ON COLUMN app_versions.force_update IS '是否强制更新，true时用户必须更新才能使用';
COMMENT ON COLUMN app_versions.is_active IS '是否启用，false时不会推送给客户端';

-- 插入示例数据（可选，用于测试）
-- INSERT INTO app_versions (platform, version, version_code, download_url, release_notes, file_size, md5, force_update, is_active)
-- VALUES 
--     ('android', '1.0.1', '2', 'https://example.com/youdu_1.0.1.apk', '1. 修复已知问题\n2. 性能优化', 52428800, 'abc123def456', false, true),
--     ('windows', '1.0.1', '2', 'https://example.com/youdu_1.0.1.exe', '1. 修复已知问题\n2. 性能优化', 104857600, 'xyz789abc123', false, true);
