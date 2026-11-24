// sat_probe.c — 通过 SCSITaskUserClient + SAT ATA PASS-THROUGH(16) 读取 USB 桥接 SATA 盘的 SMART
// 通常需要 root 权限（SCSI 任务透传在 macOS 上默认拒绝非特权进程）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/scsi/SCSICmds_REQUEST_SENSE_Defs.h>

// SAT ATA PASS-THROUGH(16)：PIO Data-In 读 512 字节
static int sat_read16(SCSITaskDeviceInterface **dev, UInt8 command, UInt8 features,
                      UInt8 lba_low, UInt8 lba_mid, UInt8 lba_high,
                      unsigned char *buf) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) { fprintf(stderr, "  CreateSCSITask 失败\n"); return -1; }

    UInt8 cdb[16];
    memset(cdb, 0, sizeof(cdb));
    cdb[0] = 0x85;                     // ATA PASS-THROUGH(16)
    cdb[1] = (4 << 1);                 // PROTOCOL=4 (PIO Data-In), EXTEND=0
    cdb[2] = (1 << 3) | (1 << 2) | 2;  // T_DIR=1(from device) BYTE_BLOK=1 T_LENGTH=2(sector count)
    cdb[4] = features;                 // FEATURES (7:0)
    cdb[6] = 1;                        // SECTOR_COUNT (7:0)
    cdb[8] = lba_low;                  // LBA_LOW (7:0)
    cdb[10] = lba_mid;                 // LBA_MID (7:0)
    cdb[12] = lba_high;                // LBA_HIGH (7:0)
    cdb[13] = 0xA0;                    // DEVICE (LBA 位)
    cdb[14] = command;                 // ATA COMMAND

    (*task)->SetTaskAttribute(task, kSCSITask_SIMPLE);
    (*task)->SetCommandDescriptorBlock(task, cdb, 16);
    SCSITaskSGElement sg;
    sg.address = (IOVirtualAddress)(uintptr_t)buf;
    sg.length = 512;
    (*task)->SetScatterGatherEntries(task, &sg, 1, 512, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 20000);

    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = kSCSITaskStatus_GOOD;
    UInt64 realized = 0;
    IOReturn kr = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
    int rc = -1;
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "  ExecuteTaskSync: 0x%x（权限/系统错误）\n", kr);
    } else if (status == kSCSITaskStatus_CHECK_CONDITION) {
        fprintf(stderr, "  CHECK_CONDITION: key=%u ASC=0x%02x ASCQ=0x%02x\n",
                sense.SENSE_KEY & 0x0F, sense.ADDITIONAL_SENSE_CODE, sense.ADDITIONAL_SENSE_CODE_QUALIFIER);
    } else if (realized < 512) {
        fprintf(stderr, "  传输不完整: %llu 字节\n", (unsigned long long)realized);
    } else {
        rc = 0;
    }
    (*task)->Release(task);
    return rc;
}

static void word_swap_str(unsigned char *s, int words) {
    for (int i = 0; i < words; i++) {
        unsigned char t = s[i * 2];
        s[i * 2] = s[i * 2 + 1];
        s[i * 2 + 1] = t;
    }
}

static const char *attr_name(unsigned id) {
    switch (id) {
    case 1: return "Raw 读取错误率";
    case 3: return "主轴起旋时间";
    case 4: return "启停次数";
    case 5: return "重映射扇区数";
    case 7: return "寻道错误率";
    case 9: return "通电小时数";
    case 10: return "主轴重试次数";
    case 11: return "校准重试次数";
    case 12: return "通电周期数";
    case 170: return "保留块磨损";
    case 173: return "磨损均衡次数";
    case 174: return "意外断电次数";
    case 175: return "断电保护失败";
    case 187: return "无法纠正的错误";
    case 190: return "气流温度";
    case 194: return "温度";
    case 196: return "重映射事件数";
    case 197: return "当前待映射扇区";
    case 198: return "离线无法纠正扇区";
    case 199: return "UDMA CRC 错误";
    case 200: return "多区错误率";
    case 240: return "磁头飞行时间";
    case 241: return "LBA 写入总量";
    case 242: return "LBA 读取总量";
    default: return NULL;
    }
}

static void report_disk(SCSITaskDeviceInterface **dev, const char *bsd) {
    printf("\n===== %s =====\n", bsd);

    static unsigned char buf[512];

    // IDENTIFY DEVICE
    if (sat_read16(dev, 0xEC, 0, 0, 0, 0, buf) == 0) {
        unsigned char model[41], serial[21], fw[9];
        memcpy(model, buf + 54, 40); model[40] = 0; word_swap_str(model, 20);
        memcpy(serial, buf + 20, 20); serial[20] = 0; word_swap_str(serial, 10);
        memcpy(fw, buf + 46, 8); fw[8] = 0; word_swap_str(fw, 4);
        printf("  型号: %s\n  序列号: %s\n  固件: %s\n", model, serial, fw);
    } else {
        printf("  IDENTIFY 失败\n");
    }

    // SMART READ DATA
    if (sat_read16(dev, 0xB0, 0xD0, 0, 0x4F, 0xC2, buf) == 0) {
        int overall = buf[362];  // Off-line data collection status 里的整体结论位不在此；先打印属性
        (void)overall;
        printf("  --- SMART 属性表 ---\n");
        printf("  %-4s %-22s %6s %6s %14s\n", "ID", "名称", "值", "最差", "原始值");
        int tempC = -1;
        unsigned long long pending = 0, offline_unc = 0, realloc = 0;
        for (int i = 0; i < 30; i++) {
            unsigned char *a = buf + 2 + 12 * i;
            unsigned id = a[0];
            if (id == 0) continue;
            unsigned value = a[3], worst = a[4];
            unsigned long long raw = 0;
            for (int b = 5; b >= 0; b--) raw = (raw << 8) | a[5 + b];
            const char *n = attr_name(id);
            printf("  %-4u %-22s %6u %6u %14llu\n", id, n ? n : "-", value, worst, raw);
            if (id == 194 || (id == 190 && tempC < 0)) tempC = (int)(raw & 0xFF);
            if (id == 197) pending = raw;
            if (id == 198) offline_unc = raw;
            if (id == 5) realloc = raw;
        }
        if (tempC >= 0) printf("  温度: %d °C\n", tempC);
        printf("  --- 判定 ---\n");
        if (pending > 0 || offline_unc > 0)
            printf("  危险：存在待映射/无法纠正扇区（197=%llu, 198=%llu）\n", pending, offline_unc);
        else if (realloc > 0)
            printf("  警告：已有重映射扇区（5=%llu）\n", realloc);
        else
            printf("  健康：关键属性（5/197/198）均无异常计数\n");
    } else {
        printf("  SMART READ DATA 失败\n");
    }
}

// 在服务子树里找 BSD Name（PDT00 → BlockStorageServices → Driver → Media）
static void find_bsd(io_object_t svc, char *out, size_t cap) {
    out[0] = 0;
    io_iterator_t it = 0;
    if (IORegistryEntryCreateIterator(svc, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS)
        return;
    io_object_t e;
    while (!out[0] && (e = IOIteratorNext(it)) != 0) {
        CFStringRef bn = IORegistryEntryCreateCFProperty(e, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        if (bn) {
            if (!CFStringGetCString(bn, out, (CFIndex)cap, kCFStringEncodingUTF8)) out[0] = 0;
            CFRelease(bn);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

// 从整盘 IOMedia 沿父链向上找 IOSCSIPeripheralDeviceType00（SCSI 任务接口挂在那里）
static io_object_t find_pdt0(io_object_t media) {
    io_object_t cur = media;
    IOObjectRetain(cur);
    for (int up = 0; up < 12; up++) {
        char cls[128] = "";
        IOObjectGetClass(cur, cls);
        if (strcmp(cls, "IOSCSIPeripheralDeviceType00") == 0) return cur;
        io_object_t parent = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(cur);
        cur = parent;
    }
    if (cur) IOObjectRelease(cur);
    return 0;
}

static int is_whole_media(io_object_t m) {
    CFTypeRef whole = IORegistryEntryCreateCFProperty(m, CFSTR("Whole"), kCFAllocatorDefault, 0);
    if (!whole) return 0;
    int w = (CFGetTypeID(whole) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)whole));
    CFRelease(whole);
    if (!w) return 0;
    CFTypeRef uuid = IORegistryEntryCreateCFProperty(m, CFSTR("UUID"), kCFAllocatorDefault, 0);
    if (uuid) { CFRelease(uuid); return 0; }  // 分区/合成卷
    return 1;
}

int main(void) {
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                    IOServiceMatching("IOMedia"),
                                                    &iter);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "枚举 IOMedia 失败\n"); return 1; }

    io_object_t media;
    int n = 0;
    while ((media = IOIteratorNext(iter)) != 0) {
        if (!is_whole_media(media)) { IOObjectRelease(media); continue; }

        io_object_t svc = find_pdt0(media);
        IOObjectRelease(media);
        if (!svc) continue;

        char bsd[32] = "";
        find_bsd(svc, bsd, sizeof(bsd));
        if (!bsd[0]) strlcpy(bsd, "disk?", 8);

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(svc, kIOSCSITaskLibFactoryID,
                                               kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != KERN_SUCCESS || !plugin) {
            printf("\n===== %s =====\n  打开 SCSI 任务接口失败: 0x%x（很可能需要 root）\n", bsd, kr);
            IOObjectRelease(svc);
            continue;
        }
        SCSITaskDeviceInterface **dev = NULL;
        HRESULT qr = (*plugin)->QueryInterface(plugin,
                CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
        if (qr != S_OK || !dev) {
            printf("\n===== %s =====\n  QueryInterface 失败: %ld\n", bsd, (long)qr);
            IODestroyPlugInInterface(plugin);
            IOObjectRelease(svc);
            continue;
        }
        (*dev)->ObtainExclusiveAccess(dev);  // 拿不到也继续（只读查询）
        report_disk(dev, bsd);
        (*dev)->ReleaseExclusiveAccess(dev);
        (*dev)->Release(dev);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(svc);
        n++;
    }
    IOObjectRelease(iter);
    if (n == 0) fprintf(stderr, "没有可探测的 SCSI/USB 磁盘\n");
    return 0;
}
