package db

import (
	"database/sql"
	"fmt"

	"youdu-server/config"

	_ "github.com/lib/pq"
)

var DB *sql.DB

// InitDB 初始化数据库连接
func InitDB() error {
	cfg := config.AppConfig

	// 调试输出
	fmt.Printf("数据库配置:\n")
	fmt.Printf("  Host: %s\n", cfg.DBHost)
	fmt.Printf("  Port: %s\n", cfg.DBPort)
	fmt.Printf("  User: %s\n", cfg.DBUser)
	fmt.Printf("  Password: %s (len=%d)\n", cfg.DBPassword, len(cfg.DBPassword))
	fmt.Printf("  DBName: %s\n", cfg.DBName)
	fmt.Printf("  SSLMode: %s\n", cfg.DBSSLMode)

	connStr := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=%s",
		cfg.DBHost,
		cfg.DBPort,
		cfg.DBUser,
		cfg.DBPassword,
		cfg.DBName,
		cfg.DBSSLMode,
	)
	fmt.Printf("连接字符串: %s\n", connStr)

	var err error
	DB, err = sql.Open("postgres", connStr)
	if err != nil {
		fmt.Printf("failed to open database: %w", err)
		return err
	}

	// 测试数据库连接
	if err = DB.Ping(); err != nil {
		fmt.Printf("failed to ping database: %w", err)
		return err
	}

	// 设置连接池参数
	DB.SetMaxOpenConns(25)
	DB.SetMaxIdleConns(5)

	// 🔴 设置数据库会话时区为 UTC
	// 服务器代码使用 time.Now().UTC() 存储 UTC 时间
	// 客户端收到带 Z 后缀的时间后会转换为本地时间显示
	_, err = DB.Exec("SET TIME ZONE 'UTC'")
	if err != nil {
		fmt.Printf("⚠️ 设置数据库时区失败: %v\n", err)
		// 不返回错误，继续运行
	} else {
		fmt.Printf("✅ 数据库时区已设置为 UTC\n")
	}

	fmt.Printf("Database connected successfully")
	return nil
}

// CloseDB 关闭数据库连接
func CloseDB() {
	if DB != nil {
		DB.Close()
		fmt.Printf("Database connection closed")
	}
}
