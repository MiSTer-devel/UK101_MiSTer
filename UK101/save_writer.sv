//============================================================================
// SD-image save-file writer for UK101 SAVE support (Phase 1)
//
// Captures bytes written by BASIC's SAVE to the ACIA (via bufferedUART.vhd,
// see save_data/save_strobe) into a capture buffer. On the single "Save" OSD
// trigger it flushes the buffer to the mounted file (as many sectors as the
// mounted file actually holds - see img_size / nsect), then zero-fills the
// buffer and resets the write pointer, arming for the next SAVE. This
// guarantees every save-to-the-same-file is a clean overwrite, never an
// append, regardless of the relative lengths of successive saves.
//
// The flush size adapts to the mounted file: the user creates a file of
// whatever size suits them (a multiple of 512 bytes, kept under 64K - e.g.
// 48K comfortably exceeds the machine's 41K max RAM), and the core flushes
// exactly that many sectors. Staying under 64K also keeps the LOAD path clear
// of the 16-bit address-wraparound boundary at exactly 65536 bytes.
//
// Clear-on-mount: mounting (or re-mounting) the file zero-fills the buffer
// ("insert blank tape"), so re-selecting the file in the OSD browser doubles
// as an explicit "start fresh" action - needed because the always-on capture
// would otherwise accumulate a whole session's ACIA output (including the echo
// from LOADing a file) between saves.
//============================================================================

module save_writer
(
	input         clk_sys,
	input         reset,

	input         save_btn,     // raw OSD status bit - may stay high for multiple cycles
	input         img_mounted,  // one-shot pulse (clk_sys domain) at each mount
	input  [63:0] img_size,     // mounted file size in bytes, valid at img_mounted

	// ACIA capture interface (from bufferedUART.vhd via uk101, crosses from
	// the CPU's own clock domain - save_strobe TOGGLES on each new byte, does
	// not pulse, so it can be safely synchronized with an edge detector).
	input   [7:0] save_data_raw,
	input         save_strobe_raw,

	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,

	input       [8:0] sd_buff_addr,
	output      [7:0] sd_buff_din,

	output            busy   // debug aid: high for the whole flush+clear sequence
);

// --- Cross save_data/save_strobe from the CPU clock domain into clk_sys ---
reg [7:0] save_data_s1, save_data_s2;
reg       save_strobe_s1, save_strobe_s2, save_strobe_s3;

always @(posedge clk_sys) begin
	save_strobe_s1 <= save_strobe_raw;
	save_strobe_s2 <= save_strobe_s1;
	save_strobe_s3 <= save_strobe_s2;
	save_data_s1   <= save_data_raw;
	save_data_s2   <= save_data_s1;
end

wire capture_edge = save_strobe_s2 ^ save_strobe_s3;

// --- Save button edge detect ---
reg save_btn_d;
wire save_btn_rise = save_btn & ~save_btn_d;

// img_mounted from hps_io is a one-shot pulse at the moment of mounting, not a
// persistent "file is mounted" level - latch it (and the file's sector count)
// so both survive until the Save button is actually pressed, possibly later.
reg       mounted;
reg [7:0] nsect;   // mounted file size in 512-byte sectors (img_size >> 9)

// --- 64KB capture buffer, registered read (infers as block RAM) ---
reg [7:0] mem [0:65535];
reg [7:0] rdata;

reg [15:0] wr_ptr;
reg [15:0] clear_ptr;
reg [7:0]  sector;

localparam IDLE          = 3'd0,
           FLUSH_ASSERT   = 3'd1,
           FLUSH_WAIT_ACK = 3'd2,
           FLUSH_WAIT_DONE= 3'd3,
           CLEAR          = 3'd4;
reg [2:0] state;

// Capture is accepted only while there is still room in the mounted file
// (wr_ptr's sector index below nsect). Beyond that, extra bytes are dropped
// rather than wrapping the pointer - a safety net; a real program can't exceed
// the machine's 41K RAM, well under a 48K file.
wire capture_ok = capture_edge && (wr_ptr[15:9] < nsect);

wire we           = (state == IDLE)  ? capture_ok : (state == CLEAR);
wire [15:0] waddr = (state == CLEAR) ? clear_ptr   : wr_ptr;
wire [7:0]  wdata = (state == CLEAR) ? 8'h00       : save_data_s2;
wire [15:0] raddr = {sector[6:0], sd_buff_addr};

always @(posedge clk_sys) begin
	if (we) mem[waddr] <= wdata;
	rdata <= mem[raddr];
end

assign sd_buff_din = rdata;
assign busy = (state != IDLE);

always @(posedge clk_sys) begin
	save_btn_d <= save_btn;

	if (img_mounted) begin
		mounted <= 1'b1;
		nsect   <= img_size[16:9]; // bytes -> sectors; 0..128 (files < 64K -> < 128)
	end

	if (reset) begin
		state   <= IDLE;
		sd_wr   <= 0;
		wr_ptr  <= 0;
		mounted <= 1'b0;
		nsect   <= 0;
	end
	else begin
		case (state)
			IDLE: begin
				if (capture_ok) wr_ptr <= wr_ptr + 1'd1;

				// A fresh mount clears the buffer ("insert blank tape").
				// Takes priority over a same-cycle Save press.
				if (img_mounted) begin
					clear_ptr <= 0;
					state     <= CLEAR;
				end
				// Flush only when something has actually been captured
				// (wr_ptr != 0) into a real file (nsect != 0) - otherwise a
				// Save press would overwrite the file with zeros.
				else if (save_btn_rise && mounted && (wr_ptr != 0) && (nsect != 0)) begin
					sector <= 0;
					state  <= FLUSH_ASSERT;
				end
			end

			FLUSH_ASSERT: begin
				sd_lba <= {24'd0, sector};
				sd_wr  <= 1;
				state  <= FLUSH_WAIT_ACK;
			end

			FLUSH_WAIT_ACK: if (sd_ack) state <= FLUSH_WAIT_DONE;

			FLUSH_WAIT_DONE: if (!sd_ack) begin
				sd_wr <= 0;
				if (sector == nsect - 1'd1) begin
					clear_ptr <= 0;
					state <= CLEAR;
				end
				else begin
					sector <= sector + 1'd1;
					state  <= FLUSH_ASSERT;
				end
			end

			CLEAR: begin
				if (clear_ptr == 16'hFFFF) begin
					wr_ptr <= 0;
					state  <= IDLE;
				end
				else
					clear_ptr <= clear_ptr + 1'd1;
			end
		endcase
	end
end

endmodule
