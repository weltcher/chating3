import { Pool } from 'pg';

console.log('DB Config:', {
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  database: process.env.DB_NAME,
  password: process.env.PASSWORD2 ? '***' : '(empty)',
});

export const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'postgres',
  password: process.env.PASSWORD2 || '',
  database: process.env.DB_NAME || 'youdu_db',
});

export const initDatabase = async () => {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS invite_codes (
      id SERIAL PRIMARY KEY,
      code VARCHAR(20) UNIQUE NOT NULL,
      status VARCHAR(20) DEFAULT 'unused',
      used_by_user_id INTEGER REFERENCES users(id),
      used_by_username VARCHAR(100),
      used_by_fullname VARCHAR(100),
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      used_at TIMESTAMP
    )
  `);
  console.log('Database initialized');
};
