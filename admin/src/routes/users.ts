import { Router, Response } from 'express';
import bcrypt from 'bcryptjs';
import { pool } from '../config/database';
import { AuthRequest, authMiddleware } from '../middleware/auth';

const router = Router();
router.use(authMiddleware);

// 用户列表（分页）
router.get('/', async (req: AuthRequest, res: Response) => {
  const page = parseInt(req.query.page as string) || 1;
  const limit = parseInt(req.query.limit as string) || 20;
  const search = req.query.search as string || '';
  const status = req.query.status as string;
  const offset = (page - 1) * limit;

  let whereClause = 'WHERE 1=1';
  const params: any[] = [];
  let paramIndex = 1;

  if (search) {
    whereClause += ` AND (username ILIKE $${paramIndex} OR full_name ILIKE $${paramIndex} OR phone ILIKE $${paramIndex})`;
    params.push(`%${search}%`);
    paramIndex++;
  }

  if (status) {
    whereClause += ` AND status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  const countResult = await pool.query(`SELECT COUNT(*) FROM users ${whereClause}`, params);
  const total = parseInt(countResult.rows[0].count);

  params.push(limit, offset);
  const result = await pool.query(
    `SELECT id, username, phone, email, avatar, full_name, gender, status, department, position, created_at, updated_at
     FROM users ${whereClause} ORDER BY id DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`,
    params
  );

  res.json({ data: result.rows, total, page, limit, totalPages: Math.ceil(total / limit) });
});

// 用户详情
router.get('/:id', async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  const result = await pool.query(
    `SELECT id, username, phone, email, avatar, full_name, gender, work_signature, status, 
            landline, short_number, department, position, region, invite_code, invited_by_code, created_at, updated_at
     FROM users WHERE id = $1`,
    [id]
  );
  if (result.rows.length === 0) {
    return res.status(404).json({ error: '用户不存在' });
  }
  res.json(result.rows[0]);
});

// 新增用户
router.post('/', async (req: AuthRequest, res: Response) => {
  const { username, password, full_name, phone, email, gender, department, position } = req.body;
  
  if (!username || !password || !full_name) {
    return res.status(400).json({ error: '用户名、密码和姓名为必填项' });
  }

  const hashedPassword = await bcrypt.hash(password, 10);
  
  try {
    const result = await pool.query(
      `INSERT INTO users (username, password, full_name, phone, email, gender, department, position, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'offline') RETURNING id`,
      [username, hashedPassword, full_name, phone || null, email || null, gender || null, department || null, position || null]
    );
    res.json({ id: result.rows[0].id, message: '用户创建成功' });
  } catch (err: any) {
    if (err.code === '23505') {
      return res.status(400).json({ error: '用户名已存在' });
    }
    throw err;
  }
});

// 更新用户
router.put('/:id', async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  const { full_name, phone, email, gender, department, position, region } = req.body;

  await pool.query(
    `UPDATE users SET full_name = COALESCE($1, full_name), phone = COALESCE($2, phone), 
     email = COALESCE($3, email), gender = COALESCE($4, gender), department = COALESCE($5, department),
     position = COALESCE($6, position), region = COALESCE($7, region), updated_at = NOW()
     WHERE id = $8`,
    [full_name, phone, email, gender, department, position, region, id]
  );
  res.json({ message: '用户更新成功' });
});

// 删除用户
router.delete('/:id', async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  await pool.query('DELETE FROM users WHERE id = $1', [id]);
  res.json({ message: '用户删除成功' });
});

// 禁用/启用用户
router.patch('/:id/status', async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  const { status } = req.body;
  
  if (!['disabled', 'offline', 'online'].includes(status)) {
    return res.status(400).json({ error: '无效的状态值' });
  }

  await pool.query('UPDATE users SET status = $1, updated_at = NOW() WHERE id = $2', [status, id]);

  // 如果是禁用用户，通知 server 强制该用户下线
  if (status === 'disabled') {
    try {
      const serverUrl = process.env.SERVER_API_URL || 'http://localhost:8180';
      await fetch(`${serverUrl}/api/admin/force-logout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_id: parseInt(id), reason: '您的账号已被管理员禁用' }),
      });
    } catch (err) {
      console.error('通知server强制下线失败:', err);
    }
  }

  res.json({ message: status === 'disabled' ? '用户已禁用' : '用户已启用' });
});

export default router;
