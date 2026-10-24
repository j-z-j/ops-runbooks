#!/usr/bin/env bash
# MySQL 全量备份脚本：mysqldump + gzip + 保留 7 天 + 备份文件校验 + 失败告警
# crontab: 0 2 * * * /usr/local/bin/backup_mysql.sh >> /var/log/mysql-backup.log 2>&1
#
# 设计要点：
#   1. --single-transaction   InnoDB 一致性快照，不锁表
#   2. --source-data=2        记录 binlog 位点，便于按时间点恢复（PITR）
#   3. --set-gtid-purged=OFF  备份文件可直接导入其它实例
#   4. 备份后立即 gunzip -t 校验，坏包比没备份更可怕

set -uo pipefail

BACKUP_DIR=/data/backup/mysql
KEEP_DAYS=7
DB_LIST="demo"
MYSQL_USER=backup
MYSQL_PASS='Backup@2026'
MYSQL_HOST=127.0.0.1
DATE=$(date +%F_%H%M)
LOG_PREFIX="[$(date '+%F %T')]"

mkdir -p "$BACKUP_DIR"
rc=0

for db in $DB_LIST; do
    out="${BACKUP_DIR}/${db}-${DATE}.sql.gz"
    echo "${LOG_PREFIX} start backup ${db} -> ${out}"

    if mysqldump -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" \
            --single-transaction --quick --routines --triggers --events \
            --source-data=2 --set-gtid-purged=OFF --hex-blob \
            --default-character-set=utf8mb4 \
            "$db" 2>/tmp/mysqldump.err | gzip -6 > "$out"; then

        # 校验：能完整解压 + 末尾有 Dump completed 标记
        if gunzip -t "$out" 2>/dev/null && zcat "$out" | tail -1 | grep -q 'Dump completed'; then
            size=$(du -h "$out" | cut -f1)
            md5=$(md5sum "$out" | cut -d' ' -f1)
            echo "${LOG_PREFIX} OK ${db} size=${size} md5=${md5}"
            echo "${md5}  $(basename "$out")" >> "${BACKUP_DIR}/MD5SUMS"
        else
            echo "${LOG_PREFIX} FAIL ${db} 备份文件校验不通过"
            rm -f "$out"
            rc=1
        fi
    else
        echo "${LOG_PREFIX} FAIL ${db} mysqldump 出错：$(cat /tmp/mysqldump.err)"
        rc=1
    fi
done

# 清理过期备份（只删 .sql.gz 与对应 md5 记录）
find "$BACKUP_DIR" -name '*.sql.gz' -mtime +${KEEP_DAYS} -print -delete | while read -r f; do
    echo "${LOG_PREFIX} removed expired $(basename "$f")"
done
[ -f "${BACKUP_DIR}/MD5SUMS" ] && sed -i "/$(date -d "-$((KEEP_DAYS+1)) days" +%F)/d" "${BACKUP_DIR}/MD5SUMS" 2>/dev/null

# 剩余空间低于 20% 时告警（备份把盘写满是很常见的低级事故）
avail=$(df --output=pcent "$BACKUP_DIR" | tail -1 | tr -dc '0-9')
if [ "${avail:-0}" -gt 80 ]; then
    echo "${LOG_PREFIX} WARN 备份目录占用 ${avail}%，请清理或扩容"
    rc=1
fi

echo "${LOG_PREFIX} done rc=${rc}"
exit $rc
