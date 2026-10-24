# ops-runbooks · 运维学习手册（LNMP / Prometheus）

我按运维岗位的要求，把「一套 LNMP 站点」和「一套 Prometheus 监控告警」**该怎么做、怎么排障、哪里会翻车**整理成了操作手册，配套可直接用的配置文件和脚本。

写这份东西的原则只有一条：**做过什么、没做什么，写清楚。**

## 真实进度

| 内容 | 状态 | 说明 |
| --- | --- | --- |
| 部署手册 / 排障手册 / 配置文件 / 脚本 | 已整理 | 命令、参数、校验点都是按手册能照着执行的 |
| 告警链路实测（86.8 s）、静态页压测（822 QPS） | 已测 | **本机 Windows 用同版本组件复现**，不是 Linux 集群，测量过程与原始输出见 [docs/05-实测记录.md](docs/05-实测记录.md) |
| 3 台 Linux 虚拟机 + LVM 在线扩容 | 未做 | 手册里有步骤，我还没在真虚拟机上跑通 |
| MySQL 主从跑通 | 未跑通 | 配到 `Replica_IO_Running: Connecting` 卡住，排错思路写在 02 手册第 3 节 |
| kubeadm 起 K8s 集群 | 未做 | 需要 3 台以上节点，等实验环境扩起来再补 |

> 没做的部分单独列在 [05-实测记录.md 第 4 节](docs/05-实测记录.md)，不混进「已完成」。

## 实测数据（本机复现，可复核）

| 指标 | 实测值 | 测量方式 |
| --- | --- | --- |
| 节点掉线 → 告警邮件到达 | **86.8 s** | 杀掉 exporter，记录邮件落库时间 |
| 其中：监控发现实例 down | 16.8 s | Prometheus 15 s 抓取周期 |
| 其中：告警从 pending → firing → 邮件 | 70.0 s | `for: 1m` + Alertmanager `group_wait: 10s` |
| 静态首页吞吐（1500 请求 / 50 并发） | **822 QPS**，服务端处理 < 1 ms | Nginx access log `$request_time` |
| 动态首页响应（50 并发） | 平均 106 ms，P95 141 ms | 客户端端到端计时 |
| 告警规则数量 | 30 条，P0/P1/P2 三级 | `grep -c 'alert:' rules/*.yml` |

## 环境与版本

> 下表是**手册面向的目标环境**；上面的实测数据不是在这个环境里跑的（见 05 第 0、4 节），两者不要混着理解。

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| Rocky Linux | 9.4 | 3 台业务机 + 1 台监控机，2C4G / 40G |
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
│   └── 05-实测记录.md              # 上面每个数字的原始输出 + 未做清单
├── configs/
│   ├── nginx/nginx.conf
│   ├── php/php-fpm-www.conf
│   ├── mysql/my.cnf.master / my.cnf.slave
│   ├── prometheus/prometheus.yml
│   ├── prometheus/rules/lnmp_rules.yml
│   ├── prometheus/targets/hosts.yml / urls.yml
│   └── alertmanager/alertmanager.yml
└── scripts/
    ├── check_host.sh               # 主机巡检：12 项，输出可读报告
    └── backup_mysql.sh             # 每日全量备份 + 保留 7 天 + 校验
```

## 怎么用这份手册

```bash
# 1. LNMP：按手册逐节执行，每节末尾都有「校验」命令，校验不过不要往下走
vim docs/01-LNMP部署手册.md

# 2. 监控：先起 exporter，再起 Prometheus / Alertmanager / Grafana
vim docs/03-Prometheus监控部署手册.md

# 3. 出问题先查这两份：按「现象 → 定位命令 → 处置」走
vim docs/02-LNMP排障手册.md
vim docs/04-Prometheus排障手册.md
```

## 四个约定

1. **每步都有校验**：装完 Nginx 一定 `curl -I`，配完主从一定 `SHOW SLAVE STATUS` 看两个 Yes。
2. **可回滚**：改配置前 `cp x.conf x.conf.bak.$(date +%F)`，改完 `nginx -t` / `promtool check config` 再 reload。
3. **排障先看日志再看配置**：`journalctl -u` → 服务自身日志 → `ss -lntp` 看端口 → 最后才怀疑配置。
4. **没做通的不装作做通**：状态在 README 和 05 里标着，等真跑通了再改。

---

作者：王瑞龄（江苏理工学院 · 计算机科学与技术） · 更新于 2026.10
