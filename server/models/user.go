package models

import (
	"database/sql"
	"time"
)

// User 用户模型
type User struct {
	ID            int        `json:"id"`
	Username      string     `json:"username"`
	Password      string     `json:"-"` // 密码不返回到前端
	Email         *string    `json:"email"`
	Avatar        string     `json:"avatar"`
	AuthCode      *string    `json:"auth_code"`
	FullName      *string    `json:"full_name"`
	Gender        *string    `json:"gender"`
	WorkSignature *string    `json:"work_signature"`
	Status        string     `json:"status"`
	Landline      *string    `json:"landline"`
	ShortNumber   *string    `json:"short_number"`
	Department    *string    `json:"department"`
	Position      *string    `json:"position"`
	Region        *string    `json:"region"`
	InviteCode    *string    `json:"invite_code"`    // 用户注册时使用的邀请码（从关联表查询）
	IsOverseas    int        `json:"is_overseas"`    // 是否海外用户：0-国内，1-海外
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	LastLoginAt   *time.Time `json:"last_login_at"`
}

// RegisterRequest 注册请求
type RegisterRequest struct {
	Username        string `json:"username" binding:"required,min=3,max=50"`
	FullName        string `json:"full_name" binding:"required"`
	Password        string `json:"password" binding:"required,min=6,max=50"`
	ConfirmPassword string `json:"confirm_password" binding:"required"`
	InviteCode      string `json:"invite_code"`
}

// LoginRequest 登录请求
type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

// VerifyCodeLoginRequest 验证码登录请求
type VerifyCodeLoginRequest struct {
	Account string `json:"account" binding:"required"`
	Code    string `json:"code" binding:"required"`
}

// ForgotPasswordRequest 忘记密码请求
type ForgotPasswordRequest struct {
	Account     string `json:"account" binding:"required"`
	Code        string `json:"code" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=6,max=50"`
}

// UserRepository 用户数据仓库
type UserRepository struct {
	DB *sql.DB
}

// NewUserRepository 创建用户仓库
func NewUserRepository(db *sql.DB) *UserRepository {
	return &UserRepository{DB: db}
}

// Create 创建用户（不再存储invite_code，改为通过关联表查询）
// isOverseas: 0-国内用户，1-海外用户
func (r *UserRepository) Create(username, fullName, password string, isOverseas int) (*User, error) {
	query := `
		INSERT INTO users (username, full_name, password, is_overseas, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 'offline', NOW() AT TIME ZONE 'UTC', NOW() AT TIME ZONE 'UTC')
		RETURNING id, username, email, avatar, auth_code, full_name, gender, 
		          work_signature, status, landline, short_number, department, position, region,
		          is_overseas, created_at, updated_at, last_login_at
	`

	user := &User{}
	err := r.DB.QueryRow(query, username, fullName, password, isOverseas).Scan(
		&user.ID,
		&user.Username,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByUsername 根据用户名查找用户（包含从关联表查询邀请码）
func (r *UserRepository) FindByUsername(username string) (*User, error) {
	query := `
		SELECT u.id, u.username, u.password, u.email, u.avatar, u.auth_code, u.full_name, u.gender, 
		       u.work_signature, u.status, u.landline, u.short_number, u.department, u.position, u.region,
		       ic.code as invite_code, COALESCE(u.is_overseas, 1) as is_overseas, u.created_at, u.updated_at, u.last_login_at
		FROM users u
		LEFT JOIN invite_code_usages icu ON icu.user_id = u.id
		LEFT JOIN invite_codes ic ON ic.id = icu.invite_code_id
		WHERE u.username = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, username).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.InviteCode,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByID 根据ID查找用户（包含从关联表查询邀请码）
func (r *UserRepository) FindByID(id int) (*User, error) {
	query := `
		SELECT u.id, u.username, u.password, u.email, u.avatar, u.auth_code, u.full_name, u.gender, 
		       u.work_signature, u.status, u.landline, u.short_number, u.department, u.position, u.region,
		       ic.code as invite_code, COALESCE(u.is_overseas, 1) as is_overseas, u.created_at, u.updated_at, u.last_login_at
		FROM users u
		LEFT JOIN invite_code_usages icu ON icu.user_id = u.id
		LEFT JOIN invite_codes ic ON ic.id = icu.invite_code_id
		WHERE u.id = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, id).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.InviteCode,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByAccount 根据账号（用户名/邮箱）查找用户（包含从关联表查询邀请码）
func (r *UserRepository) FindByAccount(account string) (*User, error) {
	query := `
		SELECT u.id, u.username, u.password, u.email, u.avatar, u.auth_code, u.full_name, u.gender, 
		       u.work_signature, u.status, u.landline, u.short_number, u.department, u.position, u.region,
		       ic.code as invite_code, COALESCE(u.is_overseas, 1) as is_overseas, u.created_at, u.updated_at, u.last_login_at
		FROM users u
		LEFT JOIN invite_code_usages icu ON icu.user_id = u.id
		LEFT JOIN invite_codes ic ON ic.id = icu.invite_code_id
		WHERE u.username = $1 OR u.email = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, account).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.InviteCode,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// InviteCodeStatus 邀请码状态常量
const (
	InviteCodeNotFound  = 0 // 邀请码不存在
	InviteCodeUnused    = 1 // 邀请码可用（还有剩余次数）
	InviteCodeUsed      = 2 // 邀请码已用完（已使用次数>=总次数）
)

// CheckInviteCodeStatus 检查邀请码状态（从invite_codes表查询，基于次数判断）
func (r *UserRepository) CheckInviteCodeStatus(inviteCode string) (int, error) {
	var totalCount, usedCount int
	query := `SELECT COALESCE(total_count, 1), COALESCE(used_count, 0) FROM invite_codes WHERE code = $1`
	err := r.DB.QueryRow(query, inviteCode).Scan(&totalCount, &usedCount)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return InviteCodeNotFound, nil
		}
		return InviteCodeNotFound, err
	}
	// 如果已使用次数 >= 总次数，则邀请码已用完
	if usedCount >= totalCount {
		return InviteCodeUsed, nil
	}
	return InviteCodeUnused, nil
}

// InviteCodeExists 检查邀请码是否存在且还有剩余次数（从invite_codes表查询）
func (r *UserRepository) InviteCodeExists(inviteCode string) (bool, error) {
	var count int
	query := `SELECT COUNT(*) FROM invite_codes WHERE code = $1 AND used_count < total_count`
	err := r.DB.QueryRow(query, inviteCode).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// MarkInviteCodeUsed 标记邀请码已使用（累加已使用次数，并插入使用记录）
func (r *UserRepository) MarkInviteCodeUsed(inviteCode string, userID int, username string, fullName string) error {
	// 获取邀请码ID
	var inviteCodeID int
	err := r.DB.QueryRow(`SELECT id FROM invite_codes WHERE code = $1`, inviteCode).Scan(&inviteCodeID)
	if err != nil {
		return err
	}

	// 插入使用记录到关联表
	_, err = r.DB.Exec(`
		INSERT INTO invite_code_usages (invite_code_id, user_id, used_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (invite_code_id, user_id) DO NOTHING
	`, inviteCodeID, userID)
	if err != nil {
		return err
	}

	// 更新邀请码的使用次数和状态
	query := `
		UPDATE invite_codes 
		SET used_count = used_count + 1,
		    status = CASE WHEN used_count + 1 >= total_count THEN 'used' ELSE 'unused' END
		WHERE code = $1 AND used_count < total_count
	`
	result, err := r.DB.Exec(query, inviteCode)
	if err != nil {
		return err
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return sql.ErrNoRows // 邀请码不存在或已用完
	}
	return nil
}

// FindUserByInviteCode 根据邀请码查找使用该邀请码注册的用户（从关联表查询）
func (r *UserRepository) FindUserByInviteCode(inviteCode string) (*User, error) {
	query := `
		SELECT u.id, u.username, u.password, u.email, u.avatar, u.auth_code, u.full_name, u.gender, 
		       u.work_signature, u.status, u.landline, u.short_number, u.department, u.position, u.region,
		       ic.code as invite_code, COALESCE(u.is_overseas, 1) as is_overseas, u.created_at, u.updated_at, u.last_login_at
		FROM users u
		JOIN invite_code_usages icu ON icu.user_id = u.id
		JOIN invite_codes ic ON ic.id = icu.invite_code_id
		WHERE ic.code = $1
		LIMIT 1
	`

	user := &User{}
	err := r.DB.QueryRow(query, inviteCode).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.InviteCode,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// UpdatePassword 更新密码（通过用户名）
func (r *UserRepository) UpdatePassword(username, newPassword string) error {
	query := `
		UPDATE users
		SET password = $1
		WHERE username = $2
	`

	_, err := r.DB.Exec(query, newPassword, username)
	return err
}

// UpdatePasswordByID 更新密码（通过用户ID）
func (r *UserRepository) UpdatePasswordByID(id int, newPassword string) error {
	query := `
		UPDATE users
		SET password = $1
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, newPassword, id)
	return err
}

// UpdateEmail 更新邮箱
func (r *UserRepository) UpdateEmail(id int, email string) error {
	query := `
		UPDATE users
		SET email = $1
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, email, id)
	return err
}

// UpdateWorkSignature 更新工作签名
func (r *UserRepository) UpdateWorkSignature(id int, signature string) error {
	query := `
		UPDATE users
		SET work_signature = $1
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, signature, id)
	return err
}

// UpdateStatus 更新状态
func (r *UserRepository) UpdateStatus(id int, status string) error {
	query := `
		UPDATE users
		SET status = $1
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, status, id)
	return err
}

// UpdateLastLoginAt 更新最近登录时间（使用UTC时间）
func (r *UserRepository) UpdateLastLoginAt(id int) error {
	query := `
		UPDATE users
		SET last_login_at = NOW() AT TIME ZONE 'UTC'
		WHERE id = $1
	`

	_, err := r.DB.Exec(query, id)
	return err
}

// UpdateProfileRequest 更新个人信息请求
type UpdateProfileRequest struct {
	FullName    *string `json:"full_name"`
	Gender      *string `json:"gender"`
	Landline    *string `json:"landline"`
	ShortNumber *string `json:"short_number"`
	Department  *string `json:"department"`
	Position    *string `json:"position"`
	Region      *string `json:"region"`
	Avatar      *string `json:"avatar"`
}

// UpdateProfile 更新个人信息（不包含邮箱，邮箱只能通过绑定接口修改）
func (r *UserRepository) UpdateProfile(id int, req UpdateProfileRequest) error {
	query := `
		UPDATE users
		SET full_name = COALESCE($1, full_name),
		    gender = COALESCE($2, gender),
		    landline = COALESCE($3, landline),
		    short_number = COALESCE($4, short_number),
		    department = COALESCE($5, department),
		    position = COALESCE($6, position),
		    region = COALESCE($7, region),
		    avatar = COALESCE($8, avatar)
		WHERE id = $9
	`

	_, err := r.DB.Exec(query,
		req.FullName,
		req.Gender,
		req.Landline,
		req.ShortNumber,
		req.Department,
		req.Position,
		req.Region,
		req.Avatar,
		id,
	)
	return err
}

// UpdateActiveToken 更新用户的活跃token（用于单设备登录限制）
func (r *UserRepository) UpdateActiveToken(userID int, token string) error {
	query := `
		UPDATE users
		SET active_token = $1, token_updated_at = NOW() AT TIME ZONE 'UTC'
		WHERE id = $2
	`
	_, err := r.DB.Exec(query, token, userID)
	return err
}

// GetActiveToken 获取用户当前的活跃token
func (r *UserRepository) GetActiveToken(userID int) (string, error) {
	var token sql.NullString
	query := `SELECT active_token FROM users WHERE id = $1`
	err := r.DB.QueryRow(query, userID).Scan(&token)
	if err != nil {
		return "", err
	}
	if !token.Valid {
		return "", nil
	}
	return token.String, nil
}

// ValidateActiveToken 验证token是否为当前活跃token
func (r *UserRepository) ValidateActiveToken(userID int, token string) (bool, error) {
	activeToken, err := r.GetActiveToken(userID)
	if err != nil {
		return false, err
	}
	return activeToken == token, nil
}

// ClearActiveToken 清除用户的活跃token（登出时调用）
func (r *UserRepository) ClearActiveToken(userID int) error {
	query := `
		UPDATE users
		SET active_token = NULL, token_updated_at = NOW() AT TIME ZONE 'UTC'
		WHERE id = $1
	`
	_, err := r.DB.Exec(query, userID)
	return err
}

// FindByEmail 根据邮箱查找用户（包含从关联表查询邀请码）
func (r *UserRepository) FindByEmail(email string) (*User, error) {
	query := `
		SELECT u.id, u.username, u.password, u.email, u.avatar, u.auth_code, u.full_name, u.gender, 
		       u.work_signature, u.status, u.landline, u.short_number, u.department, u.position, u.region,
		       ic.code as invite_code, COALESCE(u.is_overseas, 1) as is_overseas, u.created_at, u.updated_at, u.last_login_at
		FROM users u
		LEFT JOIN invite_code_usages icu ON icu.user_id = u.id
		LEFT JOIN invite_codes ic ON ic.id = icu.invite_code_id
		WHERE u.email = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, email).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Email,
		&user.Avatar,
		&user.AuthCode,
		&user.FullName,
		&user.Gender,
		&user.WorkSignature,
		&user.Status,
		&user.Landline,
		&user.ShortNumber,
		&user.Department,
		&user.Position,
		&user.Region,
		&user.InviteCode,
		&user.IsOverseas,
		&user.CreatedAt,
		&user.UpdatedAt,
		&user.LastLoginAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}
