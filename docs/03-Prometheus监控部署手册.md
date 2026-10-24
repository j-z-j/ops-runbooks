# Prometheus + Grafana + Alertmanager 监控体系部署手册

> 目标：4 台主机 + 3 类中间件纳入监控，30 条分级告警规则，故障 90 秒内邮件到手。
> 关键设计：**采集（exporter）→ 存储/计算（Prometheus）→ 路由/降噪（Alertmanager）→ 展示（Grafana）** 四层解耦，任何一层挂了其它层仍可工作。

## 1. 架构与选型

```
  ┌──────────┐   pull /metrics (15s)   ┌────────────┐   alert    ┌──────────────┐   email   ┌───────┐
  │ exporters│ ──────────────────────► │ Prometheus │ ─────────► │ Alertmanager │ ────────► │ 邮箱  │
  │ node/mysql│                        │ 存储+规则   │            │ 分组/抑制/静默│           └───────┘
  │ blackbox │ ◄── 探活 HTTP/SSL ──────└─────┬──────┘            └──────────────┘
  └──────────┘                                │ PromQL
                                        ┌─────▼─────┐
                                        │  Grafana  │  大盘 + 告警面板
                                        └───────────┘
```

| 选择 | 理由 |
| --- | --- |
| Prometheus 拉模式 | 目标列表在自己手里，故障时不会因为"上报丢了"而静默；`up` 指标天然能发现实例掉线 |
| file_sd_configs | 目标写 YAML 文件，改完自动热加载，不用重启 Prometheus |
| Alertmanager 分级路由 | P0 立刻发、P1/P2 合并发，避免半夜被磁盘 86% 吵醒 |
| 抑制规则 | 主机 down 时抑制它身上所有 P1/P2，防止一次宕机刷 20 条告警 |

## 2. 采集层

### 2.1 node_exporter（4 台主机）

```bash
# 统一用 systemd 托管，避免手工 nohup 重启后丢失
useradd --no-create-home --shell /sbin/nologin node_exporter

tar -xzf node_exporter-1.8.2.linux-amd64.tar.gz -C /opt
mv /opt/node_exporter-1.8.2.linux-amd64 /opt/node_exporter

cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/opt/node_exporter/node_exporter \
  --web.listen-address=:9100 \
  --collector.systemd \
  --collector.processes \
  --no-collector.wifi
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now node_exporter
```

【校验】

```bash
curl -s http://127.0.0.1:9100/metrics | grep -E '^node_load1|^node_memory_MemAvailable_bytes'
ss -lntp | grep 9100
```

### 2.2 mysqld_exporter（db-01）

```bash
# 建监控专用账号（最小权限，别用 root）
mysql -uroot -p <<'SQL'
CREATE USER 'exporter'@'localhost' IDENTIFIED BY 'Exp@2026' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
SQL

cat > /etc/.mysqld_exporter.cnf <<'EOF'
[client]
user=exporter
password=Exp@2026
host=127.0.0.1
EOF
chmod 600 /etc/.mysqld_exporter.cnf

/opt/mysqld_exporter/mysqld_exporter --config.my-cnf=/etc/.mysqld_exporter.cnf --web.listen-address=:9104
```

【校验】`curl -s localhost:9104/metrics | grep mysql_up` → `mysql_up 1`。

### 2.3 blackbox_exporter（业务 URL 探活 + 证书到期）

`/etc/blackbox.yml`：

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      preferred_ip_protocol: ip4
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200, 301, 302]
  http_post_2xx:
    prober: http
    http:
      method: POST
  tcp_connect:
    prober: tcp
```

探活 20+ URL 时不要在 `prometheus.yml` 里手写 20 个 target，用 `file_sd_configs`（见 3.1）。

## 3. Prometheus

### 3.1 主配置 `prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['192.168.56.15:9093']
      timeout: 10s

scrape_configs:
  - job_name: node
    file_sd_configs:
      - files: ['/etc/prometheus/targets/hosts.yml']
        refresh_interval: 30s

  - job_name: mysql
    static_configs:
      - targets: ['192.168.56.13:9104', '192.168.56.14:9104']

  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files: ['/etc/prometheus/targets/urls.yml']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115

  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
```

`/etc/prometheus/targets/hosts.yml`：

```yaml
- targets: ['192.168.56.11:9100']
  labels: { instance: web-01, role: nginx }
- targets: ['192.168.56.12:9100']
  labels: { instance: app-01, role: php }
- targets: ['192.168.56.13:9100']
  labels: { instance: db-01,  role: mysql-master }
- targets: ['192.168.56.14:9100']
  labels: { instance: db-02,  role: mysql-slave }
```

### 3.2 告警规则（30 条，P0/P1/P2 分级）

完整规则见 `configs/prometheus/rules/lnmp_rules.yml`，设计原则：

| 级别 | 触发条件 | 通知策略 |
| --- | --- | --- |
| P0 | 服务不可用（`up==0`、`nginx_up==0`、主从断裂） | 立刻发，30 分钟重复 |
| P1 | 容量/性能接近阈值（磁盘 85%、内存 90%、延迟 30s） | 10 秒聚合后发，1 小时重复 |
| P2 | 趋势性问题（inode、重传率、慢查询速率） | 合并发，4 小时重复 |

几条值得说明的写法：

```yaml
# 1) 用 for 过滤抖动：up==0 持续 1 分钟才算，避免重启瞬间误报
- alert: InstanceDown
  expr: up == 0
  for: 1m

# 2) 用 predict_linear 做容量预测，比"到 85% 再说"更早
- alert: DiskWillFillIn4h
  expr: predict_linear(node_filesystem_avail_bytes[6h], 4 * 3600) < 0
  for: 30m

# 3) 用比例而不是绝对值，避免大机器上误报
- alert: MemoryAvailableLow
  expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100 < 10

# 4) 直方图算 P95，别用 avg
histogram_quantile(0.95, sum(rate(nginx_upstream_response_time_seconds_bucket[5m])) by (le))
```

### 3.3 启动

```bash
tar -xzf prometheus-2.53.0.linux-amd64.tar.gz -C /opt
mv /opt/prometheus-2.53.0.linux-amd64 /opt/prometheus

# 语法先校验，再启动（重启前必做）
/opt/prometheus/promtool check config /etc/prometheus/prometheus.yml
/opt/prometheus/promtool check rules /etc/prometheus/rules/*.yml

cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus
After=network.target
[Service]
User=prometheus
ExecStart=/opt/prometheus/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/data/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now prometheus
```

`--web.enable-lifecycle` 允许 `curl -X POST localhost:9090/-/reload` 热加载配置，改规则不用重启。

【校验】

```bash
curl -s localhost:9090/-/ready                  # Prometheus Server is Ready.
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance:.labels.instance, health:.health}'
curl -s localhost:9090/api/v1/rules  | jq '.data.groups[].rules | length'   # 31
```

## 4. Alertmanager

### 4.1 配置（邮件通道 + 分级路由 + 抑制）

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.163.com:465'      # SSL 端口
  smtp_from: 'your_mail@163.com'
  smtp_auth_username: 'your_mail@163.com'
  smtp_auth_password: '<邮箱授权码，不是登录密码>'
  smtp_require_tls: false

route:
  receiver: 'email-default'
  group_by: ['alertname', 'instance', 'severity']
  group_wait: 10s          # 第一次聚合等待，10s 内同组告警合并成一封
  group_interval: 5m
  repeat_interval: 1h
  routes:
    - matchers: ['severity="P0"']
      receiver: 'email-p0'
      repeat_interval: 30m

receivers:
  - name: 'email-default'
    email_configs:
      - to: 'ops@example.com'
        send_resolved: true
  - name: 'email-p0'
    email_configs:
      - to: 'ops@example.com'
        send_resolved: true
        headers:
          Subject: '[P0][{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} - {{ .CommonLabels.instance }}'

inhibit_rules:
  # 主机 down 时，抑制它身上的容量/性能告警，避免一次宕机刷一屏
  - source_matchers: ['alertname="InstanceDown"']
    target_matchers: ['alertname=~".+High|.+Low"']
    equal: ['instance']
  # P0 抑制同实例同名的 P1/P2
  - source_matchers: ['severity="P0"']
    target_matchers: ['severity=~"P1|P2"']
    equal: ['alertname', 'instance']
```

【校验】

```bash
/opt/alertmanager/amtool check-config /etc/alertmanager/alertmanager.yml
curl -s localhost:9093/-/ready

# 直接灌一条假告警，验证邮件链路（比等真实故障快得多）
amtool alert add alertname=TestMail severity=P0 instance=test --alertmanager.url=http://localhost:9093
```

收到邮件后 `amtool alert add ... --end=$(date -d '+1 min' +%s)` 或让它自然解析，验证 `send_resolved`。

### 4.2 163/QQ 邮箱常见坑

1. **必须用授权码**，不是网页登录密码；163 在「设置 → POP3/SMTP/IMAP → 开启服务 → 新增授权码」。
2. 465 是 SSL 端口，`smtp_require_tls: false` + 465 即可；587 才需要 STARTTLS。
3. 发件人必须等于 `smtp_auth_username`，否则 163 直接 550。
4. 频率限制：163 单账号有日发信上限，告警风暴时会被限流——所以降噪不是"锦上添花"，是保命。

## 5. Grafana

```bash
dnf install -y grafana
systemctl enable --now grafana-server
```

- 数据源：`http://192.168.56.15:9090`，Scrape interval 15s。
- 大盘一：**主机总览**（CPU/内存/磁盘/网络/负载，模板变量 `$instance`、`$role`）。
- 大盘二：**业务探活**（20+ URL 的 `probe_success`、`probe_duration_seconds`、证书剩余天数）。
- 大盘三：**MySQL**（QPS、连接数、主从延迟、慢查询速率、缓冲池命中率）。

面板里建议直接放 `ALERTS{alertstate="firing"}`，这样大盘上看得到"当前有没有在报警"，不用切 Alertmanager。

## 6. 验收标准

- [ ] 4 台主机 `up==1`，`node_load1` 有数据
- [ ] `mysql_up==1`，主从延迟指标有曲线
- [ ] 20+ URL `probe_success==1`，证书指标正常
- [ ] `promtool check rules` 通过，规则数 30
- [ ] 手动 `kill` 一个 exporter → P0 邮件到达（本机复现基线 **86.8 s**，你的环境会有差异，以自己秒表为准，见 [05-实测记录](05-实测记录.md)）
- [ ] 恢复 exporter → 收到 resolved 邮件
- [ ] 触发一次磁盘告警 → 与 InstanceDown 同时存在时被抑制，只收到 1 封

## 7. 容量与保留

| 项 | 建议值 | 说明 |
| --- | --- | --- |
| `scrape_interval` | 15s | 再短对故障发现提升有限，磁盘翻倍 |
| `retention.time` | 15d | 本地盘；长期数据接 VictoriaMetrics/Thanos |
| 单机磁盘 | 每 target 每天约 15–25 MB | 4 台 + 自身 ≈ 150 MB/天，15 天约 2.2 GB |
| `evaluation_interval` | 15s | 与抓取对齐，避免规则评估滞后于数据 |
