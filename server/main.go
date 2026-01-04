package main

import (
	"flag"
	"time"
	"youdu-server/config"
	"youdu-server/db"
	"youdu-server/routes"
	"youdu-server/utils"
	ws "youdu-server/websocket"
)

func main() {
	// 解析命令行参数
	debugMode := flag.Bool("debug", false, "启用调试模式，使用 .env.development 配置文件")
	overseasMode := flag.Bool("overseas", false, "启用海外模式，使用 .env.overseas 配置文件")
	flag.Parse()

	// 初始化日志系统
	logFile, err := utils.InitLogger("logs")
	if err != nil {
		utils.LogFatal("日志系统初始化失败: %v", err)
	}
	defer utils.CloseLogger()
	defer logFile.Close()

	// 加载配置（先加载配置，再根据配置设置日志级别）
	config.LoadConfig(*debugMode, *overseasMode)

	// 设置日志级别（根据命令行参数或配置文件中的 APP_ENV）
	// --debug 参数或 APP_ENV=debug/development 都会启用 DEBUG 日志
	if *debugMode || config.AppConfig.AppEnv == "debug" || config.AppConfig.AppEnv == "development" {
		utils.SetLogLevel(utils.DEBUG) // 调试模式开启DEBUG日志
		utils.LogInfo("========== 应用启动 (调试模式, APP_ENV=%s) ==========", config.AppConfig.AppEnv)
	} else {
		utils.SetLogLevel(utils.INFO) // 生产模式使用INFO日志
		utils.LogInfo("========== 应用启动 (生产模式) ==========")
	}
	utils.LogInfo("✅ 配置加载成功")

	// 初始化数据库
	if err := db.InitDB(); err != nil {
		utils.LogFatal("数据库连接失败: %v", err)
	}
	defer db.CloseDB()
	utils.LogInfo("✅ 数据库连接成功")

	// 初始化Redis
	if err := utils.InitRedis(); err != nil {
		utils.LogFatal("Redis连接失败: %v", err)
	}
	defer utils.CloseRedis()
	utils.LogInfo("✅ Redis连接成功")

	// 加载已解散的群组到内存 - 暂时禁用（groups表不存在）
	// disbandedManager := models.GetDisbandedGroupsManager()
	// if err := disbandedManager.LoadDisbandedGroups(); err != nil {
	// 	utils.LogFatal("加载已解散群组失败: %v", err)
	// }
	// utils.LogInfo("✅ 已解散群组管理器初始化成功")

	// 创建并启动WebSocket Hub
	hub := ws.NewHub()
	go hub.Run()
	utils.LogInfo("✅ WebSocket Hub已启动")

	// 启动心跳检查定时器（每15秒检查一次）
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			hub.CheckHeartbeat()
		}
	}()

	// 设置HTTP API路由
	apiRouter := routes.SetupRouter(hub)

	// 设置WebSocket路由（独立端口）
	wsRouter := routes.SetupWebSocketRouter(hub)

	// 启动HTTP/HTTPS API服务器
	serverAddr := config.AppConfig.ServerHost + ":" + config.AppConfig.ServerPort
	wsAddr := config.AppConfig.WSHost + ":" + config.AppConfig.WSPort

	if config.AppConfig.EnableHTTPS {
		// HTTPS模式
		utils.LogInfo("🚀 HTTPS API服务器启动在 https://%s", serverAddr)
		utils.LogInfo("🚀 WSS服务器启动在 wss://%s", wsAddr)
		utils.LogInfo("📜 证书文件: %s", config.AppConfig.CertFile)
		utils.LogInfo("🔑 密钥文件: %s", config.AppConfig.KeyFile)

		// 在单独的goroutine中启动WSS服务器
		go func() {
			if err := wsRouter.RunTLS(wsAddr, config.AppConfig.CertFile, config.AppConfig.KeyFile); err != nil {
				utils.LogFatal("WSS服务器启动失败: %v", err)
			}
		}()

		// 启动HTTPS API服务器（主线程）
		if err := apiRouter.RunTLS(serverAddr, config.AppConfig.CertFile, config.AppConfig.KeyFile); err != nil {
			utils.LogFatal("HTTPS API服务器启动失败: %v", err)
		}
	} else {
		// HTTP模式
		utils.LogInfo("🚀 HTTP API服务器启动在 http://%s", serverAddr)
		utils.LogInfo("🚀 WebSocket服务器启动在 ws://%s", wsAddr)

		// 在单独的goroutine中启动WebSocket服务器
		go func() {
			if err := wsRouter.Run(wsAddr); err != nil {
				utils.LogFatal("WebSocket服务器启动失败: %v", err)
			}
		}()

		// 启动HTTP API服务器（主线程）
		if err := apiRouter.Run(serverAddr); err != nil {
			utils.LogFatal("HTTP API服务器启动失败: %v", err)
		}
	}
}
