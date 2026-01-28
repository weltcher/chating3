package config

import (
	"os"
	"strconv"
)

// Config holds all configuration for the server
type Config struct {
	HTTPPort      string
	EnableFileLog bool // 是否启用文件日志（默认true）
	Redis         RedisConfig
	ServerA       ServerAConfig
}

// RedisConfig holds Redis connection settings
type RedisConfig struct {
	Host     string
	Port     string
	Password string
	DB       int
}

// ServerAConfig holds Server A WebSocket connection settings
type ServerAConfig struct {
	WSURL string
	Token string
}

// Load reads configuration from environment variables
func Load() *Config {
	// 直接从 .env 中读取 ENABLE_FILE_LOG 配置，未配置则默认关闭文件日志
	envValue := os.Getenv("ENABLE_FILE_LOG")
	enableFileLog := envValue == "true" || envValue == "1" || envValue == "yes"

	return &Config{
		HTTPPort:      getEnv("HTTP_PORT", "3002"),
		EnableFileLog: enableFileLog,
		Redis: RedisConfig{
			Host:     getEnv("REDIS_HOST", "localhost"),
			Port:     getEnv("REDIS_PORT", "6379"),
			Password: getEnv("REDIS_PASSWORD", ""),
			DB:       getEnvInt("REDIS_DB", 0),
		},
		ServerA: ServerAConfig{
			WSURL: getEnv("SERVER_A_WS_URL", "ws://localhost:3000/ws"),
			Token: getEnv("SERVER_A_TOKEN", ""),
		},
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}
