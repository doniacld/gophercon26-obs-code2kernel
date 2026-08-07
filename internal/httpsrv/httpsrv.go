// Package httpsrv runs an application HTTP listener with a readiness guarantee
// and a graceful shutdown, so each demo's main function stays about the demo.
package httpsrv

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Run binds addr, serves h, and blocks until SIGINT or SIGTERM. The listener is
// bound before ready is called, so anything printed there is true by the time
// it reaches the terminal.
func Run(addr string, h http.Handler, ready func(boundAddr string)) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}

	srv := &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	if ready != nil {
		ready(ln.Addr().String())
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		return err
	case <-sig:
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(ctx)
}
