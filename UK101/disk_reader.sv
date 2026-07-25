//============================================================================
// SD-image disk-track reader for UK101 disk emulation (Phase 2, Step 3)
//
// Step 2 proved the SD-image read pipeline in isolation by always loading a
// hardcoded track 0. Step 3 replaces that with a real seek: DiskPia's
// stepper outputs drive a track counter in uk101.vhd (trackNumber/
// trackChanged), and every confirmed step here re-loads the newly-selected
// track from the mounted .65D image, the same way a mount loads track 0.
//
// Track byte offset within the image = track_number * TRKSIZ. Because TRKSIZ
// (2304 for the 5.25" C1PMF target) is not a multiple of 512, most tracks
// start at a non-sector-aligned byte offset - so each load now computes its
// own start LBA, its in-sector start offset, and how many sectors are needed
// to cover the track from there, instead of always starting at sector 0.
//
// CDC notes: track_byte_strobe_raw (byte-consumed toggle) and
// track_changed_raw (step-confirmed toggle) both cross from the CPU clock
// domain into clk_sys via the same 3-stage synchronizer + XOR edge-detector
// pattern proven in Phase 1 (save_data/save_strobe). track_number_raw is a
// multi-bit register that only changes once per step, many clk_sys cycles
// apart - by the time track_changed_raw's synchronized edge fires, it has
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
	input             sd_ack,

	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	// CDC interface to DiskAcia.vhd (CPU clock domain)
	input         track_byte_strobe_raw, // toggles once per CPU read of $C011
	output  [7:0] track_byte,

	// CDC interface to uk101.vhd's track-stepper counter (CPU clock domain)
	input   [6:0] track_number_raw,  // current head position (0..39 or 0..76)
	input         track_changed_raw, // toggles once per confirmed step

	output        busy   // debug aid: high while a track load is in progress
);

localparam BUFSECT = 9; // physical buffer capacity - covers both 5.25" (needs
                        // up to 6 incl. worst-case sub-sector offset) and 8"
                        // (needs up to 9) geometries

reg [7:0] mem [0:BUFSECT*512-1];
reg [7:0] rdata;

reg [15:0] read_ptr;
reg [3:0]  sector;
reg [3:0]  nsect_this_load;
reg [31:0] start_lba;
reg [8:0]  sub_offset;

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

localparam IDLE         = 2'd0,
           READ_ASSERT   = 2'd1,
           READ_WAIT_ACK = 2'd2,
           READ_WAIT_DONE= 2'd3;
reg [1:0] state;

assign busy = (state != IDLE);

// --- Capture incoming sector bytes whenever hps_io delivers one ---
// --- Serve bytes out to the CPU: registered read (infers as block RAM) ---
// sd_ack is qualified here (not just sd_buff_wr) because slot 1 is the only
// slot this module drives sd_rd for - save_writer's slot never reads, so
// sd_buff_wr only ever pulses for us today, but the extra qualifier makes
// that an enforced invariant rather than an incidental one.
always @(posedge clk_sys) begin
	if (sd_buff_wr && sd_ack) mem[{sector, sd_buff_addr}] <= sd_buff_dout;
	rdata <= mem[sub_offset + read_ptr];
end
assign track_byte = rdata;

// --- CDC: track_byte_strobe_raw (CPU domain) -> clk_sys ---
reg strobe_s1 = 1'b0, strobe_s2 = 1'b0, strobe_s3 = 1'b0;
always @(posedge clk_sys) begin
	strobe_s1 <= track_byte_strobe_raw;
	strobe_s2 <= strobe_s1;
	strobe_s3 <= strobe_s2;
end
wire consume_edge = strobe_s2 ^ strobe_s3;

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
		else if (track_changed_edge) begin
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
		read_ptr        <= 0;
		sector          <= 0;
		sub_offset      <= 0;
		start_lba       <= 0;
		nsect_this_load <= 0;
	end
	else begin
		if (consume_edge) begin
			if (read_ptr == trksiz-1) read_ptr <= 0;
			else                      read_ptr <= read_ptr + 1'd1;
		end

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
				if (sector == nsect_this_load-1) state <= IDLE;
				else begin
					sector <= sector + 1'd1;
					state  <= READ_ASSERT;
				end
			end
		endcase
	end
end

endmodule
