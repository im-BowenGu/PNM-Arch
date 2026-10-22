package pnm

import "testing"

// ============================================================================
// FlitMessage protocol tests
// ============================================================================

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
