import { Router, Request, Response } from 'express';
import jwt from 'jsonwebtoken';

const router = Router();

// 登录
router.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;
  
  const adminUsername = process.env.ADMIN_USERNAME || 'admin';
  const adminPassword = process.env.ADMIN_PASSWORD || 'youdu123';

  if (username === adminUsername && password === adminPassword) {
    const token = jwt.sign(
      { username },
      process.env.JWT_SECRET || 'secret',
      { expiresIn: '24h' }
    );
    return res.json({ token, username });
  }

  return res.status(401).json({ error: '用户名或密码错误' });
});

export default router;
