// What the files of cuda/src share behind the C API (#273): contexts, buffers and errors.
// Included after cuda_cpu.h, before any library's MSL.
#ifndef SILLAGE_ENGINE_H
#define SILLAGE_ENGINE_H

#include <cstddef>

#include "sillage_cuda.h"

struct sc_context {
    int32_t device;
};

struct sc_buffer {
    sc_context *context;
    void *device;
    size_t length;
};

namespace sillage {

// Leaves the message for sc_last_error() and returns the status.
sc_status fail(sc_status status, const char *format, ...) __attribute__((format(printf, 2, 3)));
// SC_OK, or the CUDA runtime's error with what was being done.
sc_status check(cudaError_t error, const char *what);
// Makes the context's device current.
sc_status use(const sc_context *context);
// A buffer of `length` bytes on the context's device, zeroed as Metal's are; NULL on failure,
// with the message left.
sc_buffer *allocate(sc_context *context, size_t length, sc_status *status);
void release(sc_buffer *&buffer);
// Whether `length` bytes from `offset` lie inside the buffer.
bool holds(const sc_buffer *buffer, size_t offset, size_t length);

template <class T>
T *pointer(const sc_buffer *buffer, size_t offset = 0) {
    return buffer ? reinterpret_cast<T *>(static_cast<char *>(buffer->device) + offset) : nullptr;
}

}  // namespace sillage

#endif
