# 竹影同步脚本桥

`ZhuyingScriptCore` is a static C module. The Swift facades are in
`Zhuying/Models/QuickJSScriptRuntime.swift`. Evaluation must execute on a
background thread. The existing
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

`QuickJSScriptRuntime.evaluate` creates an independent VM for each call.
`QuickJSScriptSession.evaluate` reuses one VM for one source/account. It loads
the source's library once, preserves library globals/functions and explicit
`globalThis` assignments, and refreshes bindings and host closures on every
call. Rule scripts run as direct eval inside a fresh child function scope:
their completion value is returned, and ordinary `var`/`let`/`const`
declarations do not leak into subsequent rules. This implements that subset of
Rhino child scope behavior; it does not claim identical Rhino object semantics.
Cached library references to `source`, `book` and `chapter` read the current
request's data and delegate methods through the current host.

The C lifecycle API is `ZYQuickJSCreateSession`,
`ZYQuickJSSessionEvaluate`, `ZYQuickJSResetSession` and
`ZYQuickJSDestroySession`. C owners must serialize all access, including reset
and destruction. The Swift session rejects concurrent or nested same-session
evaluation with `.busy`. Its `reset()` cancels an active call without waiting
for blocked native I/O, and discards the VM after that call unwinds. Idle reset,
library changes, heap-budget changes and any failed evaluation discard the
VM. Host callbacks are never retained after an evaluation returns. Serialized
VMs may move between background threads; stack top and actual available stack
are refreshed before execution and cleanup.

All Swift QuickJS entry points share `QuickJSScriptMemoryBudget.shared`, whose
default ceiling is 96 MiB. This reserves each VM's configured heap ceiling
(normally 16 MiB, hence at most six default VMs), including active and idle
sessions. It does not measure process RSS, actual JS heap use or native host
buffers. `snapshot` reports current/peak reservations, active sessions, waiters
and completed/scheduled evictions for diagnostics.

Owners wrap the entire serialized source operation in
`session.withLease(memoryLimitBytes:timeoutSeconds:cancelled:) { ... }`, before
running its first rule and until its last rule or browser interaction returns.
This pins library globals across gaps between evaluations. `evaluate` also
obtains a short lease automatically; a nested evaluation reuses the outer
reservation. A nested rule may use a smaller heap but cannot expand its pinned
operation's reservation. Explicit scope preparation/reset belongs before the
outer lease, since reset cancels the active lease.

When the ceiling is occupied, background callers first evict the least recently
used idle VM, or wait for active operations to release their leases. Waiting
observes Swift-task cancellation, the supplied cancellation check, session
reset and its own deadline (`memoryBudgetTimedOut`). Main-thread lease/evaluate
calls are rejected. Retiring VMs keep their reservation until C destruction
finishes, preventing overlapping heap ceilings during reclamation.

Darwin memory-pressure events and UIKit memory warnings reclaim idle VMs on a
background queue. Active leases, including browser waits, survive; if pressure
remains high they are reclaimed after the operation ends. Reset and releasing
the last Swift owner on the main thread also defer idle VM destruction to that
queue. A later evaluation reloads its library from the source and its persistent
host state; JS globals that were never written to host storage are intentionally
lost after idle eviction. Hosts retain responsibility for their own storage and
network limits.

The bridge preserves synchronous script completion values. Known `java.*`,
`cookie.*`, `cache.*` and the supported
`source`/`book`/`chapter` object methods call a supplied synchronous host. HTTP
response dictionaries (`body`, `statusCode`, `headers`, `url`) gain Legado-style
`body()`, `code()`, `header()`, `headers()` and `url()` methods. `toJSON()` keeps
the original response representation when returning it to Swift.

Source login methods (`getLoginInfo`, `getLoginInfoMap`, `putLoginInfo`,
`getLoginHeader`, `setLoginHeader`, `getHeaderMap`, `deleteLoginInfo`) and cache
methods delegate to the host. Unknown source get/set methods also delegate so
unsupported operations produce a clear host error. Unknown Java methods return
`undefined`, preserving `typeof` capability checks; directly calling one raises
a JavaScript TypeError. Android-only `reLoginView` is not advertised.

`java.createSymmetricCrypto` returns a chainable descriptor wrapper for
`encrypt`, `decrypt`, `encryptBase64`, `encryptHex`, `decryptBase64`,
`decryptHex`, `decryptStr` and `setIv`. It delegates encryption/decryption as
`crypto.encrypt/decrypt([descriptor,data])`, where the descriptor has
`algorithm`, `key` and optional `iv`; native code owns crypto validation.
String ciphertext is passed unchanged so the host can distinguish hex/Base64.
`decryptStr` delegates decoding to `crypto.decodeText([bytes,charset])`.
The explicitly supported Java package is `Packages.android.util.Base64`:
`encodeToString` and `decode` delegate to `android.base64Encode/Decode` with
the original flags. The frozen source's AES/Android Base64 invocation shape was
verified against its original JSON and the upstream
[JsEncodeUtils.kt API](https://github.com/gedoor/legado/blob/fd026e0/app/src/main/java/io/legado/app/help/JsEncodeUtils.kt).
Other Java packages fail explicitly; no reflection runtime is installed.
Device ID methods remain callable and also support string/JSON coercion.
An empty `new JavaImporter()` provides a Rhino-style `with` scope. Its
`importClass` accepts only the implemented Android Base64 object; constructor
imports and other classes fail explicitly. No Java String, URL or HttpUrl
implementation is advertised. Date arguments to `java.timeFormat` and
`timeFormatUTC` become milliseconds before reaching the native host; numeric
arguments and explicit formats/offsets are preserved.

The C API uses public memory, stack and interrupt controls. Its allocator caps
runtime allocations including initialization; native host buffers separately
have bridge/output quotas. The JS execution budget is elapsed time while the
interpreter and its ordinary native helpers execute, normally five seconds.
It is not a process CPU-time measurement. Cancellation/deadlines are checked
before and after every host callback. Blocking `Atomics.wait` is disabled.

Waiting inside the controlled `java.ajax`, `get`, `post`, `head` and `connect`
network callbacks is excluded from that JS budget. Their native HTTP executor
retains its request timeout, cancellation, 64-request/response quotas and the
source operation's independent wall-clock deadline (normally 25 seconds).
Network waits do not extend the operation deadline. JS argument serialization,
the rule's code before/after a network callback, host-call quotas and bridge
byte quotas still apply. A host implementation outside the source adapter must
enforce equivalent network deadlines itself; an interpreter interrupt cannot
stop arbitrary blocking native code.

Waiting inside `java.startBrowserAwait`, `showBrowser`, `startBrowser`,
`showReadingBrowser`, `startBrowserDp` and `reLoginView` is excluded from the
JS execution deadline. These user interactions also pause the source operation
deadline while its separately bounded browser wait (normally 300 seconds) is
active. The interaction host owns that timeout and cancellation. A failed interaction invalidates the VM even
if the source catches its JavaScript exception. Per-call host/bridge quotas and
cancellation still apply to interactive calls.

Input values are JSON data; invalid/intrinsic binding names are rejected.
Undefined completion maps to `NSNull`; Promise completions are rejected, and
queued Promise jobs are not run. No filesystem, process, bytecode loader or
module loader is exposed. This runtime is one part of a Legado compatibility
layer; it does not by itself implement the Android/Java host or declare any
particular source compatible.
