package pnm

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

// ============================================================================
// pipe.go — IPC primitives for linking Verilog circuits via Go
//
// Provides three mechanisms:
//   1. NamedPipe: OS-level FIFO for byte-stream IPC between Go and Verilog
//   2. CircuitLink: Socket-based real-time flit exchange between simulations
//   3. FlitMessage: Binary wire protocol for circuit-to-circuit communication
//
// The named pipe is the simplest IPC: Go writes stimulus, Verilog reads via
// $fopen/$fgets, writes results back, Go reads via os.ReadFile. Useful for
// single-direction channels.
//
// The CircuitLink is bidirectional: a Go server accepts connections from
// multiple Verilog testbench clients (via C wrapper or Go subprocess) and
// routes flits between them in real time.
// ============================================================================

// MsgType identifies the kind of IPC message.
type MsgType byte

const (
	MsgFlit     MsgType = 0x01 // Raw flit byte with metadata
	MsgStimulus MsgType = 0x02 // Stimulus vector (batch of flit bytes)
	MsgResult   MsgType = 0x03 // Verification result
	MsgControl  MsgType = 0x04 // Control signal (reset, done, error)
	MsgPing     MsgType = 0x05 // Keepalive
	MsgPong     MsgType = 0x06 // Keepalive response
)

// FlitMessage is the binary wire format for IPC:
//
//	[0]    MsgType
//	[1:2]  PayloadLen (big-endian uint16)
//	[3]    SourceID (which circuit instance)
//	[4]    SeqNum (sequence number for ordering)
//	[5..]  Payload (PayloadLen bytes)
type FlitMessage struct {
	Type     MsgType
	SourceID byte
	SeqNum   byte
	Payload  []byte
}

const flitHdrLen = 5 // type(1) + len(2) + src(1) + seq(1)

// Encode serializes a FlitMessage to bytes.
func (m *FlitMessage) Encode() []byte {
	buf := make([]byte, flitHdrLen+len(m.Payload))
	buf[0] = byte(m.Type)
	binary.BigEndian.PutUint16(buf[1:3], uint16(len(m.Payload)))
	buf[3] = m.SourceID
	buf[4] = m.SeqNum
	copy(buf[flitHdrLen:], m.Payload)
	return buf
}

// DecodeFlitMessage deserializes a FlitMessage from bytes.
func DecodeFlitMessage(data []byte) (*FlitMessage, error) {
	if len(data) < flitHdrLen {
		return nil, fmt.Errorf("message too short: %d < %d", len(data), flitHdrLen)
	}
	plen := int(binary.BigEndian.Uint16(data[1:3]))
	if len(data) < flitHdrLen+plen {
		return nil, fmt.Errorf("payload truncated: have %d, need %d", len(data)-flitHdrLen, plen)
	}
	return &FlitMessage{
		Type:     MsgType(data[0]),
		SourceID: data[3],
		SeqNum:   data[4],
		Payload:  append([]byte(nil), data[flitHdrLen:flitHdrLen+plen]...),
	}, nil
}

// ============================================================================
// NamedPipe — OS FIFO-based IPC
// ============================================================================

// NamedPipe wraps an OS file for byte-stream IPC.
type NamedPipe struct {
	path string
	wf   *os.File // write handle
	rf   *os.File // read handle
	mu   sync.Mutex
}

// CreateNamedPipe creates a pipe file for IPC.
func CreateNamedPipe(path string) (*NamedPipe, error) {
	os.Remove(path) // clean up stale
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("create pipe: %w", err)
	}
	// Open a second handle for reading (shares the same file)
	rf, err := os.Open(path)
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("open pipe for read: %w", err)
	}
	return &NamedPipe{path: path, wf: f, rf: rf}, nil
}

// OpenNamedPipe opens an existing pipe for reading.
func OpenNamedPipe(path string) (*NamedPipe, error) {
	for i := 0; i < 100; i++ {
		rf, err := os.Open(path)
		if err == nil {
			wf, err := os.OpenFile(path, os.O_WRONLY, 0o644)
			if err != nil {
				rf.Close()
				return nil, fmt.Errorf("open pipe for write: %w", err)
			}
			return &NamedPipe{path: path, wf: wf, rf: rf}, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, fmt.Errorf("open pipe %s: timeout", path)
}

// Write sends bytes through the pipe.
func (p *NamedPipe) Write(data []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err := p.wf.Write(data)
	return err
}

// Read receives bytes from the pipe.
func (p *NamedPipe) Read(buf []byte) (int, error) {
	return p.rf.Read(buf)
}

// Close cleans up the pipe.
func (p *NamedPipe) Close() error {
	p.wf.Close()
	p.rf.Close()
	return os.Remove(p.path)
}

// Path returns the filesystem path.
func (p *NamedPipe) Path() string { return p.path }

// ============================================================================
// CircuitLink — Bidirectional socket-based IPC
// ============================================================================

// CircuitLink manages real-time flit exchange between Go and Verilog circuits.
// It uses Unix domain sockets for low-latency IPC.
type CircuitLink struct {
	listener net.Listener
	conns    map[byte]net.Conn // sourceID -> connection
	mu       sync.RWMutex
	msgCh    chan *FlitMessage
	done     chan struct{}
	once     sync.Once
}

// NewCircuitLink creates a socket-based IPC server.
func NewCircuitLink(socketPath string) (*CircuitLink, error) {
	os.Remove(socketPath) // clean up stale socket
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}
	cl := &CircuitLink{
		listener: ln,
		conns:    make(map[byte]net.Conn),
		msgCh:    make(chan *FlitMessage, 1024),
		done:     make(chan struct{}),
	}
	go cl.acceptLoop()
	return cl, nil
}

// acceptLoop handles incoming connections from Verilog clients.
func (cl *CircuitLink) acceptLoop() {
	for {
		conn, err := cl.listener.Accept()
		if err != nil {
			select {
			case <-cl.done:
				return
			default:
				continue
			}
		}
		go cl.handleConn(conn)
	}
}

// handleConn reads FlitMessages from a client connection.
func (cl *CircuitLink) handleConn(conn net.Conn) {
	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			if err != io.EOF {
				// log error
			}
			return
		}
		// Parse messages from the buffer
		offset := 0
		for offset < n {
			if n-offset < flitHdrLen {
				break
			}
			plen := int(binary.BigEndian.Uint16(buf[offset+1 : offset+3]))
			msgLen := flitHdrLen + plen
			if n-offset < msgLen {
				break
			}
			msg, err := DecodeFlitMessage(buf[offset : offset+msgLen])
			if err != nil {
				break
			}
			// Register source
			cl.mu.Lock()
			cl.conns[msg.SourceID] = conn
			cl.mu.Unlock()

			cl.msgCh <- msg
			offset += msgLen
		}
	}
}

// Send writes a FlitMessage to a specific circuit instance.
func (cl *CircuitLink) Send(sourceID byte, msg *FlitMessage) error {
	cl.mu.RLock()
	conn, ok := cl.conns[sourceID]
	cl.mu.RUnlock()
	if !ok {
		return fmt.Errorf("no connection for source %d", sourceID)
	}
	_, err := conn.Write(msg.Encode())
	return err
}

// Broadcast sends a FlitMessage to all connected circuits.
func (cl *CircuitLink) Broadcast(msg *FlitMessage) error {
	cl.mu.RLock()
	defer cl.mu.RUnlock()
	data := msg.Encode()
	for _, conn := range cl.conns {
		if _, err := conn.Write(data); err != nil {
			return err
		}
	}
	return nil
}

// Recv returns the next FlitMessage from any circuit.
func (cl *CircuitLink) Recv() <-chan *FlitMessage {
	return cl.msgCh
}

// Close shuts down the IPC server.
func (cl *CircuitLink) Close() {
	cl.once.Do(func() {
		close(cl.done)
		cl.listener.Close()
		cl.mu.Lock()
		for _, conn := range cl.conns {
			conn.Close()
		}
		cl.mu.Unlock()
	})
}

// SocketPath returns the socket file path.
func (cl *CircuitLink) SocketPath() string {
	return cl.listener.Addr().String()
}

// ============================================================================
// ConnectClient — Verilog-side client (used from Go subprocess or C DPI)
// ============================================================================

// ConnectClient connects to a CircuitLink server.
func ConnectClient(socketPath string) (net.Conn, error) {
	for i := 0; i < 100; i++ {
		conn, err := net.Dial("unix", socketPath)
		if err == nil {
			return conn, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, fmt.Errorf("connect to %s: timeout", socketPath)
}

// SendFlit sends a single flit byte through a client connection.
func SendFlit(conn net.Conn, srcID, seq byte, data byte) error {
	msg := &FlitMessage{
		Type:     MsgFlit,
		SourceID: srcID,
		SeqNum:   seq,
		Payload:  []byte{data},
	}
	_, err := conn.Write(msg.Encode())
	return err
}

// RecvFlit reads a single FlitMessage from a client connection.
func RecvFlit(conn net.Conn) (*FlitMessage, error) {
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}
	return DecodeFlitMessage(buf[:n])
}
