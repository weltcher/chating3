package config

import (
	"fmt"
	"os"
	"strconv"

	"github.com/spf13/viper"
)

type Config struct {
	// Database
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	DBSSLMode  string

	// Server
	ServerPort string
	ServerHost string

	// WebSocket
	WSPort string
	WSHost string

	// HTTPS/TLS
	EnableHTTPS bool
	CertFile    string
	KeyFile     string

	// JWT
	JWTSecret string

	// Verification Code
	VerifyCodeExpireMinutes int

	// Application
	AppEnv string

	// Agora
	AgoraAppID          string
	AgoraAppCertificate string

	// Redis
	RedisHost     string
	RedisPort     string
	RedisPassword string
	RedisDB       int

	// OSS/S3 (根据环境自动选择)
	S3Endpoint  string
	S3AccessKey string
	S3SecretKey string
	S3Bucket    string

	// Email SMTP
	SMTPHost     string
	SMTPPort     int
	SMTPUser     string
	SMTPPassword string
	SMTPFrom     string
}

var AppConfig *Config

// LoadConfig 加载配置
func LoadConfig(debugMode bool) {
	// 根据调试模式选择配置文件
	var configFile string
	if debugMode {
		configFile = ".env.development"
		fmt.Println("🔧 调试模式: 使用 .env.development 配置文件")
	} else {
		configFile = ".env"
		fmt.Println("🚀 生产模式: 使用 .env 配置文件")
	}

	// 设置配置文件
	viper.SetConfigFile(configFile)
	viper.SetConfigType("env")

	// 自动读取环境变量
	viper.AutomaticEnv()

	// 读取配置文件（如果存在）
	if err := viper.ReadInConfig(); err != nil {
		fmt.Printf("Warning: %s file not found, using environment variables\n", configFile)
	}

	verifyExpire, _ := strconv.Atoi(getEnvViper("VERIFY_CODE_EXPIRE_MINUTES", "5"))
	redisDB, _ := strconv.Atoi(getEnvViper("REDIS_DB", "0"))
	smtpPort, _ := strconv.Atoi(getEnvViper("SMTP_PORT", "465"))

	// 获取应用环境
	appEnv := getEnvViper("APP_ENV", "development")
	
	// Debug模式（development）下默认使用HTTP，生产环境默认使用HTTPS
	// 可以通过ENABLE_HTTPS环境变量显式覆盖
	enableHTTPS := getEnvViper("ENABLE_HTTPS", "false") == "true"
	if appEnv == "development" || appEnv == "debug" {
		// Debug模式下，除非显式设置ENABLE_HTTPS=true，否则使用HTTP
		enableHTTPS = getEnvViper("ENABLE_HTTPS", "false") == "true"
	} else {
		// 生产环境下，除非显式设置ENABLE_HTTPS=false，否则使用HTTPS
		enableHTTPS = getEnvViper("ENABLE_HTTPS", "true") == "true"
	}

	// OSS/S3配置：根据环境自动选择
	var s3Endpoint, s3AccessKey, s3SecretKey, s3Bucket string
	if appEnv == "development" || appEnv == "debug" {
		// Debug模式使用TEST_S3配置
		s3Endpoint = getEnvViper("TEST_S3_ENDPOINT", "")
		s3AccessKey = getEnvViper("TEST_S3_ACCESS_KEY", "")
		s3SecretKey = getEnvViper("TEST_S3_SECRET_KEY", "")
		s3Bucket = getEnvViper("TEST_S3_BUCKET", "")
		fmt.Printf("🔧 Debug模式: 使用测试OSS配置 (Endpoint: %s, Bucket: %s)\n", s3Endpoint, s3Bucket)
	} else {
		// 生产环境使用正式S3配置
		s3Endpoint = getEnvViper("S3_ENDPOINT", "")
		s3AccessKey = getEnvViper("S3_ACCESS_KEY", "")
		s3SecretKey = getEnvViper("S3_SECRET_KEY", "")
		s3Bucket = getEnvViper("S3_BUCKET", "")
		fmt.Printf("🚀 生产模式: 使用正式OSS配置 (Endpoint: %s, Bucket: %s)\n", s3Endpoint, s3Bucket)
	}

	AppConfig = &Config{
		DBHost:                  getEnvViper("DB_HOST", "127.0.0.1"),
		DBPort:                  getEnvViper("DB_PORT", "5432"),
		DBUser:                  getEnvViper("DB_USER", "postgres"),
		DBPassword:              getEnvViper("PASSWORD2", "postgres"),
		DBName:                  getEnvViper("DB_NAME", "youdu_db"),
		DBSSLMode:               getEnvViper("DB_SSLMODE", "disable"),
		ServerPort:              getEnvViper("SERVER_PORT", "8080"),
		ServerHost:              getEnvViper("SERVER_HOST", "0.0.0.0"),
		WSPort:                  getEnvViper("WS_PORT", "8081"),
		WSHost:                  getEnvViper("WS_HOST", "0.0.0.0"),
		EnableHTTPS:             enableHTTPS,
		CertFile:                getEnvViper("CERT_FILE", "certs/server.crt"),
		KeyFile:                 getEnvViper("KEY_FILE", "certs/server.key"),
		JWTSecret:               getEnvViper("JWT_SECRET", "your_jwt_secret_key"),
		VerifyCodeExpireMinutes: verifyExpire,
		AppEnv:                  appEnv,
		AgoraAppID:              getEnvViper("AGORA_APP_ID", ""),
		AgoraAppCertificate:     getEnvViper("AGORA_APP_CERTIFICATE", ""),
		RedisHost:               getEnvViper("REDIS_HOST", "127.0.0.1"),
		RedisPort:               getEnvViper("REDIS_PORT", "6379"),
		RedisPassword:           getEnvViper("REDIS_PASSWORD", ""),
		RedisDB:                 redisDB,
		S3Endpoint:              s3Endpoint,
		S3AccessKey:             s3AccessKey,
		S3SecretKey:             s3SecretKey,
		S3Bucket:                s3Bucket,
		SMTPHost:                getEnvViper("SMTP_HOST", ""),
		SMTPPort:                smtpPort,
		SMTPUser:                getEnvViper("SMTP_USER", ""),
		SMTPPassword:            getEnvViper("SMTP_PASSWORD", ""),
		SMTPFrom:                getEnvViper("SMTP_FROM", ""),
	}
}

// getEnvViper 使用 Viper 获取环境变量，如果不存在则返回默认值
func getEnvViper(key, defaultValue string) string {
	viper.SetDefault(key, defaultValue)
	return viper.GetString(key)
}

// getEnv 获取环境变量，如果不存在则返回默认值（保持向后兼容）
func getEnv(key, defaultValue string) string {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return value
}
