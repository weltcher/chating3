// 简化版本发布脚本 - 只需提供下载URL
// 适用于所有平台，不需要上传文件到OSS
// 使用方法:
//   go run publish_version_simple.go -platform android -version 1.0.1 -code 2 -url "https://cdn.example.com/youdu_1.0.1.apk" -notes "更新说明"

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
)

// Config 配置
type Config struct {
	ServerURL string
}

// APIResponse API响应
type APIResponse struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

var config Config

func main() {
	// 解析命令行参数
	platform := flag.String("platform", "", "平台: windows, macos, linux, android, ios")
	version := flag.String("version", "", "版本号，如 1.0.1")
	versionCode := flag.String("code", "", "版本代码，如 2")
	downloadURL := flag.String("url", "", "下载地址URL")
	notes := flag.String("notes", "", "更新说明")
	fileSize := flag.Int64("size", 0, "文件大小（字节），可选")
	md5Hash := flag.String("md5", "", "MD5校验值，可选")
	forceUpdate := flag.Bool("force", false, "是否强制更新")
	serverURL := flag.String("server", "http://localhost:8080", "服务器地址")
	publish := flag.Bool("publish", false, "创建后立即发布")

	flag.Parse()

	// 验证必需参数
	if *platform == "" || *version == "" || *versionCode == "" || *downloadURL == "" {
		printUsage()
		os.Exit(1)
	}

	// 验证平台
	*platform = strings.ToLower(*platform)
	validPlatforms := []string{"windows", "macos", "linux", "android", "ios"}
	isValid := false
	for _, p := range validPlatforms {
		if *platform == p {
			isValid = true
			break
		}
	}
	if !isValid {
		fmt.Printf("错误: 平台必须是 %s 之一\n", strings.Join(validPlatforms, ", "))
		os.Exit(1)
	}

	config = Config{ServerURL: *serverURL}

	fmt.Println("\n╔════════════════════════════════════════╗")
	fmt.Println("║      简化版本发布工具 v1.0           ║")
	fmt.Println("╚════════════════════════════════════════╝")
	fmt.Printf("\n📦 平台: %s\n", strings.ToUpper(*platform))
	fmt.Printf("🏷️  版本: %s (代码: %s)\n", *version, *versionCode)
	fmt.Printf("🔗 下载地址: %s\n", *downloadURL)
	if *notes != "" {
		fmt.Printf("📝 说明: %s\n", *notes)
	}
	if *fileSize > 0 {
		fmt.Printf("💾 大小: %.2f MB\n", float64(*fileSize)/1024/1024)
	}
	if *md5Hash != "" {
		fmt.Printf("🔐 MD5: %s\n", *md5Hash)
	}
	if *forceUpdate {
		fmt.Println("⚠️  强制更新: 是")
	}
	fmt.Println("\n" + strings.Repeat("─", 42))

	// 创建版本记录
	fmt.Println("\n📝 [步骤 1/2] 创建版本记录...")
	versionID, err := createVersion(*platform, *version, *versionCode, *downloadURL, *notes, *forceUpdate, *fileSize, *md5Hash)
	if err != nil {
		fmt.Printf("❌ 错误: 创建版本记录失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("✅ 版本记录创建成功! (ID: %d)\n", versionID)

	// 发布版本（如果指定）
	if *publish {
		fmt.Println("\n🚀 [步骤 2/2] 发布版本...")
		if err := publishVersion(versionID); err != nil {
			fmt.Printf("❌ 错误: 发布版本失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✅ 版本发布成功!")
	} else {
		fmt.Println("\n⏭️  [步骤 2/2] 跳过发布（使用 -publish 参数可自动发布）")
	}

	fmt.Println("\n" + strings.Repeat("═", 42))
	fmt.Println("✨ 版本发布完成!")
	fmt.Println(strings.Repeat("═", 42))
	fmt.Printf("🆔 版本ID: %d\n", versionID)
	fmt.Printf("📦 平台: %s\n", strings.ToUpper(*platform))
	fmt.Printf("🏷️  版本号: %s (代码: %s)\n", *version, *versionCode)
	fmt.Printf("🔗 下载地址: %s\n", *downloadURL)
	if *publish {
		fmt.Println("📢 状态: 已发布")
	} else {
		fmt.Println("📝 状态: 草稿")
		fmt.Println("\n💡 提示: 版本当前为草稿状态，请在管理后台发布或使用 -publish 参数")
	}
	fmt.Println(strings.Repeat("═", 42))
}

func printUsage() {
	fmt.Println("用法:")
	fmt.Println("  go run publish_version_simple.go -platform <platform> -version <version> -code <code> -url <download_url> [options]")
	fmt.Println("\n必需参数:")
	fmt.Println("  -platform    平台: windows, macos, linux, android, ios")
	fmt.Println("  -version     版本号，如 1.0.1")
	fmt.Println("  -code        版本代码（数字），如 2")
	fmt.Println("  -url         下载地址URL")
	fmt.Println("\n可选参数:")
	fmt.Println("  -notes       更新说明")
	fmt.Println("  -size        文件大小（字节）")
	fmt.Println("  -md5         MD5校验值")
	fmt.Println("  -force       是否强制更新 (默认: false)")
	fmt.Println("  -server      服务器地址 (默认: http://localhost:8080)")
	fmt.Println("  -publish     创建后立即发布 (默认: false)")
	fmt.Println("\n示例:")
	fmt.Println("  # Android")
	fmt.Println("  go run publish_version_simple.go \\")
	fmt.Println("    -platform android \\")
	fmt.Println("    -version 1.0.1 \\")
	fmt.Println("    -code 2 \\")
	fmt.Println("    -url \"https://cdn.example.com/youdu_1.0.1.apk\" \\")
	fmt.Println("    -notes \"修复已知问题\" \\")
	fmt.Println("    -size 52428800 \\")
	fmt.Println("    -md5 \"abc123def456\" \\")
	fmt.Println("    -publish")
	fmt.Println("\n  # Windows")
	fmt.Println("  go run publish_version_simple.go \\")
	fmt.Println("    -platform windows \\")
	fmt.Println("    -version 1.0.1 \\")
	fmt.Println("    -code 2 \\")
	fmt.Println("    -url \"https://cdn.example.com/youdu_1.0.1.exe\" \\")
	fmt.Println("    -notes \"新功能\" \\")
	fmt.Println("    -publish")
	fmt.Println("\n  # iOS (TestFlight)")
	fmt.Println("  go run publish_version_simple.go \\")
	fmt.Println("    -platform ios \\")
	fmt.Println("    -version 1.0.1 \\")
	fmt.Println("    -code 2 \\")
	fmt.Println("    -url \"https://testflight.apple.com/join/xxx\" \\")
	fmt.Println("    -notes \"新版本\" \\")
	fmt.Println("    -publish")
}

func createVersion(platform, version, versionCode, downloadURL, notes string, forceUpdate bool, fileSize int64, md5Hash string) (int, error) {
	reqBody := map[string]interface{}{
		"platform":          platform,
		"version":           version,
		"package_url":       downloadURL,
		"release_notes":     notes,
		"is_force_update":   forceUpdate,
		"distribution_type": "url",
	}

	if fileSize > 0 {
		reqBody["file_size"] = fileSize
	}
	if md5Hash != "" {
		reqBody["file_hash"] = md5Hash
	}

	jsonData, err := json.Marshal(reqBody)
	if err != nil {
		return 0, fmt.Errorf("序列化请求失败: %v", err)
	}

	resp, err := http.Post(
		fmt.Sprintf("%s/api/app-versions", config.ServerURL),
		"application/json",
		bytes.NewBuffer(jsonData),
	)
	if err != nil {
		return 0, fmt.Errorf("请求失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return 0, fmt.Errorf("服务器返回错误状态码: %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, fmt.Errorf("解析响应失败: %v", err)
	}

	if message, ok := result["message"].(string); ok && message != "版本创建成功" {
		return 0, fmt.Errorf("创建失败: %s", message)
	}

	if id, ok := result["id"].(float64); ok {
		return int(id), nil
	}

	return 0, fmt.Errorf("无法获取版本ID")
}

func publishVersion(versionID int) error {
	req, err := http.NewRequest("POST", fmt.Sprintf("%s/api/app-versions/%d/publish", config.ServerURL, versionID), nil)
	if err != nil {
		return fmt.Errorf("创建请求失败: %v", err)
	}

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("请求失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("服务器返回错误状态码: %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("解析响应失败: %v", err)
	}

	if message, ok := result["message"].(string); ok && message != "版本发布成功" {
		return fmt.Errorf("发布失败: %s", message)
	}

	return nil
}
