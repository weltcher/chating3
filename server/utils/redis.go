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
