// Cabeçalhos de sistema usados pelo backend Vulkan no Android (ADR 0007/0008).
#ifndef CAJU_CVULKAN_SHIM_H
#define CAJU_CVULKAN_SHIM_H

#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>
#include <android/native_window.h>
#include <android/native_activity.h>
#include <android/input.h>
#include <android/looper.h>
#include <android/log.h>

#endif
