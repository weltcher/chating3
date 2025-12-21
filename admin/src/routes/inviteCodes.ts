import { Router, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { pool } from '../config/database';
import { AuthRequest, authMiddleware } from '../middleware/auth';

const router = Router();
router.use(authMiddleware);

// 生成邀请码
const generateCode = (): string => {
  return uuidv4().replace(/-/g, '').substring(0, 8).toUpperCase();
};

// 批量生成邀请码
router.post('/generate', async (req: AuthRequest, res: Response) => {
  const count = Math.min(parseInt(req.body.count) || 10, 1000);
  const codes: string[] = [];
  const existingCodes = new Set<string>();

  // 获取已存在的邀请码
  const existing = await pool.query('SELECT code FROM invite_codes');
  existing.rows.forEach((row: { code: string }) => existingCodes.add(row.code));

  // 生成不重复的邀请码
  while (codes.length < count) {
    const code = generateCode();
    if (!existingCodes.has(code) && !codes.includes(code)) {
      codes.push(code);
    }
  }

  // 批量插入
  const values = codes.map((code, i) => `($${i + 1})`).join(',');
  await pool.query(`INSERT INTO invite_codes (code) VALUES ${values}`, codes);

  res.json({ message: `成功生成 ${count} 个邀请码`, codes });
});

// 邀请码列表
router.get('/', async (req: AuthRequest, res: Response) => {
  const page = parseInt(req.query.page as string) || 1;
  const limit = parseInt(req.query.limit as string) || 20;
  const status = req.query.status as string;
  const offset = (page - 1) * limit;

  let whereClause = 'WHERE 1=1';
  const params: any[] = [];
  let paramIndex = 1;

  if (status) {
    whereClause += ` AND status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  const countResult = await pool.query(`SELECT COUNT(*) FROM invite_codes ${whereClause}`, params);
  const total = parseInt(countResult.rows[0].count);

  params.push(limit, offset);
  const result = await pool.query(
    `SELECT id, code, status, used_by_user_id, used_by_username, used_by_fullname, created_at, used_at
     FROM invite_codes ${whereClause} ORDER BY created_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`,
    params
  );

  res.json({ data: result.rows, total, page, limit, totalPages: Math.ceil(total / limit) });
});

// 删除邀请码
router.delete('/:id', async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  await pool.query('DELETE FROM invite_codes WHERE id = $1', [id]);
  res.json({ message: '邀请码已删除' });
});

// 统计
router.get('/stats', async (req: AuthRequest, res: Response) => {
  const result = await pool.query(`
    SELECT 
      COUNT(*) as total,
      COUNT(*) FILTER (WHERE status = 'unused') as unused,
      COUNT(*) FILTER (WHERE status = 'used') as used
    FROM invite_codes
  `);
  res.json(result.rows[0]);
});

export default router;
