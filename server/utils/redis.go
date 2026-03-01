package utils

import (
	"context"
	"fmt"
	"time"

	"youdu-server/config"

	"github.com/redis/go-redis/v9"
)

var RedisClient *redis.Client
var ctx = context.Background()

// InitRedis 初始化Redis连接
func InitRedis() error {
	RedisClient = redis.NewClient(&redis.Options{
		Addr:     fmt.Sprintf("%s:%s", config.AppConfig.RedisHost, config.AppConfig.RedisPort),
		Password: config.AppConfig.RedisPassword,
		DB:       config.AppConfig.RedisDB,
	})

	// 测试连接
	_, err := RedisClient.Ping(ctx).Result()
	if err != nil {
		return fmt.Errorf("Redis连接失败: %v", err)
	}

	LogDebug("✅ Redis连接成功: %s:%s", config.AppConfig.RedisHost, config.AppConfig.RedisPort)
	return nil
}

// CloseRedis 关闭Redis连接
func CloseRedis() {
	if RedisClient != nil {
		RedisClient.Close()
	}
}

// SetEmailCode 存储邮箱验证码到Redis
// key格式: email_code:{email}
// 过期时间: 5分钟
func SetEmailCode(email, code string) error {
	key := fmt.Sprintf("email_code:%s", email)
	expiration := time.Duration(config.AppConfig.VerifyCodeExpireMinutes) * time.Minute
	return RedisClient.Set(ctx, key, code, expiration).Err()
}

// GetEmailCode 从Redis获取邮箱验证码
func GetEmailCode(email string) (string, error) {
	key := fmt.Sprintf("email_code:%s", email)
	return RedisClient.Get(ctx, key).Result()
}

// DeleteEmailCode 删除邮箱验证码
func DeleteEmailCode(email string) error {
	key := fmt.Sprintf("email_code:%s", email)
	return RedisClient.Del(ctx, key).Err()
}

// VerifyEmailCode 验证邮箱验证码
func VerifyEmailCode(email, code string) (bool, error) {
	storedCode, err := GetEmailCode(email)
	if err == redis.Nil {
		return false, nil // 验证码不存在或已过期
	}
	if err != nil {
		return false, err
	}
	return storedCode == code, nil
}

// CheckMessageExists 检查消息是否已在 Redis 中存储过
// 用于使用 Hash 数据结构进行消息去重
func CheckMessageExists(key, field string) bool {
	exists, err := RedisClient.HExists(ctx, key, field).Result()
	if err != nil {
		LogDebug("⚠️ [Redis] 检查消息是否存在时出错 - Key: %s, Field: %s, Error: %v", key, field, err)
		return false // 如果出错，保守起见返回不存，让后续继续处理
	}
	return exists
}

// StoreMessageID 将消息ID存储到 Redis Hash 中，值为 "1"
// 过期时间设置为 24小时
func StoreMessageID(key, field string) {
	err := RedisClient.HSet(ctx, key, field, "1").Err()
	if err != nil {
		LogDebug("⚠️ [Redis] 存储消息ID时出错 - Key: %s, Field: %s, Error: %v", key, field, err)
		return
	}
	// 给对应的 Key 设置过期时间为 24小时
	RedisClient.Expire(ctx, key, 30*time.Second)
}
