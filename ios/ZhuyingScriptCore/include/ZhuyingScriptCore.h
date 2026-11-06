#ifndef ZHUYING_SCRIPT_CORE_H
#define ZHUYING_SCRIPT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ZYQJS_OK = 0,
    ZYQJS_INVALID_INPUT = 1,
    ZYQJS_SCRIPT_EXCEPTION = 2,
    ZYQJS_TIMED_OUT = 3,
    ZYQJS_CANCELLED = 4,
    ZYQJS_MEMORY_LIMIT = 5,
    ZYQJS_BRIDGE_LIMIT = 6
} ZYQJSStatus;

typedef struct {
    size_t memory_limit_bytes;
    size_t stack_limit_bytes;
    uint64_t timeout_milliseconds;
    size_t maximum_output_bytes;
    size_t maximum_host_calls;
    size_t maximum_bridge_bytes;
} ZYQJSLimits;

/* Return a malloc-owned UTF-8 JSON value (or error message when *is_error=1).
   The bridge frees the returned buffer with free(). Calls are synchronous on
   the evaluating thread. The host must bound and cancel any blocking I/O. */
typedef char *(*ZYQJSHostCallback)(void *opaque, const char *method, const char *arguments_json, int *is_error);
typedef int (*ZYQJSCancelCallback)(void *opaque);

typedef struct {
    ZYQJSStatus status;
    char *json;
    char *message;
} ZYQJSResult;

/* Each call creates and destroys its own runtime. Script completion values are
   returned synchronously; promises and modules are deliberately unsupported. */
ZYQJSResult ZYQuickJSEvaluate(const char *script, size_t script_length,
                            const char *library, size_t library_length,
                            const char *bindings_json, size_t bindings_length,
                            ZYQJSLimits limits, ZYQJSHostCallback host,
                            ZYQJSCancelCallback cancelled, void *opaque);
void ZYQuickJSFreeResult(ZYQJSResult *result);
const char *ZYQuickJSVersion(void);

#ifdef __cplusplus
}
#endif
#endif
