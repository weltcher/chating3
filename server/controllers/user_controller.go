package controllers

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

// UserController 用户控制器
type UserController struct {
	userRepo    *models.UserRepository
	contactRepo *models.ContactRepository
	groupRepo   *models.GroupRepository
	hub         *ws.Hub
}

// NewUserController 创建用户控制器
func NewUserController(hub *ws.Hub) *UserController {
	return &UserController{
		userRepo:    models.NewUserRepository(db.DB),
		contactRepo: models.NewContactRepository(db.DB),
		groupRepo:   models.NewGroupRepository(db.DB),
		hub:         hub,
	}
}

// UpdateWorkSignatureRequest 更新工作签名请求
type UpdateWorkSignatureRequest struct {
	WorkSignature string `json:"work_signature" binding:"max=500"`
}

// UpdateWorkSignature 更新工作签名
func (ctrl *UserController) UpdateWorkSignature(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req UpdateWorkSignatureRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 更新工作签名
	err := ctrl.userRepo.UpdateWorkSignature(userID.(int), req.WorkSignature)
	if err != nil {
		utils.LogDebug("更新工作签名失败: %v", err)
		utils.InternalServerError(c, "更新工作签名失败")
		return
	}

	utils.SuccessWithMessage(c, "工作签名更新成功", nil)
}

// UpdateStatusRequest 更新状态请求
type UpdateStatusRequest struct {
	Status string `json:"status" binding:"required,oneof=online busy away offline"`
}

// UpdateStatus 更新状态
func (ctrl *UserController) UpdateStatus(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req UpdateStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 更新状态
	err := ctrl.userRepo.UpdateStatus(userID.(int), req.Status)
	if err != nil {
		utils.LogDebug("更新状态失败: %v", err)
		utils.InternalServerError(c, "更新状态失败")
		return
	}

	utils.LogDebug("✅ 用户 %d 状态更新为: %s", userID.(int), req.Status)

	// 获取当前用户信息（用于发送通知）
	user, err := ctrl.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.LogDebug("⚠️ 获取用户信息失败，无法发送状态变更通知: %v", err)
		// 状态已更新，即使通知失败也返回成功
		utils.SuccessWithMessage(c, "状态更新成功", nil)
		return
	}

	// 获取用户的所有联系人
	contacts, err := ctrl.contactRepo.GetContactsByUserID(userID.(int))
	if err != nil {
		utils.LogDebug("⚠️ 获取联系人列表失败，无法发送状态变更通知: %v", err)
		// 状态已更新，即使通知失败也返回成功
		utils.SuccessWithMessage(c, "状态更新成功", nil)
		return
	}

	// 构造状态变更消息
	statusChangeMsg := models.WSMessage{
		Type: "status_change",
		Data: gin.H{
			"user_id":   userID.(int),
			"username":  user.Username,
			"full_name": user.FullName,
			"status":    req.Status,
		},
	}

	msgBytes, err := json.Marshal(statusChangeMsg)
	if err != nil {
		utils.LogDebug("⚠️ 序列化状态变更消息失败: %v", err)
		utils.SuccessWithMessage(c, "状态更新成功", nil)
		return
	}

	// 向所有联系人推送状态变更消息
	notifiedCount := 0
	for _, contact := range contacts {
		if ctrl.hub.SendToUser(contact.FriendID, msgBytes) {
			notifiedCount++
		}
	}

	utils.LogDebug("📤 状态变更通知已发送，共 %d/%d 个联系人在线", notifiedCount, len(contacts))

	utils.SuccessWithMessage(c, "状态更新成功", nil)
}

// UpdateProfile 更新个人信息
func (ctrl *UserController) UpdateProfile(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req models.UpdateProfileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	utils.LogDebug("📝 更新用户 %d 的个人信息", userID.(int))
	utils.LogDebug("   请求数据: FullName=%v, Gender=%v, Phone=%v, Avatar=%v",
		req.FullName, req.Gender, req.Phone, req.Avatar)

	// 验证性别值
	if req.Gender != nil && *req.Gender != "" {
		if *req.Gender != "male" && *req.Gender != "female" && *req.Gender != "other" {
			utils.BadRequest(c, "性别值必须是 male、female 或 other")
			return
		}
	}

	// 如果要更新手机号，检查手机号是否已被其他用户使用
	if req.Phone != nil && *req.Phone != "" {
		// 验证手机号格式
		if !utils.IsValidPhoneNumber(*req.Phone) {
			utils.BadRequest(c, "请输入正确的手机号格式")
			return
		}

		// 检查手机号是否已被其他用户绑定
		isUsed, err := ctrl.userRepo.IsPhoneUsedByOthers(userID.(int), *req.Phone)
		if err != nil {
			utils.LogDebug("❌ 检查手机号失败: %v", err)
			utils.InternalServerError(c, "检查手机号失败")
			return
		}
		if isUsed {
			utils.BadRequest(c, "该手机号已被其他用户绑定")
			return
		}
	}

	// 获取更新前的用户信息（用于比较头像是否改变）
	oldUser, err := ctrl.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.LogDebug("❌ 获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	// 更新个人信息
	err = ctrl.userRepo.UpdateProfile(userID.(int), req)
	if err != nil {
		utils.LogDebug("❌ 更新个人信息失败: %v", err)
		utils.InternalServerError(c, "更新个人信息失败")
		return
	}
	utils.LogDebug("✅ 用户 %d 个人信息更新成功", userID.(int))

	// 检查头像是否改变，如果改变则推送通知
	if req.Avatar != nil && *req.Avatar != oldUser.Avatar {
		utils.LogDebug("🎭 检测到头像变化，准备推送通知给相关用户")
		utils.LogDebug("   旧头像: %s", oldUser.Avatar)
		utils.LogDebug("   新头像: %s", *req.Avatar)
		go ctrl.notifyAvatarUpdate(userID.(int), req.Avatar)
	}

	// 获取更新后的用户信息
	user, err := ctrl.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	utils.SuccessWithMessage(c, "个人信息更新成功", gin.H{
		"user": user,
	})
}

// GetProfile 获取当前登录用户的个人信息
func (ctrl *UserController) GetProfile(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	// 获取用户信息
	user, err := ctrl.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	utils.Success(c, gin.H{
		"user": user,
	})
}

// GetUserByID 根据用户ID查询用户信息
func (ctrl *UserController) GetUserByID(c *gin.Context) {
	// 获取URL参数中的用户ID
	userID := c.Param("id")
	if userID == "" {
		utils.BadRequest(c, "用户ID不能为空")
		return
	}

	// 将字符串ID转换为整数
	var id int
	if _, err := fmt.Sscanf(userID, "%d", &id); err != nil {
		utils.BadRequest(c, "无效的用户ID")
		return
	}

	// 查询用户信息
	user, err := ctrl.userRepo.FindByID(id)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.NotFound(c, "用户不存在")
			return
		}
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	utils.Success(c, gin.H{
		"user": user,
	})
}

// GetUserByUsername 根据用户名查询用户信息
func (ctrl *UserController) GetUserByUsername(c *gin.Context) {
	// 获取URL参数中的用户名
	username := c.Param("username")
	if username == "" {
		utils.BadRequest(c, "用户名不能为空")
		return
	}

	// 查询用户信息
	user, err := ctrl.userRepo.FindByUsername(username)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.NotFound(c, "用户不存在")
			return
		}
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	utils.Success(c, gin.H{
		"user": user,
	})
}

// ChangePasswordRequest 修改密码请求
type ChangePasswordRequest struct {
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=4,max=16"`
}

// ChangePassword 修改密码
func (ctrl *UserController) ChangePassword(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 获取用户信息
	user, err := ctrl.userRepo.FindByID(userID.(int))
	if err != nil {
		utils.LogDebug("获取用户信息失败: %v", err)
		utils.InternalServerError(c, "获取用户信息失败")
		return
	}

	// 验证旧密码
	err = bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.OldPassword))
	if err != nil {
		utils.BadRequest(c, "旧密码错误")
		return
	}

	// 检查新密码是否与旧密码相同
	err = bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.NewPassword))
	if err == nil {
		utils.BadRequest(c, "新密码不能与旧密码相同")
		return
	}

	// 加密新密码
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		utils.LogDebug("密码加密失败: %v", err)
		utils.InternalServerError(c, "密码加密失败")
		return
	}

	// 更新密码
	err = ctrl.userRepo.UpdatePasswordByID(userID.(int), string(hashedPassword))
	if err != nil {
		utils.LogDebug("更新密码失败: %v", err)
		utils.InternalServerError(c, "更新密码失败")
		return
	}

	utils.SuccessWithMessage(c, "密码修改成功", nil)
}

// notifyAvatarUpdate 通知所有相关用户头像已更新
func (ctrl *UserController) notifyAvatarUpdate(userID int, newAvatar *string) {
	utils.LogDebug("📢 开始推送头像更新通知 - 用户ID: %d", userID)

	avatarURL := ""
	if newAvatar != nil {
		avatarURL = *newAvatar
	}

	// 使用 map 避免重复推送
	notifiedUsers := make(map[int]bool)

	// 1. 获取该用户的所有联系人（该用户添加的联系人）
	contacts, err := ctrl.contactRepo.GetUserContacts(userID)
	if err != nil {
		utils.LogDebug("获取用户联系人失败: %v", err)
	} else {
		for _, contact := range contacts {
			if !notifiedUsers[contact.FriendID] {
				ctrl.sendAvatarUpdateNotification(contact.FriendID, userID, avatarURL)
				notifiedUsers[contact.FriendID] = true
			}
		}
		utils.LogDebug("✅ 已向 %d 个联系人推送头像更新（该用户添加的）", len(contacts))
	}

	// 2. 获取所有添加了该用户为联系人的用户（别人添加该用户）
	reverseContacts, err := ctrl.contactRepo.GetUsersWhoAddedContact(userID)
	if err != nil {
		utils.LogDebug("获取反向联系人失败: %v", err)
	} else {
		count := 0
		for _, contact := range reverseContacts {
			if !notifiedUsers[contact.UserID] {
				ctrl.sendAvatarUpdateNotification(contact.UserID, userID, avatarURL)
				notifiedUsers[contact.UserID] = true
				count++
			}
		}
		utils.LogDebug("✅ 已向 %d 个反向联系人推送头像更新（添加了该用户的）", count)
	}

	// 3. 获取该用户所在的所有群组
	groups, err := ctrl.groupRepo.GetUserGroups(userID)
	if err != nil {
		utils.LogDebug("获取用户群组失败: %v", err)
	} else {
		groupMemberCount := 0
		for _, group := range groups {
			memberIDs, err := ctrl.groupRepo.GetGroupMemberIDs(group.ID)
			if err != nil {
				utils.LogDebug("获取群组 %d 成员失败: %v", group.ID, err)
				continue
			}

			for _, memberID := range memberIDs {
				// 🔴 修复：移除 memberID != userID 条件，也向用户自己推送通知
				// 这样用户更新头像后，自己的聊天记录中的头像也会实时更新
				if !notifiedUsers[memberID] {
					ctrl.sendAvatarUpdateNotification(memberID, userID, avatarURL)
					notifiedUsers[memberID] = true
					groupMemberCount++
				}
			}
		}
		utils.LogDebug("✅ 已向 %d 个群组成员推送头像更新", groupMemberCount)
	}

	// 🔴 修复：如果用户自己还没有被通知（比如没有联系人和群组的情况），也向他自己推送
	if !notifiedUsers[userID] {
		ctrl.sendAvatarUpdateNotification(userID, userID, avatarURL)
		notifiedUsers[userID] = true
		utils.LogDebug("✅ 已向用户自己推送头像更新")
	}

	utils.LogDebug("📢 头像更新通知推送完成，共通知 %d 个用户", len(notifiedUsers))
}

// sendAvatarUpdateNotification 向指定用户发送头像更新通知
func (ctrl *UserController) sendAvatarUpdateNotification(targetUserID int, updatedUserID int, avatarURL string) {
	msg := map[string]interface{}{
		"type": "avatar_updated",
		"data": map[string]interface{}{
			"user_id": updatedUserID,
			"avatar":  avatarURL,
		},
	}

	msgBytes, err := json.Marshal(msg)
	if err != nil {
		utils.LogDebug("序列化头像更新消息失败: %v", err)
		return
	}

	// 通过 WebSocket Hub 发送
	sent := ctrl.hub.SendToUser(targetUserID, msgBytes)
	if sent {
		utils.LogDebug("  ✉️  已向用户 %d 发送头像更新通知", targetUserID)
	}
}

// BatchGetOnlineStatusRequest 批量获取在线状态请求
type BatchGetOnlineStatusRequest struct {
	UserIDs []int `json:"user_ids" binding:"required"`
}

// BatchGetOnlineStatus 批量获取用户在线状态
func (ctrl *UserController) BatchGetOnlineStatus(c *gin.Context) {
	var req BatchGetOnlineStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	if len(req.UserIDs) == 0 {
		utils.BadRequest(c, "用户ID列表不能为空")
		return
	}

	// 限制一次查询的用户数量，避免性能问题
	if len(req.UserIDs) > 100 {
		utils.BadRequest(c, "一次最多查询100个用户的在线状态")
		return
	}

	// 构建在线状态映射
	statusMap := make(map[int]string)
	for _, userID := range req.UserIDs {
		if ctrl.hub.IsUserOnline(userID) {
			statusMap[userID] = "online"
		} else {
			statusMap[userID] = "offline"
		}
	}

	utils.Success(c, gin.H{
		"statuses": statusMap,
	})
}

// countStatus 统计指定状态的用户数量
func countStatus(statusMap map[int]string, status string) int {
	count := 0
	for _, s := range statusMap {
		if s == status {
			count++
		}
	}
	return count
}

// GetUserByInviteCode 根据邀请码获取用户信息
func (ctrl *UserController) GetUserByInviteCode(c *gin.Context) {
	inviteCode := c.Param("invite_code")
	if inviteCode == "" {
		utils.BadRequest(c, "邀请码不能为空")
		return
	}

	user, err := ctrl.userRepo.FindByInviteCode(inviteCode)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.BadRequest(c, "用户不存在")
			return
		}
		utils.LogDebug("查询用户失败: %v", err)
		utils.InternalServerError(c, "查询用户失败")
		return
	}

	utils.Success(c, user)
}

// CheckEmailAvailabilityRequest 检查邮箱可用性请求
type CheckEmailAvailabilityRequest struct {
	Email string `json:"email" binding:"required,email"`
}

// CheckEmailAvailability 检查邮箱是否已被其他用户绑定
func (ctrl *UserController) CheckEmailAvailability(c *gin.Context) {
	// 从上下文中获取当前用户ID（需要认证中间件）
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req CheckEmailAvailabilityRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 查询邮箱是否已被使用
	user, err := ctrl.userRepo.FindByEmail(req.Email)
	if err != nil && err != sql.ErrNoRows {
		utils.LogDebug("查询邮箱失败: %v", err)
		utils.InternalServerError(c, "查询邮箱失败")
		return
	}

	// 如果找到用户且不是当前用户，说明邮箱已被其他用户绑定
	if user != nil && user.ID != currentUserID.(int) {
		utils.Success(c, gin.H{
			"available": false,
			"message":   "该邮箱已被其他用户绑定",
		})
		return
	}

	// 邮箱可用
	utils.Success(c, gin.H{
		"available": true,
		"message":   "邮箱可用",
	})
}

// SendEmailCodeRequest 发送邮箱验证码请求
type SendEmailCodeRequest struct {
	Email string `json:"email" binding:"required,email"`
}

// SendEmailCode 发送邮箱绑定验证码
func (ctrl *UserController) SendEmailCode(c *gin.Context) {
	// 从上下文中获取当前用户ID（需要认证中间件）
	_, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req SendEmailCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 生成6位验证码
	code := utils.GenerateVerificationCode(6)

	// 存储验证码到Redis
	if err := utils.SetEmailCode(req.Email, code); err != nil {
		utils.LogDebug("存储验证码失败: %v", err)
		utils.InternalServerError(c, "发送验证码失败")
		return
	}

	// 发送邮件
	if err := utils.SendEmailCode(req.Email, code); err != nil {
		utils.LogDebug("发送邮件失败: %v", err)
		utils.InternalServerError(c, "发送验证码失败: "+err.Error())
		return
	}

	utils.SuccessWithMessage(c, "验证码已发送", nil)
}

// BindEmailRequest 绑定邮箱请求
type BindEmailRequest struct {
	Email string `json:"email" binding:"required,email"`
	Code  string `json:"code" binding:"required,len=6"`
}

// BindEmail 绑定/更换邮箱
func (ctrl *UserController) BindEmail(c *gin.Context) {
	// 从上下文中获取当前用户ID（需要认证中间件）
	currentUserID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req BindEmailRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 验证验证码
	valid, err := utils.VerifyEmailCode(req.Email, req.Code)
	if err != nil {
		utils.LogDebug("验证验证码失败: %v", err)
		utils.InternalServerError(c, "验证失败")
		return
	}
	if !valid {
		utils.BadRequest(c, "验证码错误或已过期")
		return
	}

	// 检查邮箱是否已被其他用户绑定
	existingUser, err := ctrl.userRepo.FindByEmail(req.Email)
	if err != nil && err != sql.ErrNoRows {
		utils.LogDebug("查询邮箱失败: %v", err)
		utils.InternalServerError(c, "绑定失败")
		return
	}
	if existingUser != nil && existingUser.ID != currentUserID.(int) {
		utils.BadRequest(c, "该邮箱已被其他用户绑定")
		return
	}

	// 更新用户邮箱
	if err := ctrl.userRepo.UpdateEmail(currentUserID.(int), req.Email); err != nil {
		utils.LogDebug("更新邮箱失败: %v", err)
		utils.InternalServerError(c, "绑定失败")
		return
	}

	// 删除已使用的验证码
	utils.DeleteEmailCode(req.Email)

	utils.SuccessWithMessage(c, "邮箱绑定成功", gin.H{
		"email": req.Email,
	})
}


// ForceLogoutRequest 强制下线请求
type ForceLogoutRequest struct {
	UserID int    `json:"user_id" binding:"required"`
	Reason string `json:"reason"`
}

// ForceLogout 强制用户下线（管理后台调用）
func (ctrl *UserController) ForceLogout(c *gin.Context) {
	var req ForceLogoutRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	reason := req.Reason
	if reason == "" {
		reason = "您的账号已被管理员禁用"
	}

	// 构造强制下线消息
	msg := map[string]interface{}{
		"type": "forced_logout",
		"data": map[string]interface{}{
			"reason": reason,
		},
	}

	msgBytes, err := json.Marshal(msg)
	if err != nil {
		utils.LogDebug("序列化强制下线消息失败: %v", err)
		utils.InternalServerError(c, "操作失败")
		return
	}

	// 检查用户是否在线
	isOnline := ctrl.hub.IsUserOnline(req.UserID)
	
	// 发送强制下线消息
	if isOnline {
		ctrl.hub.SendToUser(req.UserID, msgBytes)
		utils.LogDebug("✅ 已向用户 %d 发送强制下线通知", req.UserID)
	}

	utils.Success(c, gin.H{
		"success":    true,
		"was_online": isOnline,
		"message":    "操作成功",
	})
}
