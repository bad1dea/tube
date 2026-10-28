//go:build js && wasm

// SSH client for the Tube web app. Runs in the browser; the gateway only
// relays the encrypted SSH stream over a WebSocket. Credentials and terminal
// data never leave this process unencrypted.
//
// JS API (globalThis.tubeSSH):
//
//	connect({relayURL, token, hops: [{host, port, user, password?, privateKey?, passphrase?}],
//	         cols, rows, term, onData(Uint8Array), onClose(reason),
//	         verifyHostKey(host, port, algorithm, keyBase64, fingerprint) -> Promise<bool>})
//	  -> Promise<{write(Uint8Array|string), resize(cols, rows), close()}>
//	generateKey(comment) -> {privateKey, publicKey}
//	publicKey(privateKeyPEM, passphrase?) -> string
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall/js"
	"time"

	"golang.org/x/crypto/ssh"
)

func main() {
	api := js.Global().Get("Object").New()
	api.Set("connect", js.FuncOf(connect))
	api.Set("generateKey", js.FuncOf(generateKey))
	api.Set("publicKey", js.FuncOf(publicKey))
	js.Global().Set("tubeSSH", api)
	if ready := js.Global().Get("tubeSSHReady"); ready.Type() == js.TypeFunction {
		ready.Invoke()
	}
	select {}
}

// ---------------------------------------------------------------- promises

func promise(fn func() (any, error)) js.Value {
	handler := js.FuncOf(func(_ js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			v, err := fn()
			if err != nil {
				reject.Invoke(js.Global().Get("Error").New(err.Error()))
				return
			}
			resolve.Invoke(v)
		}()
		return nil
	})
	p := js.Global().Get("Promise").New(handler)
	handler.Release()
	return p
}

func await(p js.Value) (js.Value, error) {
	type result struct {
		v   js.Value
		err error
	}
	ch := make(chan result, 1)
	var then, catch js.Func
	then = js.FuncOf(func(_ js.Value, args []js.Value) any {
		ch <- result{v: args[0]}
		return nil
	})
	catch = js.FuncOf(func(_ js.Value, args []js.Value) any {
		ch <- result{err: errors.New(args[0].Call("toString").String())}
		return nil
	})
	p.Call("then", then).Call("catch", catch)
	r := <-ch
	then.Release()
	catch.Release()
	return r.v, r.err
}

func bytesFromJS(v js.Value) []byte {
	if v.Type() == js.TypeString {
		return []byte(v.String())
	}
	b := make([]byte, v.Get("length").Int())
	js.CopyBytesToGo(b, v)
	return b
}

func bytesToJS(b []byte) js.Value {
	u := js.Global().Get("Uint8Array").New(len(b))
	js.CopyBytesToJS(u, b)
	return u
}

// ---------------------------------------------------------------- relay socket

// wsConn is a net.Conn over the gateway WebSocket.
type wsConn struct {
	ws      js.Value
	mu      sync.Mutex
	buf     []byte
	cond    *sync.Cond
	closed  bool
	readErr error
	funcs   []js.Func
}

func dialRelay(url, token, host string, port int) (*wsConn, error) {
	c := &wsConn{}
	c.cond = sync.NewCond(&c.mu)
	ws := js.Global().Get("WebSocket").New(url)
	ws.Set("binaryType", "arraybuffer")
	c.ws = ws

	ready := make(chan error, 1)
	var once sync.Once
	signal := func(err error) { once.Do(func() { ready <- err }) }
	handshake := true

	onOpen := js.FuncOf(func(js.Value, []js.Value) any {
		hello := js.Global().Get("JSON").Call("stringify", map[string]any{"token": token, "host": host, "port": port})
		ws.Call("send", hello)
		return nil
	})
	onMessage := js.FuncOf(func(_ js.Value, args []js.Value) any {
		data := args[0].Get("data")
		if data.Type() == js.TypeString {
			if handshake {
				handshake = false
				s := data.String()
				if strings.Contains(s, `"ok":true`) {
					signal(nil)
				} else {
					signal(fmt.Errorf("gateway: %s", s))
				}
			}
			return nil
		}
		b := bytesFromJS(js.Global().Get("Uint8Array").New(data))
		c.mu.Lock()
		c.buf = append(c.buf, b...)
		c.cond.Broadcast()
		c.mu.Unlock()
		return nil
	})
	onClose := js.FuncOf(func(js.Value, []js.Value) any {
		signal(errors.New("gateway closed the connection"))
		c.mu.Lock()
		c.closed = true
		if c.readErr == nil {
			c.readErr = io.EOF
		}
		c.cond.Broadcast()
		c.mu.Unlock()
		return nil
	})
	onError := js.FuncOf(func(js.Value, []js.Value) any {
		signal(errors.New("cannot reach gateway " + url))
		return nil
	})
	ws.Set("onopen", onOpen)
	ws.Set("onmessage", onMessage)
	ws.Set("onclose", onClose)
	ws.Set("onerror", onError)
	c.funcs = []js.Func{onOpen, onMessage, onClose, onError}

	select {
	case err := <-ready:
		if err != nil {
			c.Close()
			return nil, err
		}
	case <-time.After(20 * time.Second):
		c.Close()
		return nil, errors.New("gateway timeout")
	}
	return c, nil
}

func (c *wsConn) Read(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.buf) == 0 && !c.closed {
		c.cond.Wait()
	}
	if len(c.buf) == 0 {
		return 0, c.readErr
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}

func (c *wsConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return 0, net.ErrClosed
	}
	c.ws.Call("send", bytesToJS(p))
	return len(p), nil
}

func (c *wsConn) Close() error {
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		c.readErr = net.ErrClosed
		c.cond.Broadcast()
	}
	c.mu.Unlock()
	c.ws.Call("close")
	return nil
}

func (c *wsConn) LocalAddr() net.Addr                { return dummyAddr{} }
func (c *wsConn) RemoteAddr() net.Addr               { return dummyAddr{} }
func (c *wsConn) SetDeadline(t time.Time) error      { return nil }
func (c *wsConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *wsConn) SetWriteDeadline(t time.Time) error { return nil }

type dummyAddr struct{}

func (dummyAddr) Network() string { return "ws" }
func (dummyAddr) String() string  { return "gateway" }

// ---------------------------------------------------------------- ssh

type hop struct {
	host, user, password, privateKey, passphrase string
	port                                         int
}

func parseHops(v js.Value) ([]hop, error) {
	n := v.Get("length").Int()
	if n == 0 {
		return nil, errors.New("no hosts")
	}
	out := make([]hop, n)
	for i := 0; i < n; i++ {
		h := v.Index(i)
		str := func(k string) string {
			x := h.Get(k)
			if x.Type() == js.TypeString {
				return x.String()
			}
			return ""
		}
		port := 22
		if p := h.Get("port"); p.Type() == js.TypeNumber {
			port = p.Int()
		}
		out[i] = hop{host: str("host"), port: port, user: str("user"), password: str("password"),
			privateKey: str("privateKey"), passphrase: str("passphrase")}
	}
	return out, nil
}

func clientConfig(h hop, verify js.Value) (*ssh.ClientConfig, error) {
	var auth []ssh.AuthMethod
	if h.privateKey != "" {
		var signer ssh.Signer
		var err error
		if h.passphrase != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(h.privateKey), []byte(h.passphrase))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(h.privateKey))
		}
		if err != nil {
			return nil, fmt.Errorf("private key for %s: %w", h.host, err)
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if h.password != "" {
		pw := h.password
		auth = append(auth, ssh.Password(pw), ssh.KeyboardInteractive(
			func(_, _ string, questions []string, _ []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = pw
				}
				return answers, nil
			}))
	}
	host, port := h.host, h.port
	return &ssh.ClientConfig{
		User: h.user,
		Auth: auth,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			fp := ssh.FingerprintSHA256(key)
			ok, err := await(verify.Invoke(host, port, key.Type(), base64.StdEncoding.EncodeToString(key.Marshal()), fp))
			if err != nil {
				return err
			}
			if !ok.Truthy() {
				return fmt.Errorf("host key for %s:%d not accepted (%s)", host, port, fp)
			}
			return nil
		},
		Timeout: 20 * time.Second,
	}, nil
}

func connect(_ js.Value, args []js.Value) any {
	opts := args[0]
	return promise(func() (any, error) {
		hops, err := parseHops(opts.Get("hops"))
		if err != nil {
			return nil, err
		}
		verify := opts.Get("verifyHostKey")
		onData := opts.Get("onData")
		onClose := opts.Get("onClose")

		first := hops[0]
		conn, err := dialRelay(opts.Get("relayURL").String(), opts.Get("token").String(), first.host, first.port)
		if err != nil {
			return nil, err
		}
		var clients []*ssh.Client
		closeAll := func() {
			for i := len(clients) - 1; i >= 0; i-- {
				clients[i].Close()
			}
			conn.Close()
		}
		var nc net.Conn = conn
		for i, h := range hops {
			cfg, err := clientConfig(h, verify)
			if err != nil {
				closeAll()
				return nil, err
			}
			addr := net.JoinHostPort(h.host, strconv.Itoa(h.port))
			if i > 0 {
				nc, err = clients[i-1].Dial("tcp", addr)
				if err != nil {
					closeAll()
					return nil, fmt.Errorf("jump to %s: %w", addr, err)
				}
			}
			c, chans, reqs, err := ssh.NewClientConn(nc, addr, cfg)
			if err != nil {
				closeAll()
				return nil, fmt.Errorf("%s: %w", addr, err)
			}
			clients = append(clients, ssh.NewClient(c, chans, reqs))
		}
		client := clients[len(clients)-1]

		sess, err := client.NewSession()
		if err != nil {
			closeAll()
			return nil, err
		}
		term := "xterm-256color"
		if t := opts.Get("term"); t.Type() == js.TypeString {
			term = t.String()
		}
		if err := sess.RequestPty(term, opts.Get("rows").Int(), opts.Get("cols").Int(), ssh.TerminalModes{ssh.ECHO: 1}); err != nil {
			closeAll()
			return nil, err
		}
		stdin, _ := sess.StdinPipe()
		stdout, _ := sess.StdoutPipe()
		sess.Stderr = sess.Stdout
		if err := sess.Shell(); err != nil {
			closeAll()
			return nil, err
		}

		go func() {
			buf := make([]byte, 32*1024)
			for {
				n, err := stdout.Read(buf)
				if n > 0 {
					onData.Invoke(bytesToJS(buf[:n]))
				}
				if err != nil {
					break
				}
			}
			reason := ""
			if err := sess.Wait(); err != nil {
				reason = err.Error()
			}
			closeAll()
			if onClose.Type() == js.TypeFunction {
				onClose.Invoke(reason)
			}
		}()

		handle := js.Global().Get("Object").New()
		handle.Set("write", js.FuncOf(func(_ js.Value, a []js.Value) any {
			b := bytesFromJS(a[0])
			go stdin.Write(b)
			return nil
		}))
		handle.Set("resize", js.FuncOf(func(_ js.Value, a []js.Value) any {
			cols, rows := a[0].Int(), a[1].Int()
			go sess.WindowChange(rows, cols)
			return nil
		}))
		handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
			go closeAll()
			return nil
		}))
		return handle, nil
	})
}

// ---------------------------------------------------------------- keys

func generateKey(_ js.Value, args []js.Value) any {
	comment := ""
	if len(args) > 0 && args[0].Type() == js.TypeString {
		comment = args[0].String()
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	block, err := ssh.MarshalPrivateKey(priv, comment)
	if err != nil {
		panic(err)
	}
	sp, _ := ssh.NewPublicKey(pub)
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	if comment != "" {
		line += " " + comment
	}
	out := js.Global().Get("Object").New()
	out.Set("privateKey", string(pem.EncodeToMemory(block)))
	out.Set("publicKey", line)
	return out
}

func publicKey(_ js.Value, args []js.Value) any {
	var signer ssh.Signer
	var err error
	if len(args) > 1 && args[1].Type() == js.TypeString && args[1].String() != "" {
		signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(args[0].String()), []byte(args[1].String()))
	} else {
		signer, err = ssh.ParsePrivateKey([]byte(args[0].String()))
	}
	if err != nil {
		return js.Global().Get("Error").New(err.Error())
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
}
