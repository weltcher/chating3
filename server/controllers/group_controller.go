package controllers

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/services"
	"youdu-server/utils"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
)

// GroupController 群组控制器
type GroupController struct {
	Hub       *ws.Hub
	groupRepo *models.GroupRepository
	userRepo  *models.UserRepository
}

// NewGroupController 创建群组控制器
func NewGroupController(hub *ws.Hub) *GroupController {
	return &GroupController{
		Hub:       hub,
		groupRepo: models.NewGroupRepository(db.DB),
		userRepo:  models.NewUserRepository(db.DB),
	}
}

// CreateGroup 创建群组
func (gc *GroupController) CreateGroup(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req models.CreateGroupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		// 友好的中文错误提示
		if len(req.MemberIDs) == 0 {
			utils.Error(c, http.StatusBadRequest, "请至少选择一个群组成员")
			return
		}
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 获取当前用户信息
	user, err := gc.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.Error(c, http.StatusInternalServerError, "获取用户信息失败")
		return
	}

	// 创建群组
	var announcement *string
	if req.Announcement != "" {
		announcement = &req.Announcement
	}

	var avatar *string
	if req.Avatar != "" {
		avatar = &req.Avatar
	}

	group, err := gc.groupRepo.CreateGroup(req.Name, announcement, avatar, user.ID)
	if err != nil {
		utils.LogDebug("创建群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "创建群组失败")
		return
	}

	// 添加群主
	var nickname *string
	if req.Nickname != "" {
		nickname = &req.Nickname
	}
	var remark *string
	if req.Remark != "" {
		remark = &req.Remark
	}

	// 使用支持消息免打扰设置的方法添加群主
	err = gc.groupRepo.AddGroupMemberWithDoNotDisturb(group.ID, user.ID, nickname, remark, "owner", req.DoNotDisturb)
	if err != nil {
		utils.LogDebug("添加群主失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "添加群主失败")
		return
	}

	// 添加群组成员（普通成员默认不开启消息免打扰）
	for _, memberID := range req.MemberIDs {
		if memberID != user.ID {
			err = gc.groupRepo.AddGroupMember(group.ID, memberID, nil, nil, "member")
			if err != nil {
				utils.LogDebug("添加群组成员失败 (UserID: %d): %v", memberID, err)
				// 继续添加其他成员
			}
		}
	}

	// 创建系统消息：群组已创建，并推送给所有成员（包括群主）
	go gc.sendGroupCreatedNotification(group.ID, user.ID, user.Username)

	// 同步群组到腾讯云 IM（异步执行，不影响创建流程）
	go func() {
		// 收集所有成员ID（包括群主）
		allMemberIDs := append([]int{user.ID}, req.MemberIDs...)
		if err := services.TencentIM.CreateGroup(group.ID, req.Name, user.ID, allMemberIDs); err != nil {
			utils.LogDebug("⚠️ 同步群组到腾讯云 IM 失败: %v", err)
		}
	}()

	utils.Success(c, gin.H{
		"group": group,
	})
}

// GetGroup 获取群组详情
func (gc *GroupController) GetGroup(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组失败")
		return
	}

	// 获取当前用户在群组中的角色
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			// 用户不是群组成员，返回基本信息（用于扫码加入场景）
			// 只返回群组基本信息和成员数量，不返回成员列表
			members, err := gc.groupRepo.GetGroupMembers(groupID)
			if err != nil {
				utils.LogDebug("获取群组成员失败: %v", err)
				utils.Error(c, http.StatusInternalServerError, "获取群组成员失败")
				return
			}

			utils.Success(c, models.GroupDetailResponse{
				Group:      *group,
				Members:    members, // 返回成员列表用于显示成员数量
				MemberRole: "", // 非成员，角色为空
			})
			return
		}
		utils.LogDebug("获取用户角色失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取用户角色失败")
		return
	}

	// 获取群组成员列表（带当前用户优先排序）
	// 群主和管理员可以看到待审核成员，普通成员只能看到已通过的成员
	var members []models.GroupMemberDetail
	if role == "owner" || role == "admin" {
		members, err = gc.groupRepo.GetGroupMembersWithPending(groupID, userID.(int))
	} else {
		members, err = gc.groupRepo.GetGroupMembers(groupID, userID.(int))
	}
	if err != nil {
		utils.LogDebug("获取群组成员失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组成员失败")
		return
	}

	utils.Success(c, models.GroupDetailResponse{
		Group:      *group,
		Members:    members,
		MemberRole: role,
	})
}

// UpdateGroup 更新群组信息
func (gc *GroupController) UpdateGroup(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	var req struct {
		Name          *string `json:"name"`
		Announcement  *string `json:"announcement"`
		Avatar        *string `json:"avatar"`         // 群组头像
		Nickname      *string `json:"nickname"`       // 用户在群组中的昵称
		Remark        *string `json:"remark"`         // 用户对群组的备注
		DoNotDisturb  *bool   `json:"do_not_disturb"` // 消息免打扰
		AddMembers    []int   `json:"add_members"`    // 要添加的成员ID列表
		RemoveMembers []int   `json:"remove_members"` // 要移除的成员ID列表
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证用户是否是群组成员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 更新用户自己在群组中的个人信息（昵称、备注和消息免打扰）- 所有成员都可以修改
	if req.Nickname != nil || req.Remark != nil || req.DoNotDisturb != nil {
		err = gc.groupRepo.UpdateGroupMemberInfo(groupID, userID.(int), req.Nickname, req.Remark, req.DoNotDisturb)
		if err != nil {
			utils.LogDebug("更新群组成员信息失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "更新个人信息失败")
			return
		}

		// 如果更新了昵称，通知所有群组成员更新历史记录
		if req.Nickname != nil {
			utils.LogDebug("🔔 用户 %d 在群组 %d 中更新了昵称: %s", userID.(int), groupID, *req.Nickname)

			// 获取当前用户信息
			user, err := gc.userRepo.FindByID(userID.(int))
			if err == nil {
				// 获取群组所有成员
				members, err := gc.groupRepo.GetGroupMembers(groupID)
				if err == nil {
					// 向所有群组成员推送昵称更新通知
					for _, member := range members {
						notificationData := gin.H{
							"type": "group_nickname_updated",
							"data": gin.H{
								"group_id":     groupID,
								"user_id":      userID.(int),
								"username":     user.Username,
								"new_nickname": *req.Nickname,
								"timestamp":    time.Now().Unix(),
							},
						}
						notificationJSON, _ := json.Marshal(notificationData)
						gc.Hub.SendToUser(member.UserID, notificationJSON)
					}
					utils.LogDebug("✅ 已向 %d 个群组成员推送昵称更新通知", len(members))
				}
			}
		}
	}

	// 更新群组基本信息
	if req.Name != nil || req.Announcement != nil || req.Avatar != nil {
		// 群组名称权限检查：只有群主和管理员可以修改群名称
		if req.Name != nil {
			if role != "owner" && role != "admin" {
				utils.Error(c, http.StatusForbidden, "只有群主和管理员可以修改群组名称")
				return
			}
		}
		// 群公告群主和管理员都可以修改
		if req.Announcement != nil && role != "owner" && role != "admin" {
			utils.Error(c, http.StatusForbidden, "只有群主和管理员可以修改群公告")
			return
		}
		// 群组头像权限检查：只有群主和管理员可以修改群组头像
		if req.Avatar != nil {
			if role != "owner" && role != "admin" {
				utils.Error(c, http.StatusForbidden, "只有群主和管理员可以修改群组头像")
				return
			}
		}
		err = gc.groupRepo.UpdateGroup(groupID, req.Name, req.Announcement, req.Avatar)
		if err != nil {
			utils.LogDebug("更新群组失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "更新群组失败")
			return
		}

		// 通知所有群组成员群组信息已更新
		members, err := gc.groupRepo.GetGroupMembers(groupID)
		if err == nil {
			// 获取更新后的群组信息
			updatedGroup, err := gc.groupRepo.GetGroupByID(groupID)
			if err == nil {
				// 向所有群组成员广播更新通知
				for _, member := range members {
					notificationData := gin.H{
						"type": "group_info_updated",
						"data": gin.H{
							"group_id": groupID,
							"group":    updatedGroup,
						},
					}
					notificationJSON, _ := json.Marshal(notificationData)
					gc.Hub.SendToUser(member.UserID, notificationJSON)
				}
				utils.LogDebug("✅ 已向 %d 个群组成员广播群组信息更新", len(members))
			}
		}
	}

	// 添加群组成员（所有群成员都可以添加）
	if len(req.AddMembers) > 0 {
		// 获取群组信息，检查是否开启邀请确认
		group, err := gc.groupRepo.GetGroupByID(groupID)
		if err != nil {
			utils.LogDebug("获取群组信息失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
			return
		}

		// 获取操作者信息（用于系统消息的发送者）
		operator, err := gc.userRepo.FindByID(userID.(int))
		if err != nil {
			utils.LogDebug("获取操作者信息失败: %v", err)
		}
		operatorName := "系统"
		if operator != nil {
			operatorName = operator.Username
			if operator.FullName != nil && *operator.FullName != "" {
				operatorName = *operator.FullName
			}
		}

		// 已经在前面验证过用户是群组成员，所以这里不需要额外的权限检查
		for _, memberID := range req.AddMembers {
			// 如果开启了邀请确认且当前用户是普通成员，则添加为待审核状态
			if group.InviteConfirmation && role == "member" {
				err = gc.groupRepo.AddGroupMemberWithApproval(groupID, memberID, nil, nil, "member", "pending")
				if err == nil {
					// 向群主和管理员发送待审核成员通知
					go gc.sendPendingMemberNotification(groupID, userID.(int), operatorName, memberID)
				}
			} else {
				// 群主和管理员添加的成员直接通过
				err = gc.groupRepo.AddGroupMember(groupID, memberID, nil, nil, "member")
				if err == nil {
					// 向新添加的成员发送系统消息：您已被添加到群组
					go gc.sendMemberAddedNotification(groupID, memberID, operatorName)
				}
			}
			if err != nil {
				utils.LogDebug("添加群组成员失败 (user_id=%d): %v", memberID, err)
			}
		}
	}

	// 移除群组成员（群主和管理员可操作，但管理员不能移除群主和其他管理员）
	if len(req.RemoveMembers) > 0 {
		if role != "owner" && role != "admin" {
			utils.Error(c, http.StatusForbidden, "只有群主和管理员可以移除成员")
			return
		}

		// 获取操作者信息（用于系统消息的发送者）
		operator, err := gc.userRepo.FindByID(userID.(int))
		if err != nil {
			utils.LogDebug("获取操作者信息失败: %v", err)
		}
		operatorName := "系统"
		if operator != nil {
			operatorName = operator.Username
			if operator.FullName != nil && *operator.FullName != "" {
				operatorName = *operator.FullName
			}
		}

		for _, memberID := range req.RemoveMembers {
			// 不能移除自己
			if memberID == userID.(int) {
				continue
			}

			// 管理员不能移除群主和其他管理员
			if role == "admin" {
				targetRole, err := gc.groupRepo.GetMemberRole(groupID, memberID)
				if err == nil && (targetRole == "owner" || targetRole == "admin") {
					utils.LogDebug("管理员不能移除群主或其他管理员 (target_user_id=%d)", memberID)
					continue
				}
			}

			// 先向被移除的成员发送系统消息：您已被移除群组（在移除之前发送）
			go gc.sendMemberRemovedNotification(groupID, memberID, userID.(int), operatorName)

			// 等待消息发送完成后再移除成员
			time.Sleep(100 * time.Millisecond)

			err = gc.groupRepo.RemoveGroupMember(groupID, memberID)
			if err != nil {
				utils.LogDebug("移除群组成员失败 (user_id=%d): %v", memberID, err)
			} else {
				utils.LogDebug("✅ 群组成员已移除 (user_id=%d)", memberID)
			}
		}
	}

	// 获取更新后的群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		utils.LogDebug("获取群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组失败")
		return
	}

	utils.Success(c, gin.H{
		"group": group,
	})
}

// GetUserGroups 获取用户的所有群组
func (gc *GroupController) GetUserGroups(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取用户的群组列表（包含备注）
	groups, err := gc.groupRepo.GetUserGroupsWithRemark(userID.(int))
	if err != nil {
		utils.LogDebug("获取用户群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组列表失败")
		return
	}

	utils.Success(c, gin.H{
		"groups": groups,
	})
}

// CreateGroupMessage 创建群组消息
func (gc *GroupController) CreateGroupMessage(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req models.CreateGroupMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 首先检查群组是否已解散
	disbandedManager := models.GetDisbandedGroupsManager()
	if disbandedManager.IsGroupDisbanded(req.GroupID) {
		utils.LogDebug("群组 %d 已被群主解散，拒绝发送消息", req.GroupID)
		utils.Error(c, http.StatusNotFound, "该群组已被群主解散")
		return
	}

	// 验证用户是否是群组成员并获取角色
	userRole, err := gc.groupRepo.GetUserGroupRole(req.GroupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 获取群组信息，检查是否开启全体禁言
	group, err := gc.groupRepo.GetGroupByID(req.GroupID)
	if err != nil {
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 如果开启了全体禁言，只有群主和管理员可以发送消息
	if group.AllMuted && userRole != "owner" && userRole != "admin" {
		utils.Error(c, http.StatusForbidden, "群组已开启全体禁言，只有群主和管理员可以发送消息")
		return
	}

	// 检查用户是否被单独禁言
	isMuted, err := gc.groupRepo.IsGroupMemberMuted(req.GroupID, userID.(int))
	if err != nil {
		utils.LogDebug("检查禁言状态失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "检查禁言状态失败")
		return
	}

	if isMuted {
		utils.Error(c, http.StatusForbidden, "你已被群主禁言")
		return
	}

	// 获取发送者信息
	user, err := gc.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.Error(c, http.StatusInternalServerError, "获取用户信息失败")
		return
	}

	senderName := user.Username
	if user.FullName != nil && *user.FullName != "" {
		senderName = *user.FullName
	}

	// 创建群组消息（HTTP API，没有群昵称信息）
	var avatar *string
	if user.Avatar != "" {
		avatar = &user.Avatar
	}
	message, err := gc.groupRepo.CreateGroupMessage(&req, user.ID, senderName, nil, user.FullName, avatar)
	if err != nil {
		utils.LogDebug("创建群组消息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "发送消息失败")
		return
	}

	// 通过WebSocket发送消息给群组所有成员
	go gc.broadcastGroupMessage(message)

	utils.Success(c, gin.H{
		"message": message,
	})
}

// GetGroupMessages 获取群组消息列表
func (gc *GroupController) GetGroupMessages(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 验证用户是否是群组成员
	_, err = gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 获取limit参数（默认100条）
	limit := 100
	if limitStr := c.Query("limit"); limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	// 获取群组消息，并过滤掉当前用户已删除的消息
	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	// 直接从数据库查询并过滤
	query := `
		SELECT 
			gm.id, 
			gm.group_id, 
			gm.sender_id, 
			gm.sender_name,
			gm.sender_avatar,
			gmem.nickname as sender_nickname,
			gm.content, 
			gm.message_type, 
			gm.file_name, 
			gm.quoted_message_id, 
			gm.quoted_message_content,
			gm.mentioned_user_ids,
			gm.mentions,
			gm.call_type,
			gm.channel_name,
			gm.status, 
			gm.created_at
		FROM group_messages gm
		LEFT JOIN group_members gmem ON gmem.group_id = gm.group_id AND gmem.user_id = gm.sender_id
		WHERE gm.group_id = $1
			AND (gm.deleted_by_users = '' OR gm.deleted_by_users NOT LIKE '%' || $3 || '%')
		ORDER BY gm.created_at DESC
		LIMIT $2
	`

	rows, err := gc.groupRepo.DB.Query(query, groupID, limit, userIDStr)
	if err != nil {
		utils.LogDebug("获取群组消息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取消息失败")
		return
	}
	defer rows.Close()

	var messages []models.GroupMessage
	for rows.Next() {
		var msg models.GroupMessage
		err := rows.Scan(
			&msg.ID,
			&msg.GroupID,
			&msg.SenderID,
			&msg.SenderName,
			&msg.SenderAvatar,
			&msg.SenderNickname,
			&msg.Content,
			&msg.MessageType,
			&msg.FileName,
			&msg.QuotedMessageID,
			&msg.QuotedMessageContent,
			&msg.MentionedUserIDs,
			&msg.Mentions,
			&msg.CallType,
			&msg.ChannelName,
			&msg.Status,
			&msg.CreatedAt,
		)
		if err != nil {
			utils.LogDebug("扫描群组消息失败: %v", err)
			continue
		}
		messages = append(messages, msg)
	}

	// 反转消息顺序（从旧到新）
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}

	if messages == nil {
		messages = []models.GroupMessage{}
	}

	utils.Success(c, gin.H{
		"messages": messages,
	})
}

// broadcastGroupMessage 广播群组消息给所有成员
func (gc *GroupController) broadcastGroupMessage(message *models.GroupMessage) {
	// 获取群组所有成员ID
	memberIDs, err := gc.groupRepo.GetGroupMemberIDs(message.GroupID)
	if err != nil {
		utils.LogDebug("获取群组成员ID列表失败: %v", err)
		return
	}

	// 构建WebSocket消息
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: message.GroupID,
		Data: models.WSGroupMessageData{
			ID:                   message.ID,
			GroupID:              message.GroupID,
			SenderID:             message.SenderID,
			SenderName:           message.SenderName,
			Content:              message.Content,
			MessageType:          message.MessageType,
			FileName:             message.FileName,
			QuotedMessageID:      message.QuotedMessageID,
			QuotedMessageContent: message.QuotedMessageContent,
			CreatedAt:            message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化群组消息失败: %v", err)
		return
	}

	// 向所有群组成员发送消息（不包括发送者自己）
	sentCount := 0
	for _, memberID := range memberIDs {
		if memberID != message.SenderID {
			gc.Hub.SendToUser(memberID, msgBytes)
			sentCount++
		}
	}

	utils.LogDebug("群组消息已广播 - GroupID: %d, MessageID: %d, 发送者: %d, 接收者数量: %d",
		message.GroupID, message.ID, message.SenderID, sentCount)
}

// sendGroupCreatedNotification 发送群组邀请通知给被邀请的成员（不包括群主）
func (gc *GroupController) sendGroupCreatedNotification(groupID int, ownerID int, ownerName string) {
	// 获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		utils.LogDebug("获取群组信息失败: %v", err)
		return
	}

	// 获取群组所有成员ID
	memberIDs, err := gc.groupRepo.GetGroupMemberIDs(groupID)
	if err != nil {
		utils.LogDebug("获取群组成员ID列表失败: %v", err)
		return
	}

	// 获取群主信息
	senderName := ownerName
	if senderName == "" {
		senderName = "系统"
	}

	sentCount := 0

	// 1. 向群主发送"创建新群组"消息
	ownerContent := "创建新群组\"" + group.Name + "\""
	ownerMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     ownerContent,
		MessageType: "system",
	}

	ownerMessage, err := gc.groupRepo.CreateGroupMessage(ownerMsg, ownerID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建群主通知消息失败: %v", err)
	} else {
		// 构建WebSocket消息
		ownerWsMsg := models.WSGroupMessage{
			Type:    "group_message",
			GroupID: groupID,
			Data: models.WSGroupMessageData{
				ID:          ownerMessage.ID,
				GroupID:     ownerMessage.GroupID,
				SenderID:    ownerMessage.SenderID,
				SenderName:  ownerMessage.SenderName,
				Content:     ownerMessage.Content,
				MessageType: ownerMessage.MessageType,
				CreatedAt:   ownerMessage.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
			},
		}

		ownerMsgBytes, err := json.Marshal(ownerWsMsg)
		if err != nil {
			utils.LogDebug("序列化群主通知消息失败: %v", err)
		} else {
			gc.Hub.SendToUser(ownerID, ownerMsgBytes)
			sentCount++
			utils.LogDebug("✅ 群组创建通知已发送给群主 - GroupID: %d, 群主ID: %d, 内容: %s",
				groupID, ownerID, ownerContent)
		}
	}

	// 2. 向被邀请的成员发送邀请消息（排除群主自己）
	// 只创建一条邀请消息记录，避免重复消息
	inviteContent := "您已被邀请加入群组\"" + group.Name + "\""
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     inviteContent,
		MessageType: "system",
	}

	message, err := gc.groupRepo.CreateGroupMessage(createMsg, ownerID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建群组邀请通知消息失败: %v", err)
	} else {
		// 构建WebSocket消息
		wsMsg := models.WSGroupMessage{
			Type:    "group_message",
			GroupID: groupID,
			Data: models.WSGroupMessageData{
				ID:          message.ID,
				GroupID:     message.GroupID,
				SenderID:    message.SenderID,
				SenderName:  message.SenderName,
				Content:     message.Content,
				MessageType: message.MessageType,
				CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
			},
		}

		msgBytes, err := json.Marshal(wsMsg)
		if err != nil {
			utils.LogDebug("序列化群组邀请通知消息失败: %v", err)
		} else {
			// 向所有被邀请的成员发送消息（排除群主）
			for _, memberID := range memberIDs {
				if memberID == ownerID {
					continue
				}
				gc.Hub.SendToUser(memberID, msgBytes)
				sentCount++
				utils.LogDebug("✅ 群组邀请通知已发送给成员 - GroupID: %d, 成员ID: %d, 内容: %s",
					groupID, memberID, inviteContent)
			}
		}
	}

	utils.LogDebug("📢 群组通知发送完成 - GroupID: %d (%s), 群主: %d (%s), 总接收者数量: %d",
		groupID, group.Name, ownerID, ownerName, sentCount)
}

// MuteGroupMember 禁言群组成员
func (gc *GroupController) MuteGroupMember(c *gin.Context) {
	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取要禁言的用户ID
	var req struct {
		UserID int `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证群组是否存在
	_, err = gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 获取当前用户和目标用户的角色
	currentUserRole, err := gc.groupRepo.GetMemberRole(groupID, currentUserID.(int))
	if err != nil {
		utils.Error(c, http.StatusForbidden, "您不是群组成员")
		return
	}

	targetUserRole, err := gc.groupRepo.GetMemberRole(groupID, req.UserID)
	if err != nil {
		utils.Error(c, http.StatusNotFound, "目标用户不是群组成员")
		return
	}

	// 验证权限：只有群主和管理员可以禁言，且不能禁言群主和管理员
	if currentUserRole != "owner" && currentUserRole != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以禁言成员")
		return
	}

	// 不能禁言自己
	if req.UserID == currentUserID.(int) {
		utils.Error(c, http.StatusBadRequest, "不能禁言自己")
		return
	}

	// 不能禁言群主和管理员
	if targetUserRole == "owner" || targetUserRole == "admin" {
		utils.Error(c, http.StatusForbidden, "不能禁言群主和管理员")
		return
	}

	// 执行禁言
	err = gc.groupRepo.MuteGroupMember(groupID, req.UserID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "该用户不是群组成员")
			return
		}
		utils.LogDebug("禁言成员失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "禁言失败")
		return
	}

	// 获取操作者信息
	operator, err := gc.userRepo.FindByID(currentUserID.(int))
	operatorName := "管理员"
	if err == nil && operator != nil {
		operatorName = operator.Username
		if operator.FullName != nil && *operator.FullName != "" {
			operatorName = *operator.FullName
		}
	}

	// 向被禁言的用户发送系统消息通知
	go gc.sendMuteNotificationToUser(groupID, req.UserID, currentUserID.(int), operatorName, true)

	utils.Success(c, gin.H{
		"message": "禁言成功",
	})
}

// UnmuteGroupMember 解除群组成员禁言
func (gc *GroupController) UnmuteGroupMember(c *gin.Context) {
	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取要解除禁言的用户ID
	var req struct {
		UserID int `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证群组是否存在
	_, err = gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 获取当前用户角色
	currentUserRole, err := gc.groupRepo.GetMemberRole(groupID, currentUserID.(int))
	if err != nil {
		utils.Error(c, http.StatusForbidden, "您不是群组成员")
		return
	}

	// 验证权限：只有群主和管理员可以解除禁言
	if currentUserRole != "owner" && currentUserRole != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以解除禁言")
		return
	}

	// 执行解除禁言
	err = gc.groupRepo.UnmuteGroupMember(groupID, req.UserID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "该用户不是群组成员")
			return
		}
		utils.LogDebug("解除禁言失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "解除禁言失败")
		return
	}

	// 获取操作者信息
	operator, err := gc.userRepo.FindByID(currentUserID.(int))
	operatorName := "管理员"
	if err == nil && operator != nil {
		operatorName = operator.Username
		if operator.FullName != nil && *operator.FullName != "" {
			operatorName = *operator.FullName
		}
	}

	// 向被解除禁言的用户发送系统消息通知
	go gc.sendMuteNotificationToUser(groupID, req.UserID, currentUserID.(int), operatorName, false)

	utils.Success(c, gin.H{
		"message": "解除禁言成功",
	})
}

// TransferOwnership 转让群主权限
func (gc *GroupController) TransferOwnership(c *gin.Context) {
	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取新群主的用户ID
	var req struct {
		NewOwnerID int `json:"new_owner_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证当前用户是否是群主
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	if group.OwnerID != currentUserID.(int) {
		utils.Error(c, http.StatusForbidden, "只有群主可以转让权限")
		return
	}

	// 不能转让给自己
	if req.NewOwnerID == currentUserID.(int) {
		utils.Error(c, http.StatusBadRequest, "不能转让给自己")
		return
	}

	// 验证新群主是否是群成员
	isMember, err := gc.groupRepo.IsGroupMember(groupID, req.NewOwnerID)
	if err != nil {
		utils.LogDebug("验证群成员失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "验证群成员失败")
		return
	}
	if !isMember {
		utils.Error(c, http.StatusBadRequest, "新群主必须是群组成员")
		return
	}

	// 执行转让
	err = gc.groupRepo.TransferOwnership(groupID, req.NewOwnerID)
	if err != nil {
		utils.LogDebug("转让群主权限失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "转让失败")
		return
	}

	utils.LogDebug("✅ 群主权限转让成功: 群组ID=%d, 新群主ID=%d", groupID, req.NewOwnerID)

	utils.Success(c, gin.H{
		"message": "转让成功",
	})
}

// DeleteGroup 删除群组（解散群组）
func (gc *GroupController) DeleteGroup(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	currentUserID, _ := c.Get("user_id")

	utils.LogDebug("🗑️ 删除群组请求: 群组ID=%d, 用户ID=%v", groupID, currentUserID)

	// 验证群组是否存在并获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 验证当前用户是否是群主（只有群主才能删除群组）
	if group.OwnerID != currentUserID.(int) {
		utils.Error(c, http.StatusForbidden, "只有群主可以解散群组")
		return
	}

	// 删除群组
	err = gc.groupRepo.DeleteGroup(groupID)
	if err != nil {
		utils.LogDebug("删除群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "删除群组失败")
		return
	}

	utils.LogDebug("✅ 群组删除成功: 群组ID=%d, 群组名称=%s", groupID, group.Name)

	// 将群组ID添加到已解散群组管理器
	disbandedManager := models.GetDisbandedGroupsManager()
	disbandedManager.AddDisbandedGroup(groupID)
	utils.LogDebug("✅ 已添加群组ID到已解散群组管理器: 群组ID=%d", groupID)

	// 通知所有群成员群组已被解散
	gc.Hub.BroadcastGroupDisbanded(groupID)

	utils.Success(c, gin.H{
		"message": "群组已解散",
	})
}

// JoinGroup 加入群组
func (gc *GroupController) JoinGroup(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	utils.LogDebug("🚪 加入群组请求: 群组ID=%d, 用户ID=%v", groupID, currentUserID)

	// 验证群组是否存在
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 检查用户是否已经是群组成员
	isMember, err := gc.groupRepo.IsGroupMember(groupID, currentUserID.(int))
	if err != nil {
		utils.LogDebug("检查群组成员失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "检查群组成员失败")
		return
	}

	if isMember {
		utils.Error(c, http.StatusBadRequest, "您已经是该群组成员")
		return
	}

	// 获取当前用户信息
	user, err := gc.userRepo.FindByID(currentUserID.(int))
	if err != nil {
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取用户信息失败")
		return
	}

	userName := user.Username
	if user.FullName != nil && *user.FullName != "" {
		userName = *user.FullName
	}

	// 如果群组开启了邀请确认，则添加为待审核状态
	if group.InviteConfirmation {
		err = gc.groupRepo.AddGroupMemberWithApproval(groupID, currentUserID.(int), nil, nil, "member", "pending")
		if err != nil {
			utils.LogDebug("添加待审核成员失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "加入群组失败")
			return
		}

		// 向群主和管理员发送待审核成员通知
		go gc.sendPendingMemberNotification(groupID, currentUserID.(int), userName, currentUserID.(int))

		utils.Success(c, gin.H{
			"message": "已提交加入申请，等待群主或管理员审核",
		})
		return
	}

	// 直接加入群组
	err = gc.groupRepo.AddGroupMember(groupID, currentUserID.(int), nil, nil, "member")
	if err != nil {
		utils.LogDebug("加入群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "加入群组失败")
		return
	}

	utils.LogDebug("✅ 用户加入群组成功: 群组ID=%d, 用户ID=%v", groupID, currentUserID)

	// 向新成员发送系统消息：您已加入群组
	go gc.sendMemberJoinedNotification(groupID, currentUserID.(int), userName)

	utils.Success(c, gin.H{
		"message": "群组加入成功",
	})
}

// LeaveGroup 退出群组
func (gc *GroupController) LeaveGroup(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	utils.LogDebug("🚪 退出群组请求: 群组ID=%d, 用户ID=%v", groupID, currentUserID)

	// 验证群组是否存在
	_, err = gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 验证用户是否是群组成员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, currentUserID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 如果是群主，不能直接退出，需要先转让群主权限
	if role == "owner" {
		utils.Error(c, http.StatusForbidden, "群主不能退出群组，请先转让群主权限")
		return
	}

	// 移除群组成员
	err = gc.groupRepo.RemoveGroupMember(groupID, currentUserID.(int))
	if err != nil {
		utils.LogDebug("退出群组失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "退出群组失败")
		return
	}

	utils.LogDebug("✅ 用户退出群组成功: 群组ID=%d, 用户ID=%v", groupID, currentUserID)

	// 通知其他群成员用户已退出（可选，如果需要实时通知的话）
	// 这里可以通过 WebSocket 发送通知

	utils.Success(c, gin.H{
		"message": "已退出群组",
	})
}

// SetGroupAdmins 设置群管理员
func (gc *GroupController) SetGroupAdmins(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	currentUserID, _ := c.Get("user_id")

	// 解析请求体
	var req struct {
		AdminIDs []int `json:"admin_ids" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误")
		return
	}

	utils.LogDebug("👥 设置群管理员请求: 群组ID=%d, 用户ID=%v, 管理员IDs=%v", groupID, currentUserID, req.AdminIDs)

	// 验证管理员数量（最多5个）
	if len(req.AdminIDs) > 5 {
		utils.Error(c, http.StatusBadRequest, "最多只能设置5个管理员")
		return
	}

	// 验证群组是否存在并获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 验证当前用户是否是群主（只有群主才能设置管理员）
	if group.OwnerID != currentUserID.(int) {
		utils.Error(c, http.StatusForbidden, "只有群主可以设置管理员")
		return
	}

	// 验证管理员ID是否都是群成员，且不包括群主
	members, err := gc.groupRepo.GetGroupMembers(groupID)
	if err != nil {
		utils.LogDebug("获取群成员列表失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群成员列表失败")
		return
	}

	memberMap := make(map[int]bool)
	for _, member := range members {
		memberMap[member.UserID] = true
	}

	for _, adminID := range req.AdminIDs {
		// 检查是否是群主
		if adminID == group.OwnerID {
			utils.Error(c, http.StatusBadRequest, "不能将群主设置为管理员")
			return
		}
		// 检查是否是群成员
		if !memberMap[adminID] {
			utils.Error(c, http.StatusBadRequest, "管理员必须是群成员")
			return
		}
	}

	// 设置群管理员
	err = gc.groupRepo.SetGroupAdmins(groupID, req.AdminIDs)
	if err != nil {
		utils.LogDebug("设置群管理员失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "设置管理员失败")
		return
	}

	utils.LogDebug("✅ 群管理员设置成功: 群组ID=%d, 管理员IDs=%v", groupID, req.AdminIDs)

	utils.Success(c, gin.H{
		"message": "管理员设置成功",
	})
}

// UpdateGroupAllMuted 更新群组全体禁言状态
func (gc *GroupController) UpdateGroupAllMuted(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req struct {
		AllMuted bool `json:"all_muted"` // 全体禁言状态
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证用户是否是群主或管理员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 只有群主和管理员可以设置全体禁言
	if role != "owner" && role != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以设置全体禁言")
		return
	}

	// 更新群组全体禁言状态
	err = gc.groupRepo.UpdateGroupAllMuted(groupID, req.AllMuted)
	if err != nil {
		utils.LogDebug("更新全体禁言状态失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "更新全体禁言状态失败")
		return
	}

	// 同步更新所有普通成员的禁言状态
	if req.AllMuted {
		// 开启全体禁言：禁言所有普通成员
		err = gc.groupRepo.MuteAllNormalMembers(groupID)
		if err != nil {
			utils.LogDebug("批量禁言普通成员失败: %v", err)
			// 注意：这里不返回错误，因为群组状态已经更新成功
		} else {
			utils.LogDebug("✅ 已禁言所有普通成员")
		}
	} else {
		// 关闭全体禁言：解除所有普通成员的禁言
		err = gc.groupRepo.UnmuteAllNormalMembers(groupID)
		if err != nil {
			utils.LogDebug("批量解除普通成员禁言失败: %v", err)
			// 注意：这里不返回错误，因为群组状态已经更新成功
		} else {
			utils.LogDebug("✅ 已解除所有普通成员的禁言")
		}
	}

	statusText := "已关闭"
	messageContent := "全体禁言已关闭"
	if req.AllMuted {
		statusText = "已开启，所有普通成员已被禁言"
		messageContent = "全体禁言已开启"
	} else {
		statusText = "已关闭，所有普通成员已解除禁言"
		messageContent = "全体禁言已关闭"
	}

	utils.LogDebug("✅ 全体禁言状态更新成功: 群组ID=%d, 状态=%v", groupID, req.AllMuted)

	// 获取操作者信息
	operator, err := gc.userRepo.FindByID(userID.(int))
	operatorName := "系统"
	if err == nil && operator != nil {
		operatorName = operator.Username
		if operator.FullName != nil && *operator.FullName != "" {
			operatorName = *operator.FullName
		}
	}

	// 向群组所有成员发送系统消息通知
	go gc.sendAllMutedNotificationToGroup(groupID, userID.(int), operatorName, messageContent)

	utils.Success(c, gin.H{
		"message":   "全体禁言" + statusText,
		"all_muted": req.AllMuted,
	})
}

// UpdateGroupInviteConfirmation 更新群组邀请确认状态
func (gc *GroupController) UpdateGroupInviteConfirmation(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req struct {
		InviteConfirmation bool `json:"invite_confirmation"` // 邀请确认状态
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证用户是否是群主或管理员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 只有群主和管理员可以设置邀请确认
	if role != "owner" && role != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以设置群聊邀请确认")
		return
	}

	// 更新群组邀请确认状态
	err = gc.groupRepo.UpdateGroupInviteConfirmation(groupID, req.InviteConfirmation)
	if err != nil {
		utils.LogDebug("更新邀请确认状态失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "更新邀请确认状态失败")
		return
	}

	statusText := "已关闭"
	if req.InviteConfirmation {
		statusText = "已开启"
	}

	utils.LogDebug("✅ 邀请确认状态更新成功: 群组ID=%d, 状态=%v", groupID, req.InviteConfirmation)

	utils.Success(c, gin.H{
		"message":             "群聊邀请确认" + statusText,
		"invite_confirmation": req.InviteConfirmation,
	})
}

// UpdateGroupAdminOnlyEditName 更新群组"仅管理员可修改群名称"状态
func (gc *GroupController) UpdateGroupAdminOnlyEditName(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req struct {
		AdminOnlyEditName bool `json:"admin_only_edit_name"` // 仅管理员可修改群名称状态
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证用户是否是群主或管理员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 只有群主和管理员可以设置此选项
	if role != "owner" && role != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以设置该选项")
		return
	}

	// 更新群组"仅管理员可修改群名称"状态
	err = gc.groupRepo.UpdateGroupAdminOnlyEditName(groupID, req.AdminOnlyEditName)
	if err != nil {
		utils.LogDebug("更新仅管理员可修改群名称状态失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "更新状态失败")
		return
	}

	statusText := "已关闭"
	if req.AdminOnlyEditName {
		statusText = "已开启"
	}

	utils.LogDebug("✅ 仅管理员可修改群名称状态更新成功: 群组ID=%d, 状态=%v", groupID, req.AdminOnlyEditName)

	utils.Success(c, gin.H{
		"message":              "仅群主/群管理员可修改群名称" + statusText,
		"admin_only_edit_name": req.AdminOnlyEditName,
	})
}

// UpdateGroupMemberViewPermission 更新群组"群成员查看权限"状态
func (gc *GroupController) UpdateGroupMemberViewPermission(c *gin.Context) {
	// 获取群组ID
	groupID, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	var req struct {
		MemberViewPermission bool `json:"member_view_permission"` // 群成员查看权限状态
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证用户是否是群主或管理员
	role, err := gc.groupRepo.GetUserGroupRole(groupID, userID.(int))
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}
		utils.Error(c, http.StatusInternalServerError, "验证群组成员失败")
		return
	}

	// 只有群主和管理员可以设置此选项
	if role != "owner" && role != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以设置该选项")
		return
	}

	// 更新群组"群成员查看权限"状态
	err = gc.groupRepo.UpdateGroupMemberViewPermission(groupID, req.MemberViewPermission)
	if err != nil {
		utils.LogDebug("更新群成员查看权限状态失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "更新状态失败")
		return
	}

	statusText := "已关闭"
	if req.MemberViewPermission {
		statusText = "已开启"
	}

	utils.LogDebug("✅ 群成员查看权限状态更新成功: 群组ID=%d, 状态=%v", groupID, req.MemberViewPermission)

	// 通知所有群组成员群组信息已更新
	members, err := gc.groupRepo.GetGroupMembers(groupID)
	if err == nil {
		// 获取更新后的群组信息
		updatedGroup, err := gc.groupRepo.GetGroupByID(groupID)
		if err == nil {
			// 向所有群组成员广播更新通知
			for _, member := range members {
				notificationData := gin.H{
					"type": "group_info_updated",
					"data": gin.H{
						"group_id": groupID,
						"group":    updatedGroup,
					},
				}
				notificationJSON, _ := json.Marshal(notificationData)
				gc.Hub.SendToUser(member.UserID, notificationJSON)
			}
			utils.LogDebug("✅ 已向所有群组成员广播群成员查看权限更新通知")
		}
	}

	utils.Success(c, gin.H{
		"message":                "群成员查看权限" + statusText,
		"member_view_permission": req.MemberViewPermission,
	})
}

// ApproveGroupMember 通过群成员审核
func (gc *GroupController) ApproveGroupMember(c *gin.Context) {
	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取要审核的用户ID
	var req struct {
		UserID int `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证群组是否存在
	_, err = gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 获取当前用户角色
	currentUserRole, err := gc.groupRepo.GetMemberRole(groupID, currentUserID.(int))
	if err != nil {
		utils.Error(c, http.StatusForbidden, "您不是群组成员")
		return
	}

	// 验证权限：只有群主和管理员可以审核
	if currentUserRole != "owner" && currentUserRole != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以审核成员")
		return
	}

	// 执行审核通过
	err = gc.groupRepo.ApproveGroupMember(groupID, req.UserID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "该用户不在待审核列表")
			return
		}
		utils.LogDebug("审核通过失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "审核失败")
		return
	}

	utils.Success(c, gin.H{
		"message": "审核通过",
	})
}

// RejectGroupMember 拒绝群成员审核
func (gc *GroupController) RejectGroupMember(c *gin.Context) {
	// 获取当前用户ID
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Error(c, http.StatusUnauthorized, "未授权")
		return
	}

	// 获取群组ID
	groupIDStr := c.Param("id")
	groupID, err := strconv.Atoi(groupIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的群组ID")
		return
	}

	// 获取要拒绝的用户ID
	var req struct {
		UserID int `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误: "+err.Error())
		return
	}

	// 验证群组是否存在
	_, err = gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "群组不存在")
			return
		}
		utils.LogDebug("获取群组信息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "获取群组信息失败")
		return
	}

	// 获取当前用户角色
	currentUserRole, err := gc.groupRepo.GetMemberRole(groupID, currentUserID.(int))
	if err != nil {
		utils.Error(c, http.StatusForbidden, "您不是群组成员")
		return
	}

	// 验证权限：只有群主和管理员可以审核
	if currentUserRole != "owner" && currentUserRole != "admin" {
		utils.Error(c, http.StatusForbidden, "只有群主和管理员可以拒绝成员")
		return
	}

	// 执行拒绝审核
	err = gc.groupRepo.RejectGroupMember(groupID, req.UserID)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.Error(c, http.StatusNotFound, "该用户不在待审核列表")
			return
		}
		utils.LogDebug("拒绝审核失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "拒绝失败")
		return
	}

	utils.Success(c, gin.H{
		"message": "已拒绝",
	})
}

// sendMemberAddedNotification 向新添加的成员发送系统消息
func (gc *GroupController) sendMemberAddedNotification(groupID int, memberID int, operatorName string) {

	// 创建系统消息：您已被添加到群组
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     "您已被添加到群组",
		MessageType: "system",
	}

	// 使用操作者名称作为发送者名称
	senderName := operatorName
	if senderName == "" {
		senderName = "系统"
	}

	// 创建群组消息（使用成员ID作为发送者，避免外键约束错误）
	message, err := gc.groupRepo.CreateGroupMessage(createMsg, memberID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建成员添加通知消息失败: %v", err)
		return
	}

	// 构建WebSocket消息
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: groupID,
		Data: models.WSGroupMessageData{
			ID:          message.ID,
			GroupID:     message.GroupID,
			SenderID:    message.SenderID,
			SenderName:  message.SenderName,
			Content:     message.Content,
			MessageType: message.MessageType,
			CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化成员添加通知消息失败: %v", err)
		return
	}

	// 只向新添加的成员发送消息
	gc.Hub.SendToUser(memberID, msgBytes)

	utils.LogDebug("成员添加通知已发送 - GroupID: %d, MessageID: %d, 新成员ID: %d",
		groupID, message.ID, memberID)
}

// sendPendingMemberNotification 向群主和管理员发送待审核成员通知
func (gc *GroupController) sendPendingMemberNotification(groupID int, operatorID int, operatorName string, newMemberID int) {
	// 获取群主和管理员的ID列表
	adminIDs, err := gc.groupRepo.GetGroupAdminsAndOwner(groupID)
	if err != nil {
		utils.LogDebug("获取群主和管理员ID列表失败: %v", err)
		return
	}

	if len(adminIDs) == 0 {
		utils.LogDebug("群组没有群主和管理员: GroupID=%d", groupID)
		return
	}

	// 获取新成员信息
	newMember, err := gc.userRepo.FindByID(newMemberID)
	if err != nil {
		utils.LogDebug("获取新成员信息失败: %v", err)
		return
	}

	newMemberName := newMember.Username
	if newMember.FullName != nil && *newMember.FullName != "" {
		newMemberName = *newMember.FullName
	}

	// 获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		utils.LogDebug("获取群组信息失败: %v", err)
		return
	}

	// 构建WebSocket通知消息
	notificationData := gin.H{
		"type": "pending_group_member",
		"data": gin.H{
			"group_id":          groupID,
			"group_name":        group.Name,
			"operator_id":       operatorID,
			"operator_name":     operatorName,
			"new_member_id":     newMemberID,
			"new_member_name":   newMemberName,
			"new_member_avatar": newMember.Avatar,
		},
	}

	notificationJSON, err := json.Marshal(notificationData)
	if err != nil {
		utils.LogDebug("序列化待审核成员通知失败: %v", err)
		return
	}

	// 向所有群主和管理员发送通知（排除操作者自己）
	sentCount := 0
	for _, adminID := range adminIDs {
		if adminID != operatorID {
			gc.Hub.SendToUser(adminID, notificationJSON)
			sentCount++
		}
	}

	utils.LogDebug("待审核成员通知已发送 - GroupID: %d, 新成员: %s (ID: %d), 操作者: %s (ID: %d), 接收者数量: %d",
		groupID, newMemberName, newMemberID, operatorName, operatorID, sentCount)
}

// sendMemberRemovedNotification 向被移除的成员发送系统消息
func (gc *GroupController) sendMemberRemovedNotification(groupID int, memberID int, operatorID int, operatorName string) {

	// 创建系统消息：您已被移除群组
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     "您已被移除群组",
		MessageType: "system",
	}

	// 使用操作者名称作为发送者名称
	senderName := operatorName
	if senderName == "" {
		senderName = "系统"
	}

	// 创建群组消息（使用操作者ID作为sender_id）
	message, err := gc.groupRepo.CreateGroupMessage(createMsg, operatorID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建成员移除通知消息失败: %v", err)
		return
	}

	// 构建WebSocket消息
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: groupID,
		Data: models.WSGroupMessageData{
			ID:          message.ID,
			GroupID:     message.GroupID,
			SenderID:    message.SenderID,
			SenderName:  message.SenderName,
			Content:     message.Content,
			MessageType: message.MessageType,
			CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化成员移除通知消息失败: %v", err)
		return
	}

	// 只向被移除的成员发送消息
	gc.Hub.SendToUser(memberID, msgBytes)

	utils.LogDebug("成员移除通知已发送 - GroupID: %d, MessageID: %d, 被移除成员ID: %d",
		groupID, message.ID, memberID)
}

// sendAllMutedNotificationToGroup 向群组所有成员发送全体禁言状态变更的系统消息
func (gc *GroupController) sendAllMutedNotificationToGroup(groupID int, operatorID int, operatorName string, content string) {
	// 1. 将消息保存到数据库
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     content,
		MessageType: "system",
	}

	// 使用操作者名称作为发送者名称
	senderName := operatorName
	if senderName == "" {
		senderName = "系统"
	}

	// 创建群组消息
	message, err := gc.groupRepo.CreateGroupMessage(createMsg, operatorID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建全体禁言通知消息失败: %v", err)
		return
	}

	// 2. 获取群组所有成员
	memberIDs, err := gc.groupRepo.GetGroupMemberIDs(groupID)
	if err != nil {
		utils.LogDebug("获取群组成员ID列表失败: %v", err)
		return
	}

	// 3. 构造消息通知
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: groupID,
		Data: models.WSGroupMessageData{
			ID:          message.ID,
			GroupID:     message.GroupID,
			SenderID:    message.SenderID,
			SenderName:  message.SenderName,
			Content:     message.Content,
			MessageType: message.MessageType,
			CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	// 序列化消息
	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化全体禁言通知消息失败: %v", err)
		return
	}

	// 4. 向所有群组成员广播消息
	sentCount := 0
	for _, memberID := range memberIDs {
		gc.Hub.SendToUser(memberID, msgBytes)
		sentCount++
	}

	utils.LogDebug("✅ 全体禁言通知已广播到 %d 个群组成员", sentCount)
}

// sendMuteNotificationToUser 向指定用户发送个人禁言/解除禁言的系统消息通知
func (gc *GroupController) sendMuteNotificationToUser(groupID int, targetUserID int, operatorID int, operatorName string, isMuted bool) {
	var content string
	if isMuted {
		content = "你已被" + operatorName + "禁言"
	} else {
		content = "你已被" + operatorName + "解除禁言"
	}

	// 1. 将消息保存到数据库
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     content,
		MessageType: "system",
	}

	// 创建群组消息
	message, err := gc.groupRepo.CreateGroupMessage(createMsg, operatorID, operatorName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建个人禁言通知消息失败: %v", err)
		return
	}

	// 2. 构造消息通知
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: groupID,
		Data: models.WSGroupMessageData{
			ID:          message.ID,
			GroupID:     message.GroupID,
			SenderID:    message.SenderID,
			SenderName:  message.SenderName,
			Content:     message.Content,
			MessageType: message.MessageType,
			CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	// 序列化消息
	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化个人禁言通知消息失败: %v", err)
		return
	}

	// 3. 向被禁言/解除禁言的用户发送通知
	gc.Hub.SendToUser(targetUserID, msgBytes)

	var action string
	if isMuted {
		action = "禁言"
	} else {
		action = "解除禁言"
	}
	utils.LogDebug("✅ %s通知已发送给用户 %d", action, targetUserID)
}

// sendMemberJoinedNotification 向用户发送主动加入群组的系统消息
func (gc *GroupController) sendMemberJoinedNotification(groupID int, memberID int, memberName string) {
	// 获取群组信息
	group, err := gc.groupRepo.GetGroupByID(groupID)
	if err != nil {
		utils.LogDebug("获取群组信息失败: %v", err)
		return
	}

	// 创建系统消息：您已加入群组"xxx"
	content := "您已加入群组\"" + group.Name + "\""
	createMsg := &models.CreateGroupMessageRequest{
		GroupID:     groupID,
		Content:     content,
		MessageType: "system",
	}

	// 使用加入者的ID作为发送者（避免外键约束错误）
	senderName := "系统"

	message, err := gc.groupRepo.CreateGroupMessage(createMsg, memberID, senderName, nil, nil, nil)
	if err != nil {
		utils.LogDebug("创建成员加入通知消息失败: %v", err)
		return
	}

	// 构建WebSocket消息
	wsMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: groupID,
		Data: models.WSGroupMessageData{
			ID:          message.ID,
			GroupID:     message.GroupID,
			SenderID:    message.SenderID,
			SenderName:  message.SenderName,
			Content:     message.Content,
			MessageType: message.MessageType,
			CreatedAt:   message.CreatedAt.UTC(), // 🔴 确保使用 UTC 时间
		},
	}

	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		utils.LogDebug("序列化成员加入通知消息失败: %v", err)
		return
	}

	// 向新加入的成员发送消息
	gc.Hub.SendToUser(memberID, msgBytes)

	utils.LogDebug("✅ 成员加入通知已发送 - GroupID: %d, 成员: %s (ID: %d), 内容: %s",
		groupID, memberName, memberID, content)
}
