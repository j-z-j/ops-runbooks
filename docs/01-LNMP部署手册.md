# LNMP 环境部署手册

> 目标：3 台全新 Rocky Linux 9 虚拟机 → 可访问的 PHP 站点 + MySQL 一主一从 + 每日备份。
> 全程约 90 分钟。每一步都有【校验】，校验不通过不要往下走。

## 1. 规划

| 主机 | IP | 角色 | 规格 |
| --- | --- | --- | --- |
| web-01 | 192.168.56.11 | Nginx 反向代理 / 静态资源 | 2C4G / 40G |
| app-01 | 192.168.56.12 | PHP-FPM 应用 | 2C4G / 40G |
| db-01 | 192.168.56.13 | MySQL 主库 | 2C4G / 40G + 数据盘 |
| db-02 | 192.168.56.14 | MySQL 从库 | 2C4G / 40G + 数据盘 |

端口约定：仅对外开放 `22 / 80 / 443`，MySQL 3306 只允许 app-01 访问（firewalld rich rule）。
时区统一 `Asia/Shanghai`，三台机器 chronyd 指向同一时间源。

> 说明：3 台业务机承载 LNMP，db-02 从库可复用 web-01 的 LVM 剩余空间单独建虚拟机（KVM 里再加一块 20G 盘）。

## 2. 系统初始化（三台都执行）

```bash
# 2.1 主机名与 hosts
hostnamectl set-hostname web-01          # 其余两台对应改名
cat >> /etc/hosts <<'EOF'
192.168.56.11 web-01
192.168.56.12 app-01
192.168.56.13 db-01
192.168.56.14 db-02
EOF

# 2.2 时区与时间同步
timedatectl set-timezone Asia/Shanghai
dnf install -y chrony && systemctl enable --now chronyd

# 2.3 基础工具
dnf install -y vim wget curl net-tools lsof sysstat tar unzip epel-release

# 2.4 关闭无用服务（降低攻击面）
systemctl disable --now firewalld 2>/dev/null || true   # 下一步单独配策略后再开
for s in postfix avahi-daemon cups bluetooth; do systemctl disable --now $s 2>/dev/null || true; done
```

【校验】

```bash
timedatectl | grep -E 'Time zone|synchronized'   # 期望：Asia/Shanghai / yes
chronyc sources -v | grep '^\^\*'                # 期望：有一个 * 的同步源
```

### 2.5 SSH 加固

```bash
# 本机生成密钥后下发（在跳板/自己电脑上执行）
ssh-keygen -t ed25519 -C "wangruiling@ops"
ssh-copy-id root@192.168.56.11

# 服务器端
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?GSSAPIAuthentication.*/GSSAPIAuthentication no/'      /etc/ssh/sshd_config
sshd -t && systemctl reload sshd
```

【校验】`ssh -o PreferredAuthentications=password root@192.168.56.11` 应被拒绝（Permission denied），密钥登录正常。

> 常见坑：先确认密钥能登，再关密码登录。顺序反了就锁死自己，只能走控制台。

### 2.6 firewalld 策略

```bash
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.56.12/32 port port=3306 protocol=tcp accept'
firewall-cmd --reload
```

【校验】`firewall-cmd --list-all` 中 `services` 只含 ssh/http/https；`rich rules` 有 3306 那条。

### 2.7 LVM 数据盘规划（db-01 / db-02）

```bash
pvcreate /dev/vdb
vgcreate vg_data /dev/vdb
lvcreate -L 20G -n lv_mysql vg_data
mkfs.xfs /dev/vg_data/lv_mysql
mkdir -p /data/mysql

# 开机自动挂载（用 UUID，不用设备名）
echo "UUID=$(blkid -s UUID -o value /dev/vg_data/lv_mysql) /data xfs defaults 0 0" >> /etc/fstab
mount -a && df -hT /data
```

**在线扩容（不卸载、不停库）**——这是 LVM 相对裸分区的关键价值：

```bash
# 盘从 20G 扩到 40G 后（KVM 里先热扩 vdb）
pvresize /dev/vdb
lvextend -L +20G /dev/vg_data/lv_mysql
xfs_growfs /data          # ext4 用 resize2fs /dev/vg_data/lv_mysql
df -hT /data              # 校验：容量变为 40G，MySQL 全程未停
```

【校验】扩容前后 `mysqladmin status` 均正常，`df -hT /data` 容量增加 20G。

## 3. 部署 Nginx（web-01）

```bash
dnf install -y nginx
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%F)
```

`/etc/nginx/conf.d/site.conf`：

```nginx
upstream php_backend {
    server 192.168.56.12:9000 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 80;
    server_name demo.example.com;
    root /data/www/demo;
    index index.php index.html;

    access_log /var/log/nginx/demo.access.log main;
    error_log  /var/log/nginx/demo.error.log warn;

    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 5;
    gzip_types text/plain text/css application/json application/javascript;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass php_backend;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 30s;
    }

    location ~* \.(css|js|png|jpg|gif|ico|woff2)$ {
        expires 7d;
        add_header Cache-Control "public";
    }

    location = /nginx-health { access_log off; return 200 "ok\n"; }
}
```

主配置里把工作进程和连接数调到位（`/etc/nginx/nginx.conf`）：

```nginx
worker_processes auto;
events { worker_connections 1024; }
http {
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;
    ...
}
```

```bash
nginx -t && systemctl enable --now nginx
```

【校验】
```bash
curl -I http://127.0.0.1/nginx-health        # 200
ss -lntp | grep :80                          # nginx master + worker
```

## 4. 部署 PHP-FPM（app-01）

```bash
dnf install -y php php-fpm php-mysqlnd php-gd php-mbstring php-opcache
cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.bak.$(date +%F)
```

`/etc/php-fpm.d/www.conf` 关键项：

```ini
user = nginx
group = nginx
listen = 0.0.0.0:9000
listen.allowed_clients = 192.168.56.11

pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500
request_terminate_timeout = 30s
slowlog = /var/log/php-fpm/www-slow.log
request_slowlog_timeout = 5s
```

```bash
systemctl enable --now php-fpm
```

【校验】
```bash
ss -lntp | grep :9000                 # php-fpm 在听
curl -I http://192.168.56.11/         # 通过 nginx 反代访问，200
tail -f /var/log/php-fpm/www-error.log # 无 Fatal
```

> `pm.max_children` 怎么定：`可用内存 / 单进程常驻内存`。单进程约 40 MB，4G 机器留 1G 给系统 → `3000/40 ≈ 75`，压测后再调到 50，避免内存被吃满触发 OOM。

## 5. 部署 MySQL 8.0 主从（db-01 / db-02）

### 5.1 安装（两台）

```bash
dnf install -y mysql-server
systemctl enable --now mysqld
mysql_secure_installation     # 设 root 密码、删匿名用户、禁 root 远程
```

### 5.2 主库配置（db-01）

`/etc/my.cnf.d/master.cnf`：

```ini
[mysqld]
server-id=1
log-bin=/data/mysql/binlog/mysql-bin
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_expire_logs_seconds=604800
innodb_buffer_pool_size=1G
max_connections=500
slow_query_log=ON
long_query_time=1
slow_query_log_file=/data/mysql/slow.log
datadir=/data/mysql
```

```bash
systemctl restart mysqld

mysql -uroot -p <<'SQL'
CREATE USER 'repl'@'192.168.56.%' IDENTIFIED WITH mysql_native_password BY 'Repl@2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.56.%';
CREATE USER 'app'@'192.168.56.12' IDENTIFIED BY 'App@2026';
GRANT SELECT,INSERT,UPDATE,DELETE ON demo.* TO 'app'@'192.168.56.12';
FLUSH PRIVILEGES;
SQL
```

### 5.3 从库配置（db-02）

`/etc/my.cnf.d/slave.cnf`：`server-id=2`、`read_only=ON`、`super_read_only=ON`，其余同主库（**不配 log-bin**）。

```bash
systemctl restart mysqld

# 用 GTID 方式建立复制，免记 binlog 文件名和位点
mysql -uroot -p <<'SQL'
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='192.168.56.13',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='Repl@2026',
  SOURCE_AUTO_POSITION=1,
  SOURCE_CONNECT_RETRY=10;
START REPLICA;
SQL
```

【校验】——两个 Yes，且延迟为 0：

```bash
mysql -uroot -p -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error'
# 期望：Replica_IO_Running: Yes / Replica_SQL_Running: Yes / Seconds_Behind_Source: 0
```

> 三个线程别记混：主库 1 个 **dump 线程**（`SHOW PROCESSLIST` 里的 Binlog Dump），从库 **IO 线程**（拉 binlog 写 relay log）+ **SQL 线程**（回放 relay log）。哪个不是 Yes，就去对应那一层找错。

### 5.4 读写分离

应用侧用两个连接串（写走 db-01，读走 db-02），或用 ProxySQL/MyCat。本实验用 PHP 配置区分：

```php
// config/db.php
$write = new PDO('mysql:host=192.168.56.13;dbname=demo;charset=utf8mb4', 'app', 'App@2026');
$read  = new PDO('mysql:host=192.168.56.14;dbname=demo;charset=utf8mb4', 'app', 'App@2026');
```

【校验】主库 `INSERT` 一条 → 从库 `SELECT` 能查到（注意 GTID 复制正常时延迟 < 1 s）。

## 6. 备份与恢复演练

`/usr/local/bin/backup_mysql.sh`（见 `scripts/backup_mysql.sh`）：

```bash
0 2 * * * /usr/local/bin/backup_mysql.sh >> /var/log/mysql-backup.log 2>&1
```

恢复演练（**每季度必须做一次，不做等于没备份**）：

```bash
# 1. 在测试库上还原
mysql -uroot -p -e "CREATE DATABASE demo_restore;"
time mysql -uroot -p demo_restore < /data/backup/mysql/demo-2026-05-20.sql

# 2. 校验行数一致
mysql -uroot -p -e "SELECT COUNT(*) FROM demo.orders; SELECT COUNT(*) FROM demo_restore.orders;"
```

实测：全量库 1.2 GB，备份耗时约 2 分 10 秒，还原耗时 8 分钟（含索引重建），行数校验一致。

## 7. 上线前检查清单

- [ ] 三台 `timedatectl` 都是 `Asia/Shanghai` 且 NTP 已同步
- [ ] `firewall-cmd --list-all` 只开 22/80/443（+ 3306 限定源 IP）
- [ ] SSH 已禁密码登录，密钥可登
- [ ] `nginx -t` / `php-fpm -t` 通过
- [ ] 主从两个 `Yes`，`Seconds_Behind_Source < 1`
- [ ] 备份脚本当天有产物，且做过一次还原
- [ ] `curl -I` 首页 200，TTFB 正常

## 8. 常见问题

| 现象 | 先查什么 |
| --- | --- |
| 502 Bad Gateway | `ss -lntp \| grep 9000` → php-fpm 是否活着；`/var/log/php-fpm/www-error.log` |
| 504 Gateway Timeout | `fastcgi_read_timeout` / `request_terminate_timeout` / PHP 里慢查询 |
| 502 且日志写 `upstream prematurely closed` | PHP 进程被 OOM killer 杀 → `dmesg -T \| grep -i oom` |
| 403 Forbidden | `nginx.conf` 的 `index`、目录权限、SELinux `getenforce` |
| 主从 `IO_Running: Connecting` | 3306 防火墙、`repl` 用户 host 是否匹配、密码 |
| 主从 `SQL_Running: No` | `Last_SQL_Error`，常见是主从数据不一致导致主键冲突 |

详细定位步骤见 [02-LNMP排障手册.md](02-LNMP排障手册.md)。
