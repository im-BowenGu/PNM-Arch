package pnm

import (
	"encoding/binary"
	"fmt"
)

// ============================================================================
// pipe.go — the FlitMessage wire protocol
//
// A small, typed envelope for circuit-to-circuit messages.  The socket IPC
// server and the named-pipe wrappers that used to live here were removed:
// nothing outside their own tests ever used them, and the harness talks to
// the RTL through the vvp server file handshake (gating_harness.go,
// node_harness.go) instead.
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
