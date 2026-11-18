package main

// Self-test (kernel command line `docatz.selftest`): with no host on the other end of vsock — the guest booted by QEMU
// for an architecture this Mac cannot run, or in CI — the agent checks the engine itself through dockerd's API: pull
// busybox, run one container on the default runtime, read its output, check an OOM kill is reported, then report on
// the console and power off.
//   docatz-selftest: PASS x86_64 runtime=runc-rs …   or   docatz-selftest: FAIL <step>: <why>

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

func selftestWanted() bool {
	b, _ := os.ReadFile("/proc/cmdline")
	for _, f := range strings.Fields(string(b)) {
		if f == "docatz.selftest" {
			return true
		}
	}
	return false
}

func selftest(d *docker) {
	start := time.Now()
	report := func(format string, a ...any) {
		fmt.Fprintf(os.Stdout, "docatz-selftest: "+format+" (%.1f s since the agent started)\n", append(a, time.Since(start).Seconds())...)
		d.stop(15 * time.Second)
		if os.Getpid() == 1 {
			powerOff()
		}
		os.Exit(0)
	}
	for i := 0; !d.isReady(); i++ {
		if i > 1800 {
			report("FAIL dockerd: not ready after 180 s")
		}
		time.Sleep(100 * time.Millisecond)
	}
	api := &http.Client{Timeout: 5 * time.Minute, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", dockerSock)
	}}}
	call := func(method, path string, body any) ([]byte, int, error) {
		var r io.Reader
		if body != nil {
			b, _ := json.Marshal(body)
			r = bytes.NewReader(b)
		}
		req, _ := http.NewRequest(method, "http://docker"+path, r)
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		res, err := api.Do(req)
		if err != nil {
			return nil, 0, err
		}
		defer res.Body.Close()
		out, err := io.ReadAll(res.Body)
		return out, res.StatusCode, err
	}
	var info struct {
		Architecture   string
		DefaultRuntime string
		ServerVersion  string
		KernelVersion  string
	}
	if b, _, err := call("GET", "/info", nil); err != nil || json.Unmarshal(b, &info) != nil {
		report("FAIL info: %v", err)
	}
	if b, code, err := call("POST", "/images/create?fromImage=busybox&tag=1.37", nil); err != nil || code != 200 || bytes.Contains(b, []byte(`"error"`)) {
		report("FAIL pull busybox: %v %d %s", err, code, lastLine(b))
	}
	b, code, err := call("POST", "/containers/create", map[string]any{
		"Image": "busybox:1.37", "Tty": true, "Cmd": []string{"sh", "-c", "echo selftest-ok $(uname -m)"},
	})
	var created struct{ Id string }
	if err != nil || code != 201 || json.Unmarshal(b, &created) != nil {
		report("FAIL create: %v %d %s", err, code, lastLine(b))
	}
	if _, code, err := call("POST", "/containers/"+created.Id+"/start", nil); err != nil || code != 204 {
		report("FAIL start: %v %d", err, code)
	}
	var waited struct{ StatusCode int }
	if b, _, err := call("POST", "/containers/"+created.Id+"/wait", nil); err != nil || json.Unmarshal(b, &waited) != nil || waited.StatusCode != 0 {
		report("FAIL wait: %v exit %d", err, waited.StatusCode)
	}
	logs, _, _ := call("GET", "/containers/"+created.Id+"/logs?stdout=1", nil)
	var inspect struct{ HostConfig struct{ Runtime string } }
	b, _, _ = call("GET", "/containers/"+created.Id+"/json", nil)
	_ = json.Unmarshal(b, &inspect)
	if !bytes.Contains(logs, []byte("selftest-ok")) {
		report("FAIL output: %q", lastLine(logs))
	}
	// OOM: a 16 MB container that keeps allocating must be reported as OOM-killed (the shim's cgroup v2 watch).
	b, code, err = call("POST", "/containers/create", map[string]any{
		"Image": "busybox:1.37", "Cmd": []string{"sh", "-c", "x=a; while :; do x=$x$x; done"},
		"HostConfig": map[string]any{"Memory": 16 << 20, "MemorySwap": 16 << 20},
	})
	var oom struct{ Id string }
	if err != nil || code != 201 || json.Unmarshal(b, &oom) != nil {
		report("FAIL create oom: %v %d %s", err, code, lastLine(b))
	}
	call("POST", "/containers/"+oom.Id+"/start", nil)
	call("POST", "/containers/"+oom.Id+"/wait", nil)
	var oomState struct{ State struct{ OOMKilled bool; ExitCode int } }
	b, _, _ = call("GET", "/containers/"+oom.Id+"/json", nil)
	_ = json.Unmarshal(b, &oomState)
	if !oomState.State.OOMKilled {
		report("FAIL oom: OOMKilled false, exit %d", oomState.State.ExitCode)
	}
	report("PASS %s oom-reported=true docker=%s kernel=%s default-runtime=%s container-runtime=%s output=%q",
		info.Architecture, info.ServerVersion, info.KernelVersion, info.DefaultRuntime, inspect.HostConfig.Runtime, strings.TrimSpace(string(logs)))
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return lines[len(lines)-1]
}
