// Errors, contexts, buffers and pinned memory of the C API (#273).
#include "cuda_cpu.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>

#include "engine.h"

namespace sillage {

static thread_local std::string lastError;

sc_status fail(sc_status status, const char *format, ...) {
    char message[1024];
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    lastError = message;
    return status;
}

sc_status check(cudaError_t error, const char *what) {
    if (error == cudaSuccess) { return SC_OK; }
    sc_status status = SC_CUDA_ERROR;
    if (error == cudaErrorMemoryAllocation) { status = SC_OUT_OF_MEMORY; }
    if (error == cudaErrorNoDevice) { status = SC_NO_DEVICE; }
#if !defined(SILLAGE_CPU)
    if (error == cudaErrorInsufficientDriver) { status = SC_NO_DEVICE; }
#endif
    return fail(status, "%s: %s: %s", what, cudaGetErrorName(error), cudaGetErrorString(error));
}

sc_status use(const sc_context *context) {
    if (!context) { return fail(SC_INVALID_ARGUMENT, "no context"); }
    return check(cudaSetDevice(context->device), "cudaSetDevice");
}

sc_buffer *allocate(sc_context *context, size_t length, sc_status *status) {
    *status = use(context);
    if (*status != SC_OK) { return nullptr; }
    // Never empty, as Metal's are not: a kernel may be handed a buffer it does not read.
    size_t bytes = length < 16 ? 16 : length;
    void *memory = nullptr;
    *status = check(cudaMalloc(&memory, bytes), "cudaMalloc");
    if (*status != SC_OK) { return nullptr; }
    *status = check(cudaMemset(memory, 0, bytes), "cudaMemset");
    sc_buffer *buffer = *status == SC_OK ? new (std::nothrow) sc_buffer{context, memory, length} : nullptr;
    if (!buffer) {
        cudaFree(memory);
        if (*status == SC_OK) { *status = fail(SC_OUT_OF_MEMORY, "no host memory for a buffer"); }
    }
    return buffer;
}

void release(sc_buffer *&buffer) {
    if (!buffer) { return; }
    cudaSetDevice(buffer->context->device);
    cudaFree(buffer->device);
    delete buffer;
    buffer = nullptr;
}

bool holds(const sc_buffer *buffer, size_t offset, size_t length) {
    return buffer && offset <= buffer->length && length <= buffer->length - offset;
}

}  // namespace sillage

using namespace sillage;

extern "C" {

sc_target sc_build_target(void) {
#if defined(SILLAGE_CPU)
    return SC_TARGET_CPU;
#else
    return SC_TARGET_GPU;
#endif
}

const char *sc_status_name(sc_status status) {
    switch (status) {
        case SC_OK: return "SC_OK";
        case SC_INVALID_ARGUMENT: return "SC_INVALID_ARGUMENT";
        case SC_OUT_OF_MEMORY: return "SC_OUT_OF_MEMORY";
        case SC_NO_DEVICE: return "SC_NO_DEVICE";
        case SC_CUDA_ERROR: return "SC_CUDA_ERROR";
        case SC_GPU_ONLY: return "SC_GPU_ONLY";
    }
    return "unknown status";
}

const char *sc_last_error(void) { return lastError.c_str(); }

sc_status sc_device_count(int32_t *count) {
    if (!count) { return fail(SC_INVALID_ARGUMENT, "sc_device_count: no count to write"); }
    int devices = 0;
    sc_status status = check(cudaGetDeviceCount(&devices), "cudaGetDeviceCount");
    cudaGetLastError();
    *count = status == SC_OK ? devices : 0;
    return status;
}

sc_status sc_context_create(int32_t device, sc_context **context) {
    if (!context) { return fail(SC_INVALID_ARGUMENT, "sc_context_create: no context to write"); }
    *context = nullptr;
    int32_t devices = 0;
    if (sc_status status = sc_device_count(&devices)) { return status; }
    if (device < 0 || device >= devices) {
        return fail(SC_NO_DEVICE, "sc_context_create: no device %d, %d found", device, devices);
    }
    if (sc_status status = check(cudaSetDevice(device), "cudaSetDevice")) { return status; }
    // Creates the device's context now, so that a broken driver says so here.
    if (sc_status status = check(cudaFree(nullptr), "creating the device's context")) { return status; }
    *context = new (std::nothrow) sc_context{device};
    return *context ? SC_OK : fail(SC_OUT_OF_MEMORY, "no host memory for a context");
}

void sc_context_destroy(sc_context *context) { delete context; }

sc_status sc_context_info(const sc_context *context, sc_device_info *info) {
    if (!info) { return fail(SC_INVALID_ARGUMENT, "sc_context_info: no info to write"); }
    if (sc_status status = use(context)) { return status; }
    std::memset(info, 0, sizeof *info);
#if defined(SILLAGE_CPU)
    std::snprintf(info->name, sizeof info->name, "the CPU target (cuda_cpu.h)");
    info->multiprocessors = 1;
    info->warp_size = 1;
#else
    cudaDeviceProp properties;
    if (sc_status status = check(cudaGetDeviceProperties(&properties, context->device), "cudaGetDeviceProperties")) {
        return status;
    }
    std::snprintf(info->name, sizeof info->name, "%s", properties.name);
    info->memory = properties.totalGlobalMem;
    info->major = properties.major;
    info->minor = properties.minor;
    info->multiprocessors = properties.multiProcessorCount;
    info->warp_size = properties.warpSize;
#endif
    return SC_OK;
}

sc_status sc_context_synchronize(sc_context *context) {
    if (sc_status status = use(context)) { return status; }
    if (sc_status status = check(cudaDeviceSynchronize(), "cudaDeviceSynchronize")) { return status; }
    return check(cudaGetLastError(), "a kernel");
}

sc_status sc_buffer_create(sc_context *context, size_t length, sc_buffer **buffer) {
    if (!buffer) { return fail(SC_INVALID_ARGUMENT, "sc_buffer_create: no buffer to write"); }
    sc_status status = SC_OK;
    *buffer = allocate(context, length, &status);
    return status;
}

void sc_buffer_destroy(sc_buffer *buffer) { release(buffer); }

size_t sc_buffer_length(const sc_buffer *buffer) { return buffer ? buffer->length : 0; }

sc_status sc_buffer_upload(sc_buffer *buffer, size_t offset, const void *bytes, size_t length) {
    if (!holds(buffer, offset, length) || (length > 0 && !bytes)) {
        return fail(SC_INVALID_ARGUMENT, "sc_buffer_upload: %zu bytes at %zu do not fit a buffer of %zu",
                    length, offset, sc_buffer_length(buffer));
    }
    if (length == 0) { return SC_OK; }
    if (sc_status status = use(buffer->context)) { return status; }
    return check(cudaMemcpy(pointer<char>(buffer, offset), bytes, length, cudaMemcpyHostToDevice),
                 "sc_buffer_upload");
}

sc_status sc_buffer_download(const sc_buffer *buffer, size_t offset, void *bytes, size_t length) {
    if (!holds(buffer, offset, length) || (length > 0 && !bytes)) {
        return fail(SC_INVALID_ARGUMENT, "sc_buffer_download: %zu bytes at %zu do not fit a buffer of %zu",
                    length, offset, sc_buffer_length(buffer));
    }
    if (length == 0) { return SC_OK; }
    if (sc_status status = use(buffer->context)) { return status; }
    return check(cudaMemcpy(bytes, pointer<char>(buffer, offset), length, cudaMemcpyDeviceToHost),
                 "sc_buffer_download");
}

sc_status sc_buffer_fill(sc_buffer *buffer, uint8_t value) {
    if (!buffer) { return fail(SC_INVALID_ARGUMENT, "sc_buffer_fill: no buffer"); }
    if (sc_status status = use(buffer->context)) { return status; }
    return check(cudaMemset(buffer->device, value, buffer->length), "sc_buffer_fill");
}

sc_status sc_buffer_copy(sc_buffer *target, size_t target_offset, const sc_buffer *source,
                         size_t source_offset, size_t length) {
    if (!holds(target, target_offset, length) || !holds(source, source_offset, length)) {
        return fail(SC_INVALID_ARGUMENT, "sc_buffer_copy: %zu bytes do not fit the buffers", length);
    }
    if (target->context != source->context) {
        return fail(SC_INVALID_ARGUMENT, "sc_buffer_copy: the buffers belong to two contexts");
    }
    if (length == 0) { return SC_OK; }
    if (sc_status status = use(target->context)) { return status; }
    return check(cudaMemcpy(pointer<char>(target, target_offset), pointer<char>(source, source_offset),
                            length, cudaMemcpyDeviceToDevice),
                 "sc_buffer_copy");
}

sc_status sc_host_allocate(sc_context *context, size_t length, void **memory) {
    if (!memory) { return fail(SC_INVALID_ARGUMENT, "sc_host_allocate: no memory to write"); }
    *memory = nullptr;
    if (sc_status status = use(context)) { return status; }
    return check(cudaMallocHost(memory, length < 1 ? 1 : length), "cudaMallocHost");
}

void sc_host_free(void *memory) {
    if (memory) { cudaFreeHost(memory); }
}

}  // extern "C"
