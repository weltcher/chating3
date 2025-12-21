package controllers

import (
	"database/sql"
	"time"

	"youdu-server/config"
	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"

	"github.com/gin-gonic/gin"
)

// AuthController 认证控制器
type AuthController struct {
	userRepo *models.UserRepository
	codeRepo *models.VerificationCodeRepository
}

// NewAuthController 创建认证控制器
func NewAuthController() *AuthController {
	return &AuthController{
		userRepo: models.NewUserRepository(db.DB),
		codeRepo: models.NewVerificationCodeRepository(db.DB),
	}
}

// Register 用户注册
func (ctrl *AuthController) Register(c *gin.Context) {
	var req models.RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 验证两次密码是否一致
	if req.Password != req.ConfirmPassword {
		utils.BadRequest(c, "两次输入的密码不一致")
		return
	}

	// 验证邀请码（必填）
	if req.InviteCode == "" {
		utils.BadRequest(c, "请输入邀请码")
		return
	}

	// 检查邀请码状态
	codeStatus, err := ctrl.userRepo.CheckInviteCodeStatus(req.InviteCode)
	if err != nil {
		utils.LogDebug("验证邀请码失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}
	if codeStatus == models.InviteCodeNotFound {
		utils.BadRequest(c, "邀请码不存在，请检查后重试")
		return
	}
	if codeStatus == models.InviteCodeUsed {
		utils.BadRequest(c, "该邀请码已被使用")
		return
	}

	// 检查用户名是否已存在
	existUser, err := ctrl.userRepo.FindByUsername(req.Username)
	if err != nil && err != sql.ErrNoRows {
		utils.LogDebug("查询用户失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}
	if existUser != nil {
		utils.BadRequest(c, "用户名已存在")
		return
	}

	// 加密密码
	hashedPassword, err := utils.HashPassword(req.Password)
	if err != nil {
		utils.LogDebug("密码加密失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 生成唯一邀请码
	var userInviteCode string
	for {
		userInviteCode = utils.GenerateInviteCode()
		// 检查邀请码是否已存在
		exists, err := ctrl.userRepo.InviteCodeExists(userInviteCode)
		if err != nil {
			utils.LogDebug("检查邀请码失败: %v", err)
			utils.InternalServerError(c, "服务器错误")
			return
		}
		// 如果不存在，则使用这个邀请码
		if !exists {
			break
		}
		utils.LogDebug("邀请码 %s 已存在，重新生成", userInviteCode)
	}

	// 创建用户（传入用户自己的邀请码和注册时使用的邀请码）
	user, err := ctrl.userRepo.Create(req.Username, req.FullName, hashedPassword, userInviteCode, req.InviteCode)
	if err != nil {
		utils.LogDebug("创建用户失败: %v", err)
		utils.InternalServerError(c, "创建用户失败")
		return
	}

	// 标记邀请码已使用
	err = ctrl.userRepo.MarkInviteCodeUsed(req.InviteCode, user.ID, user.Username, req.FullName)
	if err != nil {
		utils.LogDebug("标记邀请码已使用失败: %v", err)
		// 不影响注册流程，继续返回
	}

	utils.LogDebug("✅ 用户注册成功: username=%s, invite_code=%s, invited_by_code=%s", req.Username, userInviteCode, req.InviteCode)

	// 生成token
	token, err := utils.GenerateToken(user.ID, user.Username)
	if err != nil {
		utils.LogDebug("生成token失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	utils.Success(c, gin.H{
		"user":  user,
		"token": token,
	})
}

// Login 账号密码登录
func (ctrl *AuthController) Login(c *gin.Context) {
	var req models.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 查找用户（支持用户名/手机号/邮箱登录）
	user, err := ctrl.userRepo.FindByAccount(req.Username)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.BadRequest(c, "用户名或密码错误")
			return
		}
		utils.LogDebug("查询用户失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 检查用户是否被禁用
	if user.Status == "disabled" {
		utils.BadRequest(c, "您的账号已被禁用，请联系管理员")
		return
	}

	// 验证密码
	if !utils.CheckPassword(req.Password, user.Password) {
		utils.BadRequest(c, "用户名或密码错误")
		return
	}

	// 注释掉在线状态检查，允许直接登录
	// WebSocket连接时会自动踢掉旧设备的连接
	// if user.Status == "online" || user.Status == "busy" || user.Status == "away" {
	// 	statusText := map[string]string{
	// 		"online": "在线",
	// 		"busy":   "忙碌",
	// 		"away":   "离开",
	// 	}[user.Status]
	// 	utils.BadRequest(c, "该账号已有设备登录，当前状态为："+statusText)
	// 	return
	// }

	// 生成token
	token, err := utils.GenerateToken(user.ID, user.Username)
	if err != nil {
		utils.LogDebug("生成token失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 登录成功后立即设置用户状态为在线
	err = ctrl.userRepo.UpdateStatus(user.ID, "online")
	if err != nil {
		utils.LogDebug("设置用户状态失败: %v", err)
		// 不影响登录流程，继续返回
	} else {
		// 更新返回的用户对象中的状态
		user.Status = "online"
	}

	utils.Success(c, gin.H{
		"user":  user,
		"token": token,
	})
}

// SendVerificationCode 发送验证码
func (ctrl *AuthController) SendVerificationCode(c *gin.Context) {
	var req models.SendCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 根据类型验证账号
	if req.Type == "register" {
		// 注册时检查用户名是否已存在
		existUser, err := ctrl.userRepo.FindByAccount(req.Account)
		if err != nil && err != sql.ErrNoRows {
			utils.LogDebug("查询用户失败: %v", err)
			utils.InternalServerError(c, "服务器错误")
			return
		}
		if existUser != nil {
			utils.BadRequest(c, "账号已存在")
			return
		}
	} else if req.Type == "login" || req.Type == "reset" {
		// 登录或重置密码时检查用户是否存在
		existUser, err := ctrl.userRepo.FindByAccount(req.Account)
		if err != nil {
			if err == sql.ErrNoRows {
				utils.BadRequest(c, "账号不存在")
				return
			}
			utils.LogDebug("查询用户失败: %v", err)
			utils.InternalServerError(c, "服务器错误")
			return
		}
		if existUser == nil {
			utils.BadRequest(c, "账号不存在")
			return
		}
	}

	// 生成6位纯数字验证码
	code := utils.GenerateVerificationCode(6)

	// 所有类型（register, login, reset）统一使用数据库存储
	// Redis相关代码已禁用
	expiresAt := time.Now().Add(time.Duration(config.AppConfig.VerifyCodeExpireMinutes) * time.Minute)
	
	// 如果是登录类型，验证手机号格式并发送短信
	if req.Type == "login" {
		if !utils.IsValidPhoneNumber(req.Account) {
			utils.BadRequest(c, "请输入正确的手机号格式")
			return
		}
		
		// 保存验证码到数据库
		err := ctrl.codeRepo.Create(req.Account, code, req.Type, expiresAt)
		if err != nil {
			utils.LogDebug("保存验证码失败: %v", err)
			utils.InternalServerError(c, "发送验证码失败")
			return
		}
		
		// 发送短信
		err = utils.SendLoginSMS(req.Account, code)
		if err != nil {
			utils.LogDebug("发送短信失败: %v", err)
			// 短信发送失败时，删除数据库中的验证码
			ctrl.codeRepo.DeleteByAccount(req.Account, req.Type)
			utils.InternalServerError(c, "短信发送失败，请稍后重试")
			return
		}

		utils.LogDebug("✅ 登录验证码已发送: %s (手机号: %s, 有效期: %d分钟)", code, req.Account, config.AppConfig.VerifyCodeExpireMinutes)

		// 开发环境下返回验证码，生产环境应删除
		if config.AppConfig.AppEnv == "development" {
			utils.SuccessWithMessage(c, "验证码已发送", gin.H{
				"code":       code,
				"expires_at": expiresAt,
			})
		} else {
			utils.SuccessWithMessage(c, "验证码已发送", gin.H{
				"expires_at": expiresAt,
			})
		}
		return
	}

	// 其他类型（register, reset）使用数据库存储
	err := ctrl.codeRepo.Create(req.Account, code, req.Type, expiresAt)
	if err != nil {
		utils.LogDebug("保存验证码失败: %v", err)
		utils.InternalServerError(c, "发送验证码失败")
		return
	}

	utils.LogDebug("验证码已生成: %s (账号: %s, 类型: %s)", code, req.Account, req.Type)

	utils.SuccessWithMessage(c, "验证码已发送", gin.H{
		"code":       code, // 生产环境应删除此行
		"expires_at": expiresAt,
	})
}

// VerifyCodeLogin 验证码登录
func (ctrl *AuthController) VerifyCodeLogin(c *gin.Context) {
	var req models.VerifyCodeLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 验证手机号格式
	if !utils.IsValidPhoneNumber(req.Account) {
		utils.BadRequest(c, "请输入正确的手机号格式")
		return
	}

	// 验证验证码格式
	if !utils.IsValidVerifyCode(req.Code) {
		utils.BadRequest(c, "验证码必须是6位数字")
		return
	}

	// 首先检查用户是否存在
	user, err := ctrl.userRepo.FindByAccount(req.Account)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.BadRequest(c, "账号不存在")
			return
		}
		utils.LogDebug("查询用户失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 检查用户是否被禁用
	if user.Status == "disabled" {
		utils.BadRequest(c, "您的账号已被禁用，请联系管理员")
		return
	}

	// 从数据库验证验证码（Redis已禁用）
	valid, err := ctrl.codeRepo.Verify(req.Account, req.Code, "login")
	if err != nil {
		utils.LogDebug("验证验证码失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}
	if !valid {
		utils.BadRequest(c, "验证码错误或已过期")
		return
	}

	// 验证成功，删除数据库中的验证码
	ctrl.codeRepo.DeleteByAccount(req.Account, "login")

	// 生成token
	token, err := utils.GenerateToken(user.ID, user.Username)
	if err != nil {
		utils.LogDebug("生成token失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 登录成功后立即设置用户状态为在线
	err = ctrl.userRepo.UpdateStatus(user.ID, "online")
	if err != nil {
		utils.LogDebug("设置用户状态失败: %v", err)
		// 不影响登录流程，继续返回
	} else {
		// 更新返回的用户对象中的状态
		user.Status = "online"
	}

	utils.LogDebug("✅ 验证码登录成功: 用户=%s", user.Username)

	utils.Success(c, gin.H{
		"user":  user,
		"token": token,
	})
}

// ForgotPassword 忘记密码
func (ctrl *AuthController) ForgotPassword(c *gin.Context) {
	var req models.ForgotPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 验证验证码
	valid, err := ctrl.codeRepo.Verify(req.Account, req.Code, "reset")
	if err != nil {
		utils.LogDebug("验证验证码失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}
	if !valid {
		utils.BadRequest(c, "验证码错误或已过期")
		return
	}

	// 查找用户
	user, err := ctrl.userRepo.FindByAccount(req.Account)
	if err != nil {
		if err == sql.ErrNoRows {
			utils.BadRequest(c, "账号不存在")
			return
		}
		utils.LogDebug("查询用户失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 加密新密码
	hashedPassword, err := utils.HashPassword(req.NewPassword)
	if err != nil {
		utils.LogDebug("密码加密失败: %v", err)
		utils.InternalServerError(c, "服务器错误")
		return
	}

	// 更新密码
	err = ctrl.userRepo.UpdatePassword(user.Username, hashedPassword)
	if err != nil {
		utils.LogDebug("更新密码失败: %v", err)
		utils.InternalServerError(c, "重置密码失败")
		return
	}

	// 删除已使用的验证码
	ctrl.codeRepo.DeleteByAccount(req.Account, "reset")

	utils.SuccessWithMessage(c, "密码重置成功", nil)
}
