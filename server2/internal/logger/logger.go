package logger

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"
)

// 日志级别
type LogLevel int

const (
	DEBUG LogLevel = iota
	INFO
	WARNING
	ERROR
	FATAL
)

var (
	levelNames = map[LogLevel]string{
		DEBUG:   "DEBUG",
		INFO:    "INFO ",
		WARNING: "WARN ",
		ERROR:   "ERROR",
		FATAL:   "FATAL",
	}

	levelIcons = map[LogLevel]string{
		DEBUG:   "🔍",
		INFO:    "ℹ️",
		WARNING: "⚠️",
		ERROR:   "❌",
		FATAL:   "💀",
	}

	currentLogLevel = INFO // 默认日志级别
	logger          *log.Logger
	logFile         *os.File
)

// InitLogger 初始化日志系统
// 自动按日期创建日志文件，同时输出到控制台
// 如果 enableFileLog 为 false，则只输出到控制台，不写入文件
func InitLogger(logDir string, enableFileLog bool) (*os.File, error) {
	now := time.Now()
	
	if !enableFileLog {
		// 只输出到控制台
		logger = log.New(os.Stdout, "", 0)
		
		// 写入启动标记
		separator := "================================================================================"
		logger.Printf("\n%s\n", separator)
		logger.Printf("服务器B启动时间: %s\n", now.Format("2006-01-02 15:04:05"))
		logger.Printf("日志模式: 仅控制台输出（文件日志已禁用）\n")
		logger.Printf("%s\n", separator)
		
		LogInfo("✅ 日志系统初始化成功（仅控制台输出）")
		
		return nil, nil
	}
	
	// 启用文件日志
	// 创建日志目录
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return nil, fmt.Errorf("创建日志目录失败: %v", err)
	}

	// 生成日志文件名（按日期）
	dateStr := now.Format("2006-01-02")
	logFileName := fmt.Sprintf("server2_%s.log", dateStr)
	logFilePath := filepath.Join(logDir, logFileName)

	// 打开日志文件（追加模式）
	var err error
	logFile, err = os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		return nil, fmt.Errorf("打开日志文件失败: %v", err)
	}

	// 同时输出到文件和控制台
	multiWriter := io.MultiWriter(os.Stdout, logFile)

	// 创建logger（不带前缀，我们自己格式化）
	logger = log.New(multiWriter, "", 0)

	// 写入启动标记
	separator := "================================================================================"
	logger.Printf("\n%s\n", separator)
	logger.Printf("服务器B启动时间: %s\n", now.Format("2006-01-02 15:04:05"))
	logger.Printf("日志文件路径: %s\n", logFilePath)
	logger.Printf("%s\n", separator)

	// 清理旧日志文件（保留最近7天）
	go cleanOldLogs(logDir, 7)

	LogInfo("✅ 日志系统初始化成功（文件+控制台输出）")

	return logFile, nil
}

// cleanOldLogs 清理旧日志文件
func cleanOldLogs(logDir string, keepDays int) {
	entries, err := os.ReadDir(logDir)
	if err != nil {
		LogError("读取日志目录失败: %v", err)
		return
	}

	now := time.Now()
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		// 只处理 .log 文件
		if filepath.Ext(entry.Name()) != ".log" {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		// 删除超过 keepDays 天的文件
		age := now.Sub(info.ModTime())
		if age > time.Duration(keepDays)*24*time.Hour {
			filePath := filepath.Join(logDir, entry.Name())
			if err := os.Remove(filePath); err != nil {
				LogError("删除旧日志失败 %s: %v", filePath, err)
			} else {
				LogInfo("🗑️ 删除旧日志: %s", entry.Name())
			}
		}
	}
}

// SetLogLevel 设置日志级别
func SetLogLevel(level LogLevel) {
	currentLogLevel = level
	LogInfo("📊 日志级别已设置为: %s", levelNames[level])
}

// logMessage 统一的日志输出方法
func logMessage(level LogLevel, format string, args ...interface{}) {
	if level < currentLogLevel {
		return
	}

	if logger == nil {
		// 如果logger未初始化，使用标准输出
		fmt.Printf(format+"\n", args...)
		return
	}

	// 格式化时间戳
	timestamp := time.Now().Format("15:04:05.000")

	// 格式化消息
	message := fmt.Sprintf(format, args...)

	// 输出格式：[时间] 图标 [级别] 消息
	logger.Printf("[%s] %s [%s] %s",
		timestamp,
		levelIcons[level],
		levelNames[level],
		message,
	)
}

// LogDebug 调试日志
func LogDebug(format string, args ...interface{}) {
	logMessage(DEBUG, format, args...)
}

// LogInfo 信息日志
func LogInfo(format string, args ...interface{}) {
	logMessage(INFO, format, args...)
}

// LogWarning 警告日志
func LogWarning(format string, args ...interface{}) {
	logMessage(WARNING, format, args...)
}

// LogError 错误日志
func LogError(format string, args ...interface{}) {
	logMessage(ERROR, format, args...)
}

// LogFatal 致命错误日志（会退出程序）
func LogFatal(format string, args ...interface{}) {
	logMessage(FATAL, format, args...)
	if logFile != nil {
		logFile.Close()
	}
	os.Exit(1)
}

// CloseLogger 关闭日志系统
func CloseLogger() {
	if logFile != nil {
		LogInfo("📕 关闭日志系统")
		logFile.Close()
		logFile = nil
	}
}

// GetLogFilePath 获取当前日志文件路径
func GetLogFilePath() string {
	if logFile != nil {
		return logFile.Name()
	}
	return ""
}

// GetLogger 获取标准logger（用于兼容现有代码）
func GetLogger() *log.Logger {
	if logger == nil {
		return log.New(os.Stdout, "", log.LstdFlags)
	}
	return logger
}

