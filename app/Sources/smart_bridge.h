#ifndef SMART_BRIDGE_H
#define SMART_BRIDGE_H

#include <stdint.h>

#define DH_MAX_DISKS 16

// smart_status 取值
#define DH_SMART_UNKNOWN 0
#define DH_SMART_VERIFIED 1
#define DH_SMART_FAILING 2

typedef struct {
    uint64_t raw;
    int present;
} dh_ata_value_t;

typedef struct dh_disk_info {
    char bsd[32];          // /dev/diskN 名
    char model[64];        // 型号
    char serial[32];       // 序列号
    char firmware[16];     // 固件版本
    char transport[24];    // 传输协议（USB / Apple Fabric 等，可为空）
    int have_nvme_detail;  // 1 = 已读到 NVMe SMART/Health 日志
    int have_ata_detail;   // 1 = 有校验通过、可识别的 ATA SMART 属性
    dh_ata_value_t ata_realloc_sectors;   // attr 5
    dh_ata_value_t ata_power_on_hours;    // attr 9
    dh_ata_value_t ata_power_cycles;      // attr 12
    dh_ata_value_t ata_unsafe_shutdowns;  // attr 192
    dh_ata_value_t ata_pending_sectors;   // attr 197
    dh_ata_value_t ata_offline_unc;       // attr 198
    dh_ata_value_t ata_crc_errors;        // attr 199
    dh_ata_value_t ata_lba_written;       // attr 241（扇区数）
    dh_ata_value_t ata_lba_read;          // attr 242（扇区数）
    int smart_status;      // DH_SMART_*
    int is_internal;       // 1 = 内置盘
    unsigned critical_warning;      // NVMe 临界警告位
    unsigned temperature_k;         // 开尔文
    unsigned spare;                 // 可用备件 %
    unsigned spare_threshold;       // 备件阈值 %
    unsigned percentage_used;       // 已用寿命 %
    uint64_t size_bytes;            // 容量（IOMedia Size）
    uint64_t data_units_read;       // 读取数据单元（每单元 512,000 字节）
    uint64_t data_units_written;
    uint64_t host_read_cmds;
    uint64_t host_write_cmds;
    uint64_t busy_minutes;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
    uint64_t error_log_entries;
} dh_disk_info_t;

// 探测所有物理磁盘；返回写入 out 的条目数，失败返回负数
int dh_probe_disks(dh_disk_info_t *out, int max);

#endif /* SMART_BRIDGE_H */
