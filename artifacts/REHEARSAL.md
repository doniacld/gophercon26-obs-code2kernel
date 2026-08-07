# Rehearsal record

Captured on `Darwin 25.5.0`, arm64, Go go1.26.4.
CPUs: 11.

These are the numbers *this* machine produced. If they differ noticeably
from the READMEs, trust these and update your talk track — or find out why.

## Demo 2 — pprof: a goroutine leak

**before**
```

BROKEN

Runtime metric before:
go_goroutines 7

Sending 100 requests that time out before work completes...

Runtime metric after:
go_goroutines 107

pprof diagnosis:
100 goroutines blocked on channel send

goroutine 132 [chan send]:
main.handleWorkBroken.func1()
	server.go:176
created by main.handleWorkBroken in goroutine 130
	server.go:174

(the other 99 are the same stack)
```

**after**
```

FIXED

Runtime metric before:
go_goroutines 7

Sending the same 100 cancelled requests...

Runtime metric after:
go_goroutines 7

pprof diagnosis:
no accumulated application goroutines blocked on channel send
```

