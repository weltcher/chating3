package controllers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"youdu-server/config"
	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
)

// CallController 语音通话控制器
type CallController struct {
	Hub         *ws.Hub
	userRepo    *models.UserRepository
	contactRepo *models.ContactRepository
	groupRepo   *models.GroupRepository
	// 群组通话成员管理 - key: channelName, value: 用户ID数组
	groupCallMembers map[string][]int
	// 保护 groupCallMembers 的互斥锁
	groupCallMutex sync.RWMutex
}

// NewCallController 创建语音通话控制器
func NewCallController(hub *ws.Hub) *CallController {
	return &CallController{
		Hub:              hub,
		userRepo:         models.NewUserRepository(db.DB),
		contactRepo:      models.NewContactRepository(db.DB),
		groupRepo:        models.NewGroupRepository(db.DB),
		groupCallMembers: make(map[string][]int),
	}
}

// InitiateCallRequest 发起通话请求
type InitiateCallRequest struct {
	CalleeID int    `json:"callee_id" binding:"required"` // 被叫方用户ID
	CallType string `json:"call_type"`                    // 通话类型：voice 或 video（默认voice）
}

// InitiateCallResponse 发起通话响应
type InitiateCallResponse struct {
	ChannelName string `json:"channel_name"` // 频道名称
	Token       string `json:"token"`        // Agora Token
	CallerUID   uint32 `json:"caller_uid"`   // 主叫方 UID
	CalleeUID   uint32 `json:"callee_uid"`   // 被叫方 UID
	CallType    string `json:"call_type"`    // 通话类型
}

// InitiateCall 发起语音/视频通话
// @Summary 发起语音/视频通话
// @Description 发起方调用此接口创建通话频道，获取频道名和token，系统会自动通知被叫方
// @Tags Call
// @Accept json
// @Produce json
// @Param request body InitiateCallRequest true "发起通话请求"
// @Success 200 {object} InitiateCallResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 500 {object} map[string]interface{} "服务器错误"
// @Router /api/call/initiate [post]
func (cc *CallController) InitiateCall(c *gin.Context) {
	// 获取当前登录用户ID（主叫方）
	callerID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	callerUserID := callerID.(int)

	// 解析请求参数
	var req InitiateCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 默认通话类型为语音
	if req.CallType == "" {
		req.CallType = "voice"
	}

	// 验证被叫方是否存在
	calleeUser, err := cc.userRepo.FindByID(req.CalleeID)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "被叫用户不存在"})
		return
	}

	// 获取主叫方用户信息
	callerUser, err := cc.userRepo.FindByID(callerUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 🔴 检查好友关系：是否被删除
	isDeleted, err := cc.contactRepo.CheckContactDeleted(callerUserID, req.CalleeID)
	if err != nil {
		utils.LogDebug("❌ [通话] 检查好友删除状态失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查好友关系失败"})
		return
	}
	if isDeleted {
		utils.LogDebug("⚠️ [通话] 用户 %d 尝试呼叫已删除的联系人 %d", callerUserID, req.CalleeID)
		c.JSON(http.StatusForbidden, gin.H{"error": "您已删除该联系人，无法发起通话"})
		return
	}

	// 🔴 检查好友关系：是否被拉黑
	isBlocked, err := cc.contactRepo.CheckContactBlocked(callerUserID, req.CalleeID)
	if err != nil {
		utils.LogDebug("❌ [通话] 检查好友拉黑状态失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查好友关系失败"})
		return
	}
	if isBlocked {
		utils.LogDebug("⚠️ [通话] 用户 %d 尝试呼叫已拉黑的联系人 %d", callerUserID, req.CalleeID)
		c.JSON(http.StatusForbidden, gin.H{"error": "该联系人已被拉黑，无法发起通话"})
		return
	}

	// 🔴 反向检查：对方是否删除了我
	isDeletedByOther, err := cc.contactRepo.CheckContactDeleted(req.CalleeID, callerUserID)
	if err != nil {
		utils.LogDebug("❌ [通话] 反向检查好友删除状态失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查好友关系失败"})
		return
	}
	if isDeletedByOther {
		utils.LogDebug("⚠️ [通话] 用户 %d 尝试呼叫已将其删除的联系人 %d", callerUserID, req.CalleeID)
		c.JSON(http.StatusForbidden, gin.H{"error": "该联系人已将您删除，无法发起通话"})
		return
	}

	// 🔴 反向检查：对方是否拉黑了我
	isBlockedByOther, err := cc.contactRepo.CheckContactBlocked(req.CalleeID, callerUserID)
	if err != nil {
		utils.LogDebug("❌ [通话] 反向检查好友拉黑状态失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查好友关系失败"})
		return
	}
	if isBlockedByOther {
		utils.LogDebug("⚠️ [通话] 用户 %d 尝试呼叫已将其拉黑的联系人 %d", callerUserID, req.CalleeID)
		c.JSON(http.StatusForbidden, gin.H{"error": "该联系人已将您拉黑，无法发起通话"})
		return
	}

	// 检查 Agora 配置
	if config.AppConfig.AgoraAppID == "" || config.AppConfig.AgoraAppCertificate == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Agora配置未设置，请联系管理员"})
		utils.LogDebug("❌ Agora配置未设置: AppID=%s, Certificate=%s",
			config.AppConfig.AgoraAppID, config.AppConfig.AgoraAppCertificate)
		return
	}

	// 生成唯一的频道名称
	// 格式: call_${callerId}_${calleeId}_${timestamp}
	timestamp := time.Now().Unix()
	channelName := fmt.Sprintf("call_%d_%d_%d", callerUserID, req.CalleeID, timestamp)

	// 生成 Agora Token（有效期1小时）
	callerUID := uint32(callerUserID)
	calleeUID := uint32(req.CalleeID)
	expirationTimeInSeconds := uint32(3600) // 1小时

	// 为主叫方生成 token
	callerToken, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		channelName,
		callerUID,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		utils.LogDebug("❌ 生成Token失败: %v", err)
		return
	}

	// 为被叫方生成 token
	calleeToken, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		channelName,
		calleeUID,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		utils.LogDebug("❌ 生成Token失败: %v", err)
		return
	}

	// 构建响应数据
	response := InitiateCallResponse{
		ChannelName: channelName,
		Token:       callerToken,
		CallerUID:   callerUID,
		CalleeUID:   calleeUID,
		CallType:    req.CallType,
	}

	// 通过 WebSocket 通知被叫方（来电通知）
	// 优先使用全名，如果没有则使用用户名
	callerDisplayName := callerUser.Username
	if callerUser.FullName != nil && *callerUser.FullName != "" {
		callerDisplayName = *callerUser.FullName
	}
	go cc.notifyIncomingCall(req.CalleeID, channelName, calleeToken, callerUserID, callerUser.Username, callerDisplayName, req.CallType)

	// 记录日志
	utils.LogDebug("📞 [通话] 用户 %d(%s) 发起%s通话给用户 %d(%s), 频道: %s",
		callerUserID, callerUser.Username, req.CallType, req.CalleeID, calleeUser.Username, channelName)

	// 返回响应给主叫方
	c.JSON(http.StatusOK, response)
}

// notifyIncomingCall 通知被叫方有来电
func (cc *CallController) notifyIncomingCall(calleeID int, channelName, token string, callerID int, callerUsername, callerDisplayName, callType string) {
	// 检查被叫方是否在线
	if !cc.Hub.IsUserOnline(calleeID) {
		utils.LogDebug("⚠️ [通话] 被叫用户 %d 不在线，无法通知", calleeID)
		return
	}

	// 构建来电通知消息
	notification := map[string]interface{}{
		"type":                "incoming_call",   // 消息类型：来电通知
		"channel_name":        channelName,       // 频道名称
		"token":               token,             // Agora Token
		"caller_id":           callerID,          // 主叫方用户ID
		"caller_username":     callerUsername,    // 主叫方用户名
		"caller_display_name": callerDisplayName, // 主叫方显示名称
		"call_type":           callType,          // 通话类型
		"timestamp":           time.Now().Unix(), // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [通话] 序列化来电通知失败: %v", err)
		return
	}

	// 通过 WebSocket 发送通知
	cc.Hub.SendToUser(calleeID, message)

	utils.LogDebug("✅ [通话] 来电通知已发送给用户 %d", calleeID)
}

// InitiateGroupCallRequest 发起群组通话请求
type InitiateGroupCallRequest struct {
	CalleeIDs []int  `json:"callee_ids" binding:"required,min=1"` // 被叫方用户ID列表
	CallType  string `json:"call_type"`                           // 通话类型：voice 或 video（默认voice）
	GroupID   *int   `json:"group_id"`                            // 群组ID（可选，如果在群组内发起则传递）
}

// InitiateGroupCallResponse 发起群组通话响应
type InitiateGroupCallResponse struct {
	ChannelName string            `json:"channel_name"` // 频道名称
	Token       string            `json:"token"`        // 主叫方的Agora Token
	CallerUID   uint32            `json:"caller_uid"`   // 主叫方 UID
	CalleeUIDs  map[int]uint32    `json:"callee_uids"`  // 被叫方 UID 映射（userID -> UID）
	CallType    string            `json:"call_type"`    // 通话类型
	Members     []GroupCallMember `json:"members"`      // 所有成员信息
}

// GroupCallMember 群组通话成员信息
type GroupCallMember struct {
	UserID      int    `json:"user_id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
}

// InitiateGroupCall 发起群组语音/视频通话
// @Summary 发起群组语音/视频通话
// @Description 发起方调用此接口创建群组通话频道，获取频道名和token，系统会自动通知所有被叫方
// @Tags Call
// @Accept json
// @Produce json
// @Param request body InitiateGroupCallRequest true "发起群组通话请求"
// @Success 200 {object} InitiateGroupCallResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 500 {object} map[string]interface{} "服务器错误"
// @Router /api/call/initiate_group [post]
func (cc *CallController) InitiateGroupCall(c *gin.Context) {
	// 获取当前登录用户ID（主叫方）
	callerID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	callerUserID := callerID.(int)

	// 解析请求参数
	var req InitiateGroupCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 默认通话类型为语音
	if req.CallType == "" {
		req.CallType = "voice"
	}

	// 🔐 权限检查：如果是从群聊发起通话，只有群主和管理员可以发起
	if req.GroupID != nil && *req.GroupID > 0 && cc.groupRepo != nil {
		utils.LogDebug("🔐 [群组通话权限检查] 检查用户 %d 在群组 %d 中的权限", callerUserID, *req.GroupID)
		
		// 获取用户在群组中的角色
		role, err := cc.groupRepo.GetUserGroupRole(*req.GroupID, callerUserID)
		if err != nil {
			if err == sql.ErrNoRows {
				c.JSON(http.StatusForbidden, gin.H{"error": "您不是该群组成员"})
				utils.LogDebug("❌ [群组通话权限检查] 用户 %d 不是群组 %d 的成员", callerUserID, *req.GroupID)
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户权限失败"})
			utils.LogDebug("❌ [群组通话权限检查] 获取用户 %d 在群组 %d 中的角色失败: %v", callerUserID, *req.GroupID, err)
			return
		}

		// 只有群主(owner)和管理员(admin)可以发起群组通话
		if role != "owner" && role != "admin" {
			c.JSON(http.StatusForbidden, gin.H{"error": "只有群主和管理员可以发起群组通话"})
			utils.LogDebug("❌ [群组通话权限检查] 用户 %d 角色为 %s，无权发起群组 %d 的通话", callerUserID, role, *req.GroupID)
			return
		}

		utils.LogDebug("✅ [群组通话权限检查] 用户 %d 是群组 %d 的 %s，允许发起通话", callerUserID, *req.GroupID, role)
	}

	// 获取主叫方用户信息
	callerUser, err := cc.userRepo.FindByID(callerUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 检查 Agora 配置
	if config.AppConfig.AgoraAppID == "" || config.AppConfig.AgoraAppCertificate == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Agora配置未设置，请联系管理员"})
		utils.LogDebug("❌ Agora配置未设置: AppID=%s, Certificate=%s",
			config.AppConfig.AgoraAppID, config.AppConfig.AgoraAppCertificate)
		return
	}

	// 生成唯一的频道名称
	timestamp := time.Now().Unix()
	channelName := fmt.Sprintf("group_call_%d_%d", callerUserID, timestamp)

	// 生成 Token 的有效期（1小时）
	expirationTimeInSeconds := uint32(3600)

	// 为主叫方生成 token
	callerUID := uint32(callerUserID)
	callerToken, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		channelName,
		callerUID,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		utils.LogDebug("❌ 生成Token失败: %v", err)
		return
	}

	// 获取所有成员信息（包括主叫方）
	allMemberIDs := append([]int{callerUserID}, req.CalleeIDs...)
	members := make([]GroupCallMember, 0, len(allMemberIDs))
	calleeUIDs := make(map[int]uint32)
	calleeTokens := make(map[int]string) // 存储每个被叫方的token

	// 添加主叫方信息
	// 默认使用用户名，如果在群组内发起通话则优先使用群昵称
	callerDisplayName := callerUser.Username
	if req.GroupID != nil && *req.GroupID > 0 && cc.groupRepo != nil {
		if name, err := cc.groupRepo.GetGroupMemberNickname(*req.GroupID, callerUserID); err == nil && name != "" {
			callerDisplayName = name
		} else if callerUser.FullName != nil && *callerUser.FullName != "" {
			callerDisplayName = *callerUser.FullName
		}
	} else if callerUser.FullName != nil && *callerUser.FullName != "" {
		callerDisplayName = *callerUser.FullName
	}
	members = append(members, GroupCallMember{
		UserID:      callerUserID,
		Username:    callerUser.Username,
		DisplayName: callerDisplayName,
	})

	// 先构建完整的成员列表和生成所有token
	for _, calleeID := range req.CalleeIDs {
		// 跳过主叫方自己
		if calleeID == callerUserID {
			continue
		}

		// 获取被叫方用户信息
		calleeUser, err := cc.userRepo.FindByID(calleeID)
		if err != nil {
			utils.LogDebug("⚠️ [群组通话] 获取用户 %d 信息失败: %v", calleeID, err)
			continue
		}

		// 🔴 检查好友关系：是否被删除
		isDeleted, err := cc.contactRepo.CheckContactDeleted(callerUserID, calleeID)
		if err != nil {
			utils.LogDebug("❌ [群组通话] 检查用户 %d 好友删除状态失败: %v", calleeID, err)
			continue
		}
		if isDeleted {
			utils.LogDebug("⚠️ [群组通话] 跳过已删除的联系人 %d", calleeID)
			continue
		}

		// 🔴 检查好友关系：是否被拉黑
		isBlocked, err := cc.contactRepo.CheckContactBlocked(callerUserID, calleeID)
		if err != nil {
			utils.LogDebug("❌ [群组通话] 检查用户 %d 好友拉黑状态失败: %v", calleeID, err)
			continue
		}
		if isBlocked {
			utils.LogDebug("⚠️ [群组通话] 跳过已拉黑的联系人 %d", calleeID)
			continue
		}

		// 🔴 反向检查：对方是否删除了我
		isDeletedByOther, err := cc.contactRepo.CheckContactDeleted(calleeID, callerUserID)
		if err != nil {
			utils.LogDebug("❌ [群组通话] 反向检查用户 %d 好友删除状态失败: %v", calleeID, err)
			continue
		}
		if isDeletedByOther {
			utils.LogDebug("⚠️ [群组通话] 跳过已将我删除的联系人 %d", calleeID)
			continue
		}

		// 🔴 反向检查：对方是否拉黑了我
		isBlockedByOther, err := cc.contactRepo.CheckContactBlocked(calleeID, callerUserID)
		if err != nil {
			utils.LogDebug("❌ [群组通话] 反向检查用户 %d 好友拉黑状态失败: %v", calleeID, err)
			continue
		}
		if isBlockedByOther {
			utils.LogDebug("⚠️ [群组通话] 跳过已将我拉黑的联系人 %d", calleeID)
			continue
		}

		// 为被叫方生成 token
		calleeUID := uint32(calleeID)
		calleeToken, err := utils.GenerateRtcToken(
			config.AppConfig.AgoraAppID,
			config.AppConfig.AgoraAppCertificate,
			channelName,
			calleeUID,
			expirationTimeInSeconds,
		)
		if err != nil {
			utils.LogDebug("⚠️ [群组通话] 为用户 %d 生成Token失败: %v", calleeID, err)
			continue
		}

		calleeUIDs[calleeID] = calleeUID
		calleeTokens[calleeID] = calleeToken

		// 添加成员信息
		calleeDisplayName := calleeUser.Username
		if calleeUser.FullName != nil && *calleeUser.FullName != "" {
			calleeDisplayName = *calleeUser.FullName
		}
		members = append(members, GroupCallMember{
			UserID:      calleeID,
			Username:    calleeUser.Username,
			DisplayName: calleeDisplayName,
		})
	}

	// 将所有成员添加到群组通话管理map中
	cc.addMemberToGroupCall(channelName, callerUserID) // 添加发起者
	for calleeID := range calleeTokens {
		cc.addMemberToGroupCall(channelName, calleeID) // 添加被叫方
	}

	// 现在向所有被叫方发送完整的成员列表
	for calleeID, calleeToken := range calleeTokens {
		go cc.notifyIncomingGroupCall(calleeID, channelName, calleeToken, callerUserID, callerUser.Username, callerDisplayName, req.CallType, members, req.GroupID)
	}

	// 构建响应数据
	response := InitiateGroupCallResponse{
		ChannelName: channelName,
		Token:       callerToken,
		CallerUID:   callerUID,
		CalleeUIDs:  calleeUIDs,
		CallType:    req.CallType,
		Members:     members,
	}

	// 记录日志
	utils.LogDebug("📞 [群组通话] 用户 %d(%s) 发起%s群组通话, 成员数: %d, 频道: %s",
		callerUserID, callerUser.Username, req.CallType, len(members), channelName)

	// 如果在群组内发起通话，向群组发送"加入通话"按钮消息
	if req.GroupID != nil && *req.GroupID > 0 {
		callTypeText := "语音通话"
		messageType := "join_voice_button" // 默认语音通话按钮
		if req.CallType == "video" {
			callTypeText = "视频通话"
			messageType = "join_video_button" // 视频通话按钮
		}
		systemMessage := fmt.Sprintf("%s发起了%s", callerDisplayName, callTypeText)

		// 🔴 发送"加入通话"按钮消息到群组（作为消息存储，方便后续进入群组时展示）
		// 消息类型：join_voice_button（语音）或 join_video_button（视频）
		go func() {
			err := cc.sendSystemMessageToGroup(*req.GroupID, callerUserID, systemMessage, messageType, req.CallType, channelName)
			if err != nil {
				utils.LogDebug("⚠️ [群组通话] 发送加入通话按钮消息失败: %v", err)
			} else {
				utils.LogDebug("✅ [群组通话] 加入通话按钮消息已发送到群组 %d (类型: %s, messageType: %s)", *req.GroupID, callTypeText, messageType)
			}
		}()
	}

	// 返回响应给主叫方
	c.JSON(http.StatusOK, response)
}

// notifyIncomingGroupCall 通知被叫方有群组来电
func (cc *CallController) notifyIncomingGroupCall(calleeID int, channelName, token string, callerID int, callerUsername, callerDisplayName, callType string, members []GroupCallMember, groupID *int) {
	// 检查被叫方是否在线
	if !cc.Hub.IsUserOnline(calleeID) {
		utils.LogDebug("⚠️ [群组通话] 被叫用户 %d 不在线，无法通知", calleeID)
		return
	}

	// 构建来电通知消息
	notification := map[string]interface{}{
		"type":                "incoming_group_call", // 消息类型：群组来电通知
		"channel_name":        channelName,           // 频道名称
		"token":               token,                 // Agora Token
		"caller_id":           callerID,              // 主叫方用户ID
		"caller_username":     callerUsername,        // 主叫方用户名
		"caller_display_name": callerDisplayName,     // 主叫方显示名称
		"call_type":           callType,              // 通话类型
		"members":             members,               // 所有成员信息
		"group_id":            groupID,               // 群组ID（可能为nil）
		"timestamp":           time.Now().Unix(),     // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化来电通知失败: %v", err)
		return
	}

	// 通过 WebSocket 发送通知
	cc.Hub.SendToUser(calleeID, message)

	utils.LogDebug("✅ [群组通话] 来电通知已发送给用户 %d", calleeID)
}

// AcceptGroupCallRequest 接听群组通话请求
type AcceptGroupCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
}

// AcceptGroupCall 接听群组通话
// @Summary 接听群组通话
// @Description 被叫方接听群组通话时调用，会通知群组中的其他成员
// @Tags Call
// @Accept json
// @Produce json
// @Param request body AcceptGroupCallRequest true "接听群组通话请求"
// @Success 200 {object} map[string]interface{}
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Router /api/call/accept_group [post]
func (cc *CallController) AcceptGroupCall(c *gin.Context) {
	// 获取当前登录用户ID（被叫方）
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	accepterUserID := userID.(int)

	// 解析请求参数
	var req AcceptGroupCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 获取接听者用户信息
	accepterUser, err := cc.userRepo.FindByID(accepterUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 🔴 FIX: 将接听者添加到群组通话成员列表中
	// 这样在通知其他成员离开时，接听者也能收到通知
	cc.addMemberToGroupCall(req.ChannelName, accepterUserID)

	// 🔴 新增：为接听者生成Agora Token
	// 检查 Agora 配置
	if config.AppConfig.AgoraAppID == "" || config.AppConfig.AgoraAppCertificate == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Agora配置未设置，请联系管理员"})
		utils.LogDebug("❌ Agora配置未设置: AppID=%s, Certificate=%s",
			config.AppConfig.AgoraAppID, config.AppConfig.AgoraAppCertificate)
		return
	}

	// 生成 Token 的有效期（1小时）
	expirationTimeInSeconds := uint32(3600)
	accepterUID := uint32(accepterUserID)
	accepterToken, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		req.ChannelName,
		accepterUID,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		utils.LogDebug("❌ 为接听者生成Token失败: %v", err)
		return
	}

	// 通知群组中的其他成员有人接听了通话
	// 从频道名称解析出发起者ID，然后获取完整的成员列表
	go cc.notifyGroupCallMemberAcceptedWithMembers(req.ChannelName, accepterUserID, accepterUser.Username, accepterUser.FullName)

	utils.LogDebug("✅ [群组通话] 用户 %d 接听群组通话, 频道: %s", accepterUserID, req.ChannelName)

	c.JSON(http.StatusOK, gin.H{
		"message":      "已接听群组通话",
		"channel_name": req.ChannelName,
		"token":        accepterToken,
		"uid":          accepterUID,
	})
}

// notifyGroupCallMemberAcceptedWithMembers 通知群组中的其他成员有人接听了通话（包含成员列表获取）
func (cc *CallController) notifyGroupCallMemberAcceptedWithMembers(channelName string, accepterUserID int, accepterUsername string, accepterFullName *string) {
	// 从频道名称解析出发起者ID
	// 频道名称格式: group_call_${callerId}_${timestamp}
	var callerUserID int
	if _, err := fmt.Sscanf(channelName, "group_call_%d_", &callerUserID); err != nil {
		utils.LogDebug("❌ [群组通话] 无法从频道名称解析发起者ID: %s", channelName)
		return
	}

	// 🔴 FIX: 从群组通话成员列表中获取所有成员
	members := cc.getGroupCallMembers(channelName)
	if len(members) == 0 {
		utils.LogDebug("⚠️ [群组通话] 频道 %s 没有成员，无法发送接听通知", channelName)
		return
	}

	// 构建接听通知消息
	accepterDisplayName := accepterUsername
	if accepterFullName != nil && *accepterFullName != "" {
		accepterDisplayName = *accepterFullName
	}

	notification := map[string]interface{}{
		"type":                  "group_call_member_accepted", // 消息类型：群组通话成员接听
		"channel_name":          channelName,                  // 频道名称
		"accepter_user_id":      accepterUserID,               // 接听者用户ID
		"accepter_username":     accepterUsername,             // 接听者用户名
		"accepter_display_name": accepterDisplayName,          // 接听者显示名称
		"caller_user_id":        callerUserID,                 // 发起者用户ID（从频道名称解析）
		"timestamp":             time.Now().Unix(),            // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化成员接听通知失败: %v", err)
		return
	}

	// 🔴 FIX: 向群组通话的所有成员广播消息（除了接听者自己）
	cc.Hub.BroadcastToUsers(members, message, accepterUserID)

	utils.LogDebug("✅ [群组通话] 成员接听通知已广播，频道: %s, 接听者: %d, 通知成员: %v", channelName, accepterUserID, members)
}

// notifyGroupCallMemberAccepted 通知群组中的其他成员有人接听了通话（旧版本，保留兼容性）
func (cc *CallController) notifyGroupCallMemberAccepted(channelName string, accepterUserID int, accepterUsername string, accepterFullName *string) {
	// 构建接听通知消息
	accepterDisplayName := accepterUsername
	if accepterFullName != nil && *accepterFullName != "" {
		accepterDisplayName = *accepterFullName
	}

	notification := map[string]interface{}{
		"type":                  "group_call_member_accepted", // 消息类型：群组通话成员接听
		"channel_name":          channelName,                  // 频道名称
		"accepter_user_id":      accepterUserID,               // 接听者用户ID
		"accepter_username":     accepterUsername,             // 接听者用户名
		"accepter_display_name": accepterDisplayName,          // 接听者显示名称
		"timestamp":             time.Now().Unix(),            // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化成员接听通知失败: %v", err)
		return
	}

	// 通过 WebSocket 广播给该频道的所有在线用户（除了接听者自己）
	cc.Hub.BroadcastToChannel(channelName, message, accepterUserID)

	utils.LogDebug("✅ [群组通话] 成员接听通知已广播，频道: %s, 接听者: %d", channelName, accepterUserID)
}

// AcceptCallRequest 接听通话请求
type AcceptCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
}

// AcceptCallResponse 接听通话响应
type AcceptCallResponse struct {
	Token string `json:"token"` // Agora Token
	UID   uint32 `json:"uid"`   // 用户UID
}

// AcceptCall 接听通话（可选接口）
// @Summary 接听通话
// @Description 被叫方接听通话时调用（可选，token已在来电通知中提供）
// @Tags Call
// @Accept json
// @Produce json
// @Param request body AcceptCallRequest true "接听通话请求"
// @Success 200 {object} AcceptCallResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 500 {object} map[string]interface{} "服务器错误"
// @Router /api/call/accept [post]
func (cc *CallController) AcceptCall(c *gin.Context) {
	// 获取当前登录用户ID（被叫方）
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	calleeUserID := userID.(int)

	// 解析请求参数
	var req AcceptCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 生成 Token（有效期1小时）
	uid := uint32(calleeUserID)
	expirationTimeInSeconds := uint32(3600)

	token, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		req.ChannelName,
		uid,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		return
	}

	// 返回响应
	response := AcceptCallResponse{
		Token: token,
		UID:   uid,
	}

	utils.LogDebug("✅ [通话] 用户 %d 接听通话, 频道: %s", calleeUserID, req.ChannelName)

	c.JSON(http.StatusOK, response)
}

// RejectCallRequest 拒绝通话请求
type RejectCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
	CallerID    int    `json:"caller_id" binding:"required"`    // 主叫方用户ID
}

// RejectCall 拒绝通话
// @Summary 拒绝通话
// @Description 被叫方拒绝通话时调用，会通知主叫方
// @Tags Call
// @Accept json
// @Produce json
// @Param request body RejectCallRequest true "拒绝通话请求"
// @Success 200 {object} map[string]interface{}
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Router /api/call/reject [post]
func (cc *CallController) RejectCall(c *gin.Context) {
	// 获取当前登录用户ID（被叫方）
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	calleeUserID := userID.(int)

	// 解析请求参数
	var req RejectCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 通知主叫方通话被拒绝
	go cc.notifyCallRejected(req.CallerID, req.ChannelName, calleeUserID)

	utils.LogDebug("❌ [通话] 用户 %d 拒绝通话, 频道: %s", calleeUserID, req.ChannelName)

	c.JSON(http.StatusOK, gin.H{
		"message": "已拒绝通话",
	})
}

// notifyCallRejected 通知主叫方通话被拒绝
func (cc *CallController) notifyCallRejected(callerID int, channelName string, calleeID int) {
	// 检查主叫方是否在线
	if !cc.Hub.IsUserOnline(callerID) {
		return
	}

	// 构建拒绝通知消息
	notification := map[string]interface{}{
		"type":         "call_rejected",   // 消息类型：通话被拒绝
		"channel_name": channelName,       // 频道名称
		"callee_id":    calleeID,          // 被叫方用户ID
		"timestamp":    time.Now().Unix(), // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [通话] 序列化拒绝通知失败: %v", err)
		return
	}

	// 通过 WebSocket 发送通知
	cc.Hub.SendToUser(callerID, message)

	utils.LogDebug("✅ [通话] 拒绝通知已发送给用户 %d", callerID)
}

// EndCallRequest 结束通话请求
type EndCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
	PeerID      int    `json:"peer_id" binding:"required"`      // 对方用户ID
}

// EndCall 结束通话
// @Summary 结束通话
// @Description 任意一方结束通话时调用，会通知对方
// @Tags Call
// @Accept json
// @Produce json
// @Param request body EndCallRequest true "结束通话请求"
// @Success 200 {object} map[string]interface{}
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Router /api/call/end [post]
func (cc *CallController) EndCall(c *gin.Context) {
	// 获取当前登录用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	currentUserID := userID.(int)

	// 解析请求参数
	var req EndCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 通知对方通话已结束
	go cc.notifyCallEnded(req.PeerID, req.ChannelName, currentUserID)

	utils.LogDebug("📞 [通话] 用户 %d 结束通话, 频道: %s", currentUserID, req.ChannelName)

	c.JSON(http.StatusOK, gin.H{
		"message": "通话已结束",
	})
}

// notifyCallEnded 通知对方通话已结束
func (cc *CallController) notifyCallEnded(peerID int, channelName string, userID int) {
	// 检查对方是否在线
	if !cc.Hub.IsUserOnline(peerID) {
		return
	}

	// 构建结束通知消息
	notification := map[string]interface{}{
		"type":         "call_ended",      // 消息类型：通话结束
		"channel_name": channelName,       // 频道名称
		"user_id":      userID,            // 结束通话的用户ID
		"timestamp":    time.Now().Unix(), // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [通话] 序列化结束通知失败: %v", err)
		return
	}

	// 通过 WebSocket 发送通知
	cc.Hub.SendToUser(peerID, message)

	utils.LogDebug("✅ [通话] 结束通知已发送给用户 %d", peerID)
}

// GetChannelTokenRequest 获取频道Token请求
type GetChannelTokenRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
}

// GetChannelTokenResponse 获取频道Token响应
type GetChannelTokenResponse struct {
	Token string `json:"token"` // Agora Token
	UID   uint32 `json:"uid"`   // 用户UID
}

// GetChannelToken 获取或刷新频道Token
// @Summary 获取或刷新频道Token
// @Description 用于刷新即将过期的Token
// @Tags Call
// @Accept json
// @Produce json
// @Param request body GetChannelTokenRequest true "获取Token请求"
// @Success 200 {object} GetChannelTokenResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 500 {object} map[string]interface{} "服务器错误"
// @Router /api/call/token [post]
func (cc *CallController) GetChannelToken(c *gin.Context) {
	// 获取当前登录用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	currentUserID := userID.(int)

	// 解析请求参数
	var req GetChannelTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 生成新的 Token（有效期1小时）
	uid := uint32(currentUserID)
	expirationTimeInSeconds := uint32(3600)

	token, err := utils.GenerateRtcToken(
		config.AppConfig.AgoraAppID,
		config.AppConfig.AgoraAppCertificate,
		req.ChannelName,
		uid,
		expirationTimeInSeconds,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成Token失败: " + err.Error()})
		return
	}

	// 返回响应
	response := GetChannelTokenResponse{
		Token: token,
		UID:   uid,
	}

	utils.LogDebug("🔑 [通话] 用户 %d 刷新Token, 频道: %s", currentUserID, req.ChannelName)

	c.JSON(http.StatusOK, response)
}

// addMemberToGroupCall 将成员添加到群组通话
func (cc *CallController) addMemberToGroupCall(channelName string, userID int) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	if members, exists := cc.groupCallMembers[channelName]; exists {
		// 检查成员是否已存在
		for _, memberID := range members {
			if memberID == userID {
				return // 成员已存在，不重复添加
			}
		}
		// 添加新成员
		cc.groupCallMembers[channelName] = append(members, userID)
	} else {
		// 创建新的群组通话
		cc.groupCallMembers[channelName] = []int{userID}
	}

	utils.LogDebug("✅ [群组通话] 用户 %d 已添加到频道 %s，当前成员: %v", userID, channelName, cc.groupCallMembers[channelName])
}

// removeMemberFromGroupCall 从群组通话中移除成员
func (cc *CallController) removeMemberFromGroupCall(channelName string, userID int) []int {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	members, exists := cc.groupCallMembers[channelName]
	if !exists {
		return nil
	}

	// 查找并移除成员
	for i, memberID := range members {
		if memberID == userID {
			// 移除成员
			cc.groupCallMembers[channelName] = append(members[:i], members[i+1:]...)
			break
		}
	}

	// 如果群组通话没有成员了，删除整个频道
	if len(cc.groupCallMembers[channelName]) == 0 {
		delete(cc.groupCallMembers, channelName)
		utils.LogDebug("🗑️ [群组通话] 频道 %s 已删除（无成员）", channelName)
		return nil
	}

	remainingMembers := cc.groupCallMembers[channelName]
	utils.LogDebug("✅ [群组通话] 用户 %d 已从频道 %s 移除，剩余成员: %v", userID, channelName, remainingMembers)
	return remainingMembers
}

// getGroupCallMembers 获取群组通话的所有成员
func (cc *CallController) getGroupCallMembers(channelName string) []int {
	cc.groupCallMutex.RLock()
	defer cc.groupCallMutex.RUnlock()

	if members, exists := cc.groupCallMembers[channelName]; exists {
		// 返回副本，避免并发修改
		result := make([]int, len(members))
		copy(result, members)
		return result
	}
	return nil
}

// LeaveGroupCallRequest 离开群组通话请求
type LeaveGroupCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"` // 频道名称
	GroupID     *int   `json:"group_id"`                        // 群组ID（可选，如果在群组内通话则传递）
	CallType    string `json:"call_type"`                       // 通话类型（voice/video）
}

// LeaveGroupCall 离开群组通话
// @Summary 离开群组通话
// @Description 成员离开群组通话时调用，会通知群组中的其他成员
// @Tags Call
// @Accept json
// @Produce json
// @Param request body LeaveGroupCallRequest true "离开群组通话请求"
// @Success 200 {object} map[string]interface{}
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Router /api/call/leave_group [post]
func (cc *CallController) LeaveGroupCall(c *gin.Context) {
	// 获取当前登录用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	leavingUserID := userID.(int)

	// 解析请求参数
	var req LeaveGroupCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 获取离开用户的信息
	leavingUser, err := cc.userRepo.FindByID(leavingUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 从群组通话中移除成员
	remainingMembers := cc.removeMemberFromGroupCall(req.ChannelName, leavingUserID)

	// 通知其他成员有人离开了群组通话
	if len(remainingMembers) > 0 {
		go cc.notifyGroupCallMemberLeft(req.ChannelName, leavingUserID, leavingUser.Username, leavingUser.FullName, remainingMembers)
	} else {
		// 最后一人离开，如果在群组内发起的通话，发送通话结束系统消息
		if req.GroupID != nil && *req.GroupID > 0 {
			// 🔴 删除"加入通话"按钮消息
			go cc.removeJoinCallButtonMessage(*req.GroupID, req.ChannelName)

			// 从频道名称提取时间戳，计算通话时长
			// 频道名称格式: group_call_${callerId}_${timestamp}
			var timestamp int64
			if _, err := fmt.Sscanf(req.ChannelName, "group_call_%d_%d", new(int), &timestamp); err == nil {
				callDuration := time.Now().Unix() - timestamp
				durationMinutes := callDuration / 60
				durationSeconds := callDuration % 60
				durationText := fmt.Sprintf("%02d:%02d", durationMinutes, durationSeconds)
				systemMessage := fmt.Sprintf("通话时长 %s", durationText)

				// 根据通话类型设置正确的 message_type
				messageType := "call_ended" // 默认语音通话
				if req.CallType == "video" {
					messageType = "call_ended_video" // 视频通话
				}

				// 异步发送系统消息到群组
				go func() {
					err := cc.sendSystemMessageToGroup(*req.GroupID, leavingUserID, systemMessage, messageType, req.CallType, req.ChannelName)
					if err != nil {
						utils.LogDebug("⚠️ [群组通话] 发送通话结束系统消息失败: %v", err)
					} else {
						utils.LogDebug("✅ [群组通话] 通话结束系统消息已发送到群组 %d: %s (类型: %s)", *req.GroupID, systemMessage, messageType)
					}
				}()
			} else {
				utils.LogDebug("⚠️ [群组通话] 无法从频道名称解析时间戳: %s", req.ChannelName)
			}
		}
	}

	utils.LogDebug("👋 [群组通话] 用户 %d(%s) 离开群组通话, 频道: %s, 剩余成员: %v",
		leavingUserID, leavingUser.Username, req.ChannelName, remainingMembers)

	c.JSON(http.StatusOK, gin.H{
		"message": "已离开群组通话",
	})
}

// InviteToGroupCallRequest 邀请成员加入现有群组通话请求
type InviteToGroupCallRequest struct {
	ChannelName string `json:"channel_name" binding:"required"`     // 现有通话的频道名称
	CalleeIDs   []int  `json:"callee_ids" binding:"required,min=1"` // 被邀请的成员ID列表
	CallType    string `json:"call_type"`                           // 通话类型：voice 或 video
	GroupID     *int   `json:"group_id"`                            // 群组ID（可选，如果在群组内通话则传递）
}

// InviteToGroupCallResponse 邀请成员加入现有群组通话响应
type InviteToGroupCallResponse struct {
	ChannelName string            `json:"channel_name"` // 频道名称
	CalleeUIDs  map[int]uint32    `json:"callee_uids"`  // 被邀请方 UID 映射
	CallType    string            `json:"call_type"`    // 通话类型
	Members     []GroupCallMember `json:"members"`      // 新邀请的成员信息
}

// InviteToGroupCall 邀请成员加入现有群组通话
// @Summary 邀请成员加入现有群组通话
// @Description 在通话期间邀请新成员加入现有的群组通话
// @Tags Call
// @Accept json
// @Produce json
// @Param request body InviteToGroupCallRequest true "邀请成员加入群组通话请求"
// @Success 200 {object} InviteToGroupCallResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 500 {object} map[string]interface{} "服务器错误"
// @Router /api/call/invite_to_group [post]
func (cc *CallController) InviteToGroupCall(c *gin.Context) {
	// 获取当前登录用户ID（邀请者）
	inviterID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	inviterUserID := inviterID.(int)

	// 解析请求参数
	var req InviteToGroupCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 默认通话类型为语音
	if req.CallType == "" {
		req.CallType = "voice"
	}

	// 获取邀请者用户信息
	inviterUser, err := cc.userRepo.FindByID(inviterUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 检查 Agora 配置
	if config.AppConfig.AgoraAppID == "" || config.AppConfig.AgoraAppCertificate == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Agora配置未设置，请联系管理员"})
		utils.LogDebug("❌ Agora配置未设置: AppID=%s, Certificate=%s",
			config.AppConfig.AgoraAppID, config.AppConfig.AgoraAppCertificate)
		return
	}

	// 检查频道是否存在
	existingMembers := cc.getGroupCallMembers(req.ChannelName)
	if len(existingMembers) == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "群组通话不存在或已结束"})
		return
	}

	// 检查邀请者是否在该群组通话中
	inviterInCall := false
	for _, memberID := range existingMembers {
		if memberID == inviterUserID {
			inviterInCall = true
			break
		}
	}
	if !inviterInCall {
		c.JSON(http.StatusForbidden, gin.H{"error": "您不在该群组通话中，无法邀请其他成员"})
		return
	}

	// Token 有效期（1小时）
	expirationTimeInSeconds := uint32(3600)

	// 处理被邀请的成员
	members := make([]GroupCallMember, 0, len(req.CalleeIDs))
	calleeUIDs := make(map[int]uint32)
	calleeTokens := make(map[int]string)

	for _, calleeID := range req.CalleeIDs {
		// 跳过邀请者自己
		if calleeID == inviterUserID {
			continue
		}

		// 检查成员是否已经在通话中
		alreadyInCall := false
		for _, memberID := range existingMembers {
			if memberID == calleeID {
				alreadyInCall = true
				break
			}
		}
		if alreadyInCall {
			utils.LogDebug("⚠️ [群组通话邀请] 用户 %d 已在通话中，跳过邀请", calleeID)
			continue
		}

		// 获取被邀请方用户信息
		calleeUser, err := cc.userRepo.FindByID(calleeID)
		if err != nil {
			utils.LogDebug("⚠️ [群组通话邀请] 获取用户 %d 信息失败: %v", calleeID, err)
			continue
		}

		// 为被邀请方生成 token
		calleeUID := uint32(calleeID)
		calleeToken, err := utils.GenerateRtcToken(
			config.AppConfig.AgoraAppID,
			config.AppConfig.AgoraAppCertificate,
			req.ChannelName,
			calleeUID,
			expirationTimeInSeconds,
		)
		if err != nil {
			utils.LogDebug("⚠️ [群组通话邀请] 为用户 %d 生成Token失败: %v", calleeID, err)
			continue
		}

		calleeUIDs[calleeID] = calleeUID
		calleeTokens[calleeID] = calleeToken

		// 添加成员信息
		calleeDisplayName := calleeUser.Username
		if calleeUser.FullName != nil && *calleeUser.FullName != "" {
			calleeDisplayName = *calleeUser.FullName
		}
		members = append(members, GroupCallMember{
			UserID:      calleeID,
			Username:    calleeUser.Username,
			DisplayName: calleeDisplayName,
		})

		// 将新成员添加到群组通话管理map中
		cc.addMemberToGroupCall(req.ChannelName, calleeID)
	}

	if len(members) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "没有有效的成员可以邀请"})
		return
	}

	// 获取所有成员信息（包括现有成员）用于发送给新成员
	allMembers := make([]GroupCallMember, 0)
	for _, memberID := range existingMembers {
		memberUser, err := cc.userRepo.FindByID(memberID)
		if err != nil {
			continue
		}
		memberDisplayName := memberUser.Username
		if memberUser.FullName != nil && *memberUser.FullName != "" {
			memberDisplayName = *memberUser.FullName
		}
		allMembers = append(allMembers, GroupCallMember{
			UserID:      memberID,
			Username:    memberUser.Username,
			DisplayName: memberDisplayName,
		})
	}
	// 添加新邀请的成员
	allMembers = append(allMembers, members...)

	// 向被邀请的成员发送群组通话邀请
	inviterDisplayName := inviterUser.Username
	if inviterUser.FullName != nil && *inviterUser.FullName != "" {
		inviterDisplayName = *inviterUser.FullName
	}

	for calleeID, calleeToken := range calleeTokens {
		go cc.notifyIncomingGroupCall(calleeID, req.ChannelName, calleeToken, inviterUserID, inviterUser.Username, inviterDisplayName, req.CallType, allMembers, req.GroupID)
	}

	// 构建响应数据
	response := InviteToGroupCallResponse{
		ChannelName: req.ChannelName,
		CalleeUIDs:  calleeUIDs,
		CallType:    req.CallType,
		Members:     members,
	}

	// 记录日志
	utils.LogDebug("📞 [群组通话邀请] 用户 %d(%s) 邀请 %d 个新成员加入通话, 频道: %s",
		inviterUserID, inviterUser.Username, len(members), req.ChannelName)

	// 返回响应给邀请者
	c.JSON(http.StatusOK, response)
}

// notifyGroupCallMemberLeft 通知群组中的其他成员有人离开了通话
func (cc *CallController) notifyGroupCallMemberLeft(channelName string, leftUserID int, leftUsername string, leftFullName *string, remainingMembers []int) {
	// 构建离开通知消息
	leftDisplayName := leftUsername
	if leftFullName != nil && *leftFullName != "" {
		leftDisplayName = *leftFullName
	}

	notification := map[string]interface{}{
		"type":              "group_call_member_left", // 消息类型：群组通话成员离开
		"channel_name":      channelName,              // 频道名称
		"left_user_id":      leftUserID,               // 离开者用户ID
		"left_username":     leftUsername,             // 离开者用户名
		"left_display_name": leftDisplayName,          // 离开者显示名称
		"timestamp":         time.Now().Unix(),        // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化成员离开通知失败: %v", err)
		return
	}

	// 向剩余的群组成员发送通知
	cc.Hub.BroadcastToUsers(remainingMembers, message, leftUserID)

	utils.LogDebug("✅ [群组通话] 成员离开通知已发送，频道: %s, 离开者: %d, 通知成员: %v",
		channelName, leftUserID, remainingMembers)
}

// sendSystemMessageToGroup 向群组发送系统消息
func (cc *CallController) sendSystemMessageToGroup(groupID, senderID int, content, messageType, callType, channelName string) error {
	// 🔍 调试日志：显示接收到的参数
	utils.LogDebug("🔍 [sendSystemMessageToGroup] groupID: %d, messageType: %s, callType: '%s', channelName: '%s'", groupID, messageType, callType, channelName)

	// 1. 将消息保存到数据库（包含call_type和channel_name字段）
	query := `
		INSERT INTO group_messages (group_id, sender_id, sender_name, content, message_type, call_type, channel_name, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, group_id, sender_id, sender_name, content, message_type, created_at, call_type, channel_name
	`

	// 获取发送者信息
	// 优先使用群昵称（群昵称 > 全名 > 用户名），获取失败时回退到 users 表
	var senderName string

	// 如果在群组中，优先从 group_members + users 获取显示名称
	if groupID > 0 && cc.groupRepo != nil {
		if name, err := cc.groupRepo.GetGroupMemberNickname(groupID, senderID); err == nil && name != "" {
			senderName = name
		}
	}

	// 回退：直接从 users 表获取 full_name / username
	if senderName == "" {
		var username string
		var senderFullName sql.NullString
		var err error
		err = db.DB.QueryRow("SELECT username, full_name FROM users WHERE id = $1", senderID).Scan(&username, &senderFullName)
		if err != nil {
			return fmt.Errorf("获取发送者信息失败: %v", err)
		}
		if senderFullName.Valid && senderFullName.String != "" {
			senderName = senderFullName.String
		} else {
			senderName = username
		}
	}

	var msg struct {
		ID          int
		GroupID     int
		SenderID    int
		SenderName  string
		Content     string
		MessageType string
		IsRead      bool
		CreatedAt   time.Time
		CallType    sql.NullString
		ChannelName sql.NullString
	}

	// 🔴 使用 UTC 时间，因为数据库字段是 timestamp without time zone
	err := db.DB.QueryRow(query, groupID, senderID, senderName, content, messageType, callType, channelName, time.Now().UTC()).Scan(
		&msg.ID, &msg.GroupID, &msg.SenderID, &msg.SenderName, &msg.Content, &msg.MessageType, &msg.CreatedAt, &msg.CallType, &msg.ChannelName,
	)
	if err != nil {
		return fmt.Errorf("保存系统消息失败: %v", err)
	}

	// 2. 获取群组所有成员
	memberRows, err := db.DB.Query(`
		SELECT user_id FROM group_members WHERE group_id = $1
	`, groupID)
	if err != nil {
		return fmt.Errorf("获取群组成员失败: %v", err)
	}
	defer memberRows.Close()

	memberIDs := make([]int, 0)
	for memberRows.Next() {
		var memberID int
		if err := memberRows.Scan(&memberID); err != nil {
			continue
		}
		memberIDs = append(memberIDs, memberID)
	}

	// 3. 构造消息通知（使用数据库返回的值确保一致性）
	notificationData := map[string]interface{}{
		"id":           msg.ID,
		"group_id":     msg.GroupID,
		"sender_id":    msg.SenderID,
		"sender_name":  msg.SenderName,
		"content":      msg.Content,
		"message_type": msg.MessageType,
		"is_read":      msg.IsRead,
		"created_at":   msg.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
	}

	// 只有当callType和channelName不为空时才添加（避免发送null值）
	if msg.CallType.Valid && msg.CallType.String != "" {
		notificationData["call_type"] = msg.CallType.String
	}
	if msg.ChannelName.Valid && msg.ChannelName.String != "" {
		notificationData["channel_name"] = msg.ChannelName.String
	}

	notification := map[string]interface{}{
		"type":     "group_message",
		"data":     notificationData,
		"group_id": msg.GroupID, // 添加 group_id 到外层
	}

	// 🔍 调试日志：显示notification的data内容
	utils.LogDebug("🔍 [sendSystemMessageToGroup] notification.data包含的字段: %+v", notificationData)

	// 序列化消息
	messageBytes, err := json.Marshal(notification)
	if err != nil {
		return fmt.Errorf("序列化消息失败: %v", err)
	}

	// 🔍 调试日志：显示实际发送的JSON
	utils.LogDebug("🔍 [sendSystemMessageToGroup] 发送的JSON: %s", string(messageBytes))

	// 4. 向所有在线成员广播消息
	for _, memberID := range memberIDs {
		cc.Hub.SendToUser(memberID, messageBytes)
	}

	// 5. 如果是通话发起消息，额外发送专门的通话通知
	if (messageType == "call_initiated" || messageType == "join_voice_button" || messageType == "join_video_button") && callType != "" && channelName != "" {
		callNotification := map[string]interface{}{
			"type": "group_call_notification",
			"data": map[string]interface{}{
				"group_id":     groupID,
				"call_type":    callType,
				"channel_name": channelName,
				"caller_id":    senderID,
				"caller_name":  senderName,
				"message":      content,
				"timestamp":    time.Now().Unix(),
			},
		}

		callNotificationBytes, err := json.Marshal(callNotification)
		if err == nil {
			utils.LogDebug("🔍 [sendSystemMessageToGroup] 发送群组通话通知: %s", string(callNotificationBytes))

			// 向所有在线成员发送通话通知
			for _, memberID := range memberIDs {
				cc.Hub.SendToUser(memberID, callNotificationBytes)
			}

			utils.LogDebug("✅ [群组通话] 通话通知已发送到 %d 个群组成员", len(memberIDs))
		} else {
			utils.LogDebug("⚠️ [群组通话] 序列化通话通知失败: %v", err)
		}
	}

	utils.LogDebug("✅ [群组通话] 系统消息已广播到 %d 个群组成员", len(memberIDs))
	return nil
}

// removeJoinCallButtonMessage 删除群组中的"加入通话"按钮消息
func (cc *CallController) removeJoinCallButtonMessage(groupID int, channelName string) {
	// 从数据库删除对应 channel_name 的 join_voice_button 或 join_video_button 消息
	query := `
		DELETE FROM group_messages 
		WHERE group_id = $1 
		AND (message_type = 'join_voice_button' OR message_type = 'join_video_button')
		AND channel_name = $2
		RETURNING id
	`

	var deletedMessageID int
	err := db.DB.QueryRow(query, groupID, channelName).Scan(&deletedMessageID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.LogDebug("⚠️ [群组通话] 未找到需要删除的加入通话按钮消息 - GroupID: %d, ChannelName: %s", groupID, channelName)
		} else {
			utils.LogDebug("❌ [群组通话] 删除加入通话按钮消息失败: %v", err)
		}
		return
	}

	utils.LogDebug("✅ [群组通话] 已删除加入通话按钮消息 - MessageID: %d, GroupID: %d, ChannelName: %s", deletedMessageID, groupID, channelName)

	// 获取群组所有成员
	memberRows, err := db.DB.Query(`
		SELECT user_id FROM group_members WHERE group_id = $1
	`, groupID)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 获取群组成员失败: %v", err)
		return
	}
	defer memberRows.Close()

	memberIDs := make([]int, 0)
	for memberRows.Next() {
		var memberID int
		if err := memberRows.Scan(&memberID); err != nil {
			continue
		}
		memberIDs = append(memberIDs, memberID)
	}

	// 向所有在线成员发送删除消息的通知
	notification := map[string]interface{}{
		"type": "delete_message",
		"data": map[string]interface{}{
			"message_id": deletedMessageID,
			"group_id":   groupID,
		},
	}

	notificationBytes, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化删除通知失败: %v", err)
		return
	}

	// 向所有在线成员广播删除通知
	for _, memberID := range memberIDs {
		cc.Hub.SendToUser(memberID, notificationBytes)
	}

	utils.LogDebug("✅ [群组通话] 删除通知已广播到 %d 个群组成员", len(memberIDs))
}
