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

static int zy_interactive_method(const char *method) {
    // These synchronous hosts wait for the reader, rather than execute script
    // or network work. The host owns its own interaction timeout/cancellation.
    static const char *methods[] = {"java.startBrowserAwait", "java.showBrowser", "java.startBrowser",
        "java.showReadingBrowser", "java.startBrowserDp", "java.reLoginView"};
    for (size_t index = 0; index < sizeof(methods) / sizeof(methods[0]); index++)
        if (!strcmp(method, methods[index])) return 1;
    return 0;
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
        int interactive = zy_interactive_method(method);
        uint64_t started = interactive ? zy_now() : 0;
        char *output = state->host ? state->host(state->opaque, method, input, &is_error) : NULL;
        if (interactive) {
            uint64_t elapsed = zy_now() - started;
            state->deadline = elapsed > UINT64_MAX - state->deadline ? UINT64_MAX : state->deadline + elapsed;
        }
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
                // A cancelled/expired UI interaction must also invalidate a
                // persistent scope when a source catches the host exception.
                if (interactive && is_error) state->abort_status = ZYQJS_SCRIPT_EXCEPTION;
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
"  const nativeEval = eval;\n"
"  const ruleEval = nativeEval('(function(eval,__zhuyingProgram){return eval(__zhuyingProgram);})');\n"
"  let current = {}, names = [];\n"
"  const reserved = new Set(['source','book','chapter','java','cookie','cache','Packages']);\n"
"  const data = name => current[name] && typeof current[name] === 'object' ? current[name] : {};\n"
"  const wrap = value => {\n"
"    if (Array.isArray(value)) return value.map(wrap);\n"
"    if (!value || typeof value !== 'object' || typeof value.body !== 'string' || typeof value.statusCode !== 'number') return value;\n"
"    const headers = value.headers || {};\n"
"    return Object.freeze({body:()=>value.body, code:()=>value.statusCode, statusCode:()=>value.statusCode,\n"
"      url:()=>value.url || '', headers:()=>headers, header:name=> { const key=Object.keys(headers).find(k=>k.toLowerCase()===String(name).toLowerCase()); return key===undefined ? null : headers[key]; }, toJSON:()=>value});\n"
"  };\n"
"  const methods = new Set(['getVariable','setVariable','putVariable','getKey','getBookSourceUrl','getBookSourceName','getUrl','getName','getTitle','getAuthor','getTocUrl','getBookUrl','getChapterUrl','getChapterIndex','getIndex','get','put','getLoginInfo','getLoginInfoMap','putLoginInfo','getLoginHeader','putLoginHeader','setLoginHeader','getHeaderMap','deleteLoginInfo']);\n"
"  const object = name => new Proxy(Object.create(null), {\n"
"    get(target,key) {\n"
"      if (key==='toJSON') return ()=>data(name);\n"
"      if (typeof key==='string' && (methods.has(key) || /^(get|set|put|delete)[A-Z]/.test(key))) return (...args)=>wrap(call(name+'.'+key,args));\n"
"      return Reflect.get(data(name),key);\n"
"    },\n"
"    set(target,key,value) { return Reflect.set(data(name),key,value); },\n"
"    ownKeys() { return Reflect.ownKeys(data(name)); },\n"
"    getOwnPropertyDescriptor(target,key) { const descriptor=Reflect.getOwnPropertyDescriptor(data(name),key); return descriptor ? {...descriptor,configurable:true} : undefined; }\n"
"  });\n"
"  const normalize = value => ArrayBuffer.isView(value) ? Array.from(value) : value;\n"
"  const byteArray = value => {\n"
"    const bytes=normalize(value);\n"
"    if (!Array.isArray(bytes) || bytes.some(b=>!Number.isInteger(b)||b < -128||b > 255)) throw new TypeError('Expected a byte array');\n"
"    return bytes.map(b=>(b+256)%256);\n"
"  };\n"
"  const hex = value => byteArray(value).map(b=>b.toString(16).padStart(2,'0')).join('');\n"
"  const fromHex = value => {\n"
"    if (typeof value!=='string'||value.length%2||!/^[0-9a-f]*$/i.test(value)) throw new TypeError('Invalid hexadecimal data');\n"
"    return value.match(/../g)?.map(b=>parseInt(b,16)) || [];\n"
"  };\n"
"  const crypto = (algorithm,key,iv) => {\n"
"    const descriptor={algorithm,key:normalize(key),iv:normalize(iv) ?? null};\n"
"    const crypt=(operation,value)=>byteArray(call('crypto.'+operation,[descriptor,normalize(value)]));\n"
"    let result;\n"
"    result=Object.freeze({\n"
"      encrypt:value=>crypt('encrypt',value), decrypt:value=>crypt('decrypt',value),\n"
"      encryptBase64:value=>call('android.base64Encode',[crypt('encrypt',value),2]),\n"
"      encryptHex:value=>hex(crypt('encrypt',value)),\n"
"      decryptBase64:value=>crypt('decrypt',call('android.base64Decode',[value,2])),\n"
"      decryptHex:value=>crypt('decrypt',fromHex(value)),\n"
"      decryptStr:(value,charset='UTF-8')=>call('crypto.decodeText',[crypt('decrypt',value),charset]),\n"
"      setIv(value) { descriptor.iv=normalize(value); return result; }\n"
"    });\n"
"    return result;\n"
"  };\n"
"  const device = method => {\n"
"    const value=(...args)=>call('java.'+method,args);\n"
"    Object.defineProperties(value,{toString:{value:()=>String(value())},toJSON:{value:()=>value()},valueOf:{value:()=>value()},[Symbol.toPrimitive]:{value:()=>value()}});\n"
"    return value;\n"
"  };\n"
"  const javaMethods = new Set(['ajax','get','post','head','connect','put','getString','getStringList','getElements','getCookie','getWebViewUA','base64Encode','base64Decode','encodeURI','decodeURI','md5Encode','hexDecodeToString','startBrowserAwait','showBrowser','startBrowser','showReadingBrowser','startBrowserDp','toast','longToast','log']);\n"
"  for (const name of ['source','book','chapter']) Object.defineProperty(globalThis,name,{value:object(name),configurable:false});\n"
"  Object.defineProperty(globalThis,'java',{value:new Proxy(Object.create(null), {get(target,key) {\n"
"    if (typeof key!=='string'||key==='then'||key==='toJSON') return undefined;\n"
"    if (key==='createSymmetricCrypto') return crypto;\n"
"    if (key==='deviceID'||key==='androidId') return device(key);\n"
"    if (!javaMethods.has(key)) return undefined;\n"
"    return (...args)=>wrap(call('java.'+key,args.map(normalize)));\n"
"  }}),configurable:false});\n"
"  for (const name of ['cookie','cache']) Object.defineProperty(globalThis,name,{value:new Proxy(Object.create(null), {get(target,key) {\n"
"    if (typeof key!=='string'||key==='then'||key==='toJSON') return undefined;\n"
"    return (...args)=>wrap(call(name+'.'+key,args.map(normalize)));\n"
"  }}),configurable:false});\n"
"  const base64=Object.freeze({\n"
"    DEFAULT:0,NO_PADDING:1,NO_WRAP:2,CRLF:4,URL_SAFE:8,NO_CLOSE:16,\n"
"    encodeToString:(bytes,flags=0)=>call('android.base64Encode',[byteArray(bytes),flags]),\n"
"    decode:(value,flags=0)=>byteArray(call('android.base64Decode',[normalize(value),flags]))\n"
"  });\n"
"  const packageProxy=(path,children)=>new Proxy(children,{get(target,key) {\n"
"    if (typeof key==='symbol'||key==='then'||key==='toJSON') return undefined;\n"
"    if (Object.prototype.hasOwnProperty.call(target,key)) return target[key];\n"
"    throw new TypeError('Unsupported Java package: '+path+'.'+key);\n"
"  }});\n"
"  const packages=packageProxy('Packages',{android:packageProxy('Packages.android',{util:packageProxy('Packages.android.util',{Base64:base64})})});\n"
"  Object.defineProperty(globalThis,'Packages',{value:packages,configurable:false});\n"
"  return {\n"
"    setBindings(bindings) {\n"
"      for (const key of names) { if (!Reflect.deleteProperty(globalThis,key)) throw new TypeError('Cannot refresh binding: '+key); }\n"
"      current=bindings; names=Object.keys(bindings).filter(key=>!reserved.has(key));\n"
"      for (const key of names) Object.defineProperty(globalThis,key,{value:bindings[key],writable:true,configurable:true,enumerable:true});\n"
"    },\n"
"    evaluateRule(program) { return ruleEval.call(globalThis,nativeEval,program); }\n"
"  };\n"
"})()\n";

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

struct ZYQuickJSSession {
    ZYState state;
    JSRuntime *runtime;
    JSContext *context;
    JSValue bindings_function;
    JSValue evaluate_function;
    char *library;
    size_t library_length;
    size_t memory_limit;
    int evaluating;
};

static void zy_clear_session(ZYQuickJSSession *session) {
    if (session->runtime) JS_UpdateStackTop(session->runtime);
    if (session->context) {
        JS_FreeValue(session->context, session->bindings_function);
        JS_FreeValue(session->context, session->evaluate_function);
        JS_FreeContext(session->context);
    }
    if (session->runtime) JS_FreeRuntime(session->runtime);
    free(session->library);
    session->runtime = NULL; session->context = NULL; session->library = NULL;
    session->library_length = 0; session->memory_limit = 0;
    session->bindings_function = JS_UNDEFINED; session->evaluate_function = JS_UNDEFINED;
}

ZYQuickJSSession *ZYQuickJSCreateSession(void) {
    ZYQuickJSSession *session = calloc(1, sizeof(*session));
    if (session) { session->bindings_function = JS_UNDEFINED; session->evaluate_function = JS_UNDEFINED; }
    return session;
}

void ZYQuickJSResetSession(ZYQuickJSSession *session) {
    if (session && !session->evaluating) zy_clear_session(session);
}

void ZYQuickJSDestroySession(ZYQuickJSSession *session) {
    if (!session || session->evaluating) return;
    zy_clear_session(session);
    free(session);
}

static void zy_prepare_thread(JSRuntime *runtime, size_t requested) {
    JS_UpdateStackTop(runtime);
    size_t stack_limit = requested;
#if defined(__APPLE__)
    // Swift and Dispatch workers can have different stack sizes. Reserve space
    // for the native bridge and unwinders every time a serialized VM moves.
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    uintptr_t bottom = top - pthread_get_stacksize_np(pthread_self());
    uintptr_t current = (uintptr_t)&stack_limit;
    if (current > bottom && current < top) {
        size_t available = current - bottom;
        size_t safe = available > 128 * 1024 ? available - 128 * 1024 : available / 2;
        if (safe < stack_limit) stack_limit = safe;
    }
#endif
    JS_SetMaxStackSize(runtime, stack_limit);
}

static int zy_initialize_session(ZYQuickJSSession *session, ZYQJSResult *result) {
    ZYState *state = &session->state;
    const JSMallocFunctions allocator = {zy_malloc, zy_free, zy_realloc, zy_usable_size};
    session->runtime = JS_NewRuntime2(&allocator, state);
    if (!session->runtime) { result->status = ZYQJS_MEMORY_LIMIT; return 0; }
    JS_SetMemoryLimit(session->runtime, state->limits.memory_limit_bytes);
    zy_prepare_thread(session->runtime, state->limits.stack_limit_bytes);
    JS_SetCanBlock(session->runtime, 0);
    JS_SetInterruptHandler(session->runtime, zy_interrupted, state);
    session->context = JS_NewContext(session->runtime);
    if (!session->context) { result->status = ZYQJS_MEMORY_LIMIT; return 0; }
    JSContext *context = session->context;
    JS_SetContextOpaque(context, state);
    JSValue global = JS_GetGlobalObject(context);
    int defined = JS_DefinePropertyValueStr(context, global, "__zhuyingHost", JS_NewCFunction(context, zy_host, "host", 2), 0);
    JS_FreeValue(context, global);
    if (defined < 0) { zy_exception(context, state, result); return 0; }
    JSValue shim = JS_UNDEFINED;
    if (!zy_evaluate(context, state, zy_shim, strlen(zy_shim), "legado-host.js", &shim, result)) return 0;
    session->bindings_function = JS_GetPropertyStr(context, shim, "setBindings");
    session->evaluate_function = JS_GetPropertyStr(context, shim, "evaluateRule");
    JS_FreeValue(context, shim);
    if (!JS_IsFunction(context, session->bindings_function) || !JS_IsFunction(context, session->evaluate_function)) {
        result->status = ZYQJS_SCRIPT_EXCEPTION; result->message = strdup("Unable to initialize the Legado host"); return 0;
    }
    session->memory_limit = state->limits.memory_limit_bytes;
    return 1;
}

static void zy_serialize_result(JSContext *context, ZYState *state, JSValue value, ZYQJSResult *result) {
    if (JS_IsObject(value) && JS_PromiseState(context, value) != (JSPromiseStateEnum)-1) {
        result->status = ZYQJS_SCRIPT_EXCEPTION;
        result->message = strdup("Asynchronous results are not supported by the synchronous Legado host");
        return;
    }
    if (JS_IsUndefined(value)) { result->json = strdup("null"); return; }
    JSValue json = JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) { zy_exception(context, state, result); return; }
    if (!JS_IsString(json)) {
        JS_FreeValue(context, json); result->status = ZYQJS_SCRIPT_EXCEPTION;
        result->message = strdup("The script result cannot be represented as JSON"); return;
    }
    size_t length = 0;
    const char *bytes = JS_ToCStringLen(context, &length, json);
    if (!bytes) { JS_FreeValue(context, json); zy_exception(context, state, result); return; }
    if (length > state->limits.maximum_output_bytes) result->status = ZYQJS_BRIDGE_LIMIT;
    else result->json = strdup(bytes);
    JS_FreeCString(context, bytes); JS_FreeValue(context, json);
}

ZYQJSResult ZYQuickJSSessionEvaluate(ZYQuickJSSession *session,
                                   const char *script, size_t script_length,
                                   const char *library, size_t library_length,
                                   const char *bindings_json, size_t bindings_length,
                                   ZYQJSLimits limits, ZYQJSHostCallback host,
                                   ZYQJSCancelCallback cancelled, void *opaque) {
    ZYQJSResult result = {ZYQJS_OK, NULL, NULL};
    if (!session) { result.status = ZYQJS_INVALID_INPUT; return result; }
    if (session->evaluating) { result.status = ZYQJS_BUSY; return result; }
    if (!script || !library || !bindings_json || script_length > 256 * 1024 || library_length > 2 * 1024 * 1024 ||
        bindings_length > limits.maximum_bridge_bytes || limits.memory_limit_bytes < 256 * 1024 ||
        limits.stack_limit_bytes < 64 * 1024 || !limits.timeout_milliseconds || limits.timeout_milliseconds > 30000 ||
        !limits.maximum_output_bytes || !limits.maximum_bridge_bytes) {
        zy_clear_session(session); result.status = ZYQJS_INVALID_INPUT; return result;
    }
    if (session->runtime && (session->memory_limit != limits.memory_limit_bytes ||
        session->library_length != library_length || !session->library || memcmp(session->library, library, library_length))) zy_clear_session(session);
    session->evaluating = 1;
    session->state = (ZYState){.limits = limits, .host = host, .cancelled = cancelled, .opaque = opaque,
                               .deadline = zy_now() + limits.timeout_milliseconds * 1000000ull};
    ZYState *state = &session->state;
    if (zy_interrupted(NULL, state)) { result.status = state->abort_status; goto finish; }
    int initialized = session->runtime != NULL;
    if (!initialized && !zy_initialize_session(session, &result)) goto finish;
    JSContext *context = session->context;
    zy_prepare_thread(session->runtime, limits.stack_limit_bytes);
    JSValue value = JS_UNDEFINED;
    JSValue bindings = JS_ParseJSON(context, bindings_json, bindings_length, "bindings.json");
    if (JS_IsException(bindings)) { zy_exception(context, state, &result); goto evaluated; }
    if (!JS_IsObject(bindings) || JS_IsArray(context, bindings)) {
        JS_FreeValue(context, bindings); result.status = ZYQJS_INVALID_INPUT; goto evaluated;
    }
    value = JS_Call(context, session->bindings_function, JS_UNDEFINED, 1, &bindings);
    JS_FreeValue(context, bindings);
    if (JS_IsException(value)) { zy_exception(context, state, &result); goto evaluated; }
    JS_FreeValue(context, value); value = JS_UNDEFINED;
    if (!initialized) {
        if (library_length) {
            if (!zy_evaluate(context, state, library, library_length, "source-library.js", &value, &result)) goto evaluated;
            JS_FreeValue(context, value); value = JS_UNDEFINED;
        }
        session->library = malloc(library_length + 1);
        if (!session->library) { result.status = ZYQJS_MEMORY_LIMIT; goto evaluated; }
        memcpy(session->library, library, library_length); session->library[library_length] = 0;
        session->library_length = library_length;
    }
    JSValue program = JS_NewStringLen(context, script, script_length);
    if (JS_IsException(program)) { zy_exception(context, state, &result); goto evaluated; }
    value = JS_Call(context, session->evaluate_function, JS_UNDEFINED, 1, &program);
    JS_FreeValue(context, program);
    if (JS_IsException(value)) { zy_exception(context, state, &result); goto evaluated; }
    zy_serialize_result(context, state, value, &result);
    if (zy_interrupted(session->runtime, state)) result.status = state->abort_status;
    else if (state->memory_exhausted) result.status = ZYQJS_MEMORY_LIMIT;
    else if (result.status == ZYQJS_OK && !result.json) result.status = ZYQJS_MEMORY_LIMIT;
 evaluated:
    JS_FreeValue(context, value);
 finish:
    if (result.status != ZYQJS_OK) zy_clear_session(session);
    // Persistent JavaScript functions resolve the host on the next evaluation,
    // never through a dangling pointer to the previous Swift callback box.
    state->host = NULL; state->cancelled = NULL; state->opaque = NULL;
    state->deadline = UINT64_MAX;
    session->evaluating = 0;
    return result;
}

ZYQJSResult ZYQuickJSEvaluate(const char *script, size_t script_length,
                            const char *library, size_t library_length,
                            const char *bindings_json, size_t bindings_length,
                            ZYQJSLimits limits, ZYQJSHostCallback host,
                            ZYQJSCancelCallback cancelled, void *opaque) {
    ZYQuickJSSession *session = ZYQuickJSCreateSession();
    if (!session) return (ZYQJSResult){ZYQJS_MEMORY_LIMIT, NULL, NULL};
    ZYQJSResult result = ZYQuickJSSessionEvaluate(session, script, script_length, library, library_length,
                                              bindings_json, bindings_length, limits, host, cancelled, opaque);
    ZYQuickJSDestroySession(session);
    return result;
}

void ZYQuickJSFreeResult(ZYQJSResult *result) {
    if (!result) return;
    free(result->json); free(result->message);
    result->json = NULL; result->message = NULL;
}

const char *ZYQuickJSVersion(void) { return "2026-06-04"; }
