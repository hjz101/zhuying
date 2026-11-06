#include "ZhuyingScriptCore.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdalign.h>
#if defined(__APPLE__)
#include <pthread.h>
#endif

typedef struct {
    ZYQJSLimits limits;
    ZYQJSHostCallback host;
    ZYQJSCancelCallback cancelled;
    void *opaque;
    uint64_t deadline;
    size_t host_calls;
    size_t bridge_bytes;
    ZYQJSStatus abort_status;
    int memory_exhausted;
} ZYState;

/* Size accounting includes our headers, including runtime initialization.
   No private QuickJS allocator or interrupt APIs are used. */
typedef union {
    struct { size_t bytes; } allocation;
    max_align_t alignment;
} ZYAllocation;

static void *zy_malloc(JSMallocState *allocator, size_t size) {
    ZYState *state = allocator->opaque;
    size_t used = allocator->malloc_size, limit = state->limits.memory_limit_bytes;
    if (!size || size > SIZE_MAX - sizeof(ZYAllocation) || used > limit || size + sizeof(ZYAllocation) > limit - used) {
        state->memory_exhausted = 1;
        return NULL;
    }
    ZYAllocation *allocation = malloc(sizeof(ZYAllocation) + size);
    if (!allocation) { state->memory_exhausted = 1; return NULL; }
    allocation->allocation.bytes = size;
    allocator->malloc_count++;
    allocator->malloc_size += sizeof(ZYAllocation) + size;
    return allocation + 1;
}

static void zy_free(JSMallocState *allocator, void *pointer) {
    if (!pointer) return;
    ZYAllocation *allocation = (ZYAllocation *)pointer - 1;
    allocator->malloc_count--;
    allocator->malloc_size -= sizeof(ZYAllocation) + allocation->allocation.bytes;
    free(allocation);
}

static void *zy_realloc(JSMallocState *allocator, void *pointer, size_t size) {
    if (!pointer) return zy_malloc(allocator, size);
    if (!size) { zy_free(allocator, pointer); return NULL; }
    ZYState *state = allocator->opaque;
    ZYAllocation *allocation = (ZYAllocation *)pointer - 1;
    size_t previous = allocation->allocation.bytes;
    size_t remaining = allocator->malloc_size - previous;
    if (size > SIZE_MAX - sizeof(ZYAllocation) || remaining > state->limits.memory_limit_bytes ||
        size > state->limits.memory_limit_bytes - remaining) {
        state->memory_exhausted = 1;
        return NULL;
    }
    allocation = realloc(allocation, sizeof(ZYAllocation) + size);
    if (!allocation) { state->memory_exhausted = 1; return NULL; }
    allocation->allocation.bytes = size;
    allocator->malloc_size = remaining + size;
    return allocation + 1;
}

static size_t zy_usable_size(const void *pointer) {
    return pointer ? (((const ZYAllocation *)pointer) - 1)->allocation.bytes : 0;
}

static uint64_t zy_now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000ull + (uint64_t)time.tv_nsec;
}

static int zy_interrupted(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    ZYState *state = opaque;
    if (state->abort_status != ZYQJS_OK) return 1;
    if (state->cancelled && state->cancelled(state->opaque)) state->abort_status = ZYQJS_CANCELLED;
    else if (state->memory_exhausted) state->abort_status = ZYQJS_MEMORY_LIMIT;
    else if (zy_now() >= state->deadline) state->abort_status = ZYQJS_TIMED_OUT;
    return state->abort_status != ZYQJS_OK;
}

static JSValue zy_host(JSContext *context, JSValueConst receiver, int count, JSValueConst *arguments) {
    (void)receiver;
    ZYState *state = JS_GetContextOpaque(context);
    if (zy_interrupted(JS_GetRuntime(context), state)) return JS_ThrowInternalError(context, "script interrupted");
    if (count != 2 || !JS_IsString(arguments[0]) || !JS_IsArray(context, arguments[1]))
        return JS_ThrowTypeError(context, "host expects a method and argument array");
    if (++state->host_calls > state->limits.maximum_host_calls) {
        state->abort_status = ZYQJS_BRIDGE_LIMIT;
        return JS_ThrowInternalError(context, "host call limit exceeded");
    }
    JSValue json = JS_JSONStringify(context, arguments[1], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) return json;
    size_t length = 0, method_length = 0;
    const char *input = JS_ToCStringLen(context, &length, json);
    const char *method = JS_ToCStringLen(context, &method_length, arguments[0]);
    JS_FreeValue(context, json);
    if (!input || !method) {
        if (input) JS_FreeCString(context, input);
        if (method) JS_FreeCString(context, method);
        return JS_EXCEPTION;
    }
    JSValue result = JS_UNDEFINED;
    if (method_length > 128 || length > state->limits.maximum_bridge_bytes - state->bridge_bytes) {
        state->abort_status = ZYQJS_BRIDGE_LIMIT;
        result = JS_ThrowInternalError(context, "host argument limit exceeded");
    } else {
        state->bridge_bytes += length;
        int is_error = 0;
        char *output = state->host ? state->host(state->opaque, method, input, &is_error) : NULL;
        if (zy_interrupted(JS_GetRuntime(context), state)) result = JS_ThrowInternalError(context, "script interrupted");
        else if (!output) result = JS_ThrowInternalError(context, "host returned no value");
        else {
            size_t output_length = strlen(output);
            if (output_length > state->limits.maximum_bridge_bytes - state->bridge_bytes) {
                state->abort_status = ZYQJS_BRIDGE_LIMIT;
                result = JS_ThrowInternalError(context, "host response limit exceeded");
            } else {
                state->bridge_bytes += output_length;
                result = is_error ? JS_ThrowInternalError(context, "%s", output) : JS_ParseJSON(context, output, output_length, "host-result.json");
            }
        }
        free(output);
    }
    JS_FreeCString(context, input);
    JS_FreeCString(context, method);
    return result;
}

static const char *zy_shim =
"(() => {\n"
"  const call = globalThis.__zhuyingHost;\n"
"  const wrap = value => {\n"
"    if (Array.isArray(value)) return value.map(wrap);\n"
"    if (!value || typeof value !== 'object' || typeof value.body !== 'string' || typeof value.statusCode !== 'number') return value;\n"
"    const headers = value.headers || {};\n"
"    return Object.freeze({body:()=>value.body, code:()=>value.statusCode, statusCode:()=>value.statusCode,\n"
"      url:()=>value.url || '', headers:()=>headers, header:name=> { const key=Object.keys(headers).find(k=>k.toLowerCase()===String(name).toLowerCase()); return key===undefined ? null : headers[key]; },\n"
"      toJSON:()=>value});\n"
"  };\n"
"  const methods = ['getVariable','setVariable','getKey','getBookSourceUrl','getBookSourceName','getUrl','getName','getTitle','getAuthor','getTocUrl','getBookUrl','getChapterUrl','getChapterIndex','getIndex','get','put'];\n"
"  const object = (name, value) => new Proxy(value && typeof value==='object' ? value : {}, {\n"
"    get(target,key,receiver) { if (methods.includes(key)) return (...args)=>wrap(call(name+'.'+key,args)); return Reflect.get(target,key,receiver); }\n"
"  });\n"
"  for (const name of ['source','book','chapter']) globalThis[name] = object(name,globalThis[name]);\n"
"  globalThis.java = new Proxy(Object.create(null), {get(target,key) { if (typeof key !== 'string' || key==='then' || key==='toJSON') return undefined; return (...args)=>wrap(call('java.'+key,args)); }});\n"
"  globalThis.cookie = new Proxy(Object.create(null), {get(target,key) { if (typeof key !== 'string' || key==='then' || key==='toJSON') return undefined; return (...args)=>call('cookie.'+key,args); }});\n"
"})();\n";

static void zy_exception(JSContext *context, ZYState *state, ZYQJSResult *result) {
    JSValue error = JS_GetException(context);
    const char *message = JS_ToCString(context, error);
    result->status = state->abort_status != ZYQJS_OK ? state->abort_status : state->memory_exhausted ? ZYQJS_MEMORY_LIMIT : ZYQJS_SCRIPT_EXCEPTION;
    if (message) {
        size_t message_limit = state->limits.maximum_output_bytes < 16384 ? state->limits.maximum_output_bytes : 16384;
        size_t message_length = strnlen(message, message_limit);
        while (message_length && (((unsigned char)message[message_length] & 0xc0) == 0x80)) message_length--;
        result->message = strndup(message, message_length);
        JS_FreeCString(context, message);
    }
    else result->message = strdup("JavaScript evaluation failed");
    JS_FreeValue(context, error);
}

static int zy_evaluate(JSContext *context, ZYState *state, const char *script, size_t length, const char *name, JSValue *value, ZYQJSResult *result) {
    *value = JS_Eval(context, script, length, name, JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(*value)) { zy_exception(context, state, result); return 0; }
    return 1;
}

ZYQJSResult ZYQuickJSEvaluate(const char *script, size_t script_length,
                            const char *library, size_t library_length,
                            const char *bindings_json, size_t bindings_length,
                            ZYQJSLimits limits, ZYQJSHostCallback host,
                            ZYQJSCancelCallback cancelled, void *opaque) {
    ZYQJSResult result = {ZYQJS_OK, NULL, NULL};
    if (!script || !library || !bindings_json || limits.memory_limit_bytes < 256 * 1024 ||
        limits.stack_limit_bytes < 64 * 1024 || !limits.timeout_milliseconds || limits.timeout_milliseconds > 30000 ||
        !limits.maximum_output_bytes || !limits.maximum_bridge_bytes) {
        result.status = ZYQJS_INVALID_INPUT; return result;
    }
    ZYState state = {.limits = limits, .host = host, .cancelled = cancelled, .opaque = opaque,
                     .deadline = zy_now() + limits.timeout_milliseconds * 1000000ull};
    if (zy_interrupted(NULL, &state)) { result.status = state.abort_status; return result; }
    const JSMallocFunctions allocator = {zy_malloc, zy_free, zy_realloc, zy_usable_size};
    JSRuntime *runtime = JS_NewRuntime2(&allocator, &state);
    if (!runtime) { result.status = ZYQJS_MEMORY_LIMIT; return result; }
    JS_SetMemoryLimit(runtime, limits.memory_limit_bytes);
    size_t stack_limit = limits.stack_limit_bytes;
#if defined(__APPLE__)
    // Dispatch/Swift worker stacks can be smaller than the requested budget.
    // Leave room below QuickJS for native callbacks and exception unwinding.
    uintptr_t stack_top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t thread_stack = pthread_get_stacksize_np(pthread_self());
    uintptr_t stack_bottom = stack_top - thread_stack;
    uintptr_t current_stack = (uintptr_t)&state;
    if (current_stack > stack_bottom && current_stack < stack_top) {
        size_t available = current_stack - stack_bottom;
        size_t safe = available > 128 * 1024 ? available - 128 * 1024 : available / 2;
        if (safe < stack_limit) stack_limit = safe;
    }
#endif
    JS_SetMaxStackSize(runtime, stack_limit);
    JS_SetCanBlock(runtime, 0); // Atomics.wait must never bypass the interrupt deadline.
    JS_SetInterruptHandler(runtime, zy_interrupted, &state);
    JSContext *context = JS_NewContext(runtime);
    if (!context) { JS_FreeRuntime(runtime); result.status = ZYQJS_MEMORY_LIMIT; return result; }
    JS_SetContextOpaque(context, &state);
    JSValue global = JS_GetGlobalObject(context), value = JS_UNDEFINED;
    JSValue bindings = JS_ParseJSON(context, bindings_json, bindings_length, "bindings.json");
    if (JS_IsException(bindings)) { zy_exception(context, &state, &result); goto done; }
    if (!JS_IsObject(bindings) || JS_IsArray(context, bindings)) {
        JS_FreeValue(context, bindings); result.status = ZYQJS_INVALID_INPUT; goto done;
    }
    JSPropertyEnum *properties = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(context, &properties, &count, bindings, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        JS_FreeValue(context, bindings); zy_exception(context, &state, &result); goto done;
    }
    int failed = 0;
    for (uint32_t index = 0; index < count; index++) {
        JSValue property = JS_GetProperty(context, bindings, properties[index].atom);
        if (JS_IsException(property) || JS_DefinePropertyValue(context, global, properties[index].atom, property, JS_PROP_C_W_E) < 0) failed = 1;
        JS_FreeAtom(context, properties[index].atom);
    }
    js_free(context, properties);
    JS_FreeValue(context, bindings);
    if (failed) { zy_exception(context, &state, &result); goto done; }
    if (JS_DefinePropertyValueStr(context, global, "__zhuyingHost", JS_NewCFunction(context, zy_host, "host", 2), 0) < 0) {
        zy_exception(context, &state, &result); goto done;
    }
    if (!zy_evaluate(context, &state, zy_shim, strlen(zy_shim), "legado-host.js", &value, &result)) goto done;
    JS_FreeValue(context, value); value = JS_UNDEFINED;
    if (library_length) {
        if (!zy_evaluate(context, &state, library, library_length, "source-library.js", &value, &result)) goto done;
        JS_FreeValue(context, value); value = JS_UNDEFINED;
    }
    if (!zy_evaluate(context, &state, script, script_length, "source-rule.js", &value, &result)) goto done;
    if (JS_IsObject(value) && JS_PromiseState(context, value) != (JSPromiseStateEnum)-1) {
        result.status = ZYQJS_SCRIPT_EXCEPTION; result.message = strdup("Asynchronous results are not supported by the synchronous Legado host"); goto done;
    }
    if (JS_IsUndefined(value)) result.json = strdup("null");
    else {
        JSValue json = JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsException(json)) { zy_exception(context, &state, &result); goto done; }
        if (!JS_IsString(json)) { JS_FreeValue(context, json); result.status = ZYQJS_SCRIPT_EXCEPTION; result.message = strdup("The script result cannot be represented as JSON"); goto done; }
        size_t length = 0;
        const char *bytes = JS_ToCStringLen(context, &length, json);
        if (!bytes) { JS_FreeValue(context, json); zy_exception(context, &state, &result); goto done; }
        if (length > limits.maximum_output_bytes) result.status = ZYQJS_BRIDGE_LIMIT;
        else result.json = strdup(bytes);
        JS_FreeCString(context, bytes); JS_FreeValue(context, json);
    }
    if (zy_interrupted(runtime, &state)) result.status = state.abort_status;
    else if (state.memory_exhausted) result.status = ZYQJS_MEMORY_LIMIT;
    else if (result.status == ZYQJS_OK && !result.json) result.status = ZYQJS_MEMORY_LIMIT;
done:
    JS_FreeValue(context, value);
    JS_FreeValue(context, global);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return result;
}

void ZYQuickJSFreeResult(ZYQJSResult *result) {
    if (!result) return;
    free(result->json); free(result->message);
    result->json = NULL; result->message = NULL;
}

const char *ZYQuickJSVersion(void) { return "2026-06-04"; }
