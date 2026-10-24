# Prometheus 监控排障手册

> 监控系统的故障有两种：**"该报没报"** 和 **"报了但没用"**。前者是采集/规则断了，后者是告警风暴/阈值不合理。
> 排查顺序：`目标是否 up` → `指标有没有数据` → `规则是否 firing` → `Alertmanager 是否收到` → `邮件是否发出`。

## 0. 五段链路，逐段验证

```
exporter  →  Prometheus 抓取  →  规则评估  →  Alertmanager 路由  →  SMTP 投递
  :9100        targets/up        rules/firing      /api/v2/alerts        邮箱
```

```bash
# ① exporter 活着吗（在目标机上）
curl -s localhost:9100/metrics | head -3

# ② Prometheus 连得上吗（在监控机上）
curl -s 'http://192.168.56.15:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | "\(.labels.instance)\t\(.health)\t\(.lastError)"'

# ③ 规则在评估吗、有没有 firing
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.state=="firing") | "\(.name) \(.labels.instance)"'

# ④ Alertmanager 收到了吗
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | "\(.labels.alertname)\t\(.status.state)\t\(.startsAt)"'

# ⑤ 邮件发出去了吗
journalctl -u alertmanager -n 100 --no-pager | grep -iE 'notify|email|smtp|error'
```

哪一段断了就修哪一段，**不要跳段**。最常见的误判是"没收到邮件"其实第 ②段 target 就 down 了。

## 1. 该报没报

### 1.1 目标 down

```bash
curl -s 'localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.health!="up") | {scrapeUrl, lastError, lastScrape}'
```

| `lastError` | 原因 | 处置 |
| --- | --- | --- |
| `connection refused` | exporter 没起 / 端口错 | `systemctl status node_exporter`，`ss -lntp \| grep 9100` |
| `context deadline exceeded` | 网络不通 / 抓取超时 | 目标机防火墙放行监控机 IP |
| `server returned HTTP status 404` | `metrics_path` 写错 | 检查 job 配置的 `metrics_path` |
| 401/403 | 目标要求认证 | 配 `basic_auth` 或 bearer token |

```bash
# 在监控机上直接模拟一次抓取，比看 UI 快
curl -v --max-time 5 http://192.168.56.11:9100/metrics
```

### 1.2 目标 up 但没数据

现象：`up==1`，但 `node_load1` 查不到。

```bash
# 1) 目标真的暴露了这个指标吗
curl -s http://192.168.56.11:9100/metrics | grep '^node_load1'

# 2) 标签是否对得上（instance/job 写错是最常见原因）
#    UI 里查 {__name__="node_load1"} 看实际标签
```

注意：`relabel_configs` 顺序错了会把 `instance` 改没；`honor_labels: true` 时目标自带的 `instance` 标签会覆盖 `static_configs` 里的。

### 1.3 规则没触发

```bash
# 规则语法 + 表达式实际返回什么
promtool check rules /etc/prometheus/rules/*.yml

# 在 UI 或 API 里单独跑表达式，看有没有结果（这是最快的方法）
curl -s -G localhost:9090/api/v1/query --data-urlencode 'query=up == 0' | jq '.data.result'
```

| 症状 | 原因 |
| --- | --- |
| 表达式无结果 | 标签不匹配（`job="node"` 写成 `job="nodes"`）、时间窗口太短 |
| 有结果但状态是 `pending` | `for:` 还没到；看 `activeAt` 与当前时间差 |
| 有结果但状态 `inactive` | 规则文件没被加载 → `curl localhost:9090/api/v1/rules` 看 group 是否存在 |
| 报 `rule evaluation failed` | PromQL 语法/函数用错，看 Prometheus 日志 |

```bash
# 规则有没有被加载、上次评估时间
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[] | "\(.name)\t\(.lastEvaluation)\t\(.interval)"'
```

### 1.4 时间不同步导致误判

`for:` 的判断依赖 Prometheus 本地时钟；如果监控机 NTP 漂了，`activeAt` 会漂，规则表现怪异。

```bash
chronyc tracking | grep -E 'System time|Leap'
```

## 2. Alertmanager 收到了但没发邮件

### 2.1 先确认"收到"

```bash
curl -s localhost:9093/api/v2/alerts | jq 'length'
```

数量为 0 → 问题在 Prometheus → Alertmanager 这一段：`alerting.alertmanagers` 里的地址写错，或 Alertmanager 的 `--web.listen-address` 只监听了 127.0.0.1。看 Prometheus 日志：

```bash
journalctl -u prometheus -n 50 | grep -i alertmanager
# 期望：Completed loading of configuration file / Sending alerts to ...
```

### 2.2 收到了但状态是 `suppressed`

```bash
curl -s localhost:9093/api/v2/alerts | jq '.[] | {name:.labels.alertname, st:.status.state, inhibited:.status.inhibitedBy, silenced:.status.silencedBy}'
```

- `inhibitedBy` 有值 → 被抑制规则压掉了，检查 `inhibit_rules` 的 `equal` 标签是否过宽（常见错误：`equal: []` 把所有告警都抑制了）。
- `silencedBy` 有值 → 有静默没到期，`amtool silence query`。

### 2.3 没发邮件：SMTP 层

```bash
journalctl -u alertmanager -n 200 --no-pager | grep -iE 'smtp|notify|error'
```

| 报错 | 原因 |
| --- | --- |
| `535 Authentication failed` | 用了登录密码而不是**授权码** |
| `550 Invalid User` / `553` | `smtp_from` 与认证账号不一致 |
| `connection refused` / `i/o timeout` | 端口写错（465 是 SSL，587 是 STARTTLS）或出口被封 |
| `x509: certificate signed by unknown authority` | 企业自签证书，需 `smtp_tls_config.insecure_skip_verify: true`（仅内网） |

手工验证 SMTP（排除 Alertmanager 因素）：

```bash
# 用 swaks 最直观（dnf install swaks）
swaks --to ops@example.com --from your_mail@163.com \
      --server smtp.163.com:465 --tlsc --auth LOGIN \
      --auth-user your_mail@163.com --auth-password '<授权码>'
```

### 2.4 发了但被丢进垃圾箱 / 延迟

- 缺少 SPF/DKIM：用企业邮箱或自建时配好 `_spf` 记录。
- `group_wait` 太长：默认 30s，P0 建议 10s。
- `repeat_interval` 没到：同一组告警在窗口内不会重复发。

## 3. 告警风暴

**现象**：一次网络抖动，手机收到 40 封邮件。

### 3.1 三层降噪

| 手段 | 配置 | 效果 |
| --- | --- | --- |
| 分组 `group_by` | `['alertname','instance']` | 同实例同类告警合并成 1 封 |
| 抑制 `inhibit_rules` | 主机 down → 抑制其上所有 P1/P2 | 一次宕机从 40 封降到 1 封 |
| 静默 `silence` | 变更窗口 30 分钟 | 维护期不打扰 |
| `for` 持续时长 | 容量类 5–10 分钟 | 过滤瞬时抖动 |

### 3.2 静默的正确用法

```bash
# 变更窗口静默（带过期时间，别用 --expire 空值）
amtool silence add 'instance=~"db-0[12]"' --alertmanager.url=http://localhost:9093 \
  --duration=2h --comment="主从切换演练"

amtool silence query --alertmanager.url=http://localhost:9093
```

### 3.3 阈值不合理

- 磁盘 85% 对 `/var/log` 是常态，对 `/data` 可能是灾难 → **按分区设阈值**，用 `mountpoint` 过滤。
- CPU 85% 持续 10 分钟，对批处理机是正常 → 按 `role` 标签分机器类型。
- 用 `predict_linear` 替代硬阈值，把"还有 4 小时写满"这种可行动的告警提前发出来。

## 4. 监控系统自身故障

| 现象 | 排查 |
| --- | --- |
| Grafana 面板全空但 Prometheus 正常 | 数据源 URL、时区、面板时间范围 |
| Prometheus 启动失败 | `journalctl -u prometheus`；90% 是 YAML 缩进或规则文件路径 |
| 磁盘暴涨 | `du -sh /data/prometheus/*`；减少 target 或缩短 retention |
| 抓取很慢 | `scrape_duration_seconds` 变大 → 目标机负载高或 exporter 版本问题 |
| 规则评估慢 | `prometheus_rule_evaluation_duration_seconds`，规则过多时拆分组 |

```bash
# 自身健康
curl -s localhost:9090/api/v1/status/buildinfo | jq
curl -s localhost:9090/-/healthy
```

## 5. 复盘模板

```markdown
## 事件：2026-05-21 磁盘告警未收到
- 现象：db-01 /data 已 97%，无任何邮件
- 五段定位：target up → 指标有数据 → 规则 pending（for: 30m 未到）→ 未进 Alertmanager
- 根因：DiskUsageHigh 的 for 从 5m 被误改成 30m，且未配置 95% 的 P0 规则
- 处置：恢复 for: 5m，新增 DiskUsageCritical（>95%，for: 2m，P0）
- 改进：加"规则文件变更需 promtool check + 1 次演练"的门禁
```
