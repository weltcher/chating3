import './env'; // 必须第一个导入

import express from 'express';
import cors from 'cors';
import { initDatabase } from './config/database';
import authRoutes from './routes/auth';
import userRoutes from './routes/users';
import messageRoutes from './routes/messages';
import inviteCodeRoutes from './routes/inviteCodes';

const app = express();
const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

// 路由
app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/messages', messageRoutes);
app.use('/api/invite-codes', inviteCodeRoutes);

// 静态文件（前端）
app.use(express.static('public'));

// 错误处理
app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
  console.error(err);
  res.status(500).json({ error: '服务器内部错误' });
});

const start = async () => {
  await initDatabase();
  app.listen(PORT, () => {
    console.log(`Admin server running on http://localhost:${PORT}`);
  });
};

start();
