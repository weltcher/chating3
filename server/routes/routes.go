package routes

import (
	"youdu-server/controllers"
	"youdu-server/middleware"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
)

// SetupRouter 设置路由
func SetupRouter(hub *ws.Hub) *gin.Engine {
	// 使用 gin.New() 而不是 gin.Default()，以便使用自定义日志中间件
	router := gin.New()

	// 使用恢复中间件（处理panic）
	router.Use(gin.Recovery())

	// 使用自定义日志中间件（记录所有请求和响应）
	router.Use(middleware.LoggerMiddleware())

	// 使用跨域中间件
	router.Use(middleware.CORS())

	// 创建控制器
	authCtrl := controllers.NewAuthController()
	configCtrl := controllers.NewConfigController()
	userCtrl := controllers.NewUserController(hub)
	messageCtrl := controllers.NewMessageController(hub)
	contactCtrl := controllers.NewContactController(hub)
	uploadCtrl := controllers.NewUploadController()
	ossCtrl := controllers.NewOSSController()
	favoriteCtrl := controllers.NewFavoriteController()
	favoriteCommonCtrl := controllers.NewFavoriteCommonController()
	groupCtrl := controllers.NewGroupController(hub)
	fileAssistantCtrl := controllers.NewFileAssistantController()
	callCtrl := controllers.NewCallController(hub)
	deviceCtrl := controllers.NewDeviceController()
	appVersionCtrl := controllers.NewAppVersionController()

	// API路由组
	api := router.Group("/api")
	{
		// 认证相关路由
		auth := api.Group("/auth")
		{
			auth.POST("/register", authCtrl.Register)                     // 注册
			auth.POST("/login", authCtrl.Login)                           // 账号密码登录
			auth.POST("/verify-code/send", authCtrl.SendVerificationCode) // 发送验证码
			auth.POST("/verify-code/login", authCtrl.VerifyCodeLogin)     // 验证码登录
			auth.POST("/forgot-password", authCtrl.ForgotPassword)        // 忘记密码
		}

		// 配置相关路由
		config := api.Group("/config")
		{
			config.GET("/server", configCtrl.GetServerSettings)                // 获取所有服务器设置
			config.GET("/server/:key", configCtrl.GetServerSetting)            // 获取单个服务器设置
			config.POST("/server", configCtrl.UpdateServerSetting)             // 更新单个服务器设置
			config.POST("/server/batch", configCtrl.BatchUpdateServerSettings) // 批量更新服务器设置
		}

		// 设备相关路由（不需要认证，首次启动时使用）
		device := api.Group("/device")
		{
			device.POST("/register", deviceCtrl.RegisterDevice) // 注册设备信息（首次启动）
			device.GET("/stats", deviceCtrl.GetDeviceStats)     // 获取设备统计信息（管理用）
		}

		// 版本更新相关路由（客户端检查更新，不需要认证）
		version := api.Group("/version")
		{
			version.GET("/check", appVersionCtrl.CheckUpdate)                      // 检查更新
			version.GET("/latest", appVersionCtrl.GetLatestVersion)                // 获取指定平台最新版本
			version.GET("/all-platforms", appVersionCtrl.GetAllPlatformLatestVersions) // 获取所有平台最新版本
		}

		// 版本管理路由（管理后台使用）
		appVersion := api.Group("/app-versions")
		{
			appVersion.POST("", appVersionCtrl.CreateVersion)              // 创建版本
			appVersion.GET("", appVersionCtrl.ListVersions)                // 获取版本列表
			appVersion.GET("/:id", appVersionCtrl.GetVersion)              // 获取版本详情
			appVersion.PUT("/:id", appVersionCtrl.UpdateVersion)           // 更新版本信息
			appVersion.POST("/:id/publish", appVersionCtrl.PublishVersion) // 发布版本
			appVersion.POST("/:id/deprecate", appVersionCtrl.DeprecateVersion) // 废弃版本
			appVersion.DELETE("/:id", appVersionCtrl.DeleteVersion)        // 删除版本
		}

		// 管理后台内部API（不需要用户认证，但需要管理员密钥）
		admin := api.Group("/admin")
		{
			admin.POST("/force-logout", userCtrl.ForceLogout) // 强制用户下线
		}

		// 需要认证的路由
		authorized := api.Group("")
		authorized.Use(middleware.AuthMiddleware())
		{
			// 文件上传相关路由
			upload := authorized.Group("/upload")
			{
				upload.POST("/image", uploadCtrl.UploadImage)            // 上传图片到OSS（聊天图片）
				upload.POST("/file", uploadCtrl.UploadFile)              // 上传通用文件到OSS
				upload.POST("/avatar", uploadCtrl.UploadAvatar)          // 上传头像到OSS
				upload.POST("/video/chunk", uploadCtrl.UploadVideoChunk) // 上传视频分片到OSS（分片并发上传）
			}

			// OSS分片直传相关路由（后端只负责签名，前端直传OSS）
			oss := authorized.Group("/oss")
			{
				oss.POST("/initiate_multipart", ossCtrl.InitiateMultipartUpload)   // 初始化分片上传，返回uploadId和签名URL
				oss.POST("/sign_part", ossCtrl.SignMultipartPart)                  // 为每个分片生成签名URL
				oss.POST("/complete_multipart", ossCtrl.CompleteMultipartUpload)   // 完成分片上传，返回签名URL
				oss.POST("/get_opus_upload_url", ossCtrl.GetOpusUploadURL)         // 获取语音文件预签名上传URL
			}

			// 用户个人信息相关路由
			user := authorized.Group("/user")
			{
				user.GET("/profile", userCtrl.GetProfile)                        // 获取当前登录用户的个人信息
				user.GET("/username/:username", userCtrl.GetUserByUsername)      // 根据用户名查询用户信息
				user.GET("/invite-code/:invite_code", userCtrl.GetUserByInviteCode) // 根据邀请码查询用户信息
				user.PUT("/profile", userCtrl.UpdateProfile)                     // 更新个人信息
				user.PUT("/work-signature", userCtrl.UpdateWorkSignature)        // 更新工作签名
				user.PUT("/status", userCtrl.UpdateStatus)                       // 更新状态
				user.POST("/change-password", userCtrl.ChangePassword)           // 修改密码
				user.POST("/check-email", userCtrl.CheckEmailAvailability)       // 检查邮箱是否已被其他用户绑定
				user.POST("/send-email-code", userCtrl.SendEmailCode)            // 发送邮箱绑定验证码
				user.POST("/bind-email", userCtrl.BindEmail)                     // 绑定/更换邮箱
				user.POST("/batch-online-status", userCtrl.BatchGetOnlineStatus) // 批量获取用户在线状态
				user.GET("/:id", userCtrl.GetUserByID)                           // 根据ID查询用户信息（动态路由放最后）
			}

			// 消息相关路由
			message := authorized.Group("/messages")
			{
				message.GET("/conversations", messageCtrl.GetConversations)                   // 获取会话列表
				message.GET("/history/:user_id", messageCtrl.GetMessageHistory)               // 获取与指定用户的消息历史
				message.GET("/recent-contacts", messageCtrl.GetRecentContacts)                // 获取最近30个联系人列表
				message.GET("/conversation/:contact_id", messageCtrl.GetConversationMessages) // 查询联系人的对话记录（分页）
				message.POST("/mark-read", messageCtrl.MarkMessagesAsRead)                    // 标记私聊消息为已读
				message.POST("/mark-group-read", messageCtrl.MarkGroupMessagesAsRead)         // 标记群组消息为已读
				message.POST("/recall", messageCtrl.RecallMessage)                            // 撤回消息
				message.DELETE("/:id", messageCtrl.DeleteMessage)                             // 删除消息
				message.POST("/batch-delete", messageCtrl.BatchDeleteMessages)                // 批量删除消息
			}

			// 联系人相关路由
			contact := authorized.Group("/contacts")
			{
				contact.POST("", contactCtrl.AddContact)                                       // 添加联系人
				contact.GET("", contactCtrl.GetContacts)                                       // 获取联系人列表
				contact.GET("/requests", contactCtrl.GetPendingContactRequests)                // 获取待审核的联系人申请
				contact.GET("/search", contactCtrl.SearchContacts)                             // 搜索联系人
				contact.GET("/user/:user_id", contactCtrl.GetContactsByUserIDParam)            // 根据user_id获取联系人列表
				contact.PUT("/:relation_id/approval", contactCtrl.UpdateContactApprovalStatus) // 更新联系人审核状态
				contact.DELETE("/:username", contactCtrl.DeleteContact)                        // 删除联系人（通过用户名）
				contact.POST("/:friend_id/block", contactCtrl.BlockContact)                    // 拉黑联系人
				contact.POST("/:friend_id/unblock", contactCtrl.UnblockContact)                // 恢复联系人（取消拉黑）
				contact.POST("/:friend_id/delete", contactCtrl.DeleteContactById)              // 删除联系人（软删除，通过friendID）
			}

			// 收藏相关路由
			favorite := authorized.Group("/favorites")
			{
				favorite.POST("/batch", favoriteCtrl.CreateBatchFavorite)   // 批量创建收藏（合并模式）- 必须在通用路由之前
				favorite.POST("/direct", favoriteCtrl.CreateDirectFavorite) // 直接创建收藏（不需要message_id）
				favorite.POST("", favoriteCtrl.CreateFavorite)              // 创建收藏
				favorite.GET("", favoriteCtrl.GetFavorites)                 // 获取收藏列表（分页）
				favorite.DELETE("/:id", favoriteCtrl.DeleteFavorite)        // 删除收藏
			}

			// 常用联系人相关路由
			favoriteContact := authorized.Group("/favorite-contacts")
			{
				favoriteContact.POST("", favoriteCommonCtrl.AddFavoriteContact)                    // 添加常用联系人
				favoriteContact.DELETE("/:contact_id", favoriteCommonCtrl.RemoveFavoriteContact)   // 移除常用联系人
				favoriteContact.GET("", favoriteCommonCtrl.GetFavoriteContacts)                    // 获取常用联系人列表
				favoriteContact.GET("/check/:contact_id", favoriteCommonCtrl.CheckFavoriteContact) // 检查是否为常用联系人
			}

			// 常用群组相关路由
			favoriteGroup := authorized.Group("/favorite-groups")
			{
				favoriteGroup.POST("", favoriteCommonCtrl.AddFavoriteGroup)                  // 添加常用群组
				favoriteGroup.DELETE("/:group_id", favoriteCommonCtrl.RemoveFavoriteGroup)   // 移除常用群组
				favoriteGroup.GET("", favoriteCommonCtrl.GetFavoriteGroups)                  // 获取常用群组列表
				favoriteGroup.GET("/check/:group_id", favoriteCommonCtrl.CheckFavoriteGroup) // 检查是否为常用群组
			}

			// 群组相关路由
			group := authorized.Group("/groups")
			{
				group.POST("", groupCtrl.CreateGroup)                                                // 创建群组
				group.GET("", groupCtrl.GetUserGroups)                                               // 获取当前用户的所有群组
				group.GET("/:id", groupCtrl.GetGroup)                                                // 获取群组详情
				group.PUT("/:id", groupCtrl.UpdateGroup)                                             // 更新群组信息
				group.DELETE("/:id", groupCtrl.DeleteGroup)                                          // 删除群组（解散群组）
				group.POST("/:id/join", groupCtrl.JoinGroup)                                         // 加入群组
				group.POST("/:id/leave", groupCtrl.LeaveGroup)                                       // 退出群组
				group.GET("/:id/messages", groupCtrl.GetGroupMessages)                               // 获取群组消息列表
				group.POST("/messages", groupCtrl.CreateGroupMessage)                                // 发送群组消息
				group.POST("/:id/mute", groupCtrl.MuteGroupMember)                                   // 禁言群组成员
				group.POST("/:id/unmute", groupCtrl.UnmuteGroupMember)                               // 解除群组成员禁言
				group.POST("/:id/transfer", groupCtrl.TransferOwnership)                             // 转让群主权限
				group.POST("/:id/admins", groupCtrl.SetGroupAdmins)                                  // 设置群管理员
				group.POST("/:id/all-muted", groupCtrl.UpdateGroupAllMuted)                          // 更新群组全体禁言状态
				group.POST("/:id/invite-confirmation", groupCtrl.UpdateGroupInviteConfirmation)      // 更新群组邀请确认状态
				group.POST("/:id/admin-only-edit-name", groupCtrl.UpdateGroupAdminOnlyEditName)      // 更新群组"仅管理员可修改群名称"状态
				group.POST("/:id/member-view-permission", groupCtrl.UpdateGroupMemberViewPermission) // 更新群组"群成员查看权限"状态
				group.POST("/:id/approve-member", groupCtrl.ApproveGroupMember)                      // 通过群成员审核
				group.POST("/:id/reject-member", groupCtrl.RejectGroupMember)                        // 拒绝群成员审核
			}

			// 文件传输助手相关路由
			fileAssistant := authorized.Group("/file-assistant")
			{
				fileAssistant.POST("/messages", fileAssistantCtrl.CreateMessage)            // 创建文件助手消息
				fileAssistant.GET("/messages", fileAssistantCtrl.GetMessages)               // 获取文件助手消息列表
				fileAssistant.DELETE("/messages/:id", fileAssistantCtrl.DeleteMessage)      // 删除文件助手消息
				fileAssistant.POST("/messages/:id/recall", fileAssistantCtrl.RecallMessage) // 撤回文件助手消息
			}

			// 语音/视频通话相关路由
			call := authorized.Group("/call")
			{
				call.POST("/initiate", callCtrl.InitiateCall)             // 发起通话
				call.POST("/initiate_group", callCtrl.InitiateGroupCall)  // 发起群组通话
				call.POST("/invite_to_group", callCtrl.InviteToGroupCall) // 邀请成员加入现有群组通话
				call.POST("/accept", callCtrl.AcceptCall)                 // 接听通话（可选）
				call.POST("/accept_group", callCtrl.AcceptGroupCall)      // 接听群组通话
				call.POST("/reject", callCtrl.RejectCall)                 // 拒绝通话
				call.POST("/end", callCtrl.EndCall)                       // 结束通话
				call.POST("/leave_group", callCtrl.LeaveGroupCall)        // 离开群组通话
				call.POST("/token", callCtrl.GetChannelToken)             // 获取/刷新频道Token
			}
		}
	}

	// 健康检查
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "ok",
		})
	})

	return router
}

// SetupWebSocketRouter 设置WebSocket路由（独立端口）
func SetupWebSocketRouter(hub *ws.Hub) *gin.Engine {
	// 使用 gin.New() 而不是 gin.Default()
	router := gin.New()

	// 使用恢复中间件（处理panic）
	router.Use(gin.Recovery())

	// 使用自定义日志中间件
	router.Use(middleware.LoggerMiddleware())

	// 使用跨域中间件（允许来自HTTP API端口的连接）
	router.Use(middleware.CORS())

	// 创建消息控制器
	messageCtrl := controllers.NewMessageController(hub)

	// WebSocket路由（需要认证，但不使用中间件，在handler内部验证）
	router.GET("/ws", messageCtrl.HandleWebSocket)

	// 健康检查
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status":  "ok",
			"service": "websocket",
		})
	})

	return router
}
