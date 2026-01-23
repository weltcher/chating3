/**
 * 消息压力测试脚本
 * 
 * 功能：前250个用户(test1001-test1250)发送消息给后250个用户(test1251-test1500)
 * 然后隔1秒，后250个用户再发消息给前250个用户，循环往复
 * 
 * 使用方法:
 *   cd admin
 *   npm install ws
 *   npx ts-node scripts/message_stress_test.ts
 * 
 * 环境变量:
 *   SERVER_URL - 服务器地址 (默认: http://localhost:8180)
 *   WS_URL - WebSocket地址 (默认: ws://localhost:8180)
 */

import WebSocket from 'ws';

// 配置
const SERVER_URL = process.env.SERVER_URL || 'http://localhost:8180';
const WS_URL = process.env.WS_URL || 'ws://localhost:8180';
const PASSWORD = 'wq123123';
const START_INDEX = 1001;
const MID_INDEX = 1250;
const END_INDEX = 1500;
const MESSAGE_INTERVAL = 1000; // 1秒

interface UserConnection {
  userId: number;
  username: string;
  token: string;
  ws: WebSocket | null;
}

// 存储所有用户连接
const firstGroupUsers: UserConnection[] = []; // test1001 - test1250
const secondGroupUsers: UserConnection[] = []; // test1251 - test1500

// 登录用户获取token
async function loginUser(username: string, password: string): Promise<{ token: string; userId: number } | null> {
  try {
    const response = await fetch(`${SERVER_URL}/api/auth/login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ username, password }),
    });

    if (!response.ok) {
      const error = await response.text();
      console.error(`登录失败 ${username}: ${error}`);
      return null;
    }

    const data = await response.json();
    return {
      token: data.token,
      userId: data.user.id,
    };
  } catch (error) {
    console.error(`登录异常 ${username}:`, error);
    return null;
  }
}

// 建立WebSocket连接
function connectWebSocket(user: UserConnection): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_URL}/ws?token=${user.token}`);

    ws.on('open', () => {
      console.log(`✅ WebSocket连接成功: ${user.username}`);
      user.ws = ws;
      resolve();
    });

    ws.on('message', (_data: WebSocket.RawData) => {
      // 可以在这里处理接收到的消息
      // const msg = JSON.parse(_data.toString());
      // console.log(`📩 ${user.username} 收到消息:`, msg.type);
    });

    ws.on('error', (error: Error) => {
      console.error(`❌ WebSocket错误 ${user.username}:`, error.message);
      reject(error);
    });

    ws.on('close', () => {
      console.log(`🔌 WebSocket断开: ${user.username}`);
      user.ws = null;
    });

    // 设置超时
    setTimeout(() => {
      if (!user.ws) {
        reject(new Error(`连接超时: ${user.username}`));
      }
    }, 10000);
  });
}

// 发送私聊消息
function sendMessage(sender: UserConnection, receiverId: number, content: string): boolean {
  if (!sender.ws || sender.ws.readyState !== WebSocket.OPEN) {
    console.error(`❌ 无法发送消息: ${sender.username} 未连接`);
    return false;
  }

  const message = {
    type: 'message',
    data: {
      receiver_id: receiverId,
      content: content,
      message_type: 'text',
    },
  };

  sender.ws.send(JSON.stringify(message));
  return true;
}

// 初始化所有用户连接
async function initializeUsers(): Promise<boolean> {
  console.log('🚀 开始初始化用户连接...');
  console.log(`前250个用户: test${START_INDEX} - test${MID_INDEX}`);
  console.log(`后250个用户: test${MID_INDEX + 1} - test${END_INDEX}`);

  // 批量登录用户
  const batchSize = 50;
  
  // 登录前250个用户
  console.log('\n📝 登录前250个用户...');
  for (let i = START_INDEX; i <= MID_INDEX; i += batchSize) {
    const batchEnd = Math.min(i + batchSize - 1, MID_INDEX);
    const loginPromises: Promise<void>[] = [];

    for (let j = i; j <= batchEnd; j++) {
      const username = `test${j}`;
      loginPromises.push(
        loginUser(username, PASSWORD).then((result) => {
          if (result) {
            firstGroupUsers.push({
              userId: result.userId,
              username,
              token: result.token,
              ws: null,
            });
          }
        })
      );
    }

    await Promise.all(loginPromises);
    console.log(`  已登录: ${i} - ${batchEnd} (${firstGroupUsers.length}/${MID_INDEX - START_INDEX + 1})`);
  }

  // 登录后250个用户
  console.log('\n📝 登录后250个用户...');
  for (let i = MID_INDEX + 1; i <= END_INDEX; i += batchSize) {
    const batchEnd = Math.min(i + batchSize - 1, END_INDEX);
    const loginPromises: Promise<void>[] = [];

    for (let j = i; j <= batchEnd; j++) {
      const username = `test${j}`;
      loginPromises.push(
        loginUser(username, PASSWORD).then((result) => {
          if (result) {
            secondGroupUsers.push({
              userId: result.userId,
              username,
              token: result.token,
              ws: null,
            });
          }
        })
      );
    }

    await Promise.all(loginPromises);
    console.log(`  已登录: ${i} - ${batchEnd} (${secondGroupUsers.length}/${END_INDEX - MID_INDEX})`);
  }

  console.log(`\n✅ 登录完成: 前组 ${firstGroupUsers.length} 人, 后组 ${secondGroupUsers.length} 人`);

  if (firstGroupUsers.length === 0 || secondGroupUsers.length === 0) {
    console.error('❌ 没有足够的用户登录成功');
    return false;
  }

  // 建立WebSocket连接
  console.log('\n🔌 建立WebSocket连接...');
  
  // 连接前250个用户
  console.log('连接前250个用户...');
  for (let i = 0; i < firstGroupUsers.length; i += batchSize) {
    const batch = firstGroupUsers.slice(i, i + batchSize);
    await Promise.allSettled(batch.map((user) => connectWebSocket(user)));
    console.log(`  已连接: ${i + batch.length}/${firstGroupUsers.length}`);
    await sleep(500); // 避免连接过快
  }

  // 连接后250个用户
  console.log('连接后250个用户...');
  for (let i = 0; i < secondGroupUsers.length; i += batchSize) {
    const batch = secondGroupUsers.slice(i, i + batchSize);
    await Promise.allSettled(batch.map((user) => connectWebSocket(user)));
    console.log(`  已连接: ${i + batch.length}/${secondGroupUsers.length}`);
    await sleep(500);
  }

  const connectedFirst = firstGroupUsers.filter((u) => u.ws !== null).length;
  const connectedSecond = secondGroupUsers.filter((u) => u.ws !== null).length;
  console.log(`\n✅ WebSocket连接完成: 前组 ${connectedFirst} 人, 后组 ${connectedSecond} 人`);

  return connectedFirst > 0 && connectedSecond > 0;
}

// 睡眠函数
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// 前组发送消息给后组
function firstGroupSendToSecond(roundNumber: number): number {
  let sentCount = 0;
  const timestamp = new Date().toLocaleTimeString();

  for (let i = 0; i < Math.min(firstGroupUsers.length, secondGroupUsers.length); i++) {
    const sender = firstGroupUsers[i];
    const receiver = secondGroupUsers[i];

    if (sender.ws && receiver) {
      const content = `[第${roundNumber}轮] 你好！来自 ${sender.username} 的消息 - ${timestamp}`;
      if (sendMessage(sender, receiver.userId, content)) {
        sentCount++;
      }
    }
  }

  return sentCount;
}

// 后组发送消息给前组
function secondGroupSendToFirst(roundNumber: number): number {
  let sentCount = 0;
  const timestamp = new Date().toLocaleTimeString();

  for (let i = 0; i < Math.min(firstGroupUsers.length, secondGroupUsers.length); i++) {
    const sender = secondGroupUsers[i];
    const receiver = firstGroupUsers[i];

    if (sender.ws && receiver) {
      const content = `[第${roundNumber}轮] 回复！来自 ${sender.username} 的消息 - ${timestamp}`;
      if (sendMessage(sender, receiver.userId, content)) {
        sentCount++;
      }
    }
  }

  return sentCount;
}

// 主循环
async function runMessageLoop(): Promise<void> {
  console.log('\n🔄 开始消息循环...');
  console.log('按 Ctrl+C 停止\n');

  let roundNumber = 1;
  let totalMessagesSent = 0;

  while (true) {
    // 前组发送给后组
    const sent1 = firstGroupSendToSecond(roundNumber);
    totalMessagesSent += sent1;
    console.log(`📤 第${roundNumber}轮 - 前组→后组: 发送 ${sent1} 条消息 (总计: ${totalMessagesSent})`);

    await sleep(MESSAGE_INTERVAL);

    // 后组发送给前组
    const sent2 = secondGroupSendToFirst(roundNumber);
    totalMessagesSent += sent2;
    console.log(`📤 第${roundNumber}轮 - 后组→前组: 发送 ${sent2} 条消息 (总计: ${totalMessagesSent})`);

    await sleep(MESSAGE_INTERVAL);

    roundNumber++;
  }
}

// 清理函数
function cleanup(): void {
  console.log('\n🧹 清理连接...');
  
  for (const user of [...firstGroupUsers, ...secondGroupUsers]) {
    if (user.ws) {
      user.ws.close();
    }
  }

  console.log('✅ 清理完成');
  process.exit(0);
}

// 主函数
async function main(): Promise<void> {
  console.log('========================================');
  console.log('       消息压力测试脚本');
  console.log('========================================');
  console.log(`服务器地址: ${SERVER_URL}`);
  console.log(`WebSocket地址: ${WS_URL}`);
  console.log(`密码: ${PASSWORD}`);
  console.log('========================================\n');

  // 注册退出处理
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  // 初始化用户
  const success = await initializeUsers();
  if (!success) {
    console.error('❌ 初始化失败，退出');
    process.exit(1);
  }

  // 开始消息循环
  await runMessageLoop();
}

// 运行
main().catch((error) => {
  console.error('❌ 程序异常:', error);
  cleanup();
});
