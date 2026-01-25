package config

import (
	"os"
	"strconv"
)

// Config holds all configuration for the server
type Config struct {
	HTTPPort string
	Redis    RedisConfig
	ServerA  ServerAConfig
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
	return &Config{
		HTTPPort: getEnv("HTTP_PORT", "3002"),
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
