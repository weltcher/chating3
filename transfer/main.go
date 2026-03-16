package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
	"github.com/joho/godotenv"
)

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fmt.Fprintf(os.Stderr, "环境变量 %s 未设置\n", key)
		os.Exit(1)
	}
	return v
}

func main() {
	// 加载 .env 文件（文件不存在时使用系统环境变量）
	_ = godotenv.Load()

	// A 账号配置
	aEndpoint  := mustEnv("A_OSS_ENDPOINT")
	aAccessKey := mustEnv("A_OSS_ACCESS_KEY")
	aSecretKey := mustEnv("A_OSS_SECRET_KEY")
	aBucket    := mustEnv("A_OSS_BUCKET")

	// B 账号配置
	bEndpoint  := mustEnv("B_OSS_ENDPOINT")
	bAccessKey := mustEnv("B_OSS_ACCESS_KEY")
	bSecretKey := mustEnv("B_OSS_SECRET_KEY")
	bBucket    := mustEnv("B_OSS_BUCKET")

	// ── 1. 初始化 A 账号客户端 ──────────────────────────────────────
	aClient, err := oss.New(aEndpoint, aAccessKey, aSecretKey)
	if err != nil {
		fmt.Printf("创建A账号OSS客户端失败: %v\n", err)
		os.Exit(1)
	}
	aBkt, err := aClient.Bucket(aBucket)
	if err != nil {
		fmt.Printf("获取A账号bucket失败: %v\n", err)
		os.Exit(1)
	}

	// ── 2. 获取根目录下第一个目录 ────────────────────────────────────
	rootResult, err := aBkt.ListObjects(
		oss.Delimiter("/"),
		oss.MaxKeys(10),
	)
	if err != nil {
		fmt.Printf("列举根目录失败: %v\n", err)
		os.Exit(1)
	}
	if len(rootResult.CommonPrefixes) == 0 {
		fmt.Println("A账号bucket根目录下没有找到任何目录，退出。")
		os.Exit(0)
	}
	firstDir := rootResult.CommonPrefixes[0]
	fmt.Printf("第一个目录: %s\n", firstDir)

	// ── 3. 获取该目录下第一个文件 ────────────────────────────────────
	dirResult, err := aBkt.ListObjects(
		oss.Prefix(firstDir),
		oss.MaxKeys(10),
	)
	if err != nil {
		fmt.Printf("列举目录 [%s] 下的文件失败: %v\n", firstDir, err)
		os.Exit(1)
	}
	if len(dirResult.Objects) == 0 {
		fmt.Printf("目录 [%s] 下没有文件，退出。\n", firstDir)
		os.Exit(0)
	}
	firstFile := dirResult.Objects[0].Key
	fmt.Printf("第一个文件: %s\n", firstFile)

	// ── 4. 从 A 账号下载该文件 ───────────────────────────────────────
	fmt.Println("正在从A账号下载文件...")
	body, err := aBkt.GetObject(firstFile)
	if err != nil {
		fmt.Printf("下载文件失败: %v\n", err)
		os.Exit(1)
	}
	defer body.Close()

	data, err := io.ReadAll(body)
	if err != nil {
		fmt.Printf("读取文件内容失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("下载成功，文件大小: %d 字节\n", len(data))

	// ── 5. 初始化 B 账号客户端 ──────────────────────────────────────
	bClient, err := oss.New(bEndpoint, bAccessKey, bSecretKey)
	if err != nil {
		fmt.Printf("创建B账号OSS客户端失败: %v\n", err)
		os.Exit(1)
	}
	bBkt, err := bClient.Bucket(bBucket)
	if err != nil {
		fmt.Printf("获取B账号bucket失败: %v\n", err)
		os.Exit(1)
	}

	// ── 6. 上传到 B 账号（路径与 A 账号完全相同，OSS自动处理目录）──
	fmt.Printf("正在上传到B账号，路径: %s ...\n", firstFile)
	err = bBkt.PutObject(firstFile, bytes.NewReader(data))
	if err != nil {
		fmt.Printf("上传到B账号失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("✅ 传输完成！文件 [%s] 已成功从A账号复制到B账号。\n", firstFile)
}
