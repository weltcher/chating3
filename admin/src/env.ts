import dotenv from 'dotenv';
import path from 'path';

// 先保存系统环境变量 PASSWORD2
const systemPassword2 = process.env.PASSWORD2;

const envPath = path.resolve(process.cwd(), '.env');
dotenv.config({ path: envPath, override: true });

// 恢复系统环境变量 PASSWORD2（不被 .env 覆盖）
if (systemPassword2) {
  process.env.PASSWORD2 = systemPassword2;
}

console.log('ENV loaded, PASSWORD2:', process.env.PASSWORD2 ? '***' : '(empty)');
