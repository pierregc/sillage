// Closes a library's MSL text opened by msl_begin.h.
#undef threadgroup
#undef thread
#undef constant
#undef device
#undef SHARED_CONSTANT
#undef SHARED
#if defined(__CUDACC__)
#pragma pop_macro("__device__")
#endif
