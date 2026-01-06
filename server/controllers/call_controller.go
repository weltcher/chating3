package controllers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"

	"youdu-server/config"
	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/services"
	"youdu-server/utils"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
)

// GroupCallInfo 群组通话信息
type GroupCallInfo struct {
	ChannelName string `json:"channel_name"` // 频道名称
	CallType    string `json:"call_type"`    // 通话类型：voice 或 video
	CallerID    int    `json:"caller_id"`    // 发起者ID
	StartTime   int64  `json:"start_time"`   // 通话开始时间戳
}

// CallController 语音通话控制器
type CallController struct {
	Hub         *ws.Hub
	userRepo    *models.UserRepository
	contactRepo *models.ContactRepository
	groupRepo   *models.GroupRepository
	// 群组通话成员管理 - key: channelName, value: 用户ID数组（被邀请的成员）
	groupCallMembers map[string][]int
	// 🔴 新增：已连接成员管理 - key: channelName, value: 用户ID数组（已接听/加入的成员）
	groupCallConnectedMembers map[string][]int
	// 🔴 新增：通话开始时间 - key: channelName, value: 第一个被邀请人接听的时间戳
	// 用于计算真正的通话时长（从第一个人接听开始算起）
	groupCallStartTime map[string]int64
	// 🔴 新增：群组ID到通话信息的映射 - key: groupID, value: 通话信息
	// 用于查询某个群组是否有正在进行的通话
	groupIDToCallInfo map[int]*GroupCallInfo
	// 保护 groupCallMembers 的互斥锁
	groupCallMutex sync.RWMutex
}

// NewCallController 创建语音通话控制器
func NewCallController(hub *ws.Hub) *CallController {
	return &CallController{
		Hub:                       hub,
		userRepo:                  models.NewUserRepository(db.DB),
		contactRepo:               models.NewContactRepository(db.DB),
		groupRepo:                 models.NewGroupRepository(db.DB),
		groupCallMembers:          make(map[string][]int),
		groupCallConnectedMembers: make(map[string][]int),
		groupCallStartTime:        make(map[string]int64),
		groupIDToCallInfo:         make(map[int]*GroupCallInfo),
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
		utils.LogDebug("⚠️ [通话] 被叫用户 %d 不在线", calleeID)
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

	// 🔴 将发起者添加到已连接成员列表（发起者默认已连接）
	cc.addConnectedMember(channelName, callerUserID)

	// 🔴 新增：如果是群组通话，存储群组ID和通话信息的关联
	if req.GroupID != nil && *req.GroupID > 0 {
		cc.setGroupCallInfo(*req.GroupID, channelName, req.CallType, callerUserID)

		// 🔴 确保群组存在于腾讯云 IM（异步执行，不影响通话流程）
		go func(groupID int, memberIDs []int) {
			// 获取群组信息
			group, err := cc.groupRepo.GetGroupByID(groupID)
			if err != nil {
				utils.LogDebug("⚠️ 获取群组信息失败，无法同步到腾讯云 IM: %v", err)
				return
			}
			// 确保群组存在
			if err := services.TencentIM.EnsureGroupExists(groupID, group.Name, group.OwnerID, memberIDs); err != nil {
				utils.LogDebug("⚠️ 同步群组到腾讯云 IM 失败: %v", err)
			}
		}(*req.GroupID, allMemberIDs)
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

	// 如果在群组内发起通话，向群组发送消息
	if req.GroupID != nil && *req.GroupID > 0 {
		callTypeText := "语音通话"
		buttonMessageType := "join_voice_button" // 按钮消息类型
		initiatedMessageType := "group_call_initiated" // 发起消息类型
		if req.CallType == "video" {
			callTypeText = "视频通话"
			buttonMessageType = "join_video_button"
			initiatedMessageType = "group_video_call_initiated"
		}
		initiatedMessage := fmt.Sprintf("%s发起了%s", callerDisplayName, callTypeText)
		buttonMessage := "加入通话" // 按钮消息内容

		// 🔴 发送两条消息：
		// 1. "XX发起了语音通话" - 普通系统消息，不会被删除
		// 2. "加入通话"按钮 - 通话结束后会被删除
		go func() {
			// 先发送"XX发起了语音通话"消息
			err := cc.sendSystemMessageToGroup(*req.GroupID, callerUserID, initiatedMessage, initiatedMessageType, req.CallType, "")
			if err != nil {
				utils.LogDebug("⚠️ [群组通话] 发送通话发起消息失败: %v", err)
			} else {
				utils.LogDebug("✅ [群组通话] 通话发起消息已发送到群组 %d: %s", *req.GroupID, initiatedMessage)
			}
			
			// 再发送"加入通话"按钮消息
			err = cc.sendSystemMessageToGroup(*req.GroupID, callerUserID, buttonMessage, buttonMessageType, req.CallType, channelName)
			if err != nil {
				utils.LogDebug("⚠️ [群组通话] 发送加入通话按钮消息失败: %v", err)
			} else {
				utils.LogDebug("✅ [群组通话] 加入通话按钮消息已发送到群组 %d (类型: %s)", *req.GroupID, buttonMessageType)
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
		utils.LogDebug("⚠️ [群组通话] 被叫用户 %d 不在线", calleeID)
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

// GetGroupCallConnectedMembersRequest 获取群组通话已连接成员请求
type GetGroupCallConnectedMembersRequest struct {
	ChannelName string `form:"channel_name"` // 频道名称（可选，与 group_id 二选一）
	GroupID     int    `form:"group_id"`     // 群组ID（可选，与 channel_name 二选一）
}

// GroupCallConnectedMember 群组通话已连接成员信息
type GroupCallConnectedMember struct {
	UserID      int    `json:"user_id"`      // 用户ID
	Username    string `json:"username"`     // 用户名
	DisplayName string `json:"display_name"` // 显示名称
	Avatar      string `json:"avatar"`       // 头像URL
}

// GetGroupCallConnectedMembersResponse 获取群组通话已连接成员响应
type GetGroupCallConnectedMembersResponse struct {
	ChannelName      string                     `json:"channel_name"`      // 频道名称
	ConnectedMembers []GroupCallConnectedMember `json:"connected_members"` // 已连接成员列表
	TotalInvited     int                        `json:"total_invited"`     // 总邀请人数
	CallStartTime    int64                      `json:"call_start_time"`   // 通话开始时间戳（第一个人接听的时间）
}

// GetGroupCallConnectedMembers 获取群组通话已连接成员列表
// @Summary 获取群组通话已连接成员列表
// @Description 获取指定频道当前已连接（已接听）的成员列表，用于接听后同步成员状态
// @Tags Call
// @Accept json
// @Produce json
// @Param channel_name query string false "频道名称（与 group_id 二选一）"
// @Param group_id query int false "群组ID（与 channel_name 二选一）"
// @Success 200 {object} GetGroupCallConnectedMembersResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 401 {object} map[string]interface{} "未授权"
// @Router /api/call/group_connected_members [get]
func (cc *CallController) GetGroupCallConnectedMembers(c *gin.Context) {
	// 获取当前登录用户ID
	_, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	// 解析请求参数
	channelName := c.Query("channel_name")
	groupIDStr := c.Query("group_id")

	// 🔴 如果提供了 group_id，通过 groupIDToCallInfo 查找 channel_name
	if channelName == "" && groupIDStr != "" {
		groupID, err := strconv.Atoi(groupIDStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "group_id参数无效"})
			return
		}

		callInfo := cc.getGroupCallInfo(groupID)
		if callInfo == nil {
			// 没有正在进行的通话
			c.JSON(http.StatusOK, GetGroupCallConnectedMembersResponse{
				ChannelName:      "",
				ConnectedMembers: []GroupCallConnectedMember{},
				TotalInvited:     0,
				CallStartTime:    0,
			})
			return
		}
		channelName = callInfo.ChannelName
		utils.LogDebug("📞 [群组通话] 通过 group_id=%d 找到 channel_name=%s", groupID, channelName)
	}

	if channelName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少channel_name或group_id参数"})
		return
	}

	// 获取已连接成员ID列表
	cc.groupCallMutex.RLock()
	connectedMemberIDs := make([]int, 0)
	if members, exists := cc.groupCallConnectedMembers[channelName]; exists {
		connectedMemberIDs = append(connectedMemberIDs, members...)
	}
	
	// 获取总邀请人数
	totalInvited := 0
	if members, exists := cc.groupCallMembers[channelName]; exists {
		totalInvited = len(members)
	}
	
	// 获取通话开始时间
	callStartTime := int64(0)
	if startTime, exists := cc.groupCallStartTime[channelName]; exists {
		callStartTime = startTime
	}
	cc.groupCallMutex.RUnlock()

	// 获取每个已连接成员的详细信息
	connectedMembers := make([]GroupCallConnectedMember, 0, len(connectedMemberIDs))
	for _, memberID := range connectedMemberIDs {
		user, err := cc.userRepo.FindByID(memberID)
		if err != nil {
			utils.LogDebug("⚠️ [群组通话] 获取用户 %d 信息失败: %v", memberID, err)
			continue
		}

		displayName := user.Username
		if user.FullName != nil && *user.FullName != "" {
			displayName = *user.FullName
		}

		avatar := user.Avatar  // Avatar 是 string 类型，不是指针

		connectedMembers = append(connectedMembers, GroupCallConnectedMember{
			UserID:      memberID,
			Username:    user.Username,
			DisplayName: displayName,
			Avatar:      avatar,
		})
	}

	utils.LogDebug("✅ [群组通话] 获取已连接成员列表，频道: %s, 已连接: %d 人, 总邀请: %d 人",
		channelName, len(connectedMembers), totalInvited)

	c.JSON(http.StatusOK, GetGroupCallConnectedMembersResponse{
		ChannelName:      channelName,
		ConnectedMembers: connectedMembers,
		TotalInvited:     totalInvited,
		CallStartTime:    callStartTime,
	})
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

	// 🔴 将接听者添加到已连接成员列表（接听后即为已连接）
	cc.addConnectedMember(req.ChannelName, accepterUserID)

	// 🔴 记录通话开始时间（第一个被邀请人接听时记录）
	// 通话时长从第一个人接听开始算起
	cc.recordCallStartTime(req.ChannelName)

	// 🔴 使用 TRTC 生成 UserSig
	// 检查 TRTC 配置
	if config.AppConfig.TRTCSDKAppID == 0 || config.AppConfig.TRTCSecretKey == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "TRTC配置未设置，请联系管理员"})
		utils.LogDebug("❌ TRTC配置未设置: SDKAppID=%d, SecretKey=%s",
			config.AppConfig.TRTCSDKAppID, config.AppConfig.TRTCSecretKey)
		return
	}

	// 生成 UserSig 的有效期（7天）
	expireTime := 604800
	userSig, err := utils.GenerateUserSig(
		config.AppConfig.TRTCSDKAppID,
		config.AppConfig.TRTCSecretKey,
		strconv.Itoa(accepterUserID),
		expireTime,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成UserSig失败: " + err.Error()})
		utils.LogDebug("❌ 为接听者生成UserSig失败: %v", err)
		return
	}

	// 通知群组中的其他成员有人接听了通话
	// 从频道名称解析出发起者ID，然后获取完整的成员列表
	go cc.notifyGroupCallMemberAcceptedWithMembers(req.ChannelName, accepterUserID, accepterUser.Username, accepterUser.FullName)

	utils.LogDebug("✅ [群组通话] 用户 %d 接听群组通话, 频道: %s", accepterUserID, req.ChannelName)

	c.JSON(http.StatusOK, gin.H{
		"message":      "已接听群组通话",
		"channel_name": req.ChannelName,
		"user_sig":     userSig,
		"sdk_app_id":   config.AppConfig.TRTCSDKAppID,
		"user_id":      strconv.Itoa(accepterUserID),
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

// addMemberToGroupCall 将成员添加到群组通话（被邀请的成员）
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

// 🔴 新增：将成员标记为已连接（接听/加入通话后调用）
func (cc *CallController) addConnectedMember(channelName string, userID int) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	if members, exists := cc.groupCallConnectedMembers[channelName]; exists {
		// 检查成员是否已存在
		for _, memberID := range members {
			if memberID == userID {
				return // 成员已存在，不重复添加
			}
		}
		// 添加新成员
		cc.groupCallConnectedMembers[channelName] = append(members, userID)
	} else {
		// 创建新的已连接成员列表
		cc.groupCallConnectedMembers[channelName] = []int{userID}
	}

	utils.LogDebug("✅ [群组通话] 用户 %d 已标记为已连接，频道 %s，当前已连接成员: %v", userID, channelName, cc.groupCallConnectedMembers[channelName])
}

// 🔴 新增：记录通话开始时间（第一个被邀请人接听时调用）
// 只有当还没有记录开始时间时才记录，确保是第一个接听的时间
func (cc *CallController) recordCallStartTime(channelName string) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	// 只有当还没有记录开始时间时才记录
	if _, exists := cc.groupCallStartTime[channelName]; !exists {
		cc.groupCallStartTime[channelName] = time.Now().Unix()
		utils.LogDebug("✅ [群组通话] 记录通话开始时间，频道 %s，时间戳: %d", channelName, cc.groupCallStartTime[channelName])
	}
}

// 🔴 新增：获取通话开始时间，如果没有人接听过则返回 0
func (cc *CallController) getCallStartTime(channelName string) int64 {
	cc.groupCallMutex.RLock()
	defer cc.groupCallMutex.RUnlock()

	if startTime, exists := cc.groupCallStartTime[channelName]; exists {
		return startTime
	}
	return 0
}

// 🔴 新增：清理通话开始时间记录
func (cc *CallController) clearCallStartTime(channelName string) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	delete(cc.groupCallStartTime, channelName)
	utils.LogDebug("🗑️ [群组通话] 已清理通话开始时间记录，频道 %s", channelName)
}

// 🔴 新增：从已连接成员中移除，并返回剩余的已连接成员数量
func (cc *CallController) removeConnectedMember(channelName string, userID int) int {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	members, exists := cc.groupCallConnectedMembers[channelName]
	if !exists {
		return 0
	}

	// 查找并移除成员
	for i, memberID := range members {
		if memberID == userID {
			cc.groupCallConnectedMembers[channelName] = append(members[:i], members[i+1:]...)
			break
		}
	}

	// 如果没有已连接成员了，删除整个频道的记录
	remainingCount := len(cc.groupCallConnectedMembers[channelName])
	if remainingCount == 0 {
		delete(cc.groupCallConnectedMembers, channelName)
		utils.LogDebug("🗑️ [群组通话] 频道 %s 已连接成员列表已清空", channelName)
	} else {
		utils.LogDebug("✅ [群组通话] 用户 %d 已从已连接成员中移除，频道 %s，剩余已连接成员: %v", userID, channelName, cc.groupCallConnectedMembers[channelName])
	}

	return remainingCount
}

// removeMemberFromGroupCall 从群组通话中移除成员（被邀请的成员列表）
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
	ChannelName  string `json:"channel_name" binding:"required"` // 频道名称
	GroupID      *int   `json:"group_id"`                        // 群组ID（可选，如果在群组内通话则传递）
	CallType     string `json:"call_type"`                       // 通话类型（voice/video）
	CheckEndCall bool   `json:"check_end_call"`                  // 是否检查并结束通话（当最后一个成员离开时）
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
	utils.LogDebug("📞 ========== LeaveGroupCall 开始 ==========")
	
	// 获取当前登录用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	leavingUserID := userID.(int)
	utils.LogDebug("📞 [LeaveGroupCall] leavingUserID: %d", leavingUserID)

	// 解析请求参数
	var req LeaveGroupCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}
	
	utils.LogDebug("📞 [LeaveGroupCall] 请求参数:")
	utils.LogDebug("📞 [LeaveGroupCall]   - ChannelName: %s", req.ChannelName)
	utils.LogDebug("📞 [LeaveGroupCall]   - GroupID: %v", req.GroupID)
	utils.LogDebug("📞 [LeaveGroupCall]   - CallType: %s", req.CallType)
	utils.LogDebug("📞 [LeaveGroupCall]   - CheckEndCall: %v", req.CheckEndCall)

	// 获取离开用户的信息
	leavingUser, err := cc.userRepo.FindByID(leavingUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}
	utils.LogDebug("📞 [LeaveGroupCall] 离开用户: %s", leavingUser.Username)

	// 从群组通话中移除成员（被邀请成员列表）
	utils.LogDebug("📞 [LeaveGroupCall] 准备从被邀请成员列表中移除用户 %d", leavingUserID)
	remainingMembers := cc.removeMemberFromGroupCall(req.ChannelName, leavingUserID)
	utils.LogDebug("📞 [LeaveGroupCall] 移除后剩余被邀请成员: %v (共 %d 人)", remainingMembers, len(remainingMembers))

	// 🔴 从已连接成员中移除，并获取剩余已连接成员数量
	// 注意：此时当前用户已经从已连接成员列表中移除了
	utils.LogDebug("📞 [LeaveGroupCall] 准备从已连接成员列表中移除用户 %d", leavingUserID)
	remainingConnectedCount := cc.removeConnectedMember(req.ChannelName, leavingUserID)
	utils.LogDebug("📞 [LeaveGroupCall] 移除后剩余已连接成员数: %d", remainingConnectedCount)

	// 🔴 判断通话是否结束：
	// 1. 当没有已连接成员时（remainingConnectedCount == 0），通话结束
	// 2. 当只剩一个已连接成员时（remainingConnectedCount == 1），也视为通话结束
	//    因为一个人无法进行通话，此时应该移除"加入通话"按钮
	// 注意：判断时机是在当前用户退出房间后
	isCallEnded := remainingConnectedCount <= 1
	utils.LogDebug("📞 [LeaveGroupCall] 通话是否结束: %v (remainingConnectedCount=%d <= 1)", isCallEnded, remainingConnectedCount)

	utils.LogDebug("🔍 [群组通话] 用户 %d 离开，剩余被邀请成员: %d，剩余已连接成员: %d，通话结束: %v",
		leavingUserID, len(remainingMembers), remainingConnectedCount, isCallEnded)

	// 通知其他成员有人离开了群组通话
	if len(remainingMembers) > 0 {
		utils.LogDebug("📞 [LeaveGroupCall] 准备通知其他成员有人离开")
		go cc.notifyGroupCallMemberLeft(req.ChannelName, leavingUserID, leavingUser.Username, leavingUser.FullName, remainingMembers)
	}

	// 🔴 当通话结束时（没有已连接成员或只剩一个），移除"加入通话"按钮
	if isCallEnded && req.GroupID != nil && *req.GroupID > 0 {
		utils.LogDebug("📞 [LeaveGroupCall] 通话结束，准备清理资源")
		
		// 🔴 通知所有被邀请但未接听的成员关闭来电弹窗
		if len(remainingMembers) > 0 {
			utils.LogDebug("📞 [LeaveGroupCall] 准备通知未接听成员关闭来电弹窗")
			go cc.notifyGroupCallEnded(req.ChannelName, remainingMembers)
		}

		// 🔴 删除"加入通话"按钮消息
		utils.LogDebug("📞 [LeaveGroupCall] 准备删除加入通话按钮消息")
		go cc.removeJoinCallButtonMessage(*req.GroupID, req.ChannelName)

		// 🔴 计算通话时长：从第一个被邀请人接听开始算起
		// 如果没有人接听过，通话时长为 0
		callStartTime := cc.getCallStartTime(req.ChannelName)
		var callDuration int64 = 0
		if callStartTime > 0 {
			callDuration = time.Now().Unix() - callStartTime
			utils.LogDebug("🔍 [群组通话] 计算通话时长 - 当前时间: %d, 开始时间: %d, 时长: %d秒", time.Now().Unix(), callStartTime, callDuration)
		} else {
			utils.LogDebug("🔍 [群组通话] 没有人接听过，通话时长为 0")
		}

		// 🔴 根据通话时长决定消息内容
		var systemMessage string
		if callDuration == 0 {
			// 没有人接听过，显示"发起人已取消"
			systemMessage = "发起人已取消"
		} else {
			// 有人接听过，显示通话时长
			durationMinutes := callDuration / 60
			durationSeconds := callDuration % 60
			durationText := fmt.Sprintf("%02d:%02d", durationMinutes, durationSeconds)
			systemMessage = fmt.Sprintf("通话时长 %s", durationText)
		}
		utils.LogDebug("📞 [LeaveGroupCall] 系统消息: %s", systemMessage)

		// 根据通话类型设置正确的 message_type
		messageType := "call_ended" // 默认语音通话
		if req.CallType == "video" {
			messageType = "call_ended_video" // 视频通话
		}
		utils.LogDebug("📞 [LeaveGroupCall] 消息类型: %s", messageType)

		// 异步发送系统消息到群组
		go func() {
			err := cc.sendSystemMessageToGroup(*req.GroupID, leavingUserID, systemMessage, messageType, req.CallType, req.ChannelName)
			if err != nil {
				utils.LogDebug("⚠️ [群组通话] 发送通话结束系统消息失败: %v", err)
			} else {
				utils.LogDebug("✅ [群组通话] 通话结束系统消息已发送到群组 %d: %s (类型: %s)", *req.GroupID, systemMessage, messageType)
			}
		}()

		// 🔴 清理通话开始时间记录
		cc.clearCallStartTime(req.ChannelName)

		// 🔴 清理被邀请成员列表（因为通话已结束）
		cc.groupCallMutex.Lock()
		delete(cc.groupCallMembers, req.ChannelName)
		cc.groupCallMutex.Unlock()
		utils.LogDebug("🗑️ [群组通话] 通话结束，已清理频道 %s 的所有成员列表", req.ChannelName)

		// 🔴 清理群组ID到通话信息的映射
		cc.clearGroupCallInfo(*req.GroupID)
	}

	utils.LogDebug("👋 [群组通话] 用户 %d(%s) 离开群组通话, 频道: %s, 剩余被邀请成员: %d, 剩余已连接成员: %d, 通话结束: %v",
		leavingUserID, leavingUser.Username, req.ChannelName, len(remainingMembers), remainingConnectedCount, isCallEnded)

	// 🔴 返回是否是最后一个成员离开（通话结束）
	utils.LogDebug("📞 ========== LeaveGroupCall 结束 ==========")
	c.JSON(http.StatusOK, gin.H{
		"message": "已离开群组通话",
		"data": gin.H{
			"is_call_ended": isCallEnded,
		},
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

// 🔴 新增：通知被邀请但未接听的成员，群组通话已结束（关闭来电弹窗）
func (cc *CallController) notifyGroupCallEnded(channelName string, memberIDs []int) {
	notification := map[string]interface{}{
		"type":         "group_call_ended", // 消息类型：群组通话结束
		"channel_name": channelName,        // 频道名称
		"timestamp":    time.Now().Unix(),  // 时间戳
	}

	// 序列化消息
	message, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化通话结束通知失败: %v", err)
		return
	}

	// 向所有被邀请但未接听的成员发送通知
	for _, memberID := range memberIDs {
		cc.Hub.SendToUser(memberID, message)
	}

	utils.LogDebug("✅ [群组通话] 通话结束通知已发送，频道: %s, 通知成员: %v", channelName, memberIDs)
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
		"is_read":      false, // 新消息默认未读
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

	// 🔴 注意：不再发送额外的 group_call_notification 通知
	// 因为 group_message 已经包含了所有必要的信息（message_type, call_type, channel_name）
	// 客户端会根据 message_type 来判断是否显示为按钮

	utils.LogDebug("✅ [群组通话] 系统消息已广播到 %d 个群组成员", len(memberIDs))
	return nil
}

// removeJoinCallButtonMessage 删除群组中的"加入通话"按钮消息
// 🔴 修改：直接删除按钮消息，而不是更新消息类型
// 因为"XX发起了语音通话"已经是单独的消息，按钮消息可以直接删除
func (cc *CallController) removeJoinCallButtonMessage(groupID int, channelName string) {
	// 先查询要删除的消息ID
	var deletedMessageID int
	querySelect := `
		SELECT id FROM group_messages 
		WHERE group_id = $1 
		AND (message_type = 'join_voice_button' OR message_type = 'join_video_button')
		AND channel_name = $2
		LIMIT 1
	`
	err := db.DB.QueryRow(querySelect, groupID, channelName).Scan(&deletedMessageID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.LogDebug("⚠️ [群组通话] 未找到需要删除的加入通话按钮消息 - GroupID: %d, ChannelName: %s", groupID, channelName)
		} else {
			utils.LogDebug("❌ [群组通话] 查询加入通话按钮消息失败: %v", err)
		}
		return
	}

	// 删除按钮消息
	queryDelete := `
		DELETE FROM group_messages 
		WHERE group_id = $1 
		AND (message_type = 'join_voice_button' OR message_type = 'join_video_button')
		AND channel_name = $2
	`
	_, err = db.DB.Exec(queryDelete, groupID, channelName)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 删除加入通话按钮消息失败: %v", err)
		return
	}

	utils.LogDebug("✅ [群组通话] 已删除按钮消息 - MessageID: %d, GroupID: %d, ChannelName: %s", deletedMessageID, groupID, channelName)

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

	// 向所有在线成员发送删除消息通知
	// 客户端收到后会从消息列表中移除该按钮消息
	notification := map[string]interface{}{
		"type": "delete_message",
		"data": map[string]interface{}{
			"message_id": deletedMessageID,
			"group_id":   groupID,
			"reason":     "call_ended", // 通话结束原因
		},
	}

	notificationBytes, err := json.Marshal(notification)
	if err != nil {
		utils.LogDebug("❌ [群组通话] 序列化删除通知失败: %v", err)
		return
	}

	// 🔴 调试日志：打印发送的通知内容
	utils.LogDebug("📤 [群组通话] 准备发送 delete_message 通知:")
	utils.LogDebug("📤 [群组通话] - message_id: %d", deletedMessageID)
	utils.LogDebug("📤 [群组通话] - group_id: %d", groupID)
	utils.LogDebug("📤 [群组通话] - 通知JSON: %s", string(notificationBytes))
	utils.LogDebug("📤 [群组通话] - 目标成员数: %d, 成员IDs: %v", len(memberIDs), memberIDs)

	// 向所有在线成员广播删除通知
	for _, memberID := range memberIDs {
		utils.LogDebug("📤 [群组通话] 发送 delete_message 到用户: %d", memberID)
		cc.Hub.SendToUser(memberID, notificationBytes)
	}

	utils.LogDebug("✅ [群组通话] 删除消息通知已广播到 %d 个群组成员", len(memberIDs))
}

// setGroupCallInfo 设置群组通话信息
func (cc *CallController) setGroupCallInfo(groupID int, channelName, callType string, callerID int) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	cc.groupIDToCallInfo[groupID] = &GroupCallInfo{
		ChannelName: channelName,
		CallType:    callType,
		CallerID:    callerID,
		StartTime:   time.Now().Unix(),
	}
	utils.LogDebug("✅ [群组通话] 已记录群组 %d 的通话信息: channelName=%s, callType=%s", groupID, channelName, callType)
}

// clearGroupCallInfo 清除群组通话信息
func (cc *CallController) clearGroupCallInfo(groupID int) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	if _, exists := cc.groupIDToCallInfo[groupID]; exists {
		delete(cc.groupIDToCallInfo, groupID)
		utils.LogDebug("🗑️ [群组通话] 已清除群组 %d 的通话信息", groupID)
	}
}

// getGroupCallInfo 获取群组通话信息
func (cc *CallController) getGroupCallInfo(groupID int) *GroupCallInfo {
	cc.groupCallMutex.RLock()
	defer cc.groupCallMutex.RUnlock()

	if info, exists := cc.groupIDToCallInfo[groupID]; exists {
		return info
	}
	return nil
}

// GetGroupCallStatusRequest 获取群组通话状态请求
type GetGroupCallStatusRequest struct {
	GroupID int `form:"group_id" binding:"required"` // 群组ID
}

// GetGroupCallStatusResponse 获取群组通话状态响应
type GetGroupCallStatusResponse struct {
	HasActiveCall bool   `json:"has_active_call"` // 是否有正在进行的通话
	ChannelName   string `json:"channel_name"`    // 频道名称（如果有通话）
	CallType      string `json:"call_type"`       // 通话类型（如果有通话）
	CallerID      int    `json:"caller_id"`       // 发起者ID（如果有通话）
	MemberCount   int    `json:"member_count"`    // 当前已连接成员数量
}

// GetGroupCallStatus 获取群组通话状态
// @Summary 获取群组通话状态
// @Description 查询指定群组是否有正在进行的通话
// @Tags Call
// @Accept json
// @Produce json
// @Param group_id query int true "群组ID"
// @Success 200 {object} GetGroupCallStatusResponse
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 401 {object} map[string]interface{} "未授权"
// @Router /api/call/group_status [get]
func (cc *CallController) GetGroupCallStatus(c *gin.Context) {
	// 获取当前登录用户ID
	_, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	// 解析请求参数
	groupIDStr := c.Query("group_id")
	if groupIDStr == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少group_id参数"})
		return
	}

	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "group_id参数无效"})
		return
	}

	// 获取群组通话信息
	callInfo := cc.getGroupCallInfo(groupID)

	if callInfo == nil {
		// 没有正在进行的通话
		c.JSON(http.StatusOK, GetGroupCallStatusResponse{
			HasActiveCall: false,
			ChannelName:   "",
			CallType:      "",
			CallerID:      0,
			MemberCount:   0,
		})
		return
	}

	// 获取当前已连接成员数量
	cc.groupCallMutex.RLock()
	memberCount := len(cc.groupCallConnectedMembers[callInfo.ChannelName])
	cc.groupCallMutex.RUnlock()

	// 有正在进行的通话
	c.JSON(http.StatusOK, GetGroupCallStatusResponse{
		HasActiveCall: true,
		ChannelName:   callInfo.ChannelName,
		CallType:      callInfo.CallType,
		CallerID:      callInfo.CallerID,
		MemberCount:   memberCount,
	})

	utils.LogDebug("📞 [群组通话状态] 群组 %d 有正在进行的%s通话, 频道: %s, 已连接成员: %d",
		groupID, callInfo.CallType, callInfo.ChannelName, memberCount)
}

// SendGroupCallMessageRequest 发送群组通话消息请求
type SendGroupCallMessageRequest struct {
	GroupID  int    `json:"group_id" binding:"required"`  // 群组ID
	CallType string `json:"call_type"`                    // 通话类型：voice 或 video（默认voice）
}

// SendGroupCallMessage 发送群组通话发起消息
// @Summary 发送群组通话发起消息
// @Description 当使用 TUICallKit 内置 UI 发起群组通话时，调用此接口发送"XX发起了群组语音通话"消息和"加入通话"按钮
// @Tags Call
// @Accept json
// @Produce json
// @Param request body SendGroupCallMessageRequest true "发送群组通话消息请求"
// @Success 200 {object} map[string]interface{}
// @Failure 400 {object} map[string]interface{} "请求参数错误"
// @Failure 401 {object} map[string]interface{} "未授权"
// @Router /api/call/send_group_call_message [post]
func (cc *CallController) SendGroupCallMessage(c *gin.Context) {
	// 获取当前登录用户ID（发起者）
	callerID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	callerUserID := callerID.(int)

	// 解析请求参数
	var req SendGroupCallMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 默认通话类型为语音
	if req.CallType == "" {
		req.CallType = "voice"
	}

	// 获取发起者用户信息
	callerUser, err := cc.userRepo.FindByID(callerUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取用户信息失败"})
		return
	}

	// 获取发起者显示名称（优先使用群昵称）
	callerDisplayName := callerUser.Username
	if cc.groupRepo != nil {
		if name, err := cc.groupRepo.GetGroupMemberNickname(req.GroupID, callerUserID); err == nil && name != "" {
			callerDisplayName = name
		} else if callerUser.FullName != nil && *callerUser.FullName != "" {
			callerDisplayName = *callerUser.FullName
		}
	} else if callerUser.FullName != nil && *callerUser.FullName != "" {
		callerDisplayName = *callerUser.FullName
	}

	// 生成频道名称（用于通话状态管理）
	timestamp := time.Now().Unix()
	channelName := fmt.Sprintf("tuicallkit_group_%d_%d", req.GroupID, timestamp)

	// 构建消息内容
	callTypeText := "语音通话"
	initiatedMessageType := "group_call_initiated"
	if req.CallType == "video" {
		callTypeText = "视频通话"
		initiatedMessageType = "group_video_call_initiated"
	}
	initiatedMessage := fmt.Sprintf("%s发起了%s", callerDisplayName, callTypeText)

	// 🔴 存储群组ID和通话信息的关联（用于查询群组是否有正在进行的通话）
	cc.setGroupCallInfo(req.GroupID, channelName, req.CallType, callerUserID)

	// 🔴 将发起者添加到已连接成员列表
	cc.addMemberToGroupCall(channelName, callerUserID)
	cc.addConnectedMember(channelName, callerUserID)

	// 🔴 只发送"XX发起了语音通话"消息，不发送"加入通话"按钮消息
	// 因为客户端会自己显示"加入语音通话"按钮
	go func() {
		// 发送"XX发起了语音通话"消息
		err := cc.sendSystemMessageToGroup(req.GroupID, callerUserID, initiatedMessage, initiatedMessageType, req.CallType, "")
		if err != nil {
			utils.LogDebug("⚠️ [群组通话] 发送通话发起消息失败: %v", err)
		} else {
			utils.LogDebug("✅ [群组通话] 通话发起消息已发送到群组 %d: %s", req.GroupID, initiatedMessage)
		}
	}()

	utils.LogDebug("📞 [群组通话] 用户 %d(%s) 通过 TUICallKit 发起%s群组通话, 群组: %d, 频道: %s",
		callerUserID, callerUser.Username, req.CallType, req.GroupID, channelName)

	c.JSON(http.StatusOK, gin.H{
		"message":      "群组通话消息已发送",
		"channel_name": channelName,
		"group_id":     req.GroupID,
		"call_type":    req.CallType,
	})
}

// ClearGroupCallStateByGroupID 根据群组ID清理群组通话状态
// 当收到 group_call_ended WebSocket 信号时调用，用于清理服务器内存中的通话状态
func (cc *CallController) ClearGroupCallStateByGroupID(groupID int) {
	cc.groupCallMutex.Lock()
	defer cc.groupCallMutex.Unlock()

	// 获取该群组的通话信息
	callInfo, exists := cc.groupIDToCallInfo[groupID]
	if !exists {
		utils.LogDebug("⚠️ [ClearGroupCallStateByGroupID] 群组 %d 没有正在进行的通话", groupID)
		return
	}

	channelName := callInfo.ChannelName
	utils.LogDebug("🗑️ [ClearGroupCallStateByGroupID] 开始清理群组 %d 的通话状态, channelName: %s", groupID, channelName)

	// 清理被邀请成员列表
	if _, exists := cc.groupCallMembers[channelName]; exists {
		delete(cc.groupCallMembers, channelName)
		utils.LogDebug("🗑️ [ClearGroupCallStateByGroupID] 已清理被邀请成员列表")
	}

	// 清理已连接成员列表
	if _, exists := cc.groupCallConnectedMembers[channelName]; exists {
		delete(cc.groupCallConnectedMembers, channelName)
		utils.LogDebug("🗑️ [ClearGroupCallStateByGroupID] 已清理已连接成员列表")
	}

	// 清理通话开始时间
	if _, exists := cc.groupCallStartTime[channelName]; exists {
		delete(cc.groupCallStartTime, channelName)
		utils.LogDebug("🗑️ [ClearGroupCallStateByGroupID] 已清理通话开始时间")
	}

	// 清理群组ID到通话信息的映射
	delete(cc.groupIDToCallInfo, groupID)
	utils.LogDebug("🗑️ [ClearGroupCallStateByGroupID] 已清理群组ID到通话信息的映射")

	utils.LogDebug("✅ [ClearGroupCallStateByGroupID] 群组 %d 的通话状态已完全清理", groupID)
}
