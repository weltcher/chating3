package controllers

import (
	"database/sql"
	"net/http"
	"regexp"
	"strconv"

	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"

	"github.com/gin-gonic/gin"
)

// ScheduledMessageController 定时消息控制器
type ScheduledMessageController struct {
	repo *models.ScheduledMessageRepository
}

// NewScheduledMessageController 创建定时消息控制器
func NewScheduledMessageController() *ScheduledMessageController {
	return &ScheduledMessageController{
		repo: models.NewScheduledMessageRepository(db.DB),
	}
}

// validateSendTime 验证发送时间格式（HH:MM）
func validateSendTime(sendTime string) bool {
	pattern := `^([01]?[0-9]|2[0-3]):([0-5][0-9])$`
	matched, _ := regexp.MatchString(pattern, sendTime)
	return matched
}

// Create 创建定时消息
// POST /api/scheduled-messages
func (c *ScheduledMessageController) Create(ctx *gin.Context) {
	// 获取当前用户ID
	userID, exists := ctx.Get("user_id")
	if !exists {
		ctx.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}
	senderID := userID.(int)

	// 解析请求
	var req models.CreateScheduledMessageRequest
	if err := ctx.ShouldBindJSON(&req); err != nil {
		utils.LogDebug("❌ [定时消息] 创建失败，参数错误: %v", err)
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	// 验证发送时间格式
	if !validateSendTime(req.SendTime) {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "发送时间格式错误，应为HH:MM格式"})
		return
	}

	// 验证消息类型
	if req.MessageType != models.ScheduledMessageTypePrivate && req.MessageType != models.ScheduledMessageTypeGroup {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "消息类型错误，应为private或group"})
		return
	}

	// 验证发送类型
	if req.SendType != models.ScheduledMessageSendTypeOnce && req.SendType != models.ScheduledMessageSendTypeDaily {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "发送类型错误，应为once或daily"})
		return
	}

	// 验证内容长度
	if len([]rune(req.Content)) > 1000 {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能超过1000字"})
		return
	}

	// 创建定时消息
	msg, err := c.repo.Create(senderID, &req)
	if err != nil {
		utils.LogDebug("❌ [定时消息] 创建失败: %v", err)
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "创建失败"})
		return
	}

	utils.LogDebug("✅ [定时消息] 创建成功 - ID: %d, 发送者: %d, 接收者: %d, 类型: %s", msg.ID, senderID, req.ReceiverID, req.MessageType)
	ctx.JSON(http.StatusOK, gin.H{
		"code":    0,
		"message": "创建成功",
		"data":    msg,
	})
}

// Update 更新定时消息
// PUT /api/scheduled-messages/:id
func (c *ScheduledMessageController) Update(ctx *gin.Context) {
	// 获取当前用户ID
	userID, exists := ctx.Get("user_id")
	if !exists {
		ctx.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}
	senderID := userID.(int)

	// 获取消息ID
	idStr := ctx.Param("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "无效的ID"})
		return
	}

	// 解析请求
	var req models.UpdateScheduledMessageRequest
	if err := ctx.ShouldBindJSON(&req); err != nil {
		utils.LogDebug("❌ [定时消息] 更新失败，参数错误: %v", err)
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	// 验证发送时间格式
	if !validateSendTime(req.SendTime) {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "发送时间格式错误，应为HH:MM格式"})
		return
	}

	// 验证发送类型
	if req.SendType != models.ScheduledMessageSendTypeOnce && req.SendType != models.ScheduledMessageSendTypeDaily {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "发送类型错误，应为once或daily"})
		return
	}

	// 验证内容长度
	if len([]rune(req.Content)) > 1000 {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "消息内容不能超过1000字"})
		return
	}

	// 更新定时消息
	msg, err := c.repo.Update(id, senderID, &req)
	if err != nil {
		if err == sql.ErrNoRows {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "定时消息不存在或无权修改"})
			return
		}
		utils.LogDebug("❌ [定时消息] 更新失败: %v", err)
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "更新失败"})
		return
	}

	utils.LogDebug("✅ [定时消息] 更新成功 - ID: %d", id)
	ctx.JSON(http.StatusOK, gin.H{
		"code":    0,
		"message": "更新成功",
		"data":    msg,
	})
}

// Delete 删除定时消息
// DELETE /api/scheduled-messages/:id
func (c *ScheduledMessageController) Delete(ctx *gin.Context) {
	// 获取当前用户ID
	userID, exists := ctx.Get("user_id")
	if !exists {
		ctx.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}
	senderID := userID.(int)

	// 获取消息ID
	idStr := ctx.Param("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "无效的ID"})
		return
	}

	// 删除定时消息
	err = c.repo.Delete(id, senderID)
	if err != nil {
		if err == sql.ErrNoRows {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "定时消息不存在或无权删除"})
			return
		}
		utils.LogDebug("❌ [定时消息] 删除失败: %v", err)
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}

	utils.LogDebug("✅ [定时消息] 删除成功 - ID: %d", id)
	ctx.JSON(http.StatusOK, gin.H{
		"code":    0,
		"message": "删除成功",
	})
}

// GetByID 获取定时消息详情
// GET /api/scheduled-messages/:id
func (c *ScheduledMessageController) GetByID(ctx *gin.Context) {
	// 获取当前用户ID
	userID, exists := ctx.Get("user_id")
	if !exists {
		ctx.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}
	senderID := userID.(int)

	// 获取消息ID
	idStr := ctx.Param("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "无效的ID"})
		return
	}

	// 获取定时消息
	msg, err := c.repo.GetByID(id, senderID)
	if err != nil {
		if err == sql.ErrNoRows {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "定时消息不存在"})
			return
		}
		utils.LogDebug("❌ [定时消息] 获取失败: %v", err)
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "获取失败"})
		return
	}

	ctx.JSON(http.StatusOK, gin.H{
		"code": 0,
		"data": msg,
	})
}

// GetList 获取定时消息列表
// GET /api/scheduled-messages?receiver_id=xxx&message_type=private|group
func (c *ScheduledMessageController) GetList(ctx *gin.Context) {
	// 获取当前用户ID
	userID, exists := ctx.Get("user_id")
	if !exists {
		ctx.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}
	senderID := userID.(int)

	// 获取查询参数
	receiverIDStr := ctx.Query("receiver_id")
	messageType := ctx.Query("message_type")

	if receiverIDStr == "" {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "缺少receiver_id参数"})
		return
	}

	receiverID, err := strconv.Atoi(receiverIDStr)
	if err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "无效的receiver_id"})
		return
	}

	if messageType == "" {
		messageType = "private"
	}

	if messageType != "private" && messageType != "group" {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "无效的message_type"})
		return
	}

	// 获取列表
	messages, err := c.repo.GetListByReceiver(senderID, receiverID, models.ScheduledMessageType(messageType))
	if err != nil {
		utils.LogDebug("❌ [定时消息] 获取列表失败: %v", err)
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "获取列表失败"})
		return
	}

	if messages == nil {
		messages = []*models.ScheduledMessage{}
	}

	ctx.JSON(http.StatusOK, gin.H{
		"code": 0,
		"data": messages,
	})
}
