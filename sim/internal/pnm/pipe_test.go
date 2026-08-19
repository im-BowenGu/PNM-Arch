package pnm

import (
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// ============================================================================
// IPC mechanism tests — NamedPipe, CircuitLink, FlitMessage protocol
// ============================================================================

// ---- FlitMessage encode/decode tests ----

func TestFlitMessage_EncodeDecode(t *testing.T) {
	msg := &FlitMessage{
		Type:     MsgFlit,
		SourceID: 0x01,
		SeqNum:   0x0A,
		Payload:  []byte{0xAA, 0xBB, 0xCC},
	}
	encoded := msg.Encode()

	decoded, err := DecodeFlitMessage(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Type != MsgFlit {
		t.Errorf("Type = %d, want %d", decoded.Type, MsgFlit)
	}
	if decoded.SourceID != 0x01 {
		t.Errorf("SourceID = 0x%02X, want 0x01", decoded.SourceID)
	}
	if decoded.SeqNum != 0x0A {
		t.Errorf("SeqNum = 0x%02X, want 0x0A", decoded.SeqNum)
	}
	if len(decoded.Payload) != 3 || decoded.Payload[0] != 0xAA || decoded.Payload[1] != 0xBB || decoded.Payload[2] != 0xCC {
		t.Errorf("Payload = %v", decoded.Payload)
	}
}

func TestFlitMessage_EmptyPayload(t *testing.T) {
	msg := &FlitMessage{Type: MsgPing, SourceID: 0, SeqNum: 0, Payload: nil}
	encoded := msg.Encode()
	decoded, err := DecodeFlitMessage(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Payload) != 0 {
		t.Errorf("Payload len = %d, want 0", len(decoded.Payload))
	}
}

func TestFlitMessage_TooShort(t *testing.T) {
	_, err := DecodeFlitMessage([]byte{0x01, 0x02})
	if err == nil {
		t.Error("expected error for too-short message")
	}
}

func TestFlitMessage_TruncatedPayload(t *testing.T) {
	// Header says payload is 10 bytes but only 3 are present
	msg := &FlitMessage{Type: MsgFlit, Payload: make([]byte, 10)}
	encoded := msg.Encode()
	// Truncate
	_, err := DecodeFlitMessage(encoded[:8])
	if err == nil {
		t.Error("expected error for truncated payload")
	}
}

func TestFlitMessage_AllTypes(t *testing.T) {
	types := []MsgType{MsgFlit, MsgStimulus, MsgResult, MsgControl, MsgPing, MsgPong}
	for _, mt := range types {
		msg := &FlitMessage{Type: mt, Payload: []byte{0x01}}
		decoded, err := DecodeFlitMessage(msg.Encode())
		if err != nil {
			t.Fatalf("Type %d: %v", mt, err)
		}
		if decoded.Type != mt {
			t.Errorf("Type roundtrip: got %d, want %d", decoded.Type, mt)
		}
	}
}

// ---- NamedPipe tests ----

func TestNamedPipe_WriteRead(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.pipe")

	pipe, err := CreateNamedPipe(path)
	if err != nil {
		t.Fatal(err)
	}
	defer pipe.Close()

	// Write some data
	data := []byte("hello, pipe!")
	if err := pipe.Write(data); err != nil {
		t.Fatal(err)
	}

	// Read it back
	buf := make([]byte, 1024)
	n, err := pipe.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != string(data) {
		t.Errorf("read %q, want %q", string(buf[:n]), string(data))
	}
}

func TestNamedPipe_Close(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "close.pipe")

	pipe, err := CreateNamedPipe(path)
	if err != nil {
		t.Fatal(err)
	}
	pipe.Close()

	// File should be removed
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("pipe file should be removed after Close")
	}
}

// ---- CircuitLink tests ----

func TestCircuitLink_BasicSendRecv(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "test.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	// Connect a client
	client, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	// Register the client's source ID by having it send a message first
	if err := SendFlit(client, 0x01, 0x00, 0xAA); err != nil {
		t.Fatal(err)
	}

	// Server should receive it
	select {
	case received := <-server.Recv():
		if received.SourceID != 0x01 {
			t.Errorf("SourceID = 0x%02X, want 0x01", received.SourceID)
		}
		if len(received.Payload) != 1 || received.Payload[0] != 0xAA {
			t.Errorf("Payload = %v", received.Payload)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for message")
	}
}

func TestCircuitLink_Broadcast(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "broadcast.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	// Connect two clients
	client1, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client1.Close()
	client2, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client2.Close()

	// Register both by sending from them
	SendFlit(client1, 0x01, 0x00, 0x01)
	SendFlit(client2, 0x02, 0x00, 0x02)
	// Drain registration messages
	<-server.Recv()
	<-server.Recv()

	// Broadcast from server
	broadcastMsg := &FlitMessage{
		Type:     MsgControl,
		SourceID: 0xFF,
		SeqNum:   0x01,
		Payload:  []byte{0xDE, 0xAD},
	}
	if err := server.Broadcast(broadcastMsg); err != nil {
		t.Fatal(err)
	}

	// Both clients should receive
	for _, client := range []net.Conn{client1, client2} {
		client.(*net.UnixConn).SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 4096)
		n, err := client.Read(buf)
		if err != nil {
			t.Fatalf("client read: %v", err)
		}
		decoded, err := DecodeFlitMessage(buf[:n])
		if err != nil {
			t.Fatal(err)
		}
		if decoded.Type != MsgControl {
			t.Errorf("broadcast message type = %d, want %d", decoded.Type, MsgControl)
		}
	}
}

func TestCircuitLink_Bidirectional(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "bidir.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	client, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	// Register client
	SendFlit(client, 0x01, 0x00, 0x00)
	<-server.Recv()

	// Server sends to client
	serverMsg := &FlitMessage{Type: MsgFlit, SourceID: 0x01, SeqNum: 0x01, Payload: []byte{0xBB}}
	if err := server.Send(0x01, serverMsg); err != nil {
		t.Fatal(err)
	}

	// Client receives
	client.(*net.UnixConn).SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 4096)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	decoded, _ := DecodeFlitMessage(buf[:n])
	if decoded.Payload[0] != 0xBB {
		t.Errorf("client received 0x%02X, want 0xBB", decoded.Payload[0])
	}
}

func TestCircuitLink_MultipleFlits(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "multi.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	client, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	// Register
	SendFlit(client, 0x01, 0x00, 0x00)
	<-server.Recv()

	// Send 10 flits from client
	for i := 0; i < 10; i++ {
		SendFlit(client, 0x01, byte(i), byte(i))
	}

	// Receive all 10
	var received []*FlitMessage
	timeout := time.After(2 * time.Second)
	for len(received) < 10 {
		select {
		case msg := <-server.Recv():
			received = append(received, msg)
		case <-timeout:
			t.Fatalf("timeout: received %d/10 messages", len(received))
		}
	}

	// Verify sequence numbers
	for i, msg := range received {
		if msg.SeqNum != byte(i) {
			t.Errorf("message %d: SeqNum = %d, want %d", i, msg.SeqNum, i)
		}
	}
}

func TestCircuitLink_ConcurrentClients(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "concurrent.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	const numClients = 5
	clients := make([]net.Conn, numClients)
	for i := 0; i < numClients; i++ {
		c, err := ConnectClient(socketPath)
		if err != nil {
			t.Fatal(err)
		}
		clients[i] = c
		defer c.Close()
	}

	// Register all
	for i := 0; i < numClients; i++ {
		SendFlit(clients[i], byte(i), 0, 0)
	}
	for i := 0; i < numClients; i++ {
		<-server.Recv()
	}

	// Each client sends one message concurrently
	var wg sync.WaitGroup
	for i := 0; i < numClients; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			SendFlit(clients[id], byte(id), 1, byte(id))
		}(i)
	}
	wg.Wait()

	// Receive all
	var received []*FlitMessage
	timeout := time.After(2 * time.Second)
	for len(received) < numClients {
		select {
		case msg := <-server.Recv():
			received = append(received, msg)
		case <-timeout:
			t.Fatalf("timeout: received %d/%d", len(received), numClients)
		}
	}

	// Verify all source IDs are present
	seen := make(map[byte]bool)
	for _, msg := range received {
		seen[msg.SourceID] = true
	}
	for i := 0; i < numClients; i++ {
		if !seen[byte(i)] {
			t.Errorf("missing SourceID %d", i)
		}
	}
}

func TestCircuitLink_CloseCleanup(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "cleanup.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server.Close()

	// Socket file should be removed
	if _, err := os.Stat(socketPath); !os.IsNotExist(err) {
		t.Error("socket file should be removed after Close")
	}
}

// ---- Integration: Flit construction → IPC → decode ----

func TestIPC_FlitIntegration(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "integ.sock")

	server, err := NewCircuitLink(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	client, err := ConnectClient(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	// Build a PNM flit
	payload := []byte{0x10, 0x20, 0x30}
	flitStream := Flit(1, 0x23, 0x40, payload, false)

	// Register client
	SendFlit(client, 0x01, 0, 0)
	<-server.Recv()

	// Send each flit byte through IPC
	for i, sb := range flitStream {
		SendFlit(client, 0x01, byte(i), sb.Data)
	}

	// Receive all bytes
	received := make([]*FlitMessage, 0, len(flitStream))
	timeout := time.After(2 * time.Second)
	for len(received) < len(flitStream) {
		select {
		case msg := <-server.Recv():
			received = append(received, msg)
		case <-timeout:
			t.Fatalf("timeout: got %d/%d bytes", len(received), len(flitStream))
		}
	}

	// Reconstruct and verify
	reconstructed := make([]byte, len(received))
	for i, msg := range received {
		reconstructed[i] = msg.Payload[0]
	}

	// First byte should be LAYER_ID = 0x01
	if reconstructed[0] != 0x01 {
		t.Errorf("LAYER_ID = 0x%02X, want 0x01", reconstructed[0])
	}
	// MODULE_ID = 0x23
	if reconstructed[1] != 0x23 {
		t.Errorf("MODULE_ID = 0x%02X, want 0x23", reconstructed[1])
	}
}
