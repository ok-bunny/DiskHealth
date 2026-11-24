// smart_bridge.c — 通过 IOKit 官方接口读取磁盘 SMART 数据（无需 root）
// 数据源 1: IONVMeSMARTInterface（NVMe SMART/Health 日志完整数值）
// 数据源 2: IOMedia 的 "SMART Status" 属性（SATA 盘兜底，Verified/Failing）
#include "smart_bridge.h"

#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <IOKit/storage/ata/ATASMARTLib.h>

static void copy_str(char *dst, size_t cap, const uint8_t *src, size_t n) {
    size_t end = n < cap - 1 ? n : cap - 1;
    size_t start = 0;
    while (start < end && (src[start] == ' ' || src[start] == 0)) start++;
    while (end > start && (src[end - 1] == ' ' || src[end - 1] == 0)) end--;
    memcpy(dst, src + start, end - start);
    dst[end - start] = 0;
}

// 在服务子树（块设备 → 驱动 → IOMedia，最多 3 层）里找 "BSD Name"
static void find_bsd_name(io_object_t svc, char *out, size_t cap) {
    out[0] = 0;
    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(svc, kIOServicePlane, &it) != KERN_SUCCESS) return;
    io_object_t child;
    while (!out[0] && (child = IOIteratorNext(it)) != 0) {
        CFStringRef bn = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"),
                                                         kCFAllocatorDefault, 0);
        if (bn) {
            if (!CFStringGetCString(bn, out, (CFIndex)cap, kCFStringEncodingUTF8)) out[0] = 0;
            CFRelease(bn);
        }
        if (!out[0]) {
            io_iterator_t it2 = 0;
            if (IORegistryEntryGetChildIterator(child, kIOServicePlane, &it2) == KERN_SUCCESS) {
                io_object_t grand;
                while (!out[0] && (grand = IOIteratorNext(it2)) != 0) {
                    CFStringRef bn2 = IORegistryEntryCreateCFProperty(grand, CFSTR("BSD Name"),
                                                                      kCFAllocatorDefault, 0);
                    if (bn2) {
                        if (!CFStringGetCString(bn2, out, (CFIndex)cap, kCFStringEncodingUTF8)) out[0] = 0;
                        CFRelease(bn2);
                    }
                    IOObjectRelease(grand);
                }
                IOObjectRelease(it2);
            }
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(it);
}

// NVMe 通道：枚举 "NVMe SMART Capable" 的服务，读 Identify + SMART/Health 日志
static int probe_nvme(dh_disk_info_t *out, int max) {
    CFMutableDictionaryRef match = IOServiceMatching("IOService");
    if (!match) return 0;
    CFMutableDictionaryRef prop = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!prop) { CFRelease(match); return 0; }
    CFDictionarySetValue(prop, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);
    CFDictionarySetValue(match, CFSTR(kIOPropertyMatchKey), prop);
    CFRelease(prop);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return 0;

    int n = 0;
    io_object_t svc;
    while (n < max && (svc = IOIteratorNext(iter)) != 0) {
        dh_disk_info_t *d = &out[n];
        memset(d, 0, sizeof(*d));
        find_bsd_name(svc, d->bsd, sizeof(d->bsd));

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(svc, kIONVMeSMARTUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plugin,
                                              &score) == KERN_SUCCESS && plugin) {
            IONVMeSMARTInterface **ifc = NULL;
            if ((*plugin)->QueryInterface(plugin,
                    CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                    (LPVOID *)&ifc) == S_OK && ifc) {
                NVMeIdentifyControllerStruct ident;
                memset(&ident, 0, sizeof(ident));
                if ((*ifc)->GetIdentifyData(ifc, &ident, 0) == KERN_SUCCESS) {
                    copy_str(d->model, sizeof(d->model), ident.MODEL_NUMBER,
                             kNVMeIdentifyControllerModelNumberLen);
                    copy_str(d->serial, sizeof(d->serial), ident.SERIAL_NUMBER,
                             kNVMeIdentifyControllerSerialNumberLen);
                    copy_str(d->firmware, sizeof(d->firmware), ident.FW_REVISION,
                             kNVMeIdentifyControllerFirmwareRevisionLen);
                }
                NVMeSMARTData s;
                memset(&s, 0, sizeof(s));
                if ((*ifc)->SMARTReadData(ifc, &s) == KERN_SUCCESS) {
                    d->have_nvme_detail = 1;
                    d->critical_warning = s.CRITICAL_WARNING;
                    d->temperature_k = s.TEMPERATURE;
                    d->spare = s.AVAILABLE_SPARE;
                    d->spare_threshold = s.AVAILABLE_SPARE_THRESHOLD;
                    d->percentage_used = s.PERCENTAGE_USED;
                    d->data_units_read = s.DATA_UNITS_READ[0];
                    d->data_units_written = s.DATA_UNITS_WRITTEN[0];
                    d->host_read_cmds = s.HOST_READ_COMMANDS[0];
                    d->host_write_cmds = s.HOST_WRITE_COMMANDS[0];
                    d->busy_minutes = s.CONTROLLER_BUSY_TIME[0];
                    d->power_cycles = s.POWER_CYCLES[0];
                    d->power_on_hours = s.POWER_ON_HOURS[0];
                    d->unsafe_shutdowns = s.UNSAFE_SHUTDOWNS[0];
                    d->media_errors = s.MEDIA_ERRORS[0];
                    d->error_log_entries = s.NUM_ERROR_INFO_LOG_ENTRIES[0];
                }
                (*ifc)->Release(ifc);
            }
            IODestroyPlugInInterface(plugin);
        }
        IOObjectRelease(svc);
        n++;
    }
    IOObjectRelease(iter);
    return n;
}

// 读取整盘 IOMedia 的属性（SMART 状态 / 内置 / 容量）填入条目。
// 仅接受物理整盘：Whole = yes，且无 UUID 属性（分区、APFS 合成卷、RAID 卷都带 UUID）。
static int media_fill(dh_disk_info_t *d, io_object_t media, const char *bsd) {
    CFTypeRef whole = IORegistryEntryCreateCFProperty(media, CFSTR("Whole"),
                                                      kCFAllocatorDefault, 0);
    if (!whole) return 0;
    int isWhole = (CFGetTypeID(whole) == CFBooleanGetTypeID() &&
                   CFBooleanGetValue((CFBooleanRef)whole));
    CFRelease(whole);
    if (!isWhole) return 0;

    CFTypeRef uuid = IORegistryEntryCreateCFProperty(media, CFSTR("UUID"),
                                                     kCFAllocatorDefault, 0);
    if (uuid) { CFRelease(uuid); return 0; }  // 分区/合成卷/RAID 卷

    CFTypeRef virt = IORegistryEntryCreateCFProperty(media, CFSTR("Virtual"),
                                                     kCFAllocatorDefault, 0);
    if (virt) {
        int isVirtual = (CFGetTypeID(virt) == CFBooleanGetTypeID() &&
                         CFBooleanGetValue((CFBooleanRef)virt));
        CFRelease(virt);
        if (isVirtual) return 0;
    }

    CFStringRef st = IORegistryEntryCreateCFProperty(media, CFSTR("SMART Status"),
                                                     kCFAllocatorDefault, 0);
    CFTypeRef internal = IORegistryEntryCreateCFProperty(media, CFSTR("Internal"),
                                                         kCFAllocatorDefault, 0);
    CFTypeRef size = IORegistryEntryCreateCFProperty(media, CFSTR("Size"),
                                                     kCFAllocatorDefault, 0);
    CFTypeRef devchars = IORegistryEntryCreateCFProperty(media, CFSTR("Device Characteristics"),
                                                         kCFAllocatorDefault, 0);

    if (st) {
        if (CFStringCompare(st, CFSTR("Verified"), 0) == kCFCompareEqualTo)
            d->smart_status = DH_SMART_VERIFIED;
        else if (CFStringCompare(st, CFSTR("Failing"), 0) == kCFCompareEqualTo)
            d->smart_status = DH_SMART_FAILING;
        CFRelease(st);
    }
    if (internal) {
        if (CFGetTypeID(internal) == CFBooleanGetTypeID() &&
            CFBooleanGetValue((CFBooleanRef)internal)) d->is_internal = 1;
        CFRelease(internal);
    }
    if (size && CFGetTypeID(size) == CFNumberGetTypeID()) {
        long long v = 0;
        if (CFNumberGetValue((CFNumberRef)size, kCFNumberLongLongType, &v) && v > 0)
            d->size_bytes = (uint64_t)v;
        CFRelease(size);
    }
    // ATA/SATA 盘从 Device Characteristics 字典补型号与序列号
    if (devchars && CFGetTypeID(devchars) == CFDictionaryGetTypeID()) {
        CFDictionaryRef dc = (CFDictionaryRef)devchars;
        if (!d->model[0]) {
            CFStringRef m = CFDictionaryGetValue(dc, CFSTR("Model"));
            if (m) CFStringGetCString(m, d->model, sizeof(d->model), kCFStringEncodingUTF8);
        }
        if (!d->serial[0]) {
            CFStringRef s = CFDictionaryGetValue(dc, CFSTR("Serial Number"));
            if (s) CFStringGetCString(s, d->serial, sizeof(d->serial), kCFStringEncodingUTF8);
        }
        CFRelease(devchars);
    }

    // 向上最多 6 层父服务找 Device/Protocol Characteristics（USB/SATA 盘的信息在父链上）
    io_object_t cur = media;
    IOObjectRetain(cur);
    for (int up = 0; up < 6; up++) {
        CFTypeRef dc = IORegistryEntryCreateCFProperty(cur, CFSTR("Device Characteristics"),
                                                       kCFAllocatorDefault, 0);
        if (dc && CFGetTypeID(dc) == CFDictionaryGetTypeID()) {
            CFDictionaryRef dict = (CFDictionaryRef)dc;
            char vendor[64] = "", product[64] = "";
            CFStringRef v = CFDictionaryGetValue(dict, CFSTR("Vendor Name"));
            CFStringRef p = CFDictionaryGetValue(dict, CFSTR("Product Name"));
            CFStringRef r = CFDictionaryGetValue(dict, CFSTR("Product Revision Level"));
            if (v) CFStringGetCString(v, vendor, sizeof(vendor), kCFStringEncodingUTF8);
            if (p) CFStringGetCString(p, product, sizeof(product), kCFStringEncodingUTF8);
            // 组合厂商和产品名作为磁盘型号
            if (!d->model[0] && (vendor[0] || product[0]))
                snprintf(d->model, sizeof(d->model), "%s%s%s",
                         vendor, vendor[0] && product[0] ? " " : "", product);
            if (!d->firmware[0] && r)
                CFStringGetCString(r, d->firmware, sizeof(d->firmware), kCFStringEncodingUTF8);
            if (!d->serial[0]) {
                CFStringRef s = CFDictionaryGetValue(dict, CFSTR("Serial Number"));
                if (s) CFStringGetCString(s, d->serial, sizeof(d->serial), kCFStringEncodingUTF8);
            }
            CFRelease(dc);
        }
        if (!d->transport[0]) {
            CFTypeRef pc = IORegistryEntryCreateCFProperty(cur, CFSTR("Protocol Characteristics"),
                                                           kCFAllocatorDefault, 0);
            if (pc && CFGetTypeID(pc) == CFDictionaryGetTypeID()) {
                CFStringRef pi = CFDictionaryGetValue((CFDictionaryRef)pc, CFSTR("Physical Interconnect"));
                if (pi) CFStringGetCString(pi, d->transport, sizeof(d->transport), kCFStringEncodingUTF8);
                CFStringRef pil = CFDictionaryGetValue((CFDictionaryRef)pc, CFSTR("Physical Interconnect Location"));
                if (pil && CFStringCompare(pil, CFSTR("Internal"), 0) == kCFCompareEqualTo)
                    d->is_internal = 1;
                CFRelease(pc);
            }
        }
        io_object_t parent = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(cur);
        cur = parent;
        if (!parent) break;
    }
    if (cur) IOObjectRelease(cur);

    // Apple Fabric 是 Apple 内置 SSD 专用总线，无 Interconnect Location 属性
    if (!d->is_internal && strcmp(d->transport, "Apple Fabric") == 0) d->is_internal = 1;

    if (!d->bsd[0]) strlcpy(d->bsd, bsd, sizeof(d->bsd));
    return 1;
}

// 从整盘 IOMedia 向上找带 "SMART Capable" 的祖先，打开 ATA SMART 接口
// （USB/SATA 盘走内核 SAT 翻译，无需 root）
static io_object_t find_smart_capable_ancestor(io_object_t media) {
    io_object_t cur = media;
    IOObjectRetain(cur);
    for (int up = 0; up < 12; up++) {
        CFTypeRef sc = IORegistryEntryCreateCFProperty(cur, CFSTR(kIOPropertySMARTCapableKey),
                                                       kCFAllocatorDefault, 0);
        if (sc) {
            CFRelease(sc);
            return cur;
        }
        io_object_t parent = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(cur);
        cur = parent;
    }
    if (cur) IOObjectRelease(cur);
    return 0;
}

static void ata_ident_str(char *dst, size_t cap, const uint8_t *src, size_t words) {
    // ATA 字符串按 16 位字字节交换
    uint8_t tmp[64];
    if (words * 2 > sizeof(tmp)) words = sizeof(tmp) / 2;
    memcpy(tmp, src, words * 2);
    for (size_t i = 0; i < words; i++) {
        uint8_t t = tmp[i * 2];
        tmp[i * 2] = tmp[i * 2 + 1];
        tmp[i * 2 + 1] = t;
    }
    size_t end = words * 2 < cap - 1 ? words * 2 : cap - 1, start = 0;
    while (start < end && (tmp[start] == ' ' || tmp[start] == 0)) start++;
    while (end > start && (tmp[end - 1] == ' ' || tmp[end - 1] == 0)) end--;
    memcpy(dst, tmp + start, end - start);
    dst[end - start] = 0;
}

static void parse_ata_attributes(dh_disk_info_t *d, const ATASMARTData *sd) {
    // ATA SMART 的 512 个字节（含校验位）之和模 256 应为零。
    uint8_t checksum = 0;
    const uint8_t *bytes = (const uint8_t *)sd;
    for (size_t i = 0; i < sizeof(*sd); i++) checksum += bytes[i];
    if (checksum != 0) return;

    int tempC = -1;
    for (int i = 0; i < 30; i++) {
        const uint8_t *a = sd->vendorSpecific1 + 2 + 12 * i;
        if (!a[0]) continue;
        uint64_t raw = 0;
        for (int b = 5; b >= 0; b--) raw = (raw << 8) | a[5 + b];
        dh_ata_value_t value = { .raw = raw, .present = 1 };
        switch (a[0]) {
        case 5:   d->ata_realloc_sectors = value; break;
        case 9:   d->ata_power_on_hours = value; break;
        case 12:  d->ata_power_cycles = value; break;
        case 192: d->ata_unsafe_shutdowns = value; break;
        case 197: d->ata_pending_sectors = value; break;
        case 198: d->ata_offline_unc = value; break;
        case 199: d->ata_crc_errors = value; break;
        case 241: d->ata_lba_written = value; break;
        case 242: d->ata_lba_read = value; break;
        case 194: tempC = (int)(raw & 0xFF); break;
        case 190: if (tempC < 0) tempC = (int)(raw & 0xFF); break;
        default: continue;
        }
        d->have_ata_detail = 1;
    }
    if (tempC >= 0) d->temperature_k = (unsigned)(tempC + 273);
}

static void try_ata_smart(dh_disk_info_t *d, io_object_t media) {
    io_object_t svc = find_smart_capable_ancestor(media);
    if (!svc) return;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(svc, kIOATASMARTUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plugin) return;

    IOATASMARTInterface **ifc = NULL;
    if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID),
                                  (LPVOID *)&ifc) != S_OK || !ifc) {
        IODestroyPlugInInterface(plugin);
        return;
    }

    // SMART 结论（Verified / Failing）
    Boolean exceeded = false;
    if ((*ifc)->SMARTReturnStatus(ifc, &exceeded) == kIOReturnSuccess)
        d->smart_status = exceeded ? DH_SMART_FAILING : DH_SMART_VERIFIED;

    // 型号 / 序列号 / 固件（identify 为权威来源）
    UInt8 ident[512];
    UInt32 outSize = 0;
    memset(ident, 0, sizeof(ident));
    if ((*ifc)->GetATAIdentifyData(ifc, ident, sizeof(ident), &outSize) == kIOReturnSuccess &&
        outSize >= 62) {
        ata_ident_str(d->model, sizeof(d->model), ident + 54, 20);
        ata_ident_str(d->serial, sizeof(d->serial), ident + 20, 10);
        ata_ident_str(d->firmware, sizeof(d->firmware), ident + 46, 4);
    }

    // SMART 属性表
    ATASMARTData sd;
    memset(&sd, 0, sizeof(sd));
    if ((*ifc)->SMARTReadData(ifc, &sd) == kIOReturnSuccess)
        parse_ata_attributes(d, &sd);

    (*ifc)->Release(ifc);
    IODestroyPlugInInterface(plugin);
}

// Media 通道：枚举 IOMedia，补 SMART 状态 / 内置标志 / 容量，并纳入 SATA 盘
static void probe_media(dh_disk_info_t *out, int *n, int max) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOMedia"),
                                     &iter) != KERN_SUCCESS)
        return;
    io_object_t media;
    while ((media = IOIteratorNext(iter)) != 0) {
        CFStringRef bn = IORegistryEntryCreateCFProperty(media, CFSTR("BSD Name"),
                                                         kCFAllocatorDefault, 0);
        if (bn) {
            char bsd[32] = "";
            if (CFStringGetCString(bn, bsd, sizeof(bsd), kCFStringEncodingUTF8)) {
                // 先看这块 media 是否为合格的整盘，合格才登记/填充
                for (int i = 0; i < *n; i++) {
                    if (strcmp(out[i].bsd, bsd) == 0) {
                        media_fill(&out[i], media, bsd);
                        if (!out[i].have_nvme_detail) try_ata_smart(&out[i], media);
                        break;
                    }
                }
                // 未登记的整盘（如 SATA 盘）：填进临时槽检查
                if (*n < max) {
                    dh_disk_info_t tmp;
                    memset(&tmp, 0, sizeof(tmp));
                    if (media_fill(&tmp, media, bsd)) {
                        int found = 0;
                        for (int i = 0; i < *n; i++)
                            if (strcmp(out[i].bsd, bsd) == 0) { found = 1; break; }
                        if (!found) {
                            try_ata_smart(&tmp, media);
                            out[(*n)++] = tmp;
                        }
                    }
                }
            }
            CFRelease(bn);
        }
        IOObjectRelease(media);
    }
    IOObjectRelease(iter);
}

int dh_probe_disks(dh_disk_info_t *out, int max) {
    if (!out || max <= 0) return -1;
    memset(out, 0, (size_t)max * sizeof(*out));
    int n = probe_nvme(out, max);
    probe_media(out, &n, max);
    return n;
}
