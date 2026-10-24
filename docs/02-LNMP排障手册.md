# LNMP 排障手册

> 排障顺序固定为：**现象 → 确认影响面 → 看日志 → 定位到层 → 处置 → 复盘**。
> 不要在没看日志的情况下重启服务——重启只会让现场消失。

## 0. 通用手法

```bash
# 1) 谁在监听、连了多少
ss -lntp
ss -s

# 2) 服务状态与最近日志
systemctl status nginx php-fpm mysqld --no-pager
journalctl -u nginx -n 100 --no-pager
journalctl -u php-fpm --since "10 min ago" --no-pager

# 3) 系统层
uptime                 # 负载
free -h                # 内存
df -hT                 # 磁盘
dmesg -T | tail -50    # OOM / 硬件错误
```

一条命令快速判断"是哪一层的问题"：

```bash
curl -o /dev/null -s -w 'code=%{http_code} dns=%{time_namelookup} conn=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' http://demo.example.com/
```

- `ttfb` 大而 `conn` 小 → 后端（PHP/MySQL）慢，不是网络。
- `conn` 大 → 网络/防火墙/半连接队列问题。
- `code=000` → 连接被拒或超时。

## 1. 502 Bad Gateway

**含义**：Nginx 作为反向代理，连不上或读不到上游（PHP-FPM）的合法响应。

### 1.1 定位路径

```bash
# ① 上游活着吗
ss -lntp | grep 9000
systemctl status php-fpm

# ② Nginx 的错误日志说哪一句（关键）
tail -100 /var/log/nginx/demo.error.log
```

按日志里的原文分三类：

| 日志原文 | 根因 | 处置 |
| --- | --- | --- |
| `connect() failed (111: Connection refused)` | php-fpm 没起 / 端口不对 / 只听 127.0.0.1 而 Nginx 连的是 eth0 IP | 看 `listen =`；`ss -lntp` 对比地址 |
| `connect() to unix:/run/php-fpm/www.sock failed (13: Permission denied)` | socket 属主/权限不对，nginx 用户进不去 | `ls -l /run/php-fpm/`，`user/group` 与 `listen.owner/group/mode` 对齐 |
| `upstream prematurely closed connection while reading response header` | PHP 进程被杀死（OOM）或 `request_terminate_timeout` 到点被杀 | `dmesg -T \| grep -i oom`；调 `pm.max_children` 或加大内存 |
| `no live upstreams while connecting to upstream` | `max_fails` 连续失败后上游被摘掉 | 先修上游，再 `nginx -s reload` 恢复 |

### 1.2 典型场景：OOM 把 php-fpm 打死

```bash
dmesg -T | grep -i -E 'oom|killed process'
# 期望看到：Out of memory: Killed process 12345 (php-fpm) ...

# 判断是不是 max_children 太大
ps --no-headers -o rss -C php-fpm | awk '{s+=$1} END {print s/1024 " MB"}'
grep -E 'pm.max_children|pm.max_requests' /etc/php-fpm.d/www.conf
```

处置：`pm.max_children` 按 `可用内存 × 0.8 / 单进程 RSS` 重算；`pm.max_requests = 500` 让进程定期回收，防内存泄漏累积。

### 1.3 典型场景：`SCRIPT_FILENAME` 没传对

现象：Nginx 日志 `Primary script unknown`，页面空白 502。
原因：`fastcgi_params` 里没有 `SCRIPT_FILENAME`（RHEL 系默认文件名是 `fastcgi_params`，Debian 是 `fastcgi.conf`，两者内容不同）。
处置：显式写 `fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;`。

## 2. 504 Gateway Timeout

**含义**：连上了上游，但等响应超时。**502 是"联系不上"，504 是"联系上了但太慢"**——这是两条完全不同的排查路线。

### 2.1 先分清是"PHP 慢"还是"MySQL 慢"

```bash
# 在 app-01 上直接打 PHP，绕过 Nginx
curl -o /dev/null -s -w 'ttfb=%{time_starttransfer}\n' 'http://127.0.0.1/index.php'

# 看 PHP 慢日志（www.conf 里开了 request_slowlog_timeout = 5s）
tail -50 /var/log/php-fpm/www-slow.log
```

`www-slow.log` 里会直接打出慢在哪一行 PHP 代码，通常指向一条 SQL。

```bash
# MySQL 慢查询
tail -50 /data/mysql/slow.log
mysql -uroot -p -e "SHOW FULL PROCESSLIST" | head -20
```

### 2.2 常见的三个原因

| 根因 | 证据 | 处置 |
| --- | --- | --- |
| SQL 没走索引，全表扫 | `EXPLAIN` 里 `type=ALL`、`rows` 很大 | 加索引；临时 `SET GLOBAL long_query_time=1` 抓慢查询 |
| 锁等待 | `SHOW ENGINE INNODB STATUS\G` 里 `TRANSACTIONS` 段有 `LOCK WAIT` | `SELECT * FROM information_schema.innodb_trx` 找到阻塞事务并 kill |
| 连接池打满 | `SHOW STATUS LIKE 'Threads_connected'` 接近 `max_connections` | 调 `max_connections`；查是否有连接未释放 |

```bash
# 一眼看出谁在跑长事务
mysql -uroot -p -e "SELECT id,user,host,db,command,time,state,LEFT(info,80) FROM information_schema.processlist WHERE time>5 ORDER BY time DESC;"
```

### 2.3 超时参数别乱调

`fastcgi_read_timeout 30s` + `request_terminate_timeout 30s` 要**同时**满足业务最慢接口，且 `request_terminate_timeout` 不能小于 `fastcgi_read_timeout`，否则 PHP 先被杀，Nginx 收到 502 而不是 504，日志会互相矛盾。

## 3. MySQL 主从异常

### 3.1 分类判断

```bash
mysql -uroot -p -e "SHOW REPLICA STATUS\G" | grep -E 'Replica_(IO|SQL)_Running|Seconds_Behind_Source|Last_(IO|SQL)_Error|Retrieved_Gtid_Set|Executed_Gtid_Set'
```

| 状态 | 含义 | 方向 |
| --- | --- | --- |
| IO=Yes SQL=Yes，延迟大 | 复制正常但追不上 | 从库性能/大事务/并行复制 |
| IO=Connecting | 连不上主库 | 网络、账号、防火墙 |
| IO=Yes SQL=No | 回放报错 | 数据冲突、表结构不一致 |
| IO=No SQL=Yes | IO 线程停了 | `Last_IO_Error` 看具体 |

### 3.2 IO 线程 Connecting

```bash
# 从库上验证网络与账号
mysql -h192.168.56.13 -urepl -p'Repl@2026' -e 'SELECT 1'
telnet 192.168.56.13 3306
```

- 报 `Access denied` → `repl` 用户的 host 白名单不匹配（`'repl'@'192.168.56.%'` 对不上就从库实际 IP 检查）。
- 报 `Can't connect` → 主库 3306 没对从库开放（firewalld rich rule）。

### 3.3 SQL 线程报错（最常见：主键冲突 1062）

```bash
# 看具体错
mysql -uroot -p -e "SHOW REPLICA STATUS\G" | grep Last_SQL_Error

# 传统位点复制可以跳过一条（GTID 模式下不要这么干）
STOP REPLICA; SET GLOBAL SQL_SLAVE_SKIP_COUNTER=1; START REPLICA;
```

GTID 模式正确做法：找到冲突的 GTID，`SET GTID_NEXT='...'; BEGIN; COMMIT; SET GTID_NEXT='AUTOMATIC';` 注入空事务，再 `START REPLICA`。

**根治**：从库 `read_only=ON` + `super_read_only=ON`，禁止任何人在从库写入。

### 3.4 延迟怎么优化

```bash
# 主库：是不是大事务/大批量 DML
mysql -uroot -p -e "SHOW BINARY LOGS;"
mysqlbinlog --base64-output=DECODE-ROWS -v /data/mysql/binlog/mysql-bin.000012 | head -50

# 从库：开并行复制（8.0 默认 LOGICAL_CLOCK）
[mysqld]
replica_parallel_workers=4
replica_parallel_type=LOGICAL_CLOCK
```

## 4. 磁盘写满

```bash
df -hT
du -sh /var/log/* /data/* 2>/dev/null | sort -h | tail
lsof +L1 | head          # 已删除但仍被进程占用的文件（空间没释放）
```

- `lsof +L1` 有输出 → 文件被删但句柄未释放：重启对应服务或 `> /proc/<pid>/fd/<n>` 清空。
- 日志没有轮转 → `/etc/logrotate.d/nginx` 检查 `rotate` 与 `daily`。
- **止血优先**：先删最老的 binlog（`PURGE BINARY LOGS BEFORE ...`）或归档日志，再恢复服务，最后做容量规划。

## 5. 站点访问慢（非 5xx）

```bash
# Nginx 层：按耗时排序访问日志
awk '{print $NF, $7}' /var/log/nginx/demo.access.log | sort -k1 -t= -nr | head -20

# 单请求分阶段
curl -o /dev/null -s -w '@DNS %{time_namelookup}\n@TCP %{time_connect}\n@TLS %{time_appconnect}\n@TTFB %{time_starttransfer}\n@TOTAL %{time_total}\n' https://demo.example.com/
```

| 阶段慢 | 可能原因 |
| --- | --- |
| DNS | 解析配置、`/etc/resolv.conf` |
| TCP | 网络质量、半连接队列溢出（`netstat -s \| grep -i listen`） |
| TLS | 证书链、会话复用未开 |
| TTFB | 后端（PHP/MySQL），回到第 2 节 |

## 6. 复盘模板

```markdown
## 故障：2026-05-xx 14:32 首页 502，持续 6 分钟
- 影响：官网首页不可用，约 200 次访问失败
- 定位：nginx error.log 报 upstream prematurely closed → dmesg 发现 OOM killed php-fpm
- 根因：pm.max_children=100 超出内存预算，压测时内存打满
- 处置：max_children 降到 50，加 2G swap，加 pm.max_requests=500
- 改进：加 Prometheus 内存告警（阈值 90%）、加 OOM 事件告警
```
