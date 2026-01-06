# Bug Report: tcp-tls and testuds netlayers fail on macOS

## Summary

The `tcp-tls` and `testuds` netlayers in Goblins fail on macOS with "Invalid argument" when accepting connections. This is because the code passes `O_NONBLOCK` or `SOCK_NONBLOCK` flags to `accept()`, but macOS doesn't support the `accept4()` syscall that accepts flags.

## Environment

- **OS**: macOS 14.5 (Darwin 24.5.0)
- **Architecture**: ARM64 (Apple Silicon)
- **Guile**: 3.0.10 (Homebrew)
- **Goblins**: 0.16.1 (Homebrew tap: aconchillo/guile)
- **Fibers**: 1.4.0 (Homebrew tap: aconchillo/guile)

## Reproduction

```scheme
(use-modules (fibers)
             (goblins)
             (goblins vat)
             (goblins ocapn netlayer tcp-tls))

(run-fibers
 (lambda ()
   (define vat (spawn-vat))
   (call-with-vat vat
    (lambda ()
      ;; This will fail when accepting connections
      (spawn ^tcp-tls-netlayer "localhost" #:port 8899))))
 #:parallelism 1
 #:hz 0)
```

## Error Message

```
Error in IO handling wrapped resource #<input-output: socket 66>:
#<&compound-exception components: (
  #<&external-error>
  #<&origin origin: "accept">
  #<&message message: "~A">
  #<&irritants irritants: ("Invalid argument")>
  #<&exception-with-kind-and-args kind: system-error args: ("accept" "~A" ("Invalid argument") (22))>
)>
```

The error code 22 is `EINVAL` (Invalid argument).

## Root Cause

### tcp-tls.scm (line 261-263)

```scheme
(define (incoming-accept)
  (on (<- server-socket-io
          (lambda (resource)
            (accept resource O_NONBLOCK)))  ;; <-- Problem here
      ...))
```

### testuds.scm (line 39)

```scheme
(define (incoming-accept)
  (match (accept our-server-sock SOCK_NONBLOCK)  ;; <-- Problem here
    ((client . addr)
     ...)))
```

### Why it fails on macOS

1. **Linux** has `accept4()` syscall which accepts a flags parameter (including `SOCK_NONBLOCK`, `SOCK_CLOEXEC`)
2. **macOS** only has `accept()` which takes 3 arguments: `accept(socket, address, address_len)` - no flags parameter
3. When Guile's `accept` is called with a flags argument on macOS, it passes the flags to the underlying `accept()` syscall
4. Since macOS `accept()` doesn't understand the flags parameter, it returns `EINVAL`

This can be verified:

```scheme
;; On macOS:
(define sock (socket PF_UNIX SOCK_STREAM 0))
(bind sock AF_UNIX "/tmp/test.sock")
(listen sock 1)
(accept sock 2048)  ;; O_NONBLOCK = 2048 on macOS
;; => ERROR: system-error (accept ~A (Invalid argument) (22))
```

Additionally, `SOCK_NONBLOCK` is not even defined in Guile on macOS:

```scheme
;; On macOS:
SOCK_NONBLOCK
;; => ERROR: Unbound variable: SOCK_NONBLOCK
```

## Proposed Fix

The fix is simple: call `accept()` without flags, then set `O_NONBLOCK` on the accepted socket using `fcntl()`. This is what the code already does in `use-nonblocking-i/o` after accepting:

### tcp-tls.scm fix

```diff
 (define (incoming-accept)
   (on (<- server-socket-io
           (lambda (resource)
-            (accept resource O_NONBLOCK)))
+            (accept resource)))  ;; No flags - works on all platforms
       (match-lambda
         ((client-socket . _)
          (setvbuf client-socket 'block)
          (use-nonblocking-i/o client-socket)  ;; This already sets O_NONBLOCK via fcntl
          (make-server-tls-port client-socket cert key)))
       #:promise? #t))
```

### testuds.scm fix

```diff
+(define (use-nonblocking-i/o port)
+  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))
+
 (define (incoming-accept)
-  (match (accept our-server-sock SOCK_NONBLOCK)
+  (match (accept our-server-sock)  ;; No flags - works on all platforms
     ((client . addr)
+     (use-nonblocking-i/o client)  ;; Set O_NONBLOCK via fcntl
      (setvbuf client 'block 1024)
      client)))
```

## Notes

1. The `O_NONBLOCK` flag in `accept()` was redundant in tcp-tls.scm anyway, since `use-nonblocking-i/o` is called immediately after accepting

2. This fix works on both Linux and macOS - using `fcntl()` to set `O_NONBLOCK` is the portable approach

3. The same issue likely affects any code that passes flags to `accept()` on macOS

## Tested Platforms

- [x] macOS 14.5 ARM64 - Fix verified working
- [ ] Linux x86_64 - Not tested, but should work (fcntl is portable)

## References

- Guile bug #25790: `SOCK_CLOEXEC` and `SOCK_NONBLOCK` undeclared identifier errors
- POSIX `accept()` specification: https://pubs.opengroup.org/onlinepubs/9799919799/functions/accept.html
- Linux `accept4()` man page: https://man7.org/linux/man-pages/man2/accept.2.html
