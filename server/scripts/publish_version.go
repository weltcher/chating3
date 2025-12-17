// 版本发布脚本
// 用于录入版本信息并将升级包推送到OSS
// 支持 upsert 模式：如果平台版本不存在则新增，存在则更新
// 使用方法:
// iOS平台（只需URL，不需要本地文件）:
//   go run publish_version.go -platform ios -version 1.0.4 -url "https://apps.apple.com/app/yourapp/id123456789" -notes "新功能"
// Windows平台:
//   go run publish_version.go -platform windows -version 1.0.27-1765951695 -url "https://www.xn--wxtp0q.vip:443/download/1.0.27-1765951695.zip" -file "C:\Users\WIN10\source\flutter\chat\youdu2\build\windows\x64\runner\1.0.27-1765951695.zip" -notes "修复群组语音通话和数据同步等问题"
// Android平台:
//   go run publish_version.go -platform android -version 1.0.27-1765951695 -url "https://www.xn--wxtp0q.vip:443/download/1.0.27-1765951695.apk" -file "C:\Users\WIN10\source\flutter\chat\youdu2\build\app\outputs\flutter-apk\1.0.27-1765951695.apk" -notes "修复群组语音通话和数据同步等问题"
package main

import (
	"crypto/md5"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

// Config 配置
type Config struct {
	ServerURL    string
	OSSEndpoint  string
	OSSAccessKey string
	OSSSecretKey string
	OSSBucket    string
	// 数据库配置
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
}

// AppVersion 版本信息
type AppVersion struct {
	ID           int     `json:"id"`
	Version      string  `json:"version"`
	Platform     string  `json:"platform"`
	PackageURL   *string `json:"package_url"`
	OSSObjectKey *string `json:"oss_object_key"`
	Status       string  `json:"status"`
}

var config Config

func main() {
	// 解析命令行参数
	platform := flag.String("platform", "", "平台: windows, macos, linux, android, ios")
	version := flag.String("version", "", "版本号，如 1.0.0")
	filePath := flag.String("file", "", "升级包文件路径")
	distributionURL := flag.String("url", "", "下载地址URL（可替代文件上传）")
	notes := flag.String("notes", "", "升级说明")
	forceUpdate := flag.Bool("force", false, "是否强制更新")
	minVersion := flag.String("min-version", "", "最低支持版本")
	serverURL := flag.String("server", "http://localhost:8080", "服务器地址")
	publish := flag.Bool("publish", true, "创建后立即发布")
	deletePrevious := flag.Bool("delete-previous", false, "删除该平台的上一个版本的OSS文件")
	envFile := flag.String("env", "../.env", ".env文件路径")
	showSQL := flag.Bool("show-sql", true, "显示执行的SQL语句")

	flag.Parse()

	// 验证平台
	*platform = strings.ToLower(*platform)
	if *platform == "" || *version == "" {
		printUsage()
		os.Exit(1)
	}

	validPlatforms := []string{"windows", "macos", "linux", "android", "ios"}
	isValidPlatform := false
	for _, p := range validPlatforms {
		if *platform == p {
			isValidPlatform = true
			break
		}
	}
	if !isValidPlatform {
		fmt.Printf("错误: 平台必须是 %s 之一\n", strings.Join(validPlatforms, ", "))
		os.Exit(1)
	}

	// 确定模式：
	// 1. iOS URL模式：只提供 -url（iOS通过App Store分发，不需要本地文件）
	// 2. URL模式：提供 -url 和 -file（从本地文件计算MD5，不上传OSS）
	// 3. OSS上传模式：只提供 -file（上传到OSS）
	isIOS := *platform == "ios"
	useURLMode := *distributionURL != ""
	useOSSUpload := *filePath != "" && *distributionURL == ""

	if *distributionURL == "" && *filePath == "" {
		fmt.Println("错误: 必须提供 -url 下载地址 或 -file 文件路径")
		printUsage()
		os.Exit(1)
	}

	// iOS平台：必须提供 -url，不需要 -file
	if isIOS {
		if *distributionURL == "" {
			fmt.Println("错误: iOS平台必须提供 -url 参数（App Store或TestFlight链接）")
			printUsage()
			os.Exit(1)
		}
		// iOS不需要本地文件，忽略 -file 参数
		if *filePath != "" {
			fmt.Println("提示: iOS平台忽略 -file 参数，将只使用 -url")
			*filePath = ""
		}
	} else {
		// 非iOS平台：URL模式必须同时提供本地文件路径来计算MD5
		if useURLMode && *filePath == "" {
			fmt.Println("错误: URL模式必须同时提供 -file 参数来计算文件MD5和大小")
			printUsage()
			os.Exit(1)
		}
	}

	// 检查文件是否存在（非iOS平台且提供了文件路径时）
	if *filePath != "" {
		if _, err := os.Stat(*filePath); os.IsNotExist(err) {
			fmt.Printf("错误: 文件不存在: %s\n", *filePath)
			os.Exit(1)
		}
	}

	// 加载配置（URL模式不需要OSS配置）
	if err := loadConfig(*envFile, *serverURL, useURLMode); err != nil {
		fmt.Printf("错误: 加载配置失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("\n╔════════════════════════════════════════╗")
	fmt.Println("║       版本发布工具 v3.0 (Upsert)     ║")
	fmt.Println("╚════════════════════════════════════════╝")
	fmt.Printf("\n📦 平台: %s\n", strings.ToUpper(*platform))
	fmt.Printf("🏷️  版本: %s\n", *version)
	if isIOS && useURLMode {
		fmt.Printf("🔗 模式: iOS URL模式（App Store/TestFlight链接）\n")
		fmt.Printf("🌐 下载地址: %s\n", *distributionURL)
	} else if useURLMode {
		fmt.Printf("🔗 模式: URL下载地址（从本地文件计算MD5）\n")
		fmt.Printf("🌐 下载地址: %s\n", *distributionURL)
		fmt.Printf("📄 本地文件: %s\n", *filePath)
	} else if useOSSUpload {
		fmt.Printf("☁️  模式: 文件上传到OSS\n")
		fmt.Printf("📄 文件: %s\n", *filePath)
	}
	if *filePath != "" {
		if fileInfo, err := os.Stat(*filePath); err == nil {
			sizeMB := float64(fileInfo.Size()) / 1024 / 1024
			fmt.Printf("💾 大小: %.2f MB\n", sizeMB)
		}
	}
	if *notes != "" {
		fmt.Printf("📝 说明: %s\n", *notes)
	}
	fmt.Println("\n" + strings.Repeat("─", 42))

	var ossKey, fileURL, fileHash string
	var actualFileSize int64
	var err error
	var sqlStatement string
	var isUpdate bool

	if isIOS && useURLMode {
		// iOS URL模式：只需要URL，不需要本地文件
		fmt.Println("\n🍎 [步骤 1/2] iOS平台 - 使用App Store/TestFlight链接...")
		fileURL = *distributionURL
		ossKey = ""
		actualFileSize = 0  // iOS不需要文件大小
		fileHash = ""       // iOS不需要MD5
		fmt.Printf("✅ iOS版本信息已准备!\n")
		fmt.Printf("   🌐 下载地址: %s\n", fileURL)
		fmt.Println("   ℹ️  iOS通过App Store分发，无需文件大小和MD5")
	} else if useURLMode {
		// 非iOS URL模式：从本地文件计算MD5和大小，使用提供的URL
		fmt.Println("\n🔗 [步骤 1/2] 计算本地文件MD5和大小...")
		fileURL = *distributionURL
		ossKey = ""
		
		// 从本地文件计算MD5和大小
		actualFileSize, fileHash, err = calculateLocalFileMD5(*filePath)
		if err != nil {
			fmt.Printf("❌ 错误: 计算文件信息失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("✅ 文件信息已计算!\n")
		fmt.Printf("   🌐 下载地址: %s\n", fileURL)
		fmt.Printf("   💾 文件大小: %.2f MB (%d bytes)\n", float64(actualFileSize)/1024/1024, actualFileSize)
		fmt.Printf("   🔐 文件MD5: %s\n", fileHash)
	} else if useOSSUpload {
		// OSS上传模式
		if *deletePrevious {
			fmt.Println("\n🔍 [步骤 1/3] 检查并删除上一个版本...")
			if err := checkAndDeletePreviousVersion(*platform); err != nil {
				fmt.Printf("⚠️  警告: %v\n", err)
			}
		}

		fmt.Println("\n☁️  [步骤 2/3] 上传文件到OSS...")
		ossKey, fileURL, actualFileSize, fileHash, err = uploadToOSS(*filePath, *platform, *version)
		if err != nil {
			fmt.Printf("❌ 错误: 上传文件失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("✅ 上传成功!\n")
		fmt.Printf("   📦 OSS Key: %s\n", ossKey)
		fmt.Printf("   🌐 文件URL: %s\n", fileURL)
		fmt.Printf("   💾 文件大小: %.2f MB (%d bytes)\n", float64(actualFileSize)/1024/1024, actualFileSize)
		fmt.Printf("   🔐 文件MD5: %s\n", fileHash)
	}

	// Upsert版本记录（直接操作数据库）
	stepNum := "2/2"
	if useOSSUpload {
		stepNum = "3/3"
	}
	fmt.Printf("\n📝 [步骤 %s] Upsert版本记录...\n", stepNum)
	
	sqlStatement, isUpdate, err = upsertVersion(
		*platform, *version, fileURL, ossKey, *notes, 
		*forceUpdate, *minVersion, actualFileSize, fileHash, *publish,
	)
	if err != nil {
		fmt.Printf("❌ 错误: 版本记录操作失败: %v\n", err)
		os.Exit(1)
	}

	if isUpdate {
		fmt.Println("✅ 版本记录已更新!")
	} else {
		fmt.Println("✅ 版本记录已创建!")
	}

	// 显示SQL语句
	if *showSQL {
		fmt.Println("\n" + strings.Repeat("─", 42))
		fmt.Println("📋 执行的SQL语句:")
		fmt.Println(strings.Repeat("─", 42))
		fmt.Println(sqlStatement)
		fmt.Println(strings.Repeat("─", 42))
	}

	fmt.Println("\n" + strings.Repeat("═", 42))
	fmt.Println("✨ 版本发布完成!")
	fmt.Println(strings.Repeat("═", 42))
	fmt.Printf("📦 平台: %s\n", strings.ToUpper(*platform))
	fmt.Printf("🏷️  版本号: %s\n", *version)
	fmt.Printf("🌐 下载地址: %s\n", fileURL)
	if isUpdate {
		fmt.Println("🔄 操作: 更新已有版本")
	} else {
		fmt.Println("🆕 操作: 新增版本")
	}
	if *publish {
		fmt.Println("📢 状态: 已发布")
	} else {
		fmt.Println("📝 状态: 草稿")
	}
	fmt.Println(strings.Repeat("═", 42))
}

func printUsage() {
	fmt.Println("用法:")
	fmt.Println("  iOS平台:          go run publish_version.go -platform ios -version <version> -url <appstore_url> [options]")
	fmt.Println("  URL模式（推荐）:  go run publish_version.go -platform <platform> -version <version> -url <download_url> -file <local_file> [options]")
	fmt.Println("  OSS上传模式:      go run publish_version.go -platform <platform> -version <version> -file <file_path> [options]")
	fmt.Println("\n必需参数:")
	fmt.Println("  -platform    平台: windows, macos, linux, android, ios")
	fmt.Println("  -version     版本号，如 1.0.0")
	fmt.Println("  -url         下载地址URL（iOS平台必需；其他平台URL模式必需）")
	fmt.Println("  -file        本地升级包文件路径（iOS平台不需要；其他平台用于计算MD5和文件大小）")
	fmt.Println("\n可选参数:")
	fmt.Println("  -notes            升级说明")
	fmt.Println("  -force            是否强制更新 (默认: false)")
	fmt.Println("  -min-version      最低支持版本")
	fmt.Println("  -server           服务器地址 (默认: http://localhost:8080)")
	fmt.Println("  -publish          创建后立即发布 (默认: true)")
	fmt.Println("  -delete-previous  删除该平台的上一个版本的OSS文件 (默认: false)")
	fmt.Println("  -env              .env文件路径 (默认: ../.env)")
	fmt.Println("  -show-sql         显示执行的SQL语句 (默认: true)")
	fmt.Println("\n示例:")
	fmt.Println("  # iOS - 只需要App Store/TestFlight链接，不需要本地文件")
	fmt.Println("  go run publish_version.go -platform ios -version 1.0.2 \\")
	fmt.Println("    -url \"https://apps.apple.com/app/yourapp/id123456789\" -notes \"新功能\"")
	fmt.Println("\n  # Windows - URL模式（推荐：已上传到图床）")
	fmt.Println("  go run publish_version.go -platform windows -version 1.0.2 \\")
	fmt.Println("    -url \"https://youdu-chat2.oss-cn-beijing.aliyuncs.com/1.0.2.zip\" \\")
	fmt.Println("    -file \"C:\\build\\1.0.2.zip\" -notes \"修复bug\"")
	fmt.Println("\n  # Android - URL模式")
	fmt.Println("  go run publish_version.go -platform android -version 1.0.2 \\")
	fmt.Println("    -url \"https://youdu-chat2.oss-cn-beijing.aliyuncs.com/1.0.2.apk\" \\")
	fmt.Println("    -file \"./build/app.apk\" -notes \"新功能\"")
	fmt.Println("\n  # OSS上传模式（自动上传到OSS）")
	fmt.Println("  go run publish_version.go -platform windows -version 1.0.2 -file ./app.zip -notes \"修复bug\"")
}


func loadConfig(envFile, serverURL string, skipOSSCheck bool) error {
	// 加载.env文件
	if err := godotenv.Load(envFile); err != nil {
		fmt.Printf("警告: 无法加载.env文件: %v，将使用环境变量\n", err)
	}

	// 获取应用环境
	appEnv := os.Getenv("APP_ENV")
	if appEnv == "" {
		appEnv = "development"
	}

	// 根据环境选择OSS配置
	var ossEndpoint, ossAccessKey, ossSecretKey, ossBucket string
	if appEnv == "development" || appEnv == "debug" {
		ossEndpoint = os.Getenv("TEST_S3_ENDPOINT")
		ossAccessKey = os.Getenv("TEST_S3_ACCESS_KEY")
		ossSecretKey = os.Getenv("TEST_S3_SECRET_KEY")
		ossBucket = os.Getenv("TEST_S3_BUCKET")
		fmt.Printf("🔧 Debug模式: 使用测试OSS配置 (Bucket: %s)\n", ossBucket)
	} else {
		ossEndpoint = os.Getenv("S3_ENDPOINT")
		ossAccessKey = os.Getenv("S3_ACCESS_KEY")
		ossSecretKey = os.Getenv("S3_SECRET_KEY")
		ossBucket = os.Getenv("S3_BUCKET")
		fmt.Printf("🚀 生产模式: 使用正式OSS配置 (Bucket: %s)\n", ossBucket)
	}

	config = Config{
		ServerURL:    serverURL,
		OSSEndpoint:  ossEndpoint,
		OSSAccessKey: ossAccessKey,
		OSSSecretKey: ossSecretKey,
		OSSBucket:    ossBucket,
		DBHost:       os.Getenv("DB_HOST"),
		DBPort:       os.Getenv("DB_PORT"),
		DBUser:       os.Getenv("DB_USER"),
		DBPassword:   "postgres",
		DBName:       os.Getenv("DB_NAME"),
	}

	// 设置默认值
	if config.DBHost == "" {
		config.DBHost = "localhost"
	}
	if config.DBPort == "" {
		config.DBPort = "5432"
	}
	if config.DBUser == "" {
		config.DBUser = "postgres"
	}
	if config.DBPassword == "" {
		config.DBPassword = "postgres"
	}
	if config.DBName == "" {
		config.DBName = "youdu"
	}

	// URL模式不需要OSS配置
	if !skipOSSCheck {
		if config.OSSEndpoint == "" || config.OSSAccessKey == "" || config.OSSSecretKey == "" || config.OSSBucket == "" {
			return fmt.Errorf("OSS配置不完整，请检查环境变量或.env文件")
		}
	}

	return nil
}

// upsertVersion 插入或更新版本记录，返回执行的SQL语句
func upsertVersion(platform, version, packageURL, ossKey, notes string, 
	forceUpdate bool, minVersion string, fileSize int64, fileHash string, publish bool) (string, bool, error) {
	
	// 连接数据库
	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		config.DBHost, config.DBPort, config.DBUser, config.DBPassword, config.DBName)
	fmt.Println(connStr)
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		return "", false, fmt.Errorf("连接数据库失败: %v", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		return "", false, fmt.Errorf("数据库连接测试失败: %v", err)
	}

	// 检查该平台是否已存在版本记录
	var existingID int
	var existingVersion string
	err = db.QueryRow(`
		SELECT id, version FROM app_versions 
		WHERE platform = $1 AND status = 'published'
		ORDER BY created_at DESC 
		LIMIT 1
	`, platform).Scan(&existingID, &existingVersion)

	now := time.Now().Format("2006-01-02 15:04:05")
	status := "draft"
	if publish {
		status = "published"
	}

	// 根据是否有ossKey判断分发类型
	distributionType := "oss"
	if ossKey == "" {
		distributionType = "url"
	}

	var sqlStatement string
	var isUpdate bool

	if err == sql.ErrNoRows {
		// 不存在，执行INSERT
		isUpdate = false
		sqlStatement = fmt.Sprintf(`INSERT INTO app_versions (
    version, platform, distribution_type, package_url, oss_object_key,
    release_notes, status, is_force_update, min_supported_version,
    file_size, file_hash, created_at, updated_at, published_at
) VALUES (
    '%s', '%s', '%s', '%s', '%s',
    '%s', '%s', %t, '%s',
    %d, '%s', '%s', '%s', %s
);`,
			version, platform, distributionType, packageURL, ossKey,
			escapeSQL(notes), status, forceUpdate, minVersion,
			fileSize, fileHash, now, now, 
			func() string {
				if publish {
					return fmt.Sprintf("'%s'", now)
				}
				return "NULL"
			}())

		// 执行INSERT
		var publishedAt interface{}
		if publish {
			publishedAt = now
		} else {
			publishedAt = nil
		}

		_, err = db.Exec(`
			INSERT INTO app_versions (
				version, platform, distribution_type, package_url, oss_object_key,
				release_notes, status, is_force_update, min_supported_version,
				file_size, file_hash, created_at, updated_at, published_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
		`, version, platform, distributionType, packageURL, nullIfEmpty(ossKey),
			notes, status, forceUpdate, nullIfEmpty(minVersion),
			fileSize, nullIfEmpty(fileHash), now, now, publishedAt)

		if err != nil {
			return sqlStatement, false, fmt.Errorf("插入版本记录失败: %v", err)
		}

		fmt.Printf("   🆕 新增版本记录: %s (%s)\n", version, platform)

	} else if err != nil {
		return "", false, fmt.Errorf("查询版本记录失败: %v", err)
	} else {
		// 存在，执行UPDATE
		isUpdate = true
		sqlStatement = fmt.Sprintf(`UPDATE app_versions SET
    version = '%s',
    distribution_type = '%s',
    package_url = '%s',
    oss_object_key = '%s',
    release_notes = '%s',
    status = '%s',
    is_force_update = %t,
    min_supported_version = '%s',
    file_size = %d,
    file_hash = '%s',
    updated_at = '%s',
    published_at = %s
WHERE id = %d;`,
			version, distributionType, packageURL, ossKey,
			escapeSQL(notes), status, forceUpdate, minVersion,
			fileSize, fileHash, now,
			func() string {
				if publish {
					return fmt.Sprintf("'%s'", now)
				}
				return "NULL"
			}(),
			existingID)

		// 执行UPDATE
		var publishedAt interface{}
		if publish {
			publishedAt = now
		} else {
			publishedAt = nil
		}

		_, err = db.Exec(`
			UPDATE app_versions SET
				version = $1,
				distribution_type = $2,
				package_url = $3,
				oss_object_key = $4,
				release_notes = $5,
				status = $6,
				is_force_update = $7,
				min_supported_version = $8,
				file_size = $9,
				file_hash = $10,
				updated_at = $11,
				published_at = $12
			WHERE id = $13
		`, version, distributionType, packageURL, nullIfEmpty(ossKey),
			notes, status, forceUpdate, nullIfEmpty(minVersion),
			fileSize, nullIfEmpty(fileHash), now, publishedAt, existingID)

		if err != nil {
			return sqlStatement, false, fmt.Errorf("更新版本记录失败: %v", err)
		}

		fmt.Printf("   🔄 更新版本记录: %s -> %s (%s, ID: %d)\n", existingVersion, version, platform, existingID)
	}

	return sqlStatement, isUpdate, nil
}

// escapeSQL 转义SQL字符串中的单引号
func escapeSQL(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// nullIfEmpty 如果字符串为空则返回nil
func nullIfEmpty(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func checkAndDeletePreviousVersion(platform string) error {
	fmt.Printf("   🔍 正在查询 %s 平台的最新版本...\n", strings.ToUpper(platform))
	resp, err := http.Get(fmt.Sprintf("%s/api/version/latest?platform=%s", config.ServerURL, platform))
	if err != nil {
		return fmt.Errorf("请求失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		fmt.Printf("   ℹ️  %s 平台没有找到上一个版本，跳过删除\n", strings.ToUpper(platform))
		return nil
	}

	if resp.StatusCode != 200 {
		return fmt.Errorf("获取版本信息失败，状态码: %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("解析响应失败: %v", err)
	}

	versionData, ok := result["version"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("解析版本数据失败")
	}

	ossKeyInterface := versionData["oss_object_key"]
	if ossKeyInterface != nil {
		ossKey, ok := ossKeyInterface.(string)
		if ok && ossKey != "" {
			fmt.Printf("   🗑️  OSS Key: %s\n", ossKey)
			fmt.Println("   🔄 正在删除该版本的OSS文件...")
			if err := deleteOSSFile(ossKey); err != nil {
				return fmt.Errorf("删除OSS文件失败: %v", err)
			}
			fmt.Printf("   ✅ %s 平台的上一个版本OSS文件已删除\n", strings.ToUpper(platform))
		}
	} else {
		fmt.Printf("   ℹ️  %s 平台的上一个版本没有OSS文件\n", strings.ToUpper(platform))
	}

	return nil
}

// ProgressReader 带进度显示的Reader
type ProgressReader struct {
	reader    io.Reader
	total     int64
	current   int64
	lastPrint time.Time
}

func (pr *ProgressReader) Read(p []byte) (int, error) {
	n, err := pr.reader.Read(p)
	pr.current += int64(n)

	now := time.Now()
	if now.Sub(pr.lastPrint) >= 100*time.Millisecond || err == io.EOF {
		pr.lastPrint = now
		pr.printProgress()
	}

	return n, err
}

func (pr *ProgressReader) printProgress() {
	percent := float64(pr.current) / float64(pr.total) * 100
	currentMB := float64(pr.current) / 1024 / 1024
	totalMB := float64(pr.total) / 1024 / 1024
	
	barWidth := 30
	filled := int(percent / 100 * float64(barWidth))
	bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
	
	fmt.Printf("\r   📤 上传进度: [%s] %.1f%% | %.2f/%.2f MB", 
		bar, percent, currentMB, totalMB)
	
	if pr.current >= pr.total {
		fmt.Println()
	}
}

func uploadToOSS(filePath, platform, version string) (ossKey, fileURL string, fileSize int64, fileHash string, err error) {
	client, err := oss.New(config.OSSEndpoint, config.OSSAccessKey, config.OSSSecretKey)
	if err != nil {
		return "", "", 0, "", fmt.Errorf("创建OSS客户端失败: %v", err)
	}

	bucket, err := client.Bucket(config.OSSBucket)
	if err != nil {
		return "", "", 0, "", fmt.Errorf("获取Bucket失败: %v", err)
	}

	file, err := os.Open(filePath)
	if err != nil {
		return "", "", 0, "", fmt.Errorf("打开文件失败: %v", err)
	}
	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		return "", "", 0, "", fmt.Errorf("获取文件信息失败: %v", err)
	}
	fileSize = fileInfo.Size()

	fmt.Printf("   🔐 正在计算文件MD5...\n")
	hash := md5.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", "", 0, "", fmt.Errorf("计算MD5失败: %v", err)
	}
	fileHash = hex.EncodeToString(hash.Sum(nil))
	fmt.Printf("   ✅ MD5: %s\n", fileHash)

	file.Seek(0, 0)

	ext := filepath.Ext(filePath)
	ossKey = fmt.Sprintf("%s%s", version, ext)
	fmt.Printf("   📦 OSS路径: %s\n", ossKey)

	progressReader := &ProgressReader{
		reader:    file,
		total:     fileSize,
		current:   0,
		lastPrint: time.Now(),
	}

	fmt.Printf("   ☁️  开始上传到OSS (%.2f MB)...\n", float64(fileSize)/1024/1024)
	if err := bucket.PutObject(ossKey, progressReader); err != nil {
		return "", "", 0, "", fmt.Errorf("上传文件失败: %v", err)
	}
	fmt.Printf("   ✅ 上传完成!\n")

	endpointHost := strings.TrimPrefix(config.OSSEndpoint, "https://")
	endpointHost = strings.TrimPrefix(endpointHost, "http://")
	fileURL = fmt.Sprintf("https://%s.%s/%s", config.OSSBucket, endpointHost, ossKey)

	return ossKey, fileURL, fileSize, fileHash, nil
}

func deleteOSSFile(objectKey string) error {
	client, err := oss.New(config.OSSEndpoint, config.OSSAccessKey, config.OSSSecretKey)
	if err != nil {
		return fmt.Errorf("创建OSS客户端失败: %v", err)
	}

	bucket, err := client.Bucket(config.OSSBucket)
	if err != nil {
		return fmt.Errorf("获取Bucket失败: %v", err)
	}

	return bucket.DeleteObject(objectKey)
}

// calculateLocalFileMD5 计算本地文件的MD5和大小（不上传）
func calculateLocalFileMD5(filePath string) (fileSize int64, fileHash string, err error) {
	file, err := os.Open(filePath)
	if err != nil {
		return 0, "", fmt.Errorf("打开文件失败: %v", err)
	}
	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		return 0, "", fmt.Errorf("获取文件信息失败: %v", err)
	}
	fileSize = fileInfo.Size()

	fmt.Printf("   🔐 正在计算文件MD5...\n")
	hash := md5.New()
	if _, err := io.Copy(hash, file); err != nil {
		return 0, "", fmt.Errorf("计算MD5失败: %v", err)
	}
	fileHash = hex.EncodeToString(hash.Sum(nil))

	return fileSize, fileHash, nil
}
