package pnm

import (
	"testing"
)

// TestLustreStripeNoAlias guards against object extents overlapping on one
// OST.  Each object owns stripeSize/512 blocks; consecutive object IDs must
// be spaced by that extent, or stripe N+1's blocks land inside stripe N's and
// the second write clobbers the first (detected via the NVMe block store:
// every block stripe 0 wrote must still hold stripe 0's payload byte).
func TestLustreStripeNoAlias(t *testing.T) {
	dev := NewNVMeDev(0xD0000000)
	if err := dev.Init(); err != nil {
		t.Fatal(err)
	}
	lc, err := NewLustreClient(dev, 1) // one OST: all stripes map to it
	if err != nil {
		t.Fatal(err)
	}
	fd, err := lc.Create("f", 4, 4096)
	if err != nil {
		t.Fatal(err)
	}
	const perStripe = 4096
	data := make([]byte, 4*perStripe)
	for i := range data {
		data[i] = byte(i ^ (i >> 8)) // varies at block boundaries
	}
	if _, err := lc.Write(fd, 0, data); err != nil {
		t.Fatal(err)
	}

	// Verify no block belonging to stripe 0 was overwritten by a later
	// stripe: the block store must hold stripe 0's bytes at every LBA the
	// first stripe touched.
	stripe0LBA := lc.objLBA(&lc.OSTs[0], lc.Files[fd].ObjIDBase, lc.Files[fd].StripeSize)
	for blk := uint64(0); blk < perStripe/NVMEBlockSize; blk++ {
		b, ok := dev.blocks[stripe0LBA+blk]
		if !ok {
			t.Fatalf("stripe 0 block %d (LBA %d) never written", blk, stripe0LBA+blk)
		}
		for j := 0; j < NVMEBlockSize; j++ {
			want := byte(bitsAt(int(blk*NVMEBlockSize + uint64(j))))
			if b[j] != want {
				t.Fatalf("stripe 0 block %d byte %d = %02x, want %02x (later stripe aliased it)",
					blk, j, b[j], want)
			}
		}
	}
}

func bitsAt(i int) int {
	return i ^ (i >> 8)
}

// TestLustreObjSpacing guards the LBA arithmetic itself: object N+1 must start
// stripeSize/512 blocks after object N on the same OST.
func TestLustreObjSpacing(t *testing.T) {
	dev := NewNVMeDev(0xD0000000)
	if err := dev.Init(); err != nil {
		t.Fatal(err)
	}
	lc, err := NewLustreClient(dev, 2)
	if err != nil {
		t.Fatal(err)
	}
	fd, err := lc.Create("f", 4, 4096)
	if err != nil {
		t.Fatal(err)
	}
	for i := uint64(0); i+1 < 4; i++ {
		l0 := lc.objLBA(&lc.OSTs[0], lc.Files[fd].ObjIDBase+i, 4096)
		l1 := lc.objLBA(&lc.OSTs[0], lc.Files[fd].ObjIDBase+i+1, 4096)
		if l1-l0 != 4096/NVMEBlockSize {
			t.Fatalf("objects %d and %d on OST 0 are %d blocks apart, want %d (alias)",
				i, i+1, l1-l0, 4096/NVMEBlockSize)
		}
	}
}