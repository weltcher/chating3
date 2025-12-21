package models

import (
	"database/sql"
	"time"
)

// User 用户模型
type User struct {
	ID            int       `json:"id"`
	Username      string    `json:"username"`
	Password      string    `json:"-"` // 密码不返回到前端
	Phone         *string   `json:"phone"`
	Email         *string   `json:"email"`
	Avatar        string    `json:"avatar"`
	AuthCode      *string   `json:"auth_code"`
	FullName      *string   `json:"full_name"`
	Gender        *string   `json:"gender"`
	WorkSignature *string   `json:"work_signature"`
	Status        string    `json:"status"`
	Landline      *string   `json:"landline"`
	ShortNumber   *string   `json:"short_number"`
	Department    *string   `json:"department"`
	Position      *string   `json:"position"`
	Region        *string   `json:"region"`
	InviteCode    *string   `json:"invite_code"`
	InvitedByCode *string   `json:"invited_by_code"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
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

// Create 创建用户
func (r *UserRepository) Create(username, fullName, password, inviteCode, invitedByCode string) (*User, error) {
	query := `
		INSERT INTO users (username, full_name, password, invite_code, invited_by_code, status)
		VALUES ($1, $2, $3, $4, $5, 'offline')
		RETURNING id, username, phone, email, avatar, auth_code, full_name, gender, 
		          work_signature, status, landline, short_number, department, position, region,
		          invite_code, invited_by_code, created_at, updated_at
	`

	user := &User{}
	err := r.DB.QueryRow(query, username, fullName, password, inviteCode, invitedByCode).Scan(
		&user.ID,
		&user.Username,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByUsername 根据用户名查找用户
func (r *UserRepository) FindByUsername(username string) (*User, error) {
	query := `
		SELECT id, username, password, phone, email, avatar, auth_code, full_name, gender, 
		       work_signature, status, landline, short_number, department, position, region,
		       invite_code, invited_by_code, created_at, updated_at
		FROM users
		WHERE username = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, username).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByID 根据ID查找用户
func (r *UserRepository) FindByID(id int) (*User, error) {
	query := `
		SELECT id, username, password, phone, email, avatar, auth_code, full_name, gender, 
		       work_signature, status, landline, short_number, department, position, region,
		       invite_code, invited_by_code, created_at, updated_at
		FROM users
		WHERE id = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, id).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByAccount 根据账号（用户名/手机号/邮箱）查找用户
func (r *UserRepository) FindByAccount(account string) (*User, error) {
	query := `
		SELECT id, username, password, phone, email, avatar, auth_code, full_name, gender, 
		       work_signature, status, landline, short_number, department, position, region,
		       invite_code, invited_by_code, created_at, updated_at
		FROM users
		WHERE username = $1 OR phone = $1 OR email = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, account).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// FindByInviteCode 根据邀请码查找用户
func (r *UserRepository) FindByInviteCode(inviteCode string) (*User, error) {
	query := `
		SELECT id, username, password, phone, email, avatar, auth_code, full_name, gender, 
		       work_signature, status, landline, short_number, department, position, region,
		       invite_code, invited_by_code, created_at, updated_at
		FROM users
		WHERE invite_code = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, inviteCode).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}

// InviteCodeStatus 邀请码状态常量
const (
	InviteCodeNotFound = 0 // 邀请码不存在
	InviteCodeUnused   = 1 // 邀请码未使用
	InviteCodeUsed     = 2 // 邀请码已使用
)

// CheckInviteCodeStatus 检查邀请码状态（从invite_codes表查询）
func (r *UserRepository) CheckInviteCodeStatus(inviteCode string) (int, error) {
	var status string
	query := `SELECT status FROM invite_codes WHERE code = $1`
	err := r.DB.QueryRow(query, inviteCode).Scan(&status)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return InviteCodeNotFound, nil
		}
		return InviteCodeNotFound, err
	}
	if status == "used" {
		return InviteCodeUsed, nil
	}
	return InviteCodeUnused, nil
}

// InviteCodeExists 检查邀请码是否存在且未使用（从invite_codes表查询）
func (r *UserRepository) InviteCodeExists(inviteCode string) (bool, error) {
	var count int
	query := `SELECT COUNT(*) FROM invite_codes WHERE code = $1 AND status = 'unused'`
	err := r.DB.QueryRow(query, inviteCode).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// MarkInviteCodeUsed 标记邀请码已使用
func (r *UserRepository) MarkInviteCodeUsed(inviteCode string, userID int, username string, fullName string) error {
	query := `
		UPDATE invite_codes 
		SET status = 'used', used_by_user_id = $1, used_by_username = $2, used_by_fullname = $3, used_at = NOW()
		WHERE code = $4 AND status = 'unused'
	`
	_, err := r.DB.Exec(query, userID, username, fullName, inviteCode)
	return err
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

// UpdatePhone 更新手机号
func (r *UserRepository) UpdatePhone(id int, phone string) error {
	query := `
		UPDATE users
		SET phone = $1
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, phone, id)
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

// UpdateProfileRequest 更新个人信息请求
type UpdateProfileRequest struct {
	FullName    *string `json:"full_name"`
	Gender      *string `json:"gender"`
	Phone       *string `json:"phone"`
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
		    phone = COALESCE($3, phone),
		    landline = COALESCE($4, landline),
		    short_number = COALESCE($5, short_number),
		    department = COALESCE($6, department),
		    position = COALESCE($7, position),
		    region = COALESCE($8, region),
		    avatar = COALESCE($9, avatar)
		WHERE id = $10
	`

	_, err := r.DB.Exec(query,
		req.FullName,
		req.Gender,
		req.Phone,
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

// IsPhoneUsedByOthers 检查手机号是否被其他用户使用
// excludeUserID: 排除的用户ID（当前用户）
// phone: 要检查的手机号
// 返回: true表示已被其他用户使用，false表示未被使用或只被当前用户使用
func (r *UserRepository) IsPhoneUsedByOthers(excludeUserID int, phone string) (bool, error) {
	query := `
		SELECT COUNT(*)
		FROM users
		WHERE phone = $1 AND id != $2
	`

	var count int
	err := r.DB.QueryRow(query, phone, excludeUserID).Scan(&count)
	if err != nil {
		return false, err
	}

	return count > 0, nil
}

// FindByEmail 根据邮箱查找用户
func (r *UserRepository) FindByEmail(email string) (*User, error) {
	query := `
		SELECT id, username, password, phone, email, avatar, auth_code, full_name, gender, 
		       work_signature, status, landline, short_number, department, position, region,
		       invite_code, invited_by_code, created_at, updated_at
		FROM users
		WHERE email = $1
	`

	user := &User{}
	err := r.DB.QueryRow(query, email).Scan(
		&user.ID,
		&user.Username,
		&user.Password,
		&user.Phone,
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
		&user.InvitedByCode,
		&user.CreatedAt,
		&user.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return user, nil
}
