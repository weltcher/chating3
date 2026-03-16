-- ============================================================
-- URL 批量替换脚本
-- 将所有字段值中开头为 "https://yoududown.cc" 的内容
-- 替换为 "https://youdu.co"
-- 数据库: youdu_db (PostgreSQL)
-- 生成时间: 2026-03-17
-- ============================================================

-- 执行前可先查看受影响行数（可选）：
-- SELECT COUNT(*) FROM app_versions WHERE package_url LIKE 'https://yoududown.cc%';
-- SELECT COUNT(*) FROM favorites    WHERE content      LIKE 'https://yoududown.cc%';
-- SELECT COUNT(*) FROM messages     WHERE content LIKE '%https://yoududown.cc%'
--                                      OR quoted_message_content LIKE '%https://yoududown.cc%'
--                                      OR sender_avatar   LIKE 'https://yoududown.cc%'
--                                      OR receiver_avatar LIKE 'https://yoududown.cc%';
-- SELECT COUNT(*) FROM oss_prefix_config WHERE new_prefix_domain LIKE 'https://yoududown.cc%';
-- SELECT COUNT(*) FROM users WHERE avatar LIKE 'https://yoududown.cc%';

BEGIN;

-- ── 1. app_versions.package_url ────────────────────────────────────────────
UPDATE app_versions
SET    package_url = 'https://youdu.co' || SUBSTRING(package_url FROM LENGTH('https://yoududown.cc') + 1)
WHERE  package_url LIKE 'https://yoududown.cc%';

-- ── 2. favorites.content ───────────────────────────────────────────────────
UPDATE favorites
SET    content = REPLACE(content, 'https://yoududown.cc', 'https://youdu.co')
WHERE  content LIKE '%https://yoududown.cc%';

-- ── 3. messages.content ────────────────────────────────────────────────────
UPDATE messages
SET    content = REPLACE(content, 'https://yoududown.cc', 'https://youdu.co')
WHERE  content LIKE '%https://yoududown.cc%';

-- ── 4. messages.quoted_message_content ────────────────────────────────────
UPDATE messages
SET    quoted_message_content = REPLACE(quoted_message_content, 'https://yoududown.cc', 'https://youdu.co')
WHERE  quoted_message_content LIKE '%https://yoududown.cc%';

-- ── 5. messages.sender_avatar ─────────────────────────────────────────────
UPDATE messages
SET    sender_avatar = 'https://youdu.co' || SUBSTRING(sender_avatar FROM LENGTH('https://yoududown.cc') + 1)
WHERE  sender_avatar LIKE 'https://yoududown.cc%';

-- ── 6. messages.receiver_avatar ───────────────────────────────────────────
UPDATE messages
SET    receiver_avatar = 'https://youdu.co' || SUBSTRING(receiver_avatar FROM LENGTH('https://yoududown.cc') + 1)
WHERE  receiver_avatar LIKE 'https://yoududown.cc%';

-- ── 7. oss_prefix_config.new_prefix_domain ────────────────────────────────
UPDATE oss_prefix_config
SET    new_prefix_domain = 'https://youdu.co' || SUBSTRING(new_prefix_domain FROM LENGTH('https://yoududown.cc') + 1)
WHERE  new_prefix_domain LIKE 'https://yoududown.cc%';

-- ── 8. users.avatar ───────────────────────────────────────────────────────
UPDATE users
SET    avatar = 'https://youdu.co' || SUBSTRING(avatar FROM LENGTH('https://yoududown.cc') + 1)
WHERE  avatar LIKE 'https://yoududown.cc%';

COMMIT;

-- 验证替换结果（可选）：
-- SELECT COUNT(*) FROM app_versions     WHERE package_url          LIKE '%yoududown.cc%';
-- SELECT COUNT(*) FROM favorites        WHERE content              LIKE '%yoududown.cc%';
-- SELECT COUNT(*) FROM messages         WHERE content              LIKE '%yoududown.cc%'
--                                          OR quoted_message_content LIKE '%yoududown.cc%'
--                                          OR sender_avatar          LIKE '%yoududown.cc%'
--                                          OR receiver_avatar        LIKE '%yoududown.cc%';
-- SELECT COUNT(*) FROM oss_prefix_config WHERE new_prefix_domain   LIKE '%yoududown.cc%';
-- SELECT COUNT(*) FROM users             WHERE avatar              LIKE '%yoududown.cc%';
-- 以上查询结果应均为 0，表示替换完全成功。
