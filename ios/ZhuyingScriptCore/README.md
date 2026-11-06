# 竹影同步脚本桥

`ZhuyingScriptCore` is a static C module. The Swift facade is
`Zhuying/Models/QuickJSScriptRuntime.swift`; each evaluation owns an independent
QuickJS runtime and must execute on a background thread. The existing
`NativeScriptHost` and its asynchronous Worker protocol are separate.

Compile `QuickJSScriptBridge.c` and these unmodified upstream sources:

- `../Vendor/QuickJS/quickjs.c`
- `../Vendor/QuickJS/libregexp.c`
- `../Vendor/QuickJS/libunicode.c`
- `../Vendor/QuickJS/cutils.c`
- `../Vendor/QuickJS/dtoa.c`

Public headers/module map live in `include/`. Add `include` and
`../Vendor/QuickJS` to header search paths, define
`CONFIG_VERSION="2026-06-04"`, use C11 or GNU11 and link the system math library.
The application depends on the static target and imports `ZhuyingScriptCore`.
Neither `quickjs-libc.c` nor command-line tools belong in the target.

The bridge preserves synchronous script completion values and the shared scope
of one source library plus its rule. `java.*`, `cookie.*` and the supported
`source`/`book`/`chapter` object methods call a supplied synchronous host. HTTP
response dictionaries (`body`, `statusCode`, `headers`, `url`) gain Legado-style
`body()`, `code()`, `header()`, `headers()` and `url()` methods. `toJSON()` keeps
the original response representation when returning it to Swift.

The C API uses public memory, stack and interrupt controls. Its allocator caps
runtime allocations including initialization; native host buffers separately
have bridge/output quotas. Cancellation/deadlines are checked before and after
every host callback. A blocked network callback must separately enforce its
deadline, cancel its URLSession task and wake its waiter. An interrupt cannot
stop arbitrary blocking native code. Blocking `Atomics.wait` is disabled.

Input values are JSON data; invalid/intrinsic binding names are rejected.
Undefined completion maps to `NSNull`; Promise completions are rejected, and
queued Promise jobs are not run. No filesystem, process, bytecode loader or
module loader is exposed. This runtime is one part of a Legado compatibility
layer; it does not by itself implement the Android/Java host or declare any
particular source compatible.
