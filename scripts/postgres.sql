psql -U postgres
CREATE USER youdu_user WITH PASSWORD ''
REVOKE CONNECT ON DATABASE youdu_db FROM PUBLIC;
GRANT CONNECT ON DATABASE youdu_db TO youdu_user;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO youdu_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO youdu_user;

# 修改控制权限
C:\Program Files\PostgreSQL\<version>\data\pg_hba.conf
/etc/postgresql/<version>/main/pg_hba.conf
# 允许 youdu_user 访问 youdu_db（本地）
host    youdu_db        youdu_user      127.0.0.1/32            md5
host    youdu_db        youdu_user      ::1/128                 md5
# 拒绝其他用户访问 youdu_db
host    youdu_db        all             0.0.0.0/0               reject
host    all             postgres        127.0.0.1/32            reject

# Linux
sudo systemctl restart postgresql
# Windows
net stop postgresql-x64-15
net start postgresql-x64-15


# 加强用户密码强度
ALTER USER youdu_user WITH PASSWORD '';
[System.Environment]::SetEnvironmentVariable('PASSWORD2', 'C:\go\workspace', 'User')
export PASSWORD2=''


# 备份和恢复
psql -U postgres -h 127.0.0.1 -p 5432
CREATE DATABASE youdu_db  ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8'  LC_CTYPE='en_US.UTF-8' TEMPLATE template1;

pg_dump -U postgres -h 127.0.0.1 -p 5432 -f init.sql youdu_db
psql -U postgres -h 127.0.0.1 -p 5432 -d youdu_db -f ./server/db/init.sql

go安装
https://go.dev/dl/go1.24.9.linux-amd64.tar.gz

postgres安装
# 更新系统
sudo apt update -y
sudo apt install -y wget gnupg2 ca-certificates lsb-release
# 添加官方 PostgreSQL 仓库
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
# 导入官方 GPG key（防止伪造包）
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
# 更新并安装
sudo apt update
sudo apt install -y postgresql postgresql-contrib

安装node和npm
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# 导入变量
export PASSWORD2=''

# 搭建turn服务器
sudo apt install coturn -y
sudo systemctl enable coturn
sudo systemctl start coturn
sudo cp /etc/turnserver.conf /etc/turnserver.conf.bak
sudo vim /etc/turnserver.conf
# 配置改为：
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=<你的公网IP或私网IP>
external-ip=<你的公网IP>
realm=<your-domain.com>
fingerprint
lt-cred-mech
user=<turnuser>:<turnpassword>
min-port=10000
max-port=20000
log-file=/var/log/turnserver/turnserver.log
verbose
# 开启防火墙
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 5349/udp
sudo ufw allow 10000:20000/udp
sudo ufw reload
# 确认状态
sudo ufw status verbose
# 重启
sudo systemctl restart coturn
sudo systemctl status coturn
# 测试turn服务器
nc -vz 31.57.65.81 3478