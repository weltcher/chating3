package middleware

import (
	"strings"

	"github.com/gin-gonic/gin"
	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"
)

// AuthMiddleware JWT认证中间件
func AuthMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		// 从请求头获取token
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" {
			utils.Unauthorized(c, "未授权，请先登录")
			c.Abort()
			return
		}

		// 验证token格式
		parts := strings.SplitN(authHeader, " ", 2)
		if !(len(parts) == 2 && parts[0] == "Bearer") {
			utils.Unauthorized(c, "认证格式错误")
			c.Abort()
			return
		}

		tokenString := parts[1]

		// 解析token
		claims, err := utils.ParseToken(tokenString)
		if err != nil {
			utils.Unauthorized(c, "无效的token")
			c.Abort()
			return
		}

		// 🔴 单设备登录限制：验证token是否为当前活跃的token
		userRepo := models.NewUserRepository(db.DB)
		isValid, err := userRepo.ValidateActiveToken(claims.UserID, tokenString)
		if err != nil {
			utils.LogDebug("验证active_token失败: %v", err)
			// 数据库错误时不阻止请求，继续处理
		} else if !isValid {
			// token不是当前活跃的token，说明已在其他设备登录
			utils.Unauthorized(c, "您的账号已在其他设备登录，请重新登录")
			c.Abort()
			return
		}

		// 将用户信息存储到上下文
		c.Set("user_id", claims.UserID)
		c.Set("username", claims.Username)
		c.Set("token", tokenString) // 🔴 存储token，供后续使用

		c.Next()
	}
}

// CORS 跨域中间件
func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE, PATCH")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}

		c.Next()
	}
}

