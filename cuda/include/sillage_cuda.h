/* The CUDA engine's C API (#273), which Swift calls through Sources/SillageCUDA. Built twice
 * from the same files of cuda/src: by nvcc for an NVIDIA GPU (libsillagecuda.a) and by a host
 * compiler through cuda_cpu.h for the CPU target (libsillagecuda_cpu.a).
 *
 * Plain C: no C++ type crosses it and nothing is thrown. A call that fails returns a status
 * other than SC_OK and leaves a message for sc_last_error(). Each domain has a header of its
 * own, included at the end. docs/notes/cuda-engine.md. */
#ifndef SILLAGE_CUDA_H
#define SILLAGE_CUDA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum sc_status {
    SC_OK = 0,
    SC_INVALID_ARGUMENT = 1,
    SC_OUT_OF_MEMORY = 2,
    SC_NO_DEVICE = 3,
    /* An error of the CUDA runtime, which sc_last_error() names. */
    SC_CUDA_ERROR = 4,
    /* The CPU target cannot run it: block barriers or warp functions (#283 runs it). */
    SC_GPU_ONLY = 5
} sc_status;

typedef enum sc_target { SC_TARGET_GPU = 0, SC_TARGET_CPU = 1 } sc_target;

/* Which library this is. */
sc_target sc_build_target(void);
const char *sc_status_name(sc_status status);
/* The message of the last call that failed on this thread, "" before any. */
const char *sc_last_error(void);

/* A context per device. Every call runs on the device's default stream and returns once its
 * work is queued; a download waits for the work before it. */
typedef struct sc_context sc_context;

typedef struct sc_device_info {
    char name[256];
    uint64_t memory;
    int32_t major;
    int32_t minor;
    int32_t multiprocessors;
    int32_t warp_size;
} sc_device_info;

sc_status sc_device_count(int32_t *count);
sc_status sc_context_create(int32_t device, sc_context **context);
void sc_context_destroy(sc_context *context);
sc_status sc_context_info(const sc_context *context, sc_device_info *info);
/* Waits for the work queued so far, and reports an error a kernel left behind. */
sc_status sc_context_synchronize(sc_context *context);

/* Device memory. A buffer belongs to its context, which must outlive it. */
typedef struct sc_buffer sc_buffer;

sc_status sc_buffer_create(sc_context *context, size_t length, sc_buffer **buffer);
void sc_buffer_destroy(sc_buffer *buffer);
size_t sc_buffer_length(const sc_buffer *buffer);
sc_status sc_buffer_upload(sc_buffer *buffer, size_t offset, const void *bytes, size_t length);
sc_status sc_buffer_download(const sc_buffer *buffer, size_t offset, void *bytes, size_t length);
sc_status sc_buffer_fill(sc_buffer *buffer, uint8_t value);
sc_status sc_buffer_copy(sc_buffer *target, size_t target_offset, const sc_buffer *source,
                         size_t source_offset, size_t length);

/* Pinned host memory, which uploads and downloads read and write at full speed. */
sc_status sc_host_allocate(sc_context *context, size_t length, void **memory);
void sc_host_free(void *memory);

#ifdef __cplusplus
}
#endif

#include "sillage_cuda_tree.h"
#include "sillage_cuda_render.h"

#endif
