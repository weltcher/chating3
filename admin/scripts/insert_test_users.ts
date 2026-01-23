/**
 * Script to insert 500 test users (test1001 - test1500) into PostgreSQL database
 * Password: wq123123
 * 
 * Usage: npx ts-node scripts/insert_test_users.ts
 */

import { Pool } from 'pg';
import bcrypt from 'bcryptjs';

// Database configuration
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'postgres',
  password: process.env.PASSWORD2 || 'postgres',
  database: process.env.DB_NAME || 'youdu_db',
});

const PASSWORD = 'wq123123';
const START_INDEX = 1001;
const END_INDEX = 1500;
const BATCH_SIZE = 50; // Insert in batches for better performance

async function insertTestUsers() {
  console.log('Starting to insert test users...');
  console.log(`Users: test${START_INDEX} to test${END_INDEX}`);
  console.log(`Total users to insert: ${END_INDEX - START_INDEX + 1}`);
  
  try {
    // Hash the password once (same for all users)
    const hashedPassword = await bcrypt.hash(PASSWORD, 10);
    console.log('Password hashed successfully');
    
    let insertedCount = 0;
    let skippedCount = 0;
    
    // Process in batches
    for (let batchStart = START_INDEX; batchStart <= END_INDEX; batchStart += BATCH_SIZE) {
      const batchEnd = Math.min(batchStart + BATCH_SIZE - 1, END_INDEX);
      const values: any[] = [];
      const placeholders: string[] = [];
      let paramIndex = 1;
      
      for (let i = batchStart; i <= batchEnd; i++) {
        const username = `test${i}`;
        const fullName = `测试用户${i}`;
        
        placeholders.push(`($${paramIndex}, $${paramIndex + 1}, $${paramIndex + 2}, 'offline')`);
        values.push(username, hashedPassword, fullName);
        paramIndex += 3;
      }
      
      const query = `
        INSERT INTO users (username, password, full_name, status)
        VALUES ${placeholders.join(', ')}
        ON CONFLICT (username) DO NOTHING
        RETURNING id
      `;
      
      try {
        const result = await pool.query(query, values);
        insertedCount += result.rowCount || 0;
        skippedCount += (batchEnd - batchStart + 1) - (result.rowCount || 0);
        
        console.log(`Batch ${batchStart}-${batchEnd}: Inserted ${result.rowCount} users`);
      } catch (err: any) {
        console.error(`Error inserting batch ${batchStart}-${batchEnd}:`, err.message);
      }
    }
    
    console.log('\n========== Summary ==========');
    console.log(`Total inserted: ${insertedCount}`);
    console.log(`Skipped (already exist): ${skippedCount}`);
    console.log('Done!');
    
  } catch (error) {
    console.error('Error:', error);
  } finally {
    await pool.end();
  }
}

// Run the script
insertTestUsers();
