package models

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Group 群组模型
type Group struct {
	ID                   int        `json:"id" db:"id"`
	Name                 string     `json:"name" db:"name"`
	Announcement         *string    `json:"announcement,omitempty" db:"announcement"`
	Avatar               *string    `json:"avatar,omitempty" db:"avatar"`
	OwnerID              int        `json:"owner_id" db:"owner_id"`
	AllMuted             bool       `json:"all_muted" db:"all_muted"`                           // 是否全体禁言
	InviteConfirmation   bool       `json:"invite_confirmation" db:"invite_confirmation"`       // 是否开启群聊邀请确认
	AdminOnlyEditName    bool       `json:"admin_only_edit_name" db:"admin_only_edit_name"`     // 是否仅群主/管理员可修改群名称
	MemberViewPermission bool       `json:"member_view_permission" db:"member_view_permission"` // 群成员查看权限：true=普通成员可以查看其他成员信息，false=不可以
	CreatedAt            time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt            time.Time  `json:"updated_at" db:"updated_at"`
	DeletedAt            *time.Time `json:"deleted_at,omitempty" db:"deleted_at"`
}

// GroupMember 群组成员模型
type GroupMember struct {
	ID             int       `json:"id" db:"id"`
	GroupID        int       `json:"group_id" db:"group_id"`
	UserID         int       `json:"user_id" db:"user_id"`
	Nickname       *string   `json:"nickname,omitempty" db:"nickname"`
	Remark         *string   `json:"remark,omitempty" db:"remark"`
	Role           string    `json:"role" db:"role"`
	IsMuted        bool      `json:"is_muted" db:"is_muted"`               // 是否被禁言
	DoNotDisturb   bool      `json:"do_not_disturb" db:"do_not_disturb"`   // 消息免打扰（true表示只显示红点，false表示显示未读数量）
	ApprovalStatus string    `json:"approval_status" db:"approval_status"` // 审核状态：pending-待审核，approved-已通过，rejected-已拒绝
	JoinedAt       time.Time `json:"joined_at" db:"joined_at"`
}

// GroupMessage 群组消息模型
type GroupMessage struct {
	ID                   int       `json:"id" db:"id"`
	GroupID              int       `json:"group_id" db:"group_id"`
	SenderID             int       `json:"sender_id" db:"sender_id"`
	SenderName           string    `json:"sender_name" db:"sender_name"`
	SenderNickname       *string   `json:"sender_nickname,omitempty" db:"sender_nickname"`   // 发送者在群组中的昵称
	SenderFullName       *string   `json:"sender_full_name,omitempty" db:"sender_full_name"` // 发送者全名
	SenderAvatar         *string   `json:"sender_avatar,omitempty" db:"sender_avatar"`       // 发送者头像
	Content              string    `json:"content" db:"content"`
	MessageType          string    `json:"message_type" db:"message_type"`
	FileName             *string   `json:"file_name,omitempty" db:"file_name"`
	QuotedMessageID      *int      `json:"quoted_message_id,omitempty" db:"quoted_message_id"`
	QuotedMessageContent *string   `json:"quoted_message_content,omitempty" db:"quoted_message_content"`
	MentionedUserIDs     *string   `json:"mentioned_user_ids,omitempty" db:"mentioned_user_ids"` // 被@的用户ID列表（逗号分隔的字符串）
	Mentions             *string   `json:"mentions,omitempty" db:"mentions"`                     // @文本内容（如"@all"或"@张三(zhangsan)"）
	CallType             *string   `json:"call_type,omitempty" db:"call_type"`                   // 通话类型（voice/video），仅用于call_initiated消息
	ChannelName          *string   `json:"channel_name,omitempty" db:"channel_name"`             // Agora频道名称，用于加入群组通话
	VoiceDuration        *int      `json:"voice_duration,omitempty" db:"voice_duration"`         // 语音消息时长（秒）
	Status               string    `json:"status" db:"status"`
	DeletedByUsers       string    `json:"deleted_by_users" db:"deleted_by_users"` // 已删除该消息的用户ID列表（逗号分隔）
	CreatedAt            time.Time `json:"-" db:"created_at"`                      // 🔴 不直接序列化，使用 MarshalJSON 方法
}

// MarshalJSON 自定义 JSON 序列化，确保 CreatedAt 使用 UTC 时间
func (m GroupMessage) MarshalJSON() ([]byte, error) {
	type Alias GroupMessage
	return json.Marshal(&struct {
		Alias
		CreatedAt string `json:"created_at"`
	}{
		Alias:     Alias(m),
		CreatedAt: m.CreatedAt.UTC().Format(time.RFC3339Nano),
	})
}

// GroupMessageRead 群组消息已读记录
type GroupMessageRead struct {
	ID             int       `json:"id" db:"id"`
	GroupMessageID int       `json:"group_message_id" db:"group_message_id"`
	UserID         int       `json:"user_id" db:"user_id"`
	ReadAt         time.Time `json:"read_at" db:"read_at"`
}

// CreateGroupRequest 创建群组请求
type CreateGroupRequest struct {
	Name         string `json:"name" binding:"required,min=1,max=100"`
	Announcement string `json:"announcement,omitempty"`
	Avatar       string `json:"avatar,omitempty"` // 群头像URL
	MemberIDs    []int  `json:"member_ids" binding:"required,min=1"`
	Nickname     string `json:"nickname,omitempty"`       // 我在本群的昵称
	Remark       string `json:"remark,omitempty"`         // 备注
	DoNotDisturb bool   `json:"do_not_disturb,omitempty"` // 消息免打扰
}

// CreateGroupMessageRequest 创建群组消息请求
type CreateGroupMessageRequest struct {
	GroupID              int    `json:"group_id" binding:"required"`
	Content              string `json:"content" binding:"required"`
	MessageType          string `json:"message_type"`
	FileName             string `json:"file_name,omitempty"`
	QuotedMessageID      int    `json:"quoted_message_id,omitempty"`
	QuotedMessageContent string `json:"quoted_message_content,omitempty"`
	MentionedUserIds     []int  `json:"mentioned_user_ids,omitempty"`
	Mentions             string `json:"mentions,omitempty"`
	VoiceDuration        int    `json:"voice_duration,omitempty"`
}

// GroupDetailResponse 群组详情响应
type GroupDetailResponse struct {
	Group      Group               `json:"group"`
	Members    []GroupMemberDetail `json:"members"`
	MemberRole string              `json:"member_role"` // 当前用户在群组中的角色
}

// GroupWithRemark 群组信息（包含当前用户的备注）
type GroupWithRemark struct {
	ID                   int       `json:"id" db:"id"`
	Name                 string    `json:"name" db:"name"`
	Announcement         *string   `json:"announcement,omitempty" db:"announcement"`
	Avatar               *string   `json:"avatar,omitempty" db:"avatar"`
	OwnerID              int       `json:"owner_id" db:"owner_id"`
	AllMuted             bool      `json:"all_muted" db:"all_muted"`                           // 是否全体禁言
	InviteConfirmation   bool      `json:"invite_confirmation" db:"invite_confirmation"`       // 是否开启群聊邀请确认
	AdminOnlyEditName    bool      `json:"admin_only_edit_name" db:"admin_only_edit_name"`     // 是否仅群主/管理员可修改群名称
	MemberViewPermission bool      `json:"member_view_permission" db:"member_view_permission"` // 群成员查看权限：true=普通成员可以查看其他成员信息，false=不可以
	MemberIDs            []int     `json:"member_ids"`                                         // 群组成员ID列表
	CreatedAt            time.Time `json:"created_at" db:"created_at"`
	UpdatedAt            time.Time `json:"updated_at" db:"updated_at"`
	Remark               *string   `json:"remark,omitempty" db:"remark"` // 当前用户对该群组的备注
}

// GroupMemberDetail 群组成员详情
type GroupMemberDetail struct {
	UserID         int       `json:"user_id"`
	Username       string    `json:"username"`
	FullName       *string   `json:"full_name,omitempty"`
	Avatar         string    `json:"avatar"`
	Nickname       *string   `json:"nickname,omitempty"`
	Remark         *string   `json:"remark,omitempty"`
	Role           string    `json:"role"`
	IsMuted        bool      `json:"is_muted"`        // 是否被禁言
	DoNotDisturb   bool      `json:"do_not_disturb"`  // 消息免打扰
	ApprovalStatus string    `json:"approval_status"` // 审核状态：pending-待审核，approved-已通过，rejected-已拒绝
	JoinedAt       time.Time `json:"joined_at"`
}

// WSGroupMessage WebSocket群组消息格式
type WSGroupMessage struct {
	Type    string      `json:"type"` // group_message
	Data    interface{} `json:"data"`
	GroupID int         `json:"group_id"`
}

// WSGroupMessageData WebSocket群组消息数据
type WSGroupMessageData struct {
	ID                   int       `json:"id"`
	GroupID              int       `json:"group_id"`
	SenderID             int       `json:"sender_id"`
	SenderName           string    `json:"sender_name"`
	SenderAvatar         *string   `json:"sender_avatar,omitempty"`
	Content              string    `json:"content"`
	MessageType          string    `json:"message_type"`
	FileName             *string   `json:"file_name,omitempty"`
	QuotedMessageID      *int      `json:"quoted_message_id,omitempty"`
	QuotedMessageContent *string   `json:"quoted_message_content,omitempty"`
	MentionedUserIds     []int     `json:"mentioned_user_ids,omitempty"`
	Mentions             *string   `json:"mentions,omitempty"`
	VoiceDuration        *int      `json:"voice_duration,omitempty"`
	CreatedAt            time.Time `json:"created_at"` // 🔴 UTC 时间，客户端需要转换为本地时区显示
}

// GetCreatedAtUTC 返回 UTC 时间
func (d *WSGroupMessageData) GetCreatedAtUTC() time.Time {
	return d.CreatedAt.UTC()
}

// GroupRepository 群组数据仓库
type GroupRepository struct {
	DB *sql.DB
}

// NewGroupRepository 创建群组仓库
func NewGroupRepository(db *sql.DB) *GroupRepository {
	return &GroupRepository{DB: db}
}

// CreateGroup 创建群组
func (r *GroupRepository) CreateGroup(name string, announcement *string, avatar *string, ownerID int) (*Group, error) {
	query := `
		INSERT INTO groups (name, announcement, avatar, owner_id)
		VALUES ($1, $2, $3, $4)
		RETURNING id, name, announcement, avatar, owner_id, all_muted, invite_confirmation, admin_only_edit_name, created_at, updated_at
	`

	group := &Group{}
	err := r.DB.QueryRow(query, name, announcement, avatar, ownerID).Scan(
		&group.ID,
		&group.Name,
		&group.Announcement,
		&group.Avatar,
		&group.OwnerID,
		&group.AllMuted,
		&group.InviteConfirmation,
		&group.AdminOnlyEditName,
		&group.CreatedAt,
		&group.UpdatedAt,
	)

	return group, err
}

// AddGroupMember 添加群组成员
func (r *GroupRepository) AddGroupMember(groupID, userID int, nickname, remark *string, role string) error {
	query := `
		INSERT INTO group_members (group_id, user_id, nickname, remark, role, approval_status)
		VALUES ($1, $2, $3, $4, $5, 'approved')
	`

	_, err := r.DB.Exec(query, groupID, userID, nickname, remark, role)
	return err
}

// AddGroupMemberWithDoNotDisturb 添加群组成员（支持消息免打扰设置）
func (r *GroupRepository) AddGroupMemberWithDoNotDisturb(groupID, userID int, nickname, remark *string, role string, doNotDisturb bool) error {
	query := `
		INSERT INTO group_members (group_id, user_id, nickname, remark, role, approval_status, do_not_disturb)
		VALUES ($1, $2, $3, $4, $5, 'approved', $6)
	`

	_, err := r.DB.Exec(query, groupID, userID, nickname, remark, role, doNotDisturb)
	return err
}

// AddGroupMemberWithApproval 添加群组成员（带审核状态）
func (r *GroupRepository) AddGroupMemberWithApproval(groupID, userID int, nickname, remark *string, role string, approvalStatus string) error {
	query := `
		INSERT INTO group_members (group_id, user_id, nickname, remark, role, approval_status)
		VALUES ($1, $2, $3, $4, $5, $6)
	`

	_, err := r.DB.Exec(query, groupID, userID, nickname, remark, role, approvalStatus)
	return err
}

// GetGroupByID 根据ID获取群组
func (r *GroupRepository) GetGroupByID(groupID int) (*Group, error) {
	query := `
		SELECT id, name, announcement, avatar, owner_id, all_muted, invite_confirmation, admin_only_edit_name, member_view_permission, created_at, updated_at, deleted_at
		FROM groups
		WHERE id = $1 AND deleted_at IS NULL
	`

	group := &Group{}
	err := r.DB.QueryRow(query, groupID).Scan(
		&group.ID,
		&group.Name,
		&group.Announcement,
		&group.Avatar,
		&group.OwnerID,
		&group.AllMuted,
		&group.InviteConfirmation,
		&group.AdminOnlyEditName,
		&group.MemberViewPermission,
		&group.CreatedAt,
		&group.UpdatedAt,
		&group.DeletedAt,
	)

	return group, err
}

// GetGroupMembers 获取群组成员列表（带自定义排序）
// currentUserID: 当前用户ID，用于排序（传0表示不考虑当前用户）
// includeAll: 是否包含所有成员（true表示包含待审核成员，false表示只返回已通过的成员）
func (r *GroupRepository) GetGroupMembers(groupID int, currentUserID ...int) ([]GroupMemberDetail, error) {
	// 获取当前用户ID（如果提供）
	var userID int
	if len(currentUserID) > 0 {
		userID = currentUserID[0]
	}

	// 默认只返回已通过审核的成员
	query := `
		SELECT gm.user_id, u.username, u.full_name, u.avatar, gm.nickname, gm.remark, gm.role, gm.is_muted, gm.do_not_disturb, gm.approval_status, gm.joined_at
		FROM group_members gm
		JOIN users u ON gm.user_id = u.id
		WHERE gm.group_id = $1 AND gm.approval_status = 'approved'
		ORDER BY 
			CASE 
				WHEN gm.role = 'owner' THEN 1
				WHEN gm.role = 'admin' THEN 2
				WHEN gm.user_id = $2 AND gm.role = 'member' THEN 3
				ELSE 4
			END,
			gm.joined_at ASC
	`

	rows, err := r.DB.Query(query, groupID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []GroupMemberDetail
	for rows.Next() {
		var member GroupMemberDetail
		err := rows.Scan(
			&member.UserID,
			&member.Username,
			&member.FullName,
			&member.Avatar,
			&member.Nickname,
			&member.Remark,
			&member.Role,
			&member.IsMuted,
			&member.DoNotDisturb,
			&member.ApprovalStatus,
			&member.JoinedAt,
		)
		if err != nil {
			return nil, err
		}
		members = append(members, member)
	}

	return members, nil
}

// GetGroupMembersWithPending 获取群组所有成员（包括待审核的成员）- 仅供群主和管理员使用
func (r *GroupRepository) GetGroupMembersWithPending(groupID int, currentUserID ...int) ([]GroupMemberDetail, error) {
	// 获取当前用户ID（如果提供）
	var userID int
	if len(currentUserID) > 0 {
		userID = currentUserID[0]
	}

	query := `
		SELECT gm.user_id, u.username, u.full_name, u.avatar, gm.nickname, gm.remark, gm.role, gm.is_muted, gm.do_not_disturb, gm.approval_status, gm.joined_at
		FROM group_members gm
		JOIN users u ON gm.user_id = u.id
		WHERE gm.group_id = $1
		ORDER BY 
			CASE 
				WHEN gm.role = 'owner' THEN 1
				WHEN gm.role = 'admin' THEN 2
				WHEN gm.user_id = $2 AND gm.role = 'member' THEN 3
				WHEN gm.approval_status = 'pending' THEN 4
				ELSE 5
			END,
			gm.joined_at ASC
	`

	rows, err := r.DB.Query(query, groupID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []GroupMemberDetail
	for rows.Next() {
		var member GroupMemberDetail
		err := rows.Scan(
			&member.UserID,
			&member.Username,
			&member.FullName,
			&member.Avatar,
			&member.Nickname,
			&member.Remark,
			&member.Role,
			&member.IsMuted,
			&member.DoNotDisturb,
			&member.ApprovalStatus,
			&member.JoinedAt,
		)
		if err != nil {
			return nil, err
		}
		members = append(members, member)
	}

	return members, nil
}

// GetUserGroupRole 获取用户在群组中的角色（仅返回已通过审核的成员角色）
func (r *GroupRepository) GetUserGroupRole(groupID, userID int) (string, error) {
	query := `
		SELECT role
		FROM group_members
		WHERE group_id = $1 AND user_id = $2 AND approval_status = 'approved'
	`

	var role string
	err := r.DB.QueryRow(query, groupID, userID).Scan(&role)
	return role, err
}

// GetMemberRole 获取用户在群组中的角色（GetUserGroupRole的别名）
func (r *GroupRepository) GetMemberRole(groupID, userID int) (string, error) {
	return r.GetUserGroupRole(groupID, userID)
}

// UpdateGroup 更新群组信息
func (r *GroupRepository) UpdateGroup(groupID int, name *string, announcement *string, avatar *string) error {
	query := `
		UPDATE groups
		SET name = COALESCE($1, name),
		    announcement = COALESCE($2, announcement),
		    avatar = COALESCE($3, avatar),
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = $4
	`

	_, err := r.DB.Exec(query, name, announcement, avatar, groupID)
	return err
}

// UpdateGroupAllMuted 更新群组全体禁言状态
func (r *GroupRepository) UpdateGroupAllMuted(groupID int, allMuted bool) error {
	query := `
		UPDATE groups
		SET all_muted = $1,
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, allMuted, groupID)
	return err
}

// UpdateGroupMemberInfo 更新用户在群组中的个人信息（备注、昵称和消息免打扰）
func (r *GroupRepository) UpdateGroupMemberInfo(groupID int, userID int, nickname *string, remark *string, doNotDisturb *bool) error {
	// 构建动态更新语句
	query := `
		UPDATE group_members
		SET nickname = COALESCE($1, nickname),
		    remark = COALESCE($2, remark)
	`

	args := []interface{}{nickname, remark}
	argIndex := 3

	// 如果提供了 doNotDisturb 参数，则更新该字段
	if doNotDisturb != nil {
		query += fmt.Sprintf(", do_not_disturb = $%d", argIndex)
		args = append(args, *doNotDisturb)
		argIndex++
	}

	query += fmt.Sprintf(" WHERE group_id = $%d AND user_id = $%d", argIndex, argIndex+1)
	args = append(args, groupID, userID)

	_, err := r.DB.Exec(query, args...)
	return err
}

// RemoveGroupMember 移除群组成员
func (r *GroupRepository) RemoveGroupMember(groupID int, userID int) error {
	query := `
		DELETE FROM group_members
		WHERE group_id = $1 AND user_id = $2
	`

	_, err := r.DB.Exec(query, groupID, userID)
	return err
}

// GetGroupMemberNickname 获取用户在群组中的显示昵称
// 优先级：群昵称 > 用户全名 > 用户名
func (r *GroupRepository) GetGroupMemberNickname(groupID int, userID int) (string, error) {
	query := `
		SELECT gm.nickname, u.full_name, u.username
		FROM group_members gm
		JOIN users u ON gm.user_id = u.id
		WHERE gm.group_id = $1 AND gm.user_id = $2 AND gm.approval_status = 'approved'
	`

	var nickname sql.NullString
	var fullName sql.NullString
	var username string

	err := r.DB.QueryRow(query, groupID, userID).Scan(&nickname, &fullName, &username)
	if err != nil {
		return "", err
	}

	// 优先返回群昵称，其次是用户全名，最后是用户名
	if nickname.Valid && nickname.String != "" {
		return nickname.String, nil
	}
	if fullName.Valid && fullName.String != "" {
		return fullName.String, nil
	}
	return username, nil
}

// GetGroupMemberInfo 获取用户在群组中的完整信息（用于消息发送）
// 返回：nickname（群昵称）、fullName（全名）、username（用户名）、avatar（头像）
func (r *GroupRepository) GetGroupMemberInfo(groupID int, userID int) (nickname *string, fullName *string, username string, avatar *string, err error) {
	query := `
		SELECT gm.nickname, u.full_name, u.username, u.avatar
		FROM group_members gm
		JOIN users u ON gm.user_id = u.id
		WHERE gm.group_id = $1 AND gm.user_id = $2 AND gm.approval_status = 'approved'
	`

	var nicknameNull sql.NullString
	var fullNameNull sql.NullString
	var avatarNull sql.NullString

	err = r.DB.QueryRow(query, groupID, userID).Scan(&nicknameNull, &fullNameNull, &username, &avatarNull)
	if err != nil {
		return nil, nil, "", nil, err
	}

	// 转换为指针类型
	if nicknameNull.Valid && nicknameNull.String != "" {
		nickname = &nicknameNull.String
	}
	if fullNameNull.Valid && fullNameNull.String != "" {
		fullName = &fullNameNull.String
	}
	if avatarNull.Valid && avatarNull.String != "" {
		avatar = &avatarNull.String
	}

	return nickname, fullName, username, avatar, nil
}

// DeleteGroup 删除群组（解散群组）- 软删除
func (r *GroupRepository) DeleteGroup(groupID int) error {
	// 使用软删除：只更新 deleted_at 字段
	query := `
		UPDATE groups
		SET deleted_at = CURRENT_TIMESTAMP
		WHERE id = $1 AND deleted_at IS NULL
	`

	_, err := r.DB.Exec(query, groupID)
	return err
}

// GetUserGroups 获取用户加入的所有群组
func (r *GroupRepository) GetUserGroups(userID int) ([]Group, error) {
	query := `
		SELECT g.id, g.name, g.announcement, g.avatar, g.owner_id, g.all_muted, g.invite_confirmation, g.admin_only_edit_name, g.member_view_permission, g.created_at, g.updated_at, g.deleted_at
		FROM groups g
		JOIN group_members gm ON g.id = gm.group_id
		WHERE gm.user_id = $1 AND g.deleted_at IS NULL AND gm.approval_status = 'approved'
		ORDER BY g.created_at DESC
	`

	rows, err := r.DB.Query(query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []Group
	for rows.Next() {
		var group Group
		err := rows.Scan(
			&group.ID,
			&group.Name,
			&group.Announcement,
			&group.Avatar,
			&group.OwnerID,
			&group.AllMuted,
			&group.InviteConfirmation,
			&group.AdminOnlyEditName,
			&group.MemberViewPermission,
			&group.CreatedAt,
			&group.UpdatedAt,
			&group.DeletedAt,
		)
		if err != nil {
			return nil, err
		}
		groups = append(groups, group)
	}

	return groups, nil
}

// GetUserGroupsWithRemark 获取用户加入的所有群组（包含用户对群组的备注）
func (r *GroupRepository) GetUserGroupsWithRemark(userID int) ([]GroupWithRemark, error) {
	query := `
		SELECT g.id, g.name, g.announcement, g.avatar, g.owner_id, g.all_muted, g.invite_confirmation, g.admin_only_edit_name, g.member_view_permission, g.created_at, g.updated_at, gm.remark
		FROM groups g
		JOIN group_members gm ON g.id = gm.group_id
		WHERE gm.user_id = $1 AND g.deleted_at IS NULL AND gm.approval_status = 'approved'
		ORDER BY g.created_at DESC
	`

	rows, err := r.DB.Query(query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []GroupWithRemark
	for rows.Next() {
		var group GroupWithRemark
		err := rows.Scan(
			&group.ID,
			&group.Name,
			&group.Announcement,
			&group.Avatar,
			&group.OwnerID,
			&group.AllMuted,
			&group.InviteConfirmation,
			&group.AdminOnlyEditName,
			&group.MemberViewPermission,
			&group.CreatedAt,
			&group.UpdatedAt,
			&group.Remark,
		)
		if err != nil {
			return nil, err
		}

		// 查询该群组的所有成员ID
		memberQuery := `SELECT user_id FROM group_members WHERE group_id = $1`
		memberRows, err := r.DB.Query(memberQuery, group.ID)
		if err != nil {
			return nil, err
		}

		var memberIDs []int
		for memberRows.Next() {
			var memberID int
			if err := memberRows.Scan(&memberID); err != nil {
				memberRows.Close()
				return nil, err
			}
			memberIDs = append(memberIDs, memberID)
		}
		memberRows.Close()

		group.MemberIDs = memberIDs
		groups = append(groups, group)
	}

	return groups, nil
}

// CreateGroupMessage 创建群组消息
func (r *GroupRepository) CreateGroupMessage(msg *CreateGroupMessageRequest, senderID int, senderName string, senderNickname *string, senderFullName *string, senderAvatar *string) (*GroupMessage, error) {
	// 确定消息类型
	messageType := msg.MessageType
	if messageType == "" {
		messageType = "text"
	}

	// 注意：sender_name 已经由调用方确定好（群昵称 > 全名 > 用户名的优先级）
	// sender_nickname 和 sender_full_name 单独保存，用于前端显示逻辑

	// 🔴 显式使用 UTC 时间，确保时区一致性
	query := `
		INSERT INTO group_messages (group_id, sender_id, sender_name, sender_nickname, sender_full_name, sender_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, mentioned_user_ids, mentions, voice_duration, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
		RETURNING id, group_id, sender_id, sender_name, sender_nickname, sender_full_name, sender_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, mentioned_user_ids, mentions, voice_duration, status, created_at
	`

	var fileName *string
	if msg.FileName != "" {
		fileName = &msg.FileName
	}

	var quotedMessageID *int
	if msg.QuotedMessageID > 0 {
		quotedMessageID = &msg.QuotedMessageID
	}

	var quotedMessageContent *string
	if msg.QuotedMessageContent != "" {
		quotedMessageContent = &msg.QuotedMessageContent
	}

	// 处理@相关字段
	var mentionedUserIDs *string
	if len(msg.MentionedUserIds) > 0 {
		// 将int数组转换为逗号分隔的字符串
		var ids string
		for i, id := range msg.MentionedUserIds {
			if i > 0 {
				ids += ","
			}
			ids += fmt.Sprintf("%d", id)
		}
		mentionedUserIDs = &ids
	}

	var mentions *string
	if msg.Mentions != "" {
		mentions = &msg.Mentions
	}

	// 处理语音时长
	var voiceDuration *int
	if msg.VoiceDuration > 0 {
		voiceDuration = &msg.VoiceDuration
	}

	message := &GroupMessage{}
	// 🔴 使用 UTC 时间
	now := time.Now().UTC()
	err := r.DB.QueryRow(query, msg.GroupID, senderID, senderName, senderNickname, senderFullName, senderAvatar, msg.Content, messageType, fileName, quotedMessageID, quotedMessageContent, mentionedUserIDs, mentions, voiceDuration, now).Scan(
		&message.ID,
		&message.GroupID,
		&message.SenderID,
		&message.SenderName,
		&message.SenderNickname,
		&message.SenderFullName,
		&message.SenderAvatar,
		&message.Content,
		&message.MessageType,
		&message.FileName,
		&message.QuotedMessageID,
		&message.QuotedMessageContent,
		&message.MentionedUserIDs,
		&message.Mentions,
		&message.VoiceDuration,
		&message.Status,
		&message.CreatedAt,
	)

	return message, err
}

// GetGroupMessages 获取群组消息列表
func (r *GroupRepository) GetGroupMessages(groupID int, limit int) ([]GroupMessage, error) {
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
			gm.voice_duration,
			gm.status, 
			gm.created_at
		FROM group_messages gm
		LEFT JOIN group_members gmem ON gmem.group_id = gm.group_id AND gmem.user_id = gm.sender_id
		WHERE gm.group_id = $1
		ORDER BY gm.created_at DESC
		LIMIT $2
	`

	rows, err := r.DB.Query(query, groupID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []GroupMessage
	for rows.Next() {
		var msg GroupMessage
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
			&msg.VoiceDuration,
			&msg.Status,
			&msg.CreatedAt,
		)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}

	// 反转消息顺序（从旧到新）
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}

	return messages, nil
}

// GetGroupMemberIDs 获取群组所有成员ID列表（仅返回已通过审核的成员）
func (r *GroupRepository) GetGroupMemberIDs(groupID int) ([]int, error) {
	query := `
		SELECT user_id
		FROM group_members
		WHERE group_id = $1 AND approval_status = 'approved'
	`

	rows, err := r.DB.Query(query, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var memberIDs []int
	for rows.Next() {
		var userID int
		if err := rows.Scan(&userID); err != nil {
			return nil, err
		}
		memberIDs = append(memberIDs, userID)
	}

	return memberIDs, nil
}

// MuteGroupMember 禁言群组成员
func (r *GroupRepository) MuteGroupMember(groupID, userID int) error {
	query := `
		UPDATE group_members
		SET is_muted = true
		WHERE group_id = $1 AND user_id = $2
	`

	result, err := r.DB.Exec(query, groupID, userID)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return sql.ErrNoRows
	}

	return nil
}

// UnmuteGroupMember 解除群组成员禁言
func (r *GroupRepository) UnmuteGroupMember(groupID, userID int) error {
	query := `
		UPDATE group_members
		SET is_muted = false
		WHERE group_id = $1 AND user_id = $2
	`

	result, err := r.DB.Exec(query, groupID, userID)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return sql.ErrNoRows
	}

	return nil
}

// MuteAllNormalMembers 禁言所有普通成员（不包括群主和管理员）
func (r *GroupRepository) MuteAllNormalMembers(groupID int) error {
	query := `
		UPDATE group_members
		SET is_muted = true
		WHERE group_id = $1 AND role = 'member'
	`

	_, err := r.DB.Exec(query, groupID)
	return err
}

// UnmuteAllNormalMembers 解除所有普通成员的禁言（不包括群主和管理员）
func (r *GroupRepository) UnmuteAllNormalMembers(groupID int) error {
	query := `
		UPDATE group_members
		SET is_muted = false
		WHERE group_id = $1 AND role = 'member'
	`

	_, err := r.DB.Exec(query, groupID)
	return err
}

// IsGroupMemberMuted 检查群组成员是否被禁言
func (r *GroupRepository) IsGroupMemberMuted(groupID, userID int) (bool, error) {
	query := `
		SELECT is_muted
		FROM group_members
		WHERE group_id = $1 AND user_id = $2
	`

	var isMuted bool
	err := r.DB.QueryRow(query, groupID, userID).Scan(&isMuted)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, fmt.Errorf("用户不是群组成员")
		}
		return false, err
	}

	return isMuted, nil
}

// IsGroupMember 检查用户是否是群组成员
func (r *GroupRepository) IsGroupMember(groupID, userID int) (bool, error) {
	query := `
		SELECT COUNT(*) > 0
		FROM group_members
		WHERE group_id = $1 AND user_id = $2
	`

	var isMember bool
	err := r.DB.QueryRow(query, groupID, userID).Scan(&isMember)
	return isMember, err
}

// TransferOwnership 转让群主权限
func (r *GroupRepository) TransferOwnership(groupID, newOwnerID int) error {
	// 使用事务确保数据一致性
	tx, err := r.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// 更新groups表的owner_id
	updateGroupQuery := `
		UPDATE groups
		SET owner_id = $1, updated_at = NOW()
		WHERE id = $2
	`
	_, err = tx.Exec(updateGroupQuery, newOwnerID, groupID)
	if err != nil {
		return err
	}

	// 更新group_members表，将新群主的角色设置为owner
	updateNewOwnerQuery := `
		UPDATE group_members
		SET role = 'owner'
		WHERE group_id = $1 AND user_id = $2
	`
	_, err = tx.Exec(updateNewOwnerQuery, groupID, newOwnerID)
	if err != nil {
		return err
	}

	// 更新原群主的角色为member
	updateOldOwnerQuery := `
		UPDATE group_members
		SET role = 'member'
		WHERE group_id = $1 AND role = 'owner' AND user_id != $2
	`
	_, err = tx.Exec(updateOldOwnerQuery, groupID, newOwnerID)
	if err != nil {
		return err
	}

	return tx.Commit()
}

// SetGroupAdmins 设置群管理员
func (r *GroupRepository) SetGroupAdmins(groupID int, adminIDs []int) error {
	// 使用事务确保数据一致性
	tx, err := r.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// 首先，将该群组所有非群主成员的role从admin改为member
	resetQuery := `
		UPDATE group_members
		SET role = 'member'
		WHERE group_id = $1 AND role = 'admin'
	`
	_, err = tx.Exec(resetQuery, groupID)
	if err != nil {
		return err
	}

	// 如果有新的管理员，将这些成员的role设置为admin
	if len(adminIDs) > 0 {
		for _, adminID := range adminIDs {
			updateQuery := `
				UPDATE group_members
				SET role = 'admin'
				WHERE group_id = $1 AND user_id = $2 AND role != 'owner'
			`
			_, err = tx.Exec(updateQuery, groupID, adminID)
			if err != nil {
				return err
			}
		}
	}

	return tx.Commit()
}

// GetGroupAdminsAndOwner 获取群组的群主和管理员ID列表
func (r *GroupRepository) GetGroupAdminsAndOwner(groupID int) ([]int, error) {
	query := `
		SELECT user_id
		FROM group_members
		WHERE group_id = $1 AND (role = 'owner' OR role = 'admin') AND approval_status = 'approved'
	`

	rows, err := r.DB.Query(query, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var adminIDs []int
	for rows.Next() {
		var userID int
		if err := rows.Scan(&userID); err != nil {
			return nil, err
		}
		adminIDs = append(adminIDs, userID)
	}

	return adminIDs, nil
}

// UpdateGroupInviteConfirmation 更新群组邀请确认状态
func (r *GroupRepository) UpdateGroupInviteConfirmation(groupID int, inviteConfirmation bool) error {
	query := `
		UPDATE groups
		SET invite_confirmation = $1,
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, inviteConfirmation, groupID)
	return err
}

// UpdateGroupAdminOnlyEditName 更新群组"仅管理员可修改群名称"状态
func (r *GroupRepository) UpdateGroupAdminOnlyEditName(groupID int, adminOnlyEditName bool) error {
	query := `
		UPDATE groups
		SET admin_only_edit_name = $1,
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, adminOnlyEditName, groupID)
	return err
}

// UpdateGroupMemberViewPermission 更新群组"群成员查看权限"状态
func (r *GroupRepository) UpdateGroupMemberViewPermission(groupID int, memberViewPermission bool) error {
	query := `
		UPDATE groups
		SET member_view_permission = $1,
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = $2
	`

	_, err := r.DB.Exec(query, memberViewPermission, groupID)
	return err
}

// ApproveGroupMember 通过群成员审核
func (r *GroupRepository) ApproveGroupMember(groupID, userID int) error {
	query := `
		UPDATE group_members
		SET approval_status = 'approved'
		WHERE group_id = $1 AND user_id = $2 AND approval_status = 'pending'
	`

	result, err := r.DB.Exec(query, groupID, userID)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return sql.ErrNoRows
	}

	return nil
}

// RejectGroupMember 拒绝群成员审核
func (r *GroupRepository) RejectGroupMember(groupID, userID int) error {
	query := `
		DELETE FROM group_members
		WHERE group_id = $1 AND user_id = $2 AND approval_status = 'pending'
	`

	result, err := r.DB.Exec(query, groupID, userID)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return sql.ErrNoRows
	}

	return nil
}
