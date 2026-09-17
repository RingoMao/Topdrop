// Adapted from the local codex-keyboard-traffic-light host client (July 2026).
// See docs/KEYBOARD_LIGHT.md for provenance and protocol boundaries.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define QMK_RAW_USAGE_PAGE 0xFF60
#define QMK_RAW_USAGE 0x61
#define RAW_HID_PACKET_SIZE 32
#define MAX_TARGETS 8

#define VIA_ID_CUSTOM_SET_VALUE 0x07
#define VIA_RGB_MATRIX_CHANNEL 0x03
#define VIA_RGB_MATRIX_BRIGHTNESS 0x01
#define VIA_RGB_MATRIX_EFFECT 0x02
#define VIA_RGB_MATRIX_EFFECT_SPEED 0x03
#define VIA_RGB_MATRIX_COLOR 0x04

typedef enum {
    EFFECT_NONE = 0,
    EFFECT_SOLID,
    EFFECT_BREATHING,
    EFFECT_BAND_SPIRAL_VAL,
    EFFECT_SPLASH,
} effect_kind_t;

typedef struct {
    const char *name;
    uint16_t vendor_id;
    uint16_t product_id;
    uint8_t solid;
    uint8_t breathing;
    uint8_t band_spiral_val;
    uint8_t splash;
} keyboard_profile_t;

typedef struct {
    uint8_t enabled;
    effect_kind_t effect;
    uint8_t hue;
    uint8_t saturation;
    uint8_t brightness;
    uint8_t speed;
    effect_kind_t final_effect;
    uint8_t transition_seconds;
} color_t;

typedef struct {
    IOHIDDeviceRef device;
    const keyboard_profile_t *profile;
} target_t;

// Keychron Q11 ships a reduced effect table, so VIA IDs are remapped.
static const keyboard_profile_t PROFILE_Q11 = {
    .name = "Keychron Q11 ANSI",
    .vendor_id = 0x3434,
    .product_id = 0x01E0,
    .solid = 0x01,
    .breathing = 0x02,
    .band_spiral_val = 0x03,
    .splash = 0x15,
};

// ZUOHE ST68 uses the full VIA RGB-matrix effect list from st68.json.
static const keyboard_profile_t PROFILE_ST68 = {
    .name = "ZUOHE ST68",
    .vendor_id = 0x342D,
    .product_id = 0xE4CE,
    .solid = 0x01,
    .breathing = 0x05,
    .band_spiral_val = 0x0B,
    .splash = 0x29,
};

static const keyboard_profile_t *PROFILES[] = {
    &PROFILE_Q11,
    &PROFILE_ST68,
};

static IOReturn hid_manager_open_result = kIOReturnSuccess;
static CFIndex hid_matching_device_count = 0;
static long hid_registry_device_count = 0;

static long number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return -1;
    }
    long result = -1;
    CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    return result;
}

static long registry_number_property(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, key, kCFAllocatorDefault, kNilOptions);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        if (value) {
            CFRelease(value);
        }
        return -1;
    }
    long result = -1;
    CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    CFRelease(value);
    return result;
}

static const keyboard_profile_t *profile_for_ids(long vendor, long product) {
    for (size_t i = 0; i < sizeof(PROFILES) / sizeof(PROFILES[0]); ++i) {
        if (PROFILES[i]->vendor_id == vendor && PROFILES[i]->product_id == product) {
            return PROFILES[i];
        }
    }
    return NULL;
}

static uint8_t map_effect(const keyboard_profile_t *profile, effect_kind_t kind) {
    switch (kind) {
        case EFFECT_SOLID:
            return profile->solid;
        case EFFECT_BREATHING:
            return profile->breathing;
        case EFFECT_BAND_SPIRAL_VAL:
            return profile->band_spiral_val;
        case EFFECT_SPLASH:
            return profile->splash;
        case EFFECT_NONE:
        default:
            return 0;
    }
}

static bool target_already_added(const target_t *targets, size_t count, IOHIDDeviceRef device) {
    for (size_t i = 0; i < count; ++i) {
        if (targets[i].device == device) {
            return true;
        }
    }
    return false;
}

static size_t collect_targets_registry(target_t *targets, size_t capacity) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator);
    if (status != KERN_SUCCESS) {
        return 0;
    }

    size_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        long vendor = registry_number_property(service, CFSTR(kIOHIDVendorIDKey));
        long product = registry_number_property(service, CFSTR(kIOHIDProductIDKey));
        long page = registry_number_property(service, CFSTR(kIOHIDPrimaryUsagePageKey));
        long usage = registry_number_property(service, CFSTR(kIOHIDPrimaryUsageKey));
        const keyboard_profile_t *profile = profile_for_ids(vendor, product);
        if (profile) {
            ++hid_registry_device_count;
        }
        if (profile && page == QMK_RAW_USAGE_PAGE && usage == QMK_RAW_USAGE && count < capacity) {
            IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
            if (device && !target_already_added(targets, count, device)) {
                targets[count].device = device;
                targets[count].profile = profile;
                ++count;
            } else if (device) {
                CFRelease(device);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

static size_t collect_targets_manager(target_t *targets, size_t capacity, size_t already) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) {
        return already;
    }

    CFMutableArrayRef matches = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < sizeof(PROFILES) / sizeof(PROFILES[0]); ++i) {
        int vendor = PROFILES[i]->vendor_id;
        int product = PROFILES[i]->product_id;
        int usage_page = QMK_RAW_USAGE_PAGE;
        int usage = QMK_RAW_USAGE;
        CFNumberRef vendor_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
        CFNumberRef product_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
        CFNumberRef usage_page_number =
            CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage_page);
        CFNumberRef usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        const void *keys[] = {
            CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey),
            CFSTR(kIOHIDPrimaryUsagePageKey), CFSTR(kIOHIDPrimaryUsageKey)};
        const void *values[] = {
            vendor_number, product_number, usage_page_number, usage_number};
        CFDictionaryRef matching = CFDictionaryCreate(
            kCFAllocatorDefault, keys, values, 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(matches, matching);
        CFRelease(matching);
        CFRelease(vendor_number);
        CFRelease(product_number);
        CFRelease(usage_page_number);
        CFRelease(usage_number);
    }

    IOHIDManagerSetDeviceMatchingMultiple(manager, matches);
    IOReturn open_result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    hid_manager_open_result = open_result;
    CFSetRef devices = open_result == kIOReturnSuccess ? IOHIDManagerCopyDevices(manager) : NULL;
    size_t count = already;

    if (devices) {
        CFIndex set_count = CFSetGetCount(devices);
        hid_matching_device_count = set_count;
        IOHIDDeviceRef *items = calloc((size_t)set_count, sizeof(*items));
        if (items) {
            CFSetGetValues(devices, (const void **)items);
            for (CFIndex i = 0; i < set_count && count < capacity; ++i) {
                long vendor = number_property(items[i], CFSTR(kIOHIDVendorIDKey));
                long product = number_property(items[i], CFSTR(kIOHIDProductIDKey));
                long page = number_property(items[i], CFSTR(kIOHIDPrimaryUsagePageKey));
                long usage = number_property(items[i], CFSTR(kIOHIDPrimaryUsageKey));
                long output_size =
                    number_property(items[i], CFSTR(kIOHIDMaxOutputReportSizeKey));
                const keyboard_profile_t *profile = profile_for_ids(vendor, product);
                if (!profile) {
                    continue;
                }
                if (!((page == QMK_RAW_USAGE_PAGE && usage == QMK_RAW_USAGE) ||
                      output_size == RAW_HID_PACKET_SIZE)) {
                    continue;
                }
                if (target_already_added(targets, count, items[i])) {
                    continue;
                }
                CFRetain(items[i]);
                targets[count].device = items[i];
                targets[count].profile = profile;
                ++count;
            }
            free(items);
        }
        CFRelease(devices);
    }

    CFRelease(matches);
    CFRelease(manager);
    return count;
}

static size_t collect_targets(target_t *targets, size_t capacity) {
    size_t count = collect_targets_registry(targets, capacity);
    if (count == 0) {
        count = collect_targets_manager(targets, capacity, 0);
    }
    return count;
}

static void release_targets(target_t *targets, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        CFRelease(targets[i].device);
        targets[i].device = NULL;
        targets[i].profile = NULL;
    }
}

static bool parse_byte(const char *text, uint8_t *result) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 0);
    if (errno || !end || end == text || *end || value < 0 || value > 255) {
        return false;
    }
    *result = (uint8_t)value;
    return true;
}

static bool parse_color(int argc, char **argv, color_t *color) {
    if (argc == 2) {
        if (strcmp(argv[1], "working") == 0 || strcmp(argv[1], "yellow") == 0) {
            // #ff6a10 warm orange-yellow with band spiral value.
            *color = (color_t){
                1, EFFECT_BAND_SPIRAL_VAL, 16, 239, 255, 80, EFFECT_NONE, 0};
            return true;
        }
        if (strcmp(argv[1], "attention") == 0 || strcmp(argv[1], "red") == 0) {
            // Alert with three seconds of max-speed breathing, then solid #ff154c.
            *color = (color_t){
                1, EFFECT_BREATHING, 245, 234, 255, 255, EFFECT_SOLID, 3};
            return true;
        }
        if (strcmp(argv[1], "attention-solid") == 0) {
            // Internal daemon reassertion: retain attention without replaying its alert.
            *color = (color_t){
                1, EFFECT_SOLID, 245, 234, 255, 0, EFFECT_NONE, 0};
            return true;
        }
        if (strcmp(argv[1], "done") == 0 || strcmp(argv[1], "green") == 0) {
            // #82ffc9 mint green with splash.
            *color = (color_t){
                1, EFFECT_SPLASH, 109, 125, 255, 40, EFFECT_NONE, 0};
            return true;
        }
        if (strcmp(argv[1], "off") == 0) {
            *color = (color_t){0};
            return true;
        }
    }

    if (argc == 5 && strcmp(argv[1], "hsv") == 0) {
        color->enabled = 1;
        color->effect = EFFECT_SOLID;
        color->brightness = 255;
        return parse_byte(argv[2], &color->hue) &&
               parse_byte(argv[3], &color->saturation) &&
               parse_byte(argv[4], &color->brightness);
    }
    return false;
}

static IOReturn send_packet(
    IOHIDDeviceRef device, uint8_t field, uint8_t value_a, uint8_t value_b, bool use_b) {
    uint8_t packet[RAW_HID_PACKET_SIZE] = {0};
    packet[0] = VIA_ID_CUSTOM_SET_VALUE;
    packet[1] = VIA_RGB_MATRIX_CHANNEL;
    packet[2] = field;
    packet[3] = value_a;
    if (use_b) {
        packet[4] = value_b;
    }
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, sizeof(packet));
}

static IOReturn apply_color_to_target(const target_t *target, const color_t *color) {
    IOReturn result = IOHIDDeviceOpen(target->device, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        return result;
    }

    if (color->enabled) {
        result = send_packet(
            target->device, VIA_RGB_MATRIX_COLOR, color->hue, color->saturation, true);
        if (result == kIOReturnSuccess) {
            usleep(5000);
            result = send_packet(
                target->device, VIA_RGB_MATRIX_BRIGHTNESS, color->brightness, 0, false);
        }
        if (result == kIOReturnSuccess && color->effect != EFFECT_SOLID) {
            usleep(5000);
            result = send_packet(
                target->device, VIA_RGB_MATRIX_EFFECT_SPEED, color->speed, 0, false);
        }
    }

    if (result == kIOReturnSuccess) {
        usleep(5000);
        uint8_t effect =
            color->enabled ? map_effect(target->profile, color->effect) : 0;
        result = send_packet(target->device, VIA_RGB_MATRIX_EFFECT, effect, 0, false);
    }

    IOHIDDeviceClose(target->device, kIOHIDOptionsTypeNone);
    return result;
}

static IOReturn apply_final_effect(const target_t *target, const color_t *color) {
    IOReturn result = IOHIDDeviceOpen(target->device, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        return result;
    }
    uint8_t effect = map_effect(target->profile, color->final_effect);
    result = send_packet(target->device, VIA_RGB_MATRIX_EFFECT, effect, 0, false);
    IOHIDDeviceClose(target->device, kIOHIDOptionsTypeNone);
    return result;
}

static void usage(const char *program) {
    fprintf(stderr,
            "Usage: %s working|attention|done|off\n"
            "       %s hsv HUE SATURATION BRIGHTNESS\n"
            "       %s --probe\n",
            program, program, program);
}

int main(int argc, char **argv) {
    bool probe = argc == 2 && strcmp(argv[1], "--probe") == 0;
    color_t color = {0};
    if (!probe && !parse_color(argc, argv, &color)) {
        usage(argv[0]);
        return 64;
    }

    target_t targets[MAX_TARGETS] = {0};
    size_t count = collect_targets(targets, MAX_TARGETS);
    if (count == 0) {
        fprintf(stderr,
                "No supported VIA raw-HID keyboards found "
                "(Q11 3434:01E0 or ST68 342D:E4CE, usage FF60:61; "
                "registry devices %ld, manager 0x%08x, matching devices %ld).\n",
                hid_registry_device_count, hid_manager_open_result,
                (long)hid_matching_device_count);
        return 69;
    }

    if (probe) {
        for (size_t i = 0; i < count; ++i) {
            printf("Found %s VIA raw-HID interface %04X:%04X (usage FF60:61).\n",
                   targets[i].profile->name,
                   targets[i].profile->vendor_id,
                   targets[i].profile->product_id);
        }
        release_targets(targets, count);
        return 0;
    }

    IOReturn result = kIOReturnSuccess;
    size_t applied = 0;
    for (size_t i = 0; i < count; ++i) {
        IOReturn device_result = apply_color_to_target(&targets[i], &color);
        if (device_result == kIOReturnSuccess) {
            ++applied;
        } else {
            result = device_result;
            fprintf(stderr,
                    "Failed to update %s (IOReturn 0x%08x).\n",
                    targets[i].profile->name,
                    device_result);
        }
    }

    if (applied > 0 && color.transition_seconds > 0) {
        sleep(color.transition_seconds);
        for (size_t i = 0; i < count; ++i) {
            IOReturn device_result = apply_final_effect(&targets[i], &color);
            if (device_result != kIOReturnSuccess) {
                result = device_result;
                fprintf(stderr,
                        "Failed to settle %s after attention pulse (IOReturn 0x%08x).\n",
                        targets[i].profile->name,
                        device_result);
            }
        }
    }

    release_targets(targets, count);
    if (applied == 0) {
        fprintf(stderr, "Failed to send VIA RGB-matrix packet (IOReturn 0x%08x).\n", result);
        return 74;
    }
    return result == kIOReturnSuccess && applied == count ? 0 : 74;
}
