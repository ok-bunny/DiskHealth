// smart_probe.c — 无 root 探测本机 NVMe SMART 健康数据（官方 IOKit CFPlugIn 接口）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

// 把 NVMe identify 里的字符串字段拷成 C 字符串（去掉首尾空格）
static void copy_str(char *dst, size_t dstlen, const uint8_t *src, size_t srclen) {
    size_t n = srclen < dstlen - 1 ? srclen : dstlen - 1;
    size_t start = 0, end = n;
    while (start < end && (src[start] == ' ' || src[start] == 0)) start++;
    while (end > start && (src[end-1] == ' ' || src[end-1] == 0)) end--;
    memcpy(dst, src + start, end - start);
    dst[end - start] = 0;
}

// 128-bit 计数（低 64 位在前），返回低 64 位并顺带打印高位
static unsigned long long cnt128(const uint64_t v[2]) {
    // 忽略高 64 位溢出（几乎不可能达到）
    return (unsigned long long)v[0];
}

// 在控制器子树里找 IOMedia 的 BSD Name（diskN）
static bool find_bsd_name(io_object_t ctrl, char *out, size_t outlen) {
    io_iterator_t it1 = 0, it2 = 0, it3 = 0;
    io_object_t a = 0, b = 0, c = 0;
    bool found = false;
    out[0] = 0;
    kern_return_t kr = IORegistryEntryCreateIterator(ctrl, kIOServicePlane,
                                                     kIORegistryIterateRecursively | kIORegistryIterateParents, &it1);
    // 上面创建的是从 ctrl 开始的递归迭代器（含自身），改为直接遍历 child
    if (it1) IOObjectRelease(it1);
    kr = IORegistryEntryGetChildIterator(ctrl, kIOServicePlane, &it1);
    if (kr != KERN_SUCCESS) return false;
    while (!found && (a = IOIteratorNext(it1)) != 0) {
        kr = IORegistryEntryGetChildIterator(a, kIOServicePlane, &it2);
        if (kr != KERN_SUCCESS) { IOObjectRelease(a); continue; }
        while (!found && (b = IOIteratorNext(it2)) != 0) {
            CFStringRef bn = IORegistryEntryCreateCFProperty(b, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
            if (bn) {
                found = CFStringGetCString(bn, out, (CFIndex)outlen, kCFStringEncodingUTF8);
                CFRelease(bn);
            }
            if (!found) {
                kr = IORegistryEntryGetChildIterator(b, kIOServicePlane, &it3);
                if (kr == KERN_SUCCESS) {
                    while (!found && (c = IOIteratorNext(it3)) != 0) {
                        CFStringRef bn3 = IORegistryEntryCreateCFProperty(c, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                        if (bn3) {
                            found = CFStringGetCString(bn3, out, (CFIndex)outlen, kCFStringEncodingUTF8);
                            CFRelease(bn3);
                        }
                        IOObjectRelease(c);
                    }
                    if (it3) IOObjectRelease(it3); it3 = 0;
                }
            }
            IOObjectRelease(b);
        }
        if (it2) IOObjectRelease(it2); it2 = 0;
        IOObjectRelease(a);
    }
    if (it1) IOObjectRelease(it1);
    return found;
}

int main(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOService");
    if (!match) { fprintf(stderr, "IOServiceMatching failed\n"); return 1; }
    CFMutableDictionaryRef propMatch = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(propMatch, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);
    CFDictionarySetValue(match, CFSTR(kIOPropertyMatchKey), propMatch);
    CFRelease(propMatch);

    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceGetMatchingServices: 0x%x — 未找到 NVMe SMART Capable 设备\n", kr);
        return 1;
    }

    io_object_t svc;
    int idx = 0;
    while ((svc = IOIteratorNext(iter)) != 0) {
        idx++;
        char bsd[64] = "";
        find_bsd_name(svc, bsd, sizeof(bsd));

        char cls[128] = "";
        IOObjectGetClass(svc, cls);
        printf("=== NVMe 设备 #%d (class=%s, bsd=%s) ===\n", idx, cls, bsd[0] ? bsd : "?");

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        // smartmontools 的做法：直接在带 NVMe SMART Capable 属性的服务上，
        // 用 kIONVMeSMARTUserClientTypeID 创建插件接口（无需找父控制器）
        kr = IOCreatePlugInInterfaceForService(svc, kIONVMeSMARTUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != KERN_SUCCESS || !plugin) {
            printf("  打开 SMART 接口失败: 0x%x（可能需要 root 或不受支持）\n", kr);
            IOObjectRelease(svc);
            continue;
        }

        IONVMeSMARTInterface **ifc = NULL;
        HRESULT qr = (*plugin)->QueryInterface(plugin,
                CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&ifc);
        if (qr != S_OK || !ifc) {
            printf("  QueryInterface 失败: %ld\n", (long)qr);
            IODestroyPlugInInterface(plugin);
            IOObjectRelease(svc);
            continue;
        }

        NVMeIdentifyControllerStruct ident;
        memset(&ident, 0, sizeof(ident));
        kr = (*ifc)->GetIdentifyData(ifc, &ident, 0);
        if (kr == KERN_SUCCESS) {
            char model[41] = "", serial[21] = "", fw[9] = "";
            copy_str(model, sizeof(model), ident.MODEL_NUMBER, kNVMeIdentifyControllerModelNumberLen);
            copy_str(serial, sizeof(serial), ident.SERIAL_NUMBER, kNVMeIdentifyControllerSerialNumberLen);
            copy_str(fw, sizeof(fw), ident.FW_REVISION, kNVMeIdentifyControllerFirmwareRevisionLen);
            printf("  型号: %s\n  序列号: %s\n  固件: %s\n", model, serial, fw);
        } else {
            printf("  GetIdentifyData 失败: 0x%x\n", kr);
        }

        NVMeSMARTData d;
        memset(&d, 0, sizeof(d));
        kr = (*ifc)->SMARTReadData(ifc, &d);
        if (kr == KERN_SUCCESS) {
            printf("  --- SMART / Health 日志 ---\n");
            printf("  临界警告(CRITICAL_WARNING): 0x%02x\n", d.CRITICAL_WARNING);
            printf("  温度: %u K (%d °C)\n", d.TEMPERATURE, d.TEMPERATURE - 273);
            printf("  可用备件(AVAILABLE_SPARE): %u %%\n", d.AVAILABLE_SPARE);
            printf("  备件阈值(SPARE_THRESHOLD): %u %%\n", d.AVAILABLE_SPARE_THRESHOLD);
            printf("  已用寿命(PERCENTAGE_USED): %u %%\n", d.PERCENTAGE_USED);
            printf("  读取数据单元(512KB/单元): %llu (≈ %.2f TB)\n", cnt128(d.DATA_UNITS_READ), cnt128(d.DATA_UNITS_READ) * 512000.0 / 1e12);
            printf("  写入数据单元(512KB/单元): %llu (≈ %.2f TB)\n", cnt128(d.DATA_UNITS_WRITTEN), cnt128(d.DATA_UNITS_WRITTEN) * 512000.0 / 1e12);
            printf("  主机读命令: %llu\n", cnt128(d.HOST_READ_COMMANDS));
            printf("  主机写命令: %llu\n", cnt128(d.HOST_WRITE_COMMANDS));
            printf("  控制器忙时间: %llu 分钟\n", cnt128(d.CONTROLLER_BUSY_TIME));
            printf("  通电次数: %llu\n", cnt128(d.POWER_CYCLES));
            printf("  通电时间: %llu 小时\n", cnt128(d.POWER_ON_HOURS));
            printf("  异常断电: %llu 次\n", cnt128(d.UNSAFE_SHUTDOWNS));
            printf("  介质错误(MEDIA_ERRORS): %llu\n", cnt128(d.MEDIA_ERRORS));
            printf("  错误日志条目: %llu\n", cnt128(d.NUM_ERROR_INFO_LOG_ENTRIES));
        } else {
            printf("  SMARTReadData 失败: 0x%x\n", kr);
        }

        (*ifc)->Release(ifc);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(svc);
        printf("\n");
    }
    IOObjectRelease(iter);

    if (idx == 0) printf("未找到任何 NVMe SMART Capable 设备\n");
    return 0;
}
