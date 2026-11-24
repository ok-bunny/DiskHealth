// smart_ata_probe.c — 通过 IOATASMARTInterface（内核 SAT 翻译）读 USB/SATA 机械盘 SMART
// 接口挂在带 "SMART Capable" 属性的服务上（USB 盘为 IOBlockStorageServices）
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>

static const char *attr_name(unsigned id) {
    switch (id) {
    case 1: return "Raw 读取错误率";
    case 3: return "主轴起旋时间";
    case 4: return "启停次数";
    case 5: return "重映射扇区数";
    case 7: return "寻道错误率";
    case 9: return "通电小时数";
    case 10: return "主轴重试次数";
    case 12: return "通电周期数";
    case 187: return "无法纠正的错误";
    case 190: return "气流温度";
    case 194: return "温度";
    case 196: return "重映射事件数";
    case 197: return "当前待映射扇区";
    case 198: return "离线无法纠正扇区";
    case 199: return "UDMA CRC 错误";
    case 240: return "磁头飞行时间";
    case 241: return "LBA 写入总量";
    case 242: return "LBA 读取总量";
    default: return "-";
    }
}

static void report(const char *bsd, IOATASMARTInterface **ifc) {
    printf("\n===== %s =====\n", bsd);

    Boolean exceeded = false;
    IOReturn kr = (*ifc)->SMARTReturnStatus(ifc, &exceeded);
    if (kr == kIOReturnSuccess)
        printf("  SMART 结论: %s\n", exceeded ? "Failing（阈值已超）" : "Verified（正常）");
    else
        printf("  SMARTReturnStatus: 0x%x\n", kr);

    unsigned char ident[512];
    UInt32 outSize = 0;
    memset(ident, 0, sizeof(ident));
    kr = (*ifc)->GetATAIdentifyData(ifc, ident, sizeof(ident), &outSize);
    if (kr == kIOReturnSuccess && outSize >= 47) {
        char model[41], serial[21], fw[9];
        memcpy(model, ident + 54, 40); model[40] = 0;
        memcpy(serial, ident + 20, 20); serial[20] = 0;
        memcpy(fw, ident + 46, 8); fw[8] = 0;
        for (int i = 0; i < 20; i++) { char t = model[i*2]; model[i*2] = model[i*2+1]; model[i*2+1] = t; }
        for (int i = 0; i < 10; i++) { char t = serial[i*2]; serial[i*2] = serial[i*2+1]; serial[i*2+1] = t; }
        for (int i = 0; i < 4; i++) { char t = fw[i*2]; fw[i*2] = fw[i*2+1]; fw[i*2+1] = t; }
        printf("  型号: %s\n  序列号: %s\n  固件: %s\n", model, serial, fw);
    } else {
        printf("  GetATAIdentifyData: 0x%x\n", kr);
    }

    ATASMARTData d;
    memset(&d, 0, sizeof(d));
    kr = (*ifc)->SMARTReadData(ifc, &d);
    if (kr != kIOReturnSuccess) {
        printf("  SMARTReadData: 0x%x\n", kr);
        return;
    }

    printf("  --- SMART 属性表（ID/名称/值/最差/原始值/阈值） ---\n");
    ATASMARTDataThresholds th;
    memset(&th, 0, sizeof(th));
    int haveTh = ((*ifc)->SMARTReadDataThresholds(ifc, &th) == kIOReturnSuccess);

    int tempC = -1;
    unsigned long long pending = 0, offline_unc = 0, realloc = 0;
    for (int i = 0; i < 30; i++) {
        const unsigned char *a = d.vendorSpecific1 + 2 + 12 * i;
        unsigned id = a[0];
        if (id == 0) continue;
        unsigned value = a[3], worst = a[4];
        unsigned long long raw = 0;
        for (int b = 5; b >= 0; b--) raw = (raw << 8) | a[5 + b];
        unsigned thresh = haveTh ? (unsigned)th.vendorSpecific1[2 + 12 * i + 5] : 0;
        printf("  %-4u %-20s %4u %4u %14llu %4u\n", id, attr_name(id), value, worst, raw, thresh);
        if (id == 194 || (id == 190 && tempC < 0)) tempC = (int)(raw & 0xFF);
        if (id == 197) pending = raw;
        if (id == 198) offline_unc = raw;
        if (id == 5) realloc = raw;
    }
    if (tempC >= 0) printf("  温度: %d °C\n", tempC);

    printf("  --- 判定 ---\n");
    if (exceeded) printf("  危险：设备自报 SMART 阈值超限（Failing）\n");
    if (pending > 0 || offline_unc > 0)
        printf("  危险：待映射/无法纠正扇区（197=%llu, 198=%llu）\n", pending, offline_unc);
    else if (realloc > 0)
        printf("  警告：已有重映射扇区（5=%llu）\n", realloc);
    else if (!exceeded)
        printf("  健康：关键属性（5/197/198）无异常，SMART 自检通过\n");
}

// 从整盘 IOMedia 向上找带 "SMART Capable" 的祖先
static io_object_t find_smart_capable(io_object_t media) {
    io_object_t cur = media;
    IOObjectRetain(cur);
    for (int up = 0; up < 12; up++) {
        CFTypeRef sc = IORegistryEntryCreateCFProperty(cur, CFSTR(kIOPropertySMARTCapableKey),
                                                       kCFAllocatorDefault, 0);
        if (sc) {
            CFRelease(sc);
            return cur;  // 这个服务（含 media 自身）支持 ATA SMART 接口
        }
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
    if (uuid) { CFRelease(uuid); return 0; }
    return 1;
}

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

int main(void) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"),
                                     &iter) != KERN_SUCCESS) return 1;
    io_object_t media;
    int n = 0;
    while ((media = IOIteratorNext(iter)) != 0) {
        if (!is_whole_media(media)) { IOObjectRelease(media); continue; }
        io_object_t svc = find_smart_capable(media);
        IOObjectRelease(media);
        if (!svc) continue;

        char bsd[32] = "";
        find_bsd(svc, bsd, sizeof(bsd));
        if (!bsd[0]) strlcpy(bsd, "disk?", 8);

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        IOReturn kr = IOCreatePlugInInterfaceForService(svc, kIOATASMARTUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != KERN_SUCCESS || !plugin) {
            printf("\n===== %s =====\n  打开 ATA SMART 接口失败: 0x%x\n", bsd, kr);
            IOObjectRelease(svc);
            continue;
        }
        IOATASMARTInterface **ifc = NULL;
        if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID),
                                      (LPVOID *)&ifc) != S_OK || !ifc) {
            IODestroyPlugInInterface(plugin);
            IOObjectRelease(svc);
            continue;
        }
        report(bsd, ifc);
        (*ifc)->Release(ifc);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(svc);
        n++;
    }
    IOObjectRelease(iter);
    if (n == 0) fprintf(stderr, "没有 SMART Capable 的 SATA/USB 磁盘\n");
    return 0;
}
