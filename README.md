# ops-runbooks · LNMP 与 Prometheus 监控体系实践

两个从零搭建、按文档可复现的运维实验环境：一套 **LNMP 站点（Nginx + PHP-FPM + MySQL 主从）**，一套 **Prometheus + Grafana + Alertmanager 监控告警链路**。
本仓库是这两个项目的**部署手册、排障手册、可落地配置文件与实测记录**，所有数字都来自本机复现环境（见 [docs/05-实测记录.md](docs/05-实测记录.md)）。

> 定位：不是"教程搬运"，而是把每一步做成**有校验、能回滚、出问题知道先看哪**的操作文档。

## 实测数据（可复现）

| 指标 | 实测值 | 测量方式 |
| --- | --- | --- |
| 节点掉线 → 告警邮件到达 | **86.8 s** | 杀掉 node_exporter，记录邮件落库时间 |
| 其中：监控发现实例 down | 16.8 s | Prometheus 15 s 抓取周期 |
| 其中：告警从 pending → firing → 邮件 | 70.0 s | `for: 1m` + Alertmanager `group_wait: 10s` |
| 静态首页吞吐（1500 请求 / 50 并发） | **822 QPS**，服务端处理 < 1 ms | Nginx access log `$request_time` |
| 动态首页响应（50 并发） | 平均 106 ms，P95 141 ms | 客户端端到端计时 |
| 告警规则数量 | 30 条，P0/P1/P2 三级 | `grep -c 'alert:' rules/*.yml` |
| 监控目标 | 4 台主机 + 1 个 Prometheus 自身 | `prometheus.yml` |

## 环境与版本

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| Rocky Linux | 9.4 | 3 台业务机 + 1 台监控机，KVM 虚拟机，2C4G / 40G |
| Nginx | 1.24.0 | 七层反代 + 静态资源 + gzip |
| PHP-FPM | 8.2 | `pm = dynamic`，`pm.max_children = 50` |
| MySQL | 8.0.36 | 一主一从，binlog ROW 格式 |
| Prometheus | 2.53.0 | 15 s 抓取 / 15 s 评估 |
| Alertmanager | 0.27.0 | 邮件通道，P0 优先路由 |
| Grafana | 11.1 | 主机资源大盘 + 业务探活大盘 |

## 仓库结构

```
.
├── README.md
├── docs/
│   ├── 01-LNMP部署手册.md          # 从空系统到站点可访问，含校验点
│   ├── 02-LNMP排障手册.md          # 502/504/主从断连/磁盘满 的定位路径
│   ├── 03-Prometheus监控部署手册.md # 采集 → 规则 → 分级 → 邮件
│   ├── 04-Prometheus排障手册.md     # 告警不触发/邮件收不到/告警风暴
│   └── 05-实测记录.md              # 本文表格里每个数字的原始测量过程
├── configs/
│   ├── nginx/nginx.conf
│   ├── php/php-fpm-www.conf
│   ├── mysql/my.cnf.master / my.cnf.slave
│   ├── prometheus/prometheus.yml
│   ├── prometheus/rules/lnmp_rules.yml
│   └── alertmanager/alertmanager.yml
└── scripts/
    ├── check_host.sh               # 主机巡检：12 项指标，输出可读报告
    └── backup_mysql.sh             # 每日全量备份 + 保留 7 天 + 校验
```

## 快速开始

```bash
# 1. LNMP：按手册逐节执行，每节末尾都有「校验」命令
vim docs/01-LNMP部署手册.md

# 2. 监控：先起 exporters，再起 Prometheus / Alertmanager / Grafana
vim docs/03-Prometheus监控部署手册.md

# 3. 出问题了先查这两份，按「现象 → 定位命令 → 处置」走
vim docs/02-LNMP排障手册.md
vim docs/04-Prometheus排障手册.md
```

## 三个约定

1. **每步都有校验**：装完 Nginx 一定 `curl -I`，配完主从一定 `SHOW SLAVE STATUS` 看两个 Yes。
2. **可回滚**：改配置前 `cp x.conf x.conf.bak.$(date +%F)`，改完 `nginx -t` / `promtool check config` 再 reload。
3. **排障先看日志再看配置**：`journalctl -u` → 服务自身日志 → `ss -lntp` 看端口 → 最后才怀疑配置。

---

作者：王瑞龄（江苏理工学院 · 计算机科学与技术） · 2026.05
