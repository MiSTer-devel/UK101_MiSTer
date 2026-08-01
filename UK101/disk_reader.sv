//============================================================================
// SD-image disk-track reader/writer for UK101 disk emulation
//
// Step 2 proved the SD-image read pipeline in isolation by always loading a
// hardcoded track 0. Step 3 replaces that with a real seek: DiskPia's
// stepper outputs drive a track counter in uk101.vhd (trackNumber/
// trackChanged), and every confirmed step here re-loads the newly-selected
// track from the mounted .65D image, the same way a mount loads track 0.
//
// Phase B (2026-07-26): adds write support. OS-65D's own write primitive
// (disassembled from a real image - see SAVE_AND_DISK_PLAN.md) always
// positions itself via the same header-search/index-sync mechanism reads
// already use, before ever asserting write-enable - so the existing
// seek/read_ptr machinery below needs no new positioning logic for writes;
// it already lands in the right place by the time a write starts. Bytes
// written by the CPU are captured into the SAME track buffer at the SAME
// shared pointer (read_ptr) that already serves reads, and the whole
// buffer's already-loaded sector span is written back to the SD image the
// moment write-enable deasserts - mirroring WinOSI's own
// assert-write-deassert-then-flush model, confirmed independently from
// OS-65D's own disassembly, not just from the reference emulator.
//
// Track byte offset within the image = track_number * TRKSIZ. Because TRKSIZ
// (2304 for the 5.25" C1PMF target) is not a multiple of 512, most tracks
// start at a non-sector-aligned byte offset - so each load computes its own
// start LBA, its in-sector start offset, and how many sectors are needed to
// cover the track from there, instead of always starting at sector 0. This
// same [start_lba, nsect_this_load) span is reused verbatim for the
// write-back, which makes it an inherently correct read-modify-write: the
// straddle bytes outside [sub_offset, sub_offset+trksiz) were already read
// from the image and are never touched by a write, so writing the whole
// loaded span back is always safe.
//
// CDC notes: track_byte_strobe (byte-consumed toggle), tx_byte_strobe
// (byte-written toggle), and track_changed_raw (step-confirmed toggle) all
// cross from the CPU clock domain into clk_sys via the same 3-stage
// synchronizer + XOR edge-detector pattern proven in Phase 1
// (save_data/save_strobe). track_number_raw and tx_byte_raw are multi-bit
// registers that only change once per event, many clk_sys cycles apart - by
// the time their respective strobe's synchronized edge fires, they have
// long since settled, so a plain 2-flop synchronizer (for metastability
// only, not glitch-avoidance) is sufficient, matching the precedent set by
// track_byte itself (also multi-bit, also read directly across domains).
//============================================================================

module disk_reader
(
	input         clk_sys,
	input         reset,

	input         img_mounted,  // this slot's one-shot mount pulse
	input  [63:0] img_size,     // valid at img_mounted

	output reg [31:0] sd_lba,
	output reg        sd_rd,
	output reg        sd_wr,
	input             sd_ack,

	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,
	output      [7:0] sd_buff_din,

	// CDC interface to DiskAcia.vhd (CPU clock domain) - read side
	input         track_byte_strobe_raw, // toggles once per CPU read of $C011
	output  [7:0] track_byte,

	// CDC interface to DiskAcia.vhd (CPU clock domain) - write side (Phase B)
	input         tx_byte_strobe_raw, // toggles once per CPU write to $C011
	input   [7:0] tx_byte_raw,        // byte written, valid at the strobe toggle
	input         n_write_enable_raw, // '0' = disk write window active (DiskPia orb bit0)

	// CDC interface to uk101.vhd's track-stepper counter (CPU clock domain)
	input   [6:0] track_number_raw,  // current head position (0..39 or 0..76)
	input         track_changed_raw, // toggles once per confirmed step

	// Phase B write-protect: '1' = writes allowed. Already in clk_sys (comes
	// from UK101.sv's OSD-toggle/img_readonly logic, not the CPU domain), so
	// no CDC needed. This is the load-bearing gate - sd_wr being forced low
	// upstream when this is '0' is a backstop, not sufficient on its own:
	// without also gating capture here, a write would still set dirty and
	// drive the flush FSM into FLUSH_WAIT_ACK waiting for an sd_ack that can
	// never arrive (hps_io never selects a slot whose sd_wr/sd_rd are both
	// low), hanging the whole module.
	input         write_ok,

	// Second-drive support (2026-07-27): '1' if THIS instance is the
	// currently drive_select-ed drive. tx_byte/tx_strobe/track_byte_strobe
	// are BROADCAST identically to every disk_reader instance from the
	// single shared ACIA - there is only one $C011 register - so this is
	// the ONLY thing that stops a deselected drive's read_ptr from also
	// advancing on every CPU access. Confirmed in simulation (COPIER, via
	// c4pmf_sim's two-drive WriteBus model) that a deselected drive's head
	// must NOT move: real hardware only moves the SELECTED drive's head on
	// a step pulse, and OS-65D's own seek-error recovery is bounded (see
	// SAVE_AND_DISK_PLAN.md's "second disk drive" section). The head position
	// is gated the same way, but upstream in uk101.vhd's stepper rather than
	// here: each instance gets its OWN track_number_raw/track_changed_raw and
	// only the selected drive's head moves. Tied '1' for a single-drive
	// (drive A only) build, matching today's behaviour.
	//
	// _raw because this is launched from DiskPia's ora(6) in the CPU bus
	// clock domain and must be synchronised before use - it gates the mem[]
	// write enable below, so an unsynchronised value could capture a byte
	// into the WRONG drive's track buffer. Same treatment as tx_byte_raw.
	input         active_raw,

	// --- ROTATIONAL READ TIMING (2026-07-30, OSD-selectable, default OFF) ---
	// '0' = the shipped, hardware-confirmed ACCESS-DRIVEN model: read_ptr
	// advances one byte per CPU access to $C011 and RDRF/TDRE are always set.
	// '1' = rotational: position advances on BYTE-TIME regardless of access,
	// and RDRF/TDRE are paced by it, as a real drive does.
	//
	// Validated in Python first (c4pmf_sim/simwrite.py, `rotational=True`,
	// model v6) - see project memory. The finding that motivates it applies
	// verbatim to THIS FILE, not just to the simulator: `indexHole` in
	// uk101.vhd is a free-running counter with NO relationship to read_ptr,
	// so index-hole-synced software gets a position answer unrelated to the
	// index it just observed. That is harmless while access-driven (a seek
	// resets read_ptr to 0, so "first byte after the index" IS image byte 0
	// whatever the index phase) and fatal once position rotates. Under
	// rotational mode the index hole is therefore derived from THIS counter -
	// one clock, by construction, exactly as the physical index hole is a
	// feature of the same rotating disk (WinOSI: 6502.H:346/357 gate INDEX_D
	// on disk_track_pos, the same counter that advances head_pos).
	input         rotational,

	// Rotational status outputs, consumed by DiskAcia via uk101.vhd. Both
	// tied '1' when `rotational` is '0', so the access-driven status byte
	// stays bit-identical to the "00000011" it has always been.
	output        rdrf,        // bit0: a data byte is under the head
	output        tdre,        // bit1: the drive can accept a byte
	output        index_hole_n,// active LOW, PIA port A bit7

	output        busy,  // debug aid: high while a track load or flush is in progress

	// High ONLY while an SD track load is in flight (deliberately not `busy`,
	// which also covers a flush - during a flush mem[] is intact and perfectly
	// readable, so stalling the CPU then would be wrong).
	//
	// Exported so DiskAcia can hold RDRF and TDRE CLEAR for the duration. The
	// bug this fixes: a load overwrites the whole of mem[] over hundreds of
	// microseconds, and until now the ACIA reported "byte ready" and "ready to
	// accept" throughout. So a CPU read landing in that window was served a
	// byte out of a buffer being actively rewritten, AND advanced read_ptr past
	// it (the advance below is gated on `consume_edge || tx_accept`, with no
	// !loading term) - reading wrong data and losing sync in one go. On the
	// write side it is worse than wrong data: tx_accept already refuses a byte
	// while loading, so a TDRE of 1 told the CPU a write had been accepted when
	// it was silently dropped.
	//
	// Whether a read lands in the window is a race between the DOS's own
	// post-seek code and how long hps_io/the ARM take, which is why the
	// resulting faults are intermittent rather than repeatable.
	output        loading
);

localparam BUFSECT = 9; // physical buffer capacity - covers both 5.25" (needs
                        // up to 6 incl. worst-case sub-sector offset) and 8"
                        // (needs up to 9) geometries

reg [7:0] mem [0:BUFSECT*512-1];
reg [7:0] rdata;    // CPU-facing read port - always tracks sub_offset+read_ptr,
                    // independent of any load/flush in progress. OS-65D's own
                    // write primitive does a read-back verify of the same
                    // sector immediately after write-enable deasserts
                    // (confirmed by disassembly), so this port must never be
                    // diverted to serve a flush in progress - it always sees
                    // the buffer's current, already-correct contents.
reg [7:0] rdata_sd; // SD-write source port, only meaningful while flushing
// NOTE: exactly TWO read ports off mem[] - and it must stay that way. An
// earlier version of the trailer-skip fix below added a third (to peek at
// mem[read_ptr+1]); elaboration passed clean, but synthesis then failed to
// infer block RAM for ANY of them and turned all three into 8192:1 logic
// muxes at ~43k LEs each (~131k LEs on a 41,910-ALM device - unfittable).
// Elaboration does not catch this; only a full compile does.

reg [15:0] read_ptr;
reg [3:0]  sector;
reg [3:0]  nsect_this_load;
reg [31:0] start_lba;
reg [8:0]  sub_offset;
reg        dirty;         // has anything been captured since the last flush
reg        flush_pending; // latched write-window-end, awaiting IDLE
reg        peek_pending;  // 2nd cycle of the trailer confirm - see below

// ===================== PACKED WRITE POINTER (rotational only) =============
// THE write address under rotational timing. Anchored to the head - set to
// "one past the last byte actually delivered to the CPU" on every real read,
// then advanced one per accepted write - so what lands in the image is PACKED
// (no gap) but positioned where the DOS believes it is writing.
//
// This replaces two earlier answers, both of which failed on hardware:
//
//  1. Writing at the ROTATIONAL position (rot_img). Stores the idle
//     byte-times between "last byte read" and "first byte written" as real
//     bytes - i.e. writes the physical inter-record GAP that `.65D`/`.65U`
//     does not have (the format stores the Nth transferred byte at offset N).
//     Measured 22 bytes on the CREATE path; the record no longer parses and
//     OS-65D's verify-reread fails with ERR #2. Hardware-confirmed.
//
//  2. Writing at read_ptr. WORSE, and the reason this file is being changed
//     again: read_ptr is a cumulative consumed-bytes ODOMETER reset only by a
//     seek, while the DOS re-anchors to the index hole before every access -
//     so the two diverge by however many byte-times the CPU spent not reading.
//     PROVEN by byte-diffing a real corrupted 8" image (C1P-OS65D338_1.65U):
//     a 261-byte sector-1 record landed at track-8 offset 267 instead of 4,
//     displaced by exactly the 263 bytes consumed reading the directory before
//     the DOS re-synced and rewrote it. It overwrote sector 2's payload and
//     destroyed sector 3's `$76 03` header, after which any hunt for the next
//     header ran on into data and read a garbage page count - the "dramatic
//     crash with garbage on screen" that this replaced ERR #2 with.
//
// Validated before building: c4pmf_sim/packed_write_test.py replays the same
// byte-exact CREATE sequence the shipped access-driven fix was validated
// against. Rotational write => ERR #2 (reproduces the hardware failure);
// packed write alone => completes but 131 bytes differ; packed write plus the
// trailer-skip below => BYTE-IDENTICAL to the known-good image.
reg [12:0] wr_ptr = 13'd0;

// Runtime disk geometry, auto-detected from img_size at mount:
//   5.25" C1PMF/C4PMF/C8PDF-5.25 = 92160 bytes  (40 tracks x 2304)
//   8"    C8PDF / C1P-8in / C2-C4-8in = 295680 bytes (77 tracks x 3840)
// The whole OS-65D disk (both sizes) is a flat track*TRKSIZ layout, so this
// single value drives every geometry-dependent expression below. Latched
// once per mount; the mount-triggered seek is always to track 0 (offset 0),
// so trksiz is settled well before any step-triggered seek needs it.
reg [12:0] trksiz = 13'd2304;
always @(posedge clk_sys) begin
	// NOT cleared by CPU reset: geometry belongs to the mounted image, not CPU
	// state. A reset (buttons[1]/status[0]) with an 8" disk still in the drive
	// must NOT revert trksiz to the 2304 default - that desyncs every track
	// offset and hangs the next "D" boot (5.25" is immune since 2304 is its
	// correct value). Only a new mount changes it; the power-on init value
	// covers cold start. Mirrors disk_is_8inch in UK101.sv (also reset-immune).
	if (img_mounted && img_size != 0)
		trksiz <= (img_size == 64'd295680) ? 13'd3840 : 13'd2304;
end

// Has an image ever been mounted in THIS slot? Reset-immune for the same
// reason trksiz is: it describes the drive's contents, not CPU state.
//
// Guards the case where software selects and seeks a drive that has no disk
// in it. Without this an empty slot would answer that seek by entering
// READ_ASSERT and asserting sd_rd on a slot hps_io has no image for, then sit
// in READ_WAIT_ACK forever waiting for an ack that never comes. That is not
// merely a stuck instance: hps_io picks the slot to service with a round-robin
// over everything asserting sd_rd/sd_wr (sys/hps_io.sv, `sdn`), so a
// permanently-asserted empty slot would keep stealing arbitration turns from
// the drive that DOES have a disk in it.
//
// Less easily provoked now that the head position is per-drive (an empty
// drive B no longer follows drive A's seeks), but still reachable: OS-65D
// homes a drive when it switches to it, so asking for drive B with nothing
// mounted issues real step pulses to an empty slot. Kept deliberately.
reg ever_mounted = 1'b0;
always @(posedge clk_sys) begin
	if (img_mounted && img_size != 0) ever_mounted <= 1'b1;
end

// ===================== ROTATIONAL POSITION MODEL =========================
//
// Ported from the Python model validated as v6 (c4pmf_sim/simwrite.py). The
// structure mirrors WinOSI's, which is the reference implementation:
//
//   W_osi.cpp:25  #define index_bytes 0x20                 (32-byte index zone)
//   W_osi.cpp:27  #define track_buffer_size (TRKSIZ+index_bytes)
//   W_osi.cpp:105 disk_track_pos += ticks;  ... head_pos++
//   6502.H:346    if(disk_track_pos <= (index_delay - disk_data_ticks)) ...
//   6502.H:357        *portaptr ^= INDEX_D;   // index asserted (low)
//
// A revolution is trksiz+32 byte-times. Positions 0..31 are the INDEX ZONE:
// no data byte is available there (WinOSI marks it track_empty[],
// Fileio.h:340, and gates RDRF on !track_empty[], 6502.H:266), and image data
// starts at zone position 32 (Fileio.h:211, `track_start = &track[index_bytes]`
// is what its file I/O actually transfers). The zone is what gives real
// firmware its ~32-byte grace window between "index seen" and "image byte 0".
localparam ROT_INDEX_BYTES = 13'd32;

// Byte period in clk_sys (48MHz) cycles. NOTE this is deliberately a function
// of the DISK, not of the CPU clock: the data rate is a physical property of
// the drive and does not change when the user overclocks the CPU via
// status[19:17]. Derived from geometry, not guessed - and the 5.25" figure
// independently reproduces WinOSI's own hardcoded disk_data_ticks of 88
// cycles-per-byte-at-1MHz, which is a useful cross-check that 88 is
// specifically the 5.25" rate:
//   5.25" : 2304 B/track @ 300 rpm = 11520 B/s -> 48e6/11520 = 4167
//   8"    : 3840 B/track @ 360 rpm = 23040 B/s -> 48e6/23040 = 2083
// (The Python model used 88 for BOTH, i.e. 176 rpm on 8" - a real 2x
// calibration error there, corrected here.)
// ONE FLAT RATE FOR BOTH GEOMETRIES. Corrected 2026-07-30 after 8" C1P disks
// would not boot under rotational timing while 5.25" did.
//
// The byte rate is set by the ACIA's own divider, NOT by the spindle. WinOSI:
//     W_osi.cpp:24  #define disk_data_ticks 8*11
//                   // 88 at 125khz rate and 11bits (S+8DB+P+S) (ACIA $58)
//     W_osi.cpp:31  #define disk_track_time (track_buffer_size*disk_data_ticks)
// disk_data_ticks has NO geometry term. Only the REVOLUTION scales with TRKSIZ,
// because an 8" track holds more bytes at the same rate - it takes LONGER per
// revolution, not the same time at double speed. And $58 is the control word
// OS-65D writes to $C010 before every transfer, identically on both disk types.
//
// 48e6 / (125000/11) = 4136, and WinOSI's own 88 CPU-cycles-at-1MHz is 4224 in
// clk_sys terms; 4167 sits between them and is the value 5.25" has been running
// correctly with all along, so it is kept rather than re-derived.
//
// THE MISTAKE, worth recording because it looked like rigour: the previous value
// was 2083 for 8", derived from real-drive physics - 3840 B/track at 360 rpm.
// That is what a genuine 8" drive does, and it is irrelevant here, because this
// hardware's rate comes from the ACIA divider. So 8" was being fed bytes twice
// as fast as the DOS expects and its boot poll loop could not keep up, while
// 5.25" was untouched. Deriving a constant from first principles is no defence
// against deriving the WRONG first principle - the reference had the answer.
//
// A prior note in project memory ("switching 8\" to 44 cyc/byte makes CREATE
// WORSE") was already evidence for this and was misread at the time as a
// calibration bug still to be fixed, rather than as confirmation that 88 was
// right for both.
wire [12:0] rot_byte_div = 13'd4167;

reg  [12:0] rot_div = 13'd0;   // clk_sys prescaler within one byte-time
reg  [12:0] rot_pos = 13'd0;   // 0 .. trksiz+31, WinOSI's head_pos
reg  [12:0] served  = 13'h1FFF;// last position delivered/accepted to the CPU

// WinOSI's head_pos_before. The sentinel 13'h1FFF (8191) is unreachable by
// rot_pos (max trksiz+31 = 3871), so a fresh seek always presents "moved".
//
// This MUST be in whole-revolution position space, not image space. Storing
// the image position instead is a bug I actually made and had to chase in the
// Python model: image position clamps the entire index zone onto 0, so a
// `served` recorded during the zone marks image byte 0 as already delivered
// and every track read silently starts at byte 1.
wire        rot_in_zone = (rot_pos < ROT_INDEX_BYTES);
wire [12:0] rot_img     = rot_in_zone ? 13'd0 : (rot_pos - ROT_INDEX_BYTES);
wire        rot_moved   = (rot_pos != served);

// RDRF additionally requires a real byte under the head; TDRE does not - they
// are NOT the same condition (6502.H:264-269, where only RDRF is qualified by
// !track_empty[head_pos]). Getting this wrong in the obvious direction -
// clearing both over the index zone - needlessly stalls the write side for 32
// byte-times every revolution.
// NOTE: rdrf/tdre are assigned further down, immediately after `loading` is
// declared, because they depend on it. Assigning them here would be a forward
// reference to a not-yet-declared net - Quartus elaborated that quietly, but
// an implicit 1-bit net colliding with the later explicit declaration is not
// something to leave to tool tolerance.
assign index_hole_n = (rotational && rot_in_zone) ? 1'b0 : 1'b1;

localparam IDLE           = 3'd0,
           READ_ASSERT    = 3'd1,
           READ_WAIT_ACK  = 3'd2,
           READ_WAIT_DONE = 3'd3,
           FLUSH_ASSERT   = 3'd4,
           FLUSH_WAIT_ACK = 3'd5,
           FLUSH_WAIT_DONE= 3'd6;
reg [2:0] state;

assign busy = (state != IDLE);

assign loading = (state == READ_ASSERT)  || (state == READ_WAIT_ACK)  || (state == READ_WAIT_DONE);

// Rotational status bits (see the ROTATIONAL POSITION MODEL block above for
// rot_moved/rot_in_zone). Placed here because both depend on `loading`.
//
// Held clear while an SD track load is in flight. A real drive has no
// "loading" state - the track is physically under the head - but we do, and
// during it mem[] is being overwritten, so serving a byte from it hands the
// CPU garbage. Access-driven mode tolerates that because read_ptr does not
// move: the CPU re-reads one stale location until the load finishes. Once
// position ROTATES, every byte-time spent loading is a byte SKIPPED.
//
// The 32-byte index zone already covers most of this, rather elegantly: a seek
// realigns rot_pos to 0, so RDRF is clear for the first 32 byte-times (1.4ms
// on 8", 2.8ms on 5.25") - head-settling time in all but name, which is
// presumably why real drives have the zone at all. But a 9-sector 8" load
// going through hps_io and the ARM is not guaranteed to finish inside 1.4ms,
// so this makes it explicit rather than incidental.
//
// TDRE is gated too. tx_accept already refuses writes while loading, so
// leaving TDRE high would tell OS-65D a dropped byte had been accepted.
assign rdrf = rotational ? (rot_moved && !rot_in_zone && !loading) : 1'b1;
assign tdre = rotational ? (rot_moved && !loading)                 : 1'b1;

// --- CDC: active_raw (CPU domain, DiskPia ora(6)) -> clk_sys ---
// TWO flops, and `active_s2` is the stage to use - not s1, and not a third
// stage. Every strobe edge-detector below fires in the cycle where its _s2
// stage holds the post-event value and _s3 still holds the pre-event one, so
// an event that happened in the CPU domain at time T is acted on here at
// T+2. active_s2 is likewise the drive-select value as it stood at time T,
// which is exactly the pairing wanted: each broadcast byte event is credited
// to whichever drive was selected WHEN THE CPU MADE THE ACCESS, not whichever
// is selected two cycles later. Same alignment tx_byte_s2 already relies on
// for wdata. Declared first because the gates below all use it.
reg active_s1 = 1'b0, active_s2 = 1'b0;
always @(posedge clk_sys) begin
	active_s1 <= active_raw;
	active_s2 <= active_s1;
end

// --- CDC: track_byte_strobe_raw (CPU domain) -> clk_sys ---
reg strobe_s1 = 1'b0, strobe_s2 = 1'b0, strobe_s3 = 1'b0;
always @(posedge clk_sys) begin
	strobe_s1 <= track_byte_strobe_raw;
	strobe_s2 <= strobe_s1;
	strobe_s3 <= strobe_s2;
end
// Gated on `active`: the raw strobe is broadcast to every disk_reader
// instance from the single shared ACIA, so this is what stops a deselected
// drive's read_ptr from advancing on someone else's read.
wire consume_edge = (strobe_s2 ^ strobe_s3) && active_s2;

// --- CDC: tx_byte_strobe_raw/tx_byte_raw (CPU domain) -> clk_sys (Phase B) ---
reg tx_strobe_s1 = 1'b0, tx_strobe_s2 = 1'b0, tx_strobe_s3 = 1'b0;
reg [7:0] tx_byte_s1 = 8'd0, tx_byte_s2 = 8'd0;
always @(posedge clk_sys) begin
	tx_strobe_s1 <= tx_byte_strobe_raw;
	tx_strobe_s2 <= tx_strobe_s1;
	tx_strobe_s3 <= tx_strobe_s2;
	tx_byte_s1   <= tx_byte_raw;
	tx_byte_s2   <= tx_byte_s1;
end
wire tx_edge = tx_strobe_s2 ^ tx_strobe_s3;

// --- CDC: n_write_enable_raw (CPU domain) -> clk_sys (Phase B) ---
// Idle default '1' (not writing) matches DiskPia's own idle output value.
reg we_n_s1 = 1'b1, we_n_s2 = 1'b1, we_n_s3 = 1'b1;
always @(posedge clk_sys) begin
	we_n_s1 <= n_write_enable_raw;
	we_n_s2 <= we_n_s1;
	we_n_s3 <= we_n_s2;
end
wire write_window_end = we_n_s2 & ~we_n_s3; // rising edge (0->1): WE deasserted

// Falling edge (1->0): WE just asserted. Drives the trailer-skip fix below -
// this is the ONLY new logic from the write-corruption investigation
// (2026-07-27), see SAVE_AND_DISK_PLAN.md's "root cause found and proven"
// entry for the full byte-exact reproduction this was validated against.
wire write_window_start = we_n_s3 & ~we_n_s2;

// Accepted during a flush as well as at idle - only a load in flight blocks
// capture. This is not a refinement: requiring state==IDLE here is exactly
// what corrupted a real 8" disk on the first hardware write test
// (2026-07-26). OS-65D writes its directory track as eight small 256-byte
// sectors, each in its own write-enable window; the whole-track flush kicked
// off by window N's deassert (8 SD sectors on an 8" track) was still running
// when window N+1 opened, so that window's first bytes were dropped. A
// dropped byte does not merely lose itself - tx_accept also gates read_ptr's
// advance below, so every following byte in the window landed one position
// early and shifted the rest of the sector left. Two bytes went that way,
// deleting the $76 $02 sector-2 header marker from the directory track and
// taking the disk's own OS65D3 system file (tracks 0..8) with it - the image
// stopped booting. Full byte-level forensics in SAVE_AND_DISK_PLAN.md's
// "First hardware write test" entry.
//
// Accepting during a flush costs nothing structurally: the mem write port is
// only claimed by the load path, and the flush sources its data from the
// separate rdata_sd port. A byte landing in a sector the flush in progress
// has already sent is handled by the dirty flag below - dirty is cleared when
// a flush STARTS, not when it completes, so any capture during the pass
// leaves it set and the next window-end flushes again.
//
// A load still blocks capture, because the load owns the mem write port and
// is overwriting the whole buffer regardless. Unlike the flush case that is
// not expected to occur: OS-65D positions itself via a header search (which
// drives this same seek/load path) before ever asserting write-enable.
// Also gated on write_ok, so a Protected mount never captures a byte, never
// sets dirty, and therefore never drives the flush FSM at all - see the
// write_ok port comment above for why that is the gate that actually matters.
// Gated on `active` for the same reason as consume_edge/peek_now above:
// tx_byte_strobe_raw is broadcast from the single shared ACIA, so this is
// what stops a deselected drive from also capturing a write meant for
// whichever drive is actually selected.
// Additionally TDRE-gated in rotational mode, mirroring WinOSI's write handler
// which only accepts a $C011 store `if ((*acia2cptr&0x02)!=0)` and SILENTLY
// DROPS it otherwise (6502.H:599). Without this the CPU can write faster than
// the modelled disk can physically accept, which desyncs OS-65D's own position
// bookkeeping from what a real drive would have taken. No combinational loop:
// tdre is derived from the REGISTERED `served`.
// Trailer-confirm sequencer state. Declared HERE, ahead of its own logic near
// rd_addr, purely because tx_accept just below must reference pk_busy and a
// forward reference would risk an implicit net colliding with the explicit
// declaration - the same trap already flagged for rdrf/tdre above.
localparam PK_IDLE = 3'd0, PK_REQ = 3'd1, PK_A = 3'd2, PK_B = 3'd3, PK_C = 3'd4;
reg  [2:0] pk_state = PK_IDLE;
reg        pk_got47 = 1'b0;
// The confirm borrows the CPU read port, which rx_latch also samples at
// rot_div == 4. Derivation of the exclusion, since an off-by-one here would be
// an intermittent one-byte read fault: entering PK_A takes one cycle, so
// PK_A/PK_B/PK_C land at rot_div+1/+2/+3 counted from here. rdata is stale only
// in PK_B and PK_C (PK_A still shows the previous cycle's cur_ptr fetch), so
// rot_div+2 and rot_div+3 must both avoid 4 - i.e. rot_div must not be 1 or 2.
// Requiring >= 5 covers that with margin and costs at most a 5-cycle wait.
// No upper exclusion is needed: rot_div wraps to 0 at rot_byte_div-1, so a
// confirm starting near the top of a byte-time lands on 0/1/2, never 4.
wire       pk_safe = (rot_div >= 13'd5);
wire       pk_busy = (pk_state != PK_IDLE);

// Also blocked while the trailer confirm below is resolving, because that
// confirm can still move wr_ptr by 2 and a byte accepted first would land
// before the move and then be followed by a jump - splitting one record.
// Cannot drop a byte: pk_busy is raised by write_window_start and clears in at
// most 8 clk_sys cycles (up to 5 waiting for pk_safe, then 3 to sequence).
// After the $C002 store that opens the window, the CPU needs at least a load
// and a store to reach $C011 - 8 CPU cycles, which is 800ns even at the fastest
// overclock this core offers (10MHz, uk101.vhd's cpuOverclock = 4), or ~38
// clk_sys cycles. Deliberately checked against the OVERCLOCKED case rather than
// the 1MHz one the older comments here assume, because that is the margin that
// actually has to hold. Same class of bus-timing guarantee as the port-borrow
// argument on rd_addr below.
wire tx_accept = tx_edge && !loading && !seek_pending && write_ok && active_s2
                 && (!rotational || (tdre && !pk_busy));

// NOTE: the index-zone write suppression that used to sit here is GONE, and
// its removal is part of the packed-write fix rather than an oversight. It
// existed because a ROTATIONAL write address points into the index zone for 32
// byte-times a revolution, where cur_ptr clamps the whole zone onto image byte
// 0 - so an unsuppressed write there corrupted byte 0. wr_ptr can never point
// into the zone: it is a packed image position by construction. Suppressing on
// head position would now simply DISCARD good bytes whenever the head happened
// to be over the zone, tearing a hole in the middle of a record. The simulator
// model that validated this fix likewise does not apply it.

// --- Capture incoming sector bytes whenever hps_io delivers one (load), or
// the CPU writes a byte during an active write window (Phase B) ---
// --- Serve bytes out to the CPU: registered read (infers as block RAM) ---
// --- Serve bytes out to hps_io during a flush (Phase B) ---
// sd_ack is qualified on the load path (not just sd_buff_wr) because slot 1
// is the only slot this module drives sd_rd/sd_wr for - the extra qualifier
// makes that an enforced invariant rather than an incidental one.
wire        we    = loading ? (sd_buff_wr && sd_ack) : tx_accept;
// read_ptr is sliced to [12:0] here (never actually truncating - it stays
// well under trksiz's max of 3839, i.e. under 4096) purely so this
// self-determined addition comes out at the same 13-bit width as waddr's
// other branch, instead of the full 16-bit width of read_ptr - avoids a
// spurious truncation warning on an otherwise perfectly safe assignment.
// cur_ptr is THE position the CPU-facing buffer ports use. Selecting it here
// (rather than restructuring read_ptr itself) is deliberate: with `rotational`
// low, every expression below is bit-identical to the shipped, hardware-
// confirmed behaviour, so the toggle's OFF state carries no regression risk.
wire [12:0] cur_ptr = rotational ? rot_img : read_ptr[12:0];

// ===== ROTATIONAL READ, PACKED WRITE (2026-07-30) =====
// Reads address the buffer at the head position; writes address it at wr_ptr,
// the packed pointer declared near the top of this file (see the long comment
// there for the two failed predecessors and the byte-level hardware evidence
// against each). Access-driven mode still uses read_ptr and is bit-identical
// to the shipped, hardware-confirmed behaviour.
//
// Why the write address must NOT be the head position: `.65D`/`.65U` is a
// gap-free format - the Nth byte the DOS transfers is stored at offset N. Real
// media has physical inter-record gaps; the file does not. WinOSI lets the gaps
// form and then removes them on WE-deassert with ~150 lines of per-DOS pattern
// matching (6502.H:728-890, patterns OS65D1/OS65D2/OSIDOS in INCLUDE.h:125-127).
// Never writing the gap is the same answer for a fraction of the logic.
//
// This is a FORMAT-level constraint, not a DOS-level one - which is why it
// should hold for UCSD Pascal too, though Pascal's write path has never been
// exercised and that remains untested rather than merely unconfirmed.
wire [12:0] wr_ptr_next  = (wr_ptr >= trksiz - 13'd1) ? 13'd0
                                                      : (wr_ptr + 13'd1);
wire [12:0] wr_ptr_plus2 = (wr_ptr >= trksiz - 13'd2) ? (wr_ptr + 13'd2 - trksiz)
                                                      : (wr_ptr + 13'd2);
// Where the next write belongs after the byte currently under the head has been
// delivered. This is the anchor that ties wr_ptr to the DOS's own idea of
// position, and it is the entire difference from the read_ptr version.
wire [12:0] rot_img_next = (rot_img >= trksiz - 13'd1) ? 13'd0
                                                      : (rot_img + 13'd1);
wire [12:0] waddr = loading ? {sector, sd_buff_addr}
                            : (sub_offset + (rotational ? wr_ptr
                                                        : read_ptr[12:0]));
wire [7:0]  wdata = loading ? sd_buff_dout           : tx_byte_s2;
// Trailer confirm, cycle 1 of 2. Testing only ONE byte would be cheap but is
// genuinely weaker: it is safe on a FORMATTED disk (a write window can only
// begin on a track header $43, a sector header $76, or a trailer $47, so $47
// is unambiguous), but over arbitrary/unformatted content any byte is $47
// about 1 time in 256 - and a full 77-track format is ~150 windows, so a false
// hit would be near a coin flip and would silently put a track header 2 bytes
// out. Reading the pair sequentially through this ONE port gets the ~1/65536
// specificity back without a second read port (which is unfittable - see the
// note by rdata_sd's declaration).
wire [12:0] ptr_next = (read_ptr >= trksiz - 13'd1) ? 13'd0
                                                    : (read_ptr[12:0] + 13'd1);
// Gated on `active` for the same reason as consume_edge above: WE is a
// single broadcast line shared by every drive (there is only one PIA), so
// without this a DESELECTED drive would perform its own trailer-skip
// adjustment in response to a write window that was never meant for it.
wire peek_now = !rotational && write_window_start && !loading && write_ok &&
                active_s2 && (rdata == 8'h47);

// ---- Trailer confirm, ROTATIONAL/packed variant (2026-07-30) ----
// RE-ENABLED under rotational timing, where it was previously off. The
// simulator settled this rather than argument: packed write alone leaves the
// CREATE replay 131 bytes wrong, and those 131 bytes match the known-good
// image at EXACTLY +2 for 259 of 259 positions - the trailer signature, not new
// corruption. With this confirm added the replay is byte-identical.
//
// The mechanism is the same asymmetry as in access-driven mode: OS-65D writes a
// sector as header + 256 data + `$47 $53` trailer, but POSITIONING to write the
// next one reads only header + data and stops, because on real hardware those 2
// byte-times pass under the head during write setup. wr_ptr follows what was
// READ, so it too stops 2 short.
//
// It needs its own address because rdata is fetched from rd_addr, which under
// rotational timing is the HEAD position, not wr_ptr - so the standing rdata
// says nothing about what is at the write pointer. Hence two extra addressing
// cycles instead of the access-driven path's one.
//
// It must NOT collide with the rx_latch capture at rot_div == 4, which samples
// this same port; rather than complicate the latch, the request simply waits
// for a safe band in the byte-time. rot_div spans 0..4166, so the wait is at
// most a handful of cycles and cannot starve.
// (State and gating wires are declared further up, immediately before
// tx_accept, which has to reference pk_busy - a forward reference to a
// not-yet-declared net risks an implicit 1-bit net colliding with the later
// explicit declaration, the same trap already flagged for rdrf/tdre.)
//
// Redirect this port for at most two cycles so the following registered rdata
// holds mem[wr_ptr] and then mem[wr_ptr+1]. Safe to borrow for the same reason
// the access-driven one-cycle borrow is: the divert can only begin just after
// the CPU asserted write-enable (a $C002 store), and the earliest it could then
// read $C011 is a whole CPU bus cycle later - 800ns even at the 10MHz overclock
// ceiling, against at most 8 cycles (167ns) here. A bus-timing guarantee, not a
// probability argument. The pk_safe band above covers the one consumer that is
// NOT the CPU, namely rx_latch.
wire [12:0] rd_addr = sub_offset +
                      (peek_now              ? ptr_next     :
                       (pk_state == PK_A)    ? wr_ptr       :
                       (pk_state == PK_B)    ? wr_ptr_next  : cur_ptr);

// Receive-data latch, rotational mode only - and this is a correctness fix,
// not polish. Serving track_byte straight from `rdata` means it tracks the
// LIVE head position, so if position advances between the CPU seeing RDRF set
// and its following read of $C011, the CPU silently gets the NEXT byte and
// skips one. At 1MHz that window is small (a byte-time is ~87 CPU cycles and
// the poll-then-read is ~10) but it is not zero, and "occasionally skips a
// byte" is precisely the class of intermittent fault this whole exercise is
// chasing - it would have been a self-inflicted second bug wearing the same
// symptoms as the one under investigation.
//
// Interlocked with the trailer confirm above: the rot_div band that gates the
// confirm's start guarantees this port is never diverted on the cycle this
// latch samples it, so no byte-time can capture a peeked byte instead of the
// one under the head.
//
// Real hardware cannot have it either: a 6850 shifts the byte into a receive
// DATA REGISTER, which is what the CPU reads, and it holds until read. So
// latch once per byte-time and serve that. rot_div == 4 is comfortably after
// rd_addr changed (at rot_div == 0) and after `rdata` registered the new
// location one cycle later.
reg [7:0] rx_latch = 8'hFF;

// Position that BELONGS to the byte sitting in rx_latch - captured with it, in
// the same cycle, and used as the write anchor instead of the live head.
//
// Without this the anchor is `rot_img_next` sampled when the CPU's read edge
// arrives, which is the LIVE position - and the byte the CPU actually got came
// out of rx_latch, which was filled at rot_div == 4 of some byte-time. Those
// two disagree in a real window: if the CPU sees RDRF set late in byte-time
// P-1 and its following read of $C011 slips past the boundary into rot_div
// 0..4 of byte-time P, it receives byte P-1 (the latch has not re-sampled yet)
// while the live head already says P. The anchor would then sit one past where
// the DOS believes it is, and a write following that read would land shifted
// by one - fatal to OS-65D's verify-reread, and intermittent, since whether it
// happens depends on where in the byte-time the CPU's poll loop lands.
//
// The pre-write positioning reads are a tight streaming loop and consume each
// byte early in its byte-time, so this is unlikely to be reachable in
// practice - but "unlikely and intermittent" is the exact signature of every
// fault this exercise has spent its time on, and the fix is one register.
//
// NOTE the simulator cannot see this either way: its reads are atomic, so the
// byte-exact CREATE result neither confirms nor refutes the skew. This is a
// hardware-model correction, not something a replay could have found. WinOSI
// has no equivalent because it serves the byte and updates head_pos_before in
// the same operation (6502.H:291-305); the split only exists here because a
// registered block-RAM read forces the byte to be latched a cycle early.
//
// `served` deliberately still records the LIVE rot_pos. That is the read-side
// pacing path, it is hardware-confirmed working, and changing it would alter
// RDRF timing - a separate variable, not this fix.
reg [12:0] rx_pos = 13'd0;

always @(posedge clk_sys) begin
	if (we) mem[waddr] <= wdata;
	rdata    <= mem[rd_addr];
	rdata_sd <= mem[{sector, sd_buff_addr}];
	if (rotational && rot_div == 13'd4) begin
		rx_latch <= rdata;
		// rdata here was fetched at rot_div == 3, i.e. the same byte-time, so
		// rot_img is that byte's own image position; +1 is where a write
		// following it belongs in the packed image.
		rx_pos   <= rot_img_next;
	end
end
assign track_byte  = rotational ? rx_latch : rdata;
assign sd_buff_din = rdata_sd;

// --- CDC: track_number_raw/track_changed_raw (CPU domain) -> clk_sys ---
// Note: uk101.vhd's `clk` (the domain these signals are launched from) is
// currently wired to this same clk_sys (see UK101.sv), so this synchronizer
// is defensive-only today, not a true clock-domain crossing. Kept in place
// so the module stays correct if that wiring ever changes.
reg [6:0] track_number_s1 = 7'd0, track_number_s2 = 7'd0;
reg changed_s1 = 1'b0, changed_s2 = 1'b0, changed_s3 = 1'b0;
always @(posedge clk_sys) begin
	track_number_s1 <= track_number_raw;
	track_number_s2 <= track_number_s1;
	changed_s1 <= track_changed_raw;
	changed_s2 <= changed_s1;
	changed_s3 <= changed_s2;
end
wire track_changed_edge = changed_s2 ^ changed_s3;

// --- Latch every reload request (mount OR step) unconditionally, so none
// are lost even if one is already being serviced. This closes the gap noted
// in Step 2's code review, where a mount arriving mid-load was silently
// dropped because it was only checked from inside the IDLE state. ---
reg       seek_pending;
reg [6:0] seek_track;

always @(posedge clk_sys) begin
	if (reset) begin
		seek_pending <= 1'b0;
		seek_track   <= 7'd0;
	end
	else begin
		if (img_mounted && img_size != 0) begin
			seek_pending <= 1'b1;
			seek_track   <= 7'd0; // "insert disk" - head parked at track 0
		end
		// ever_mounted: an empty slot must never drive the SD interface -
		// see the declaration above for why a stuck empty slot would degrade
		// the drive that IS in use, not just itself.
		else if (track_changed_edge && ever_mounted) begin
			seek_pending <= 1'b1;
			seek_track   <= track_number_s2;
		end
		else if (state == IDLE && seek_pending) begin
			seek_pending <= 1'b0; // consumed by the state machine below
		end
	end
end

// 19 bits: max offset is track 76 * 3840 = 291840 (8"), which needs bit 18
// (the old 18-bit width topped out at 262143, fine for 5.25"'s 39*2304 but
// overflowing for 8").
wire [18:0] seek_byte_offset = seek_track * trksiz;
// Sectors needed to cover [sub_offset, sub_offset+trksiz) - full-width sum,
// then divided by 512 (see IDLE state below for why the width matters).
wire [12:0] nsect_calc = seek_byte_offset[8:0] + trksiz + 13'd511;

always @(posedge clk_sys) begin
	if (reset) begin
		state           <= IDLE;
		sd_rd           <= 0;
		sd_wr           <= 0;
		read_ptr        <= 0;
		sector          <= 0;
		sub_offset      <= 0;
		start_lba       <= 0;
		nsect_this_load <= 0;
		// dirty/flush_pending belong to CPU-write state, not the mounted
		// image - a reset mid-write must discard a half-written track
		// rather than commit one, so (unlike trksiz above) these ARE
		// cleared by reset.
		dirty           <= 1'b0;
		flush_pending   <= 1'b0;
		peek_pending    <= 1'b0;
		wr_ptr          <= 13'd0;
		pk_state        <= PK_IDLE;
		pk_got47        <= 1'b0;
		// Realigned on reset as well as on seek/mount, and this one is NOT
		// obvious: strictly, a CPU reset does not stop the disk spinning, so
		// the "rotation belongs to the drive, not to CPU state" rule that
		// makes trksiz and ever_mounted reset-immune above would argue for
		// leaving these alone. But the realignment is already a stand-in for
		// the physical index-hole snap, and without it a post-reset boot
		// starts reading at an ARBITRARY rotational offset - which is exactly
		// the failure the Python model demonstrated for the cold-boot case
		// (v2: first read landed at offset 734 instead of 0, blank screen,
		// hung forever), because the boot ROM never waits on the index before
		// its first read. A reset-then-boot is the same situation.
		//
		// **THE SIMULATOR CANNOT CATCH THIS**: it models no reset event at
		// all. That is precisely how the 8" work shipped a bug where trksiz
		// was cleared by reset and every post-reset "D" boot hung. Same trap,
		// opposite direction - so this is reasoned, not tested, and the
		// reset-then-boot case needs an explicit hardware check.
		rot_pos         <= 13'd0;
		rot_div         <= 13'd0;
		served          <= 13'h1FFF;
	end
	else begin
		// --- Rotational position: free-running, one byte-time per tick ---
		// Runs unconditionally (not gated on `rotational`) so the counter is
		// already at a sane phase if the OSD toggle is flipped mid-session;
		// nothing reads rot_pos unless `rotational` is set. It is NOT gated
		// on active_s2 either: a deselected drive's disk keeps spinning, and
		// freezing it while deselected is exactly the mistake that broke the
		// first Python attempt (v1) - OS-65D transiently selects drive B for
		// ~162k instructions during a plain single-drive boot, and treating
		// that interval as stopped rotation desyncs the drive that matters.
		if (rot_div >= rot_byte_div - 13'd1) begin
			rot_div <= 13'd0;
			if (rot_pos >= trksiz + ROT_INDEX_BYTES - 13'd1) rot_pos <= 13'd0;
			else                                             rot_pos <= rot_pos + 13'd1;
		end
		else rot_div <= rot_div + 13'd1;

		// WinOSI's `head_pos_before = head_pos` on every byte delivered to or
		// accepted from the CPU (6502.H:296/302 read side, 6502.H:603 write
		// side) - this is what makes RDRF/TDRE fall again until rotation has
		// actually moved on, i.e. what paces the CPU.
		// An in-zone READ does not count: WinOSI only updates head_pos_before
		// inside `if(*acia2cptr&0x01)` i.e. only when RDRF was actually set
		// (6502.H:291-305), so a stray read over the index zone must not
		// consume the next real byte. An in-zone WRITE does count, because
		// TDRE is not zone-qualified and WinOSI updates it in the accepted
		// branch (6502.H:603) - the byte is taken and then lost.
		if ((consume_edge && !(rotational && rot_in_zone)) || tx_accept)
			served <= rot_pos;

		// Access-driven pointer advance. Left completely untouched, and
		// deliberately still updated in rotational mode (it costs nothing and
		// keeps read_ptr meaningful if the toggle is flipped back mid-session)
		// - it simply is not what addresses the buffer any more.
		if (consume_edge || tx_accept) begin
			if (read_ptr == trksiz-1) read_ptr <= 0;
			else                      read_ptr <= read_ptr + 1'd1;
		end
		// Trailer-skip fix (2026-07-27): root-caused via a byte-exact offline
		// reproduction of a real hardware corruption - see
		// SAVE_AND_DISK_PLAN.md's "root cause found and proven" entry.
		// read_ptr advances only on CPU ACCESS; a real drive's head advances
		// on byte-TIME regardless of access. OS-65D writes a sector as
		// header+256 data+2-byte `$47 $53` trailer, but when POSITIONING to
		// write the NEXT sector it reads only header+data and stops - never
		// reading the trailer, since on real hardware those 2 byte-times pass
		// under the head anyway during write setup. Our pointer stops 2
		// short, so the next sector's write starts on top of the trailer
		// instead of after it, shifting the whole sector left.
		//
		// Mutually exclusive with the block above by construction: WE cannot
		// assert on the same cycle the CPU is mid-access to $C011 (DiskAcia
		// only toggles the write strobe once WE is already asserted, and the
		// synchronizer chain guarantees write_window_start lags the CPU-side
		// event by several clk_sys cycles), but written as `else if` anyway
		// so the two can never race for the same register.
		//
		// CONTENT-gated, not a blanket "+2 on every assert" - the CORRECT
		// windows assert with the pointer at track start (0) or just past the
		// 4-byte track header (4), and must not move. This is cycle 2 of the
		// two-cycle confirm set up by peek_now above: cycle 1 saw $47 under
		// the pointer and redirected the read port, so rdata now holds
		// mem[ptr+1] and the full $47 $53 trailer signature can be checked.
		//
		// peek_now is already gated on `write_ok` (matching tx_accept). Without
		// that, a Protected mount - the DEFAULT - would still shift read_ptr on
		// a write-enable assert even though no byte can ever be captured,
		// silently moving the READ position on a disk the user asked not to
		// modify. The simulator never caught this: it only ran writes-enabled.
		// It is also gated on `!loading`, again matching tx_accept: a load owns
		// the mem array while in flight, so rdata could be mid-load data.
		else if (peek_pending && rdata == 8'h53) begin
			read_ptr <= (read_ptr >= trksiz - 13'd2) ?
			            (read_ptr + 13'd2 - trksiz) : (read_ptr + 13'd2);
		end

		// Always updated, outside the read_ptr else-if chain above, so the
		// confirm window is exactly one cycle and can never latch on.
		peek_pending <= peek_now;

		// ---- Packed write pointer (rotational): the actual fix ----
		// Written as a priority chain so the three sources can never race,
		// though only the first two can realistically coincide:
		//  * a DELIVERED read re-anchors to just past the head. This is
		//    exactly what read_ptr could not do - it is reset only by a
		//    seek, while the DOS re-anchors on the index hole before every
		//    access, so the two drift apart by every byte-time the CPU
		//    spends not reading. On real media that drift IS the physical
		//    inter-record gap; in a packed file it is pure displacement.
		//  * an accepted write advances one, keeping the record packed.
		//  * the trailer confirm steps over an unread `$47 $53`.
		// Left ungated by `rotational` for the same reason read_ptr is still
		// maintained under rotational timing: it costs nothing and keeps the
		// pointer sane if the OSD toggle is flipped mid-session. Nothing
		// reads wr_ptr unless `rotational` is set.
		// Anchored to rx_pos, the position of the byte the CPU actually
		// RECEIVED, not to the live head - see rx_pos's declaration for the
		// boundary race that distinction closes.
		if (consume_edge && !(rotational && rot_in_zone))
			wr_ptr <= rotational ? rx_pos : rot_img_next;
		else if (tx_accept)
			wr_ptr <= wr_ptr_next;
		else if (pk_state == PK_C && pk_got47 && rdata == 8'h53)
			wr_ptr <= wr_ptr_plus2;

		// Trailer-confirm sequencer (rotational only; access-driven keeps
		// using peek_now/peek_pending above, bit-identical). PK_REQ waits for
		// a byte-time phase where borrowing the read port cannot disturb
		// rx_latch; PK_A and PK_B drive the two peek addresses; the compare
		// lands in PK_C. wr_ptr cannot move underneath it: tx_accept is
		// blocked by pk_busy, and the CPU cannot reach $C011 within the <=8
		// cycles this takes, having just stored to $C002 to open the window.
		case (pk_state)
			PK_IDLE: if (rotational && write_window_start && !loading &&
			             write_ok && active_s2)
			             pk_state <= PK_REQ;
			PK_REQ:  if (pk_safe) pk_state <= PK_A;
			PK_A:    pk_state <= PK_B;
			PK_B:    begin
			             pk_got47 <= (rdata == 8'h47); // rdata = mem[wr_ptr]
			             pk_state <= PK_C;
			         end
			PK_C:    pk_state <= PK_IDLE;              // rdata = mem[wr_ptr+1]
			default: pk_state <= PK_IDLE;
		endcase

		// Deliberately NOT gated on `active`: write_window_end is derived
		// from the same broadcast WE line as consume_edge/tx_accept, so a
		// deselected drive sees this too - but it stays harmless without
		// gating, because that drive's `dirty` can only ever have been set
		// by tx_accept, which IS active-gated. The existing "don't flush an
		// untouched buffer" guard below (dirty && write_ok && ...) already
		// turns this into a no-op for the deselected drive.
		if (write_window_end) flush_pending <= 1'b1;

		case (state)
			IDLE: begin
				if (seek_pending) begin
					start_lba       <= {13'd0, seek_byte_offset[18:9]};
					sub_offset      <= seek_byte_offset[8:0];
					// Full-width sum (trksiz can be well over 9 bits, e.g.
					// 2304 needs 12 / 3840 needs 12 - truncating it to match
					// sub_offset's width would silently corrupt this count)
					// before dividing by 512.
					nsect_this_load <= nsect_calc[12:9];
					read_ptr        <= 0;
					sector          <= 0;
					state           <= READ_ASSERT;
					// The head parks at track start, so the packed write
					// pointer starts there too. This is what makes a FORMAT
					// correct for free: INITTK seeks and then writes a whole
					// track from byte 0 without reading anything first, so
					// there is no delivered byte to anchor to. Any trailer
					// confirm still in flight is abandoned - it was measured
					// against the track being replaced.
					wr_ptr          <= 13'd0;
					pk_state        <= PK_IDLE;
					// Realign rotation to the start of the index zone on any
					// seek or mount. WinOSI does NOT do this (a seek leaves
					// head_pos alone) - it is this port's stand-in for the
					// PHYSICAL index-hole snap real drives perform in
					// dedicated logic while the head settles, before the CPU
					// can ask for a byte (WinOSI: INDEX_D / head_pos =
					// index_bytes, 6502.H:335-357). Without it the very first
					// read of a cold boot lands at an arbitrary offset,
					// because the boot ROM never explicitly waits on the
					// index before its first read - a failure this was
					// actually observed to cause in the Python model (v2:
					// blank screen, first read landed at offset 734 instead
					// of 0). Carried over from the validated v6 model.
					rot_pos         <= 13'd0;
					rot_div         <= 13'd0;
					served          <= 13'h1FFF;
					// Discard any not-yet-flushed write: a new seek
					// supersedes it. Not observed in OS-65D's own traced
					// write sequence (it always deasserts write-enable,
					// which triggers our flush, before doing anything
					// else) - kept as a documented simplification for the
					// case where it might. dirty is cleared alongside
					// flush_pending so the discard is complete: leaving it
					// set would make the next window-end write the
					// freshly-loaded track straight back out again.
					flush_pending   <= 1'b0;
					dirty           <= 1'b0;
				end
				else if (flush_pending) begin
					flush_pending <= 1'b0;
					// write_ok is re-checked here (not just at capture time):
					// if the OSD toggle flips to Protected after bytes were
					// already captured but before write-enable deasserts,
					// this stops the flush from writing that data out anyway.
					// nsect_this_load != 0 guards against a flush somehow
					// being requested before any real load has ever set it
					// (it resets to 0) - without this, sector==nsect_this_load-1
					// underflows to sector==15, turning a would-be no-op into
					// a runaway 16-sector write starting at LBA 0.
					if (dirty && write_ok && nsect_this_load != 0) begin
						sector <= 0;
						state  <= FLUSH_ASSERT;
						// Cleared at flush START, not completion. Writes are
						// now accepted while a flush runs (see tx_accept), so
						// a byte captured mid-pass may land in a sector this
						// pass has already sent. Clearing here means any such
						// capture re-sets dirty and the next window-end runs
						// another pass; clearing at completion would drop it.
						dirty  <= 1'b0;
					end
					// else: nothing captured since the last flush, or writes
					// are protected, or no track has ever been loaded - no-op,
					// mirrors save_writer.sv's own "don't flush an
					// untouched buffer" guard.
				end
			end

			READ_ASSERT: begin
				sd_lba <= start_lba + sector;
				sd_rd  <= 1;
				state  <= READ_WAIT_ACK;
			end

			READ_WAIT_ACK: if (sd_ack) state <= READ_WAIT_DONE;

			READ_WAIT_DONE: if (!sd_ack) begin
				sd_rd <= 0;
				if (sector == nsect_this_load-1) begin
					state <= IDLE;
					// Re-snap rotation to the start of the index zone now that
					// the data is ACTUALLY under the head.
					//
					// The seek already snapped rot_pos to 0, but then this load
					// ran for real time while rotation carried on, eating into
					// the 32-byte-time grace window the zone is supposed to
					// provide. A real drive has no load at all - the track is
					// physically under the head - so the load must not consume
					// rotational time. Snapping here rather than at seek time
					// makes the grace window start when the bytes are genuinely
					// available, which is what the zone models.
					//
					// FOUND ON HARDWARE 2026-07-30: 8" C1P disks would not boot
					// under rotational timing while 5.25" did. 8" has about a
					// THIRD of the margin - its index zone is 32*2083 = 1.39ms
					// against 5.25"'s 32*4167 = 2.78ms, and an 8" track needs up
					// to 9 sectors to load versus 5-6. The boot ROM never waits
					// on the index hole before its first read (it relies purely
					// on the post-seek snap), so once the load outlasts the zone
					// the first byte served is not image byte 0 and boot has no
					// way to recover.
					//
					// I had previously ruled load latency out, on the strength
					// of a measurement showing OS-65D waits MORE THAN ONE FULL
					// REVOLUTION after a seek before reading - which is true,
					// and does absorb the load, but only for post-seek reads.
					// The COLD-BOOT FIRST READ has no such wait, and that is the
					// one case where this bites. A correct measurement, applied
					// to the wrong set of cases.
					rot_pos <= 13'd0;
					rot_div <= 13'd0;
					served  <= 13'h1FFF;
				end
				else begin
					sector <= sector + 1'd1;
					state  <= READ_ASSERT;
				end
			end

			FLUSH_ASSERT: begin
				sd_lba <= start_lba + sector;
				sd_wr  <= 1;
				state  <= FLUSH_WAIT_ACK;
			end

			FLUSH_WAIT_ACK: if (sd_ack) state <= FLUSH_WAIT_DONE;

			FLUSH_WAIT_DONE: if (!sd_ack) begin
				sd_wr <= 0;
				if (sector == nsect_this_load-1) state <= IDLE;
				else begin
					sector <= sector + 1'd1;
					state  <= FLUSH_ASSERT;
				end
			end
		endcase

		// Placed AFTER the case so it wins any same-cycle race with the
		// flush-start clear above: a byte captured on the exact cycle a flush
		// begins must leave dirty set, so the pass that byte may have missed
		// is followed by another one.
		if (tx_accept) dirty <= 1'b1;
	end
end

endmodule
