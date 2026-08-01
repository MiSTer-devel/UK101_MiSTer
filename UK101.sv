//============================================================================
//  Compukit UK101 port to MiSTer
//  Based on Grant Searle's original FPGA project http://searle.x10host.com/uk101FPGA/
//  Ported by Daniel Baum, August 2021.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

//assign LED_USER = ioctl_download;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign UART_DTR = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

//assign VGA_SL = 0;
//assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = {1'b1, save_busy | disk_busy | disk_busy_b | disk_busy_c | disk_busy_d}; // debug aid: lit during flush/track-load (any drive)
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////





`include "build_id.v"
localparam CONF_STR = {
	"UK101;;",
	"-;",
	"D0F,TXTBASLOD,Load Ascii;",
	"S0,TXT,Save Ascii;",
	"R[11],Save;",
	"S1,65D65U,Mount Disk;",
	"S2,65D65U,Mount Disk B;",
	// D7/D8 (2026-08-01): grey out Mount Disk C/D whenever "Drives fitted"
	// (below) doesn't include them, verified against the real MiSTer
	// framework source (menu.cpp) rather than guessed - see status_menumask
	// below for the grey_mount_c/grey_mount_d bit assignment.
	"D7S3,65D65U,Mount Disk C;",
	"D8S4,65D65U,Mount Disk D;",
	// Mirrors a real WinOSI settings panel this core had no equivalent of
	// (2026-08-01): "how many drive connectors exist" as its own explicit
	// choice, separate from whether a diskette is in any of them. Defaults
	// to "2" (status[2:1]="00") - the ONLY configuration ever hardware-
	// confirmed with UCSD Pascal - so an unmounted C/D reads back exactly as
	// "no such drive" unless the user deliberately opts into more. See
	// uk101.vhd's disk_drives_fitted port comment for why an always-real C/D
	// would otherwise be a different signal to software that scans drives by
	// index-hole behaviour.
	"O[2:1],Drives fitted,2,3,4;",
	"O[20],Disk writes,Protected,Enabled;",
	"O[3],Load programs from,File,UART;",
	"O[7],Baud Rate,9600,300;",
	"-;",
	"O[9:8],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[13:12],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"O[16:15],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	//"O34,Colours,White on blue,White on black,Green on black,Yellow on black;",
	// D6 dropped here (2026-07-21): it used to force-grey this row whenever
	// C1P was selected (status_menumask bit6 = status[28], set only for
	// C1P) - the only reason C1P had no selectable screen mode at all. C2P's
	// own row below keeps D6 (vestigial - status[27]/status[28] can't both
	// be set, so it never actually fires there, but left alone since it's
	// provably inert).
	"H4d5O4,Screen resolution,Low,High;",
	"h4d5D6O56,Screen resolution,Low,High,Auto;",
	"-;",
	// D9 (2026-08-01): greyed whenever 48K memory is selected, since UCSD
	// Pascal's 48K requirement only works booted as OSI C2P + Synmon (Disk) -
	// mem48k below both forces machine_type/monitor_type to that combination
	// and pushes it back into status[] via hps_io's status_in/status_set (see
	// below) so the OSD's own display reflects it, not just internal
	// behaviour.
	"D9O[28:27],Machine,UK101,OSI C2P,OSI C1P;",
	"O[19:17],Clock speed,1Mhz,2Mhz,4Mhz,8Mhz,10Mhz;",
	// 48K banks the 8K BASIC ROM out of $A000-$BFFF - the two cannot coexist,
	// since that is exactly the range taking contiguous RAM from 40K to 48K.
	// Needed by UCSD Pascal (its hang was insufficient RAM, nothing else -
	// see uk101.vhd's n_basRomCS comment). Labelled so the trade-off is
	// visible at the point of choice rather than discovered afterwards.
	"O[26:24],Memory Size,4K,8K,32K,41K,48K (Basic disabled);",
	"H4H6O[22:21],Monitor,Cegmon,MonUK02,Wemon;",
	"h4D9O[23:22],Monitor,Cegmon,Synmon (Basic),Synmon (Disk);",
	"h6O[23],Monitor,Cegmon,Synmon;",
	"-;",
	"-;",
	"R[10],Reset;",
	"-;",
	"-;",
	"V,v",`BUILD_DATE
};



//
// HPS is the module that communicates between the linux and fpga
//
wire  [1:0] buttons;
wire [127:0] status;
wire PS2_CLK;
wire PS2_DAT;
wire loadFrom = status[3];
wire [1:0]resolution;
wire [1:0]monitor_type;
wire baud_rate=status[7];
// 48K memory only works as OSI C2P + Synmon (Disk) - forces machine_type
// (and, in the always_comb block below, monitor_type) regardless of what
// status[] holds, as a defense-in-depth against the status_in/status_set
// push below not having round-tripped through the ARM side yet. See the
// CONF_STR D9 comment above.
//
// BOTH of these must be fed to the uk101 instantiation (and to
// status_menumask) in place of the raw status bits, or this override is
// inert where it matters: uk101.vhd does its own decoding from the RAW
// fields, and the monitor row visibility masks key off them too. Caught in
// review - the first cut of this change left .machine_type/.monitor_type
// wired to status[...] directly, so the whole 48K lock silently depended on
// the ARM round-trip landing.
wire mem48k = (status[26:24] == 3'b100);
wire [1:0] machine_type = mem48k ? 2'b01 : status[28:27];
// The 3-bit RAW monitor field as uk101.vhd expects it (it slices this
// per-machine itself: bits 1:0 for UK101, 2:1 for C2P, bit 2 for C1P - see
// uk101.vhd's i_monitor_type assignment). Under 48K, C2P reads bits 2:1, so
// "10" there selects i_monitor_type = 2 = SynmonHDMRomData = "Synmon
// (Disk)"; bit 0 is a don't-care for C2P and is passed through untouched.
wire [2:0] monitor_type_raw = mem48k ? {2'b10, status[21]} : status[23:21];
// Drives-fitted-based mount-slot greying (2026-08-01): grey Mount Disk C
// when fewer than 3 drives are fitted, Mount Disk D when fewer than 4.
// disk_drives_fitted itself is declared later (status[2:1]) - duplicated
// here as raw status bits since it's only needed for this comparison.
wire grey_mount_c = (status[2:1] == 2'b00);
wire grey_mount_d = ~status[2];
//assign resolution = status[5];
wire forced_scandoubler;
wire [21:0] gamma_bus;
// Preserves prior behaviour (always true for C2P, since the old 1-bit
// Synmon selector's only two values were 0=Cegmon/1=Synmon, both already
// covered) now that C2P's Synmon choice has split into two values (1=Basic,
// 2=Disk) - both still count.
// C1P (2026-07-21, Step 4f follow-up): unlike UK101, whose resolution switch
// is tied to a Cegmon-only ROM patch table (so the menu is only meaningful
// under that one monitor), C1P's 64x16 mode is a plain RTL video-timing
// selection with no ROM-patch dependency on any monitor - it should stay
// enabled for either C1P monitor choice. Without this, only C1P+Cegmon
// enabled the row (via the monitor_type==0 clause below) and C1P+Synmon was
// stuck permanently greyed - reported by the user immediately after Step 4f.
wire grey_res_menu = (monitor_type==2'b0 || (machine_type==2'b01 && (monitor_type==2'b01 || monitor_type==2'b10)) || machine_type==2'b10);
wire ioctl_download;
wire ioctl_wr;
wire [15:0] ioctl_addr;
wire [7:0] ioctl_data;
wire [7:0] ioctl_index;
wire ioctl_wait;

// SD-image mounts: slot 0 = save file (Phase 1), slot 1 = disk image (Phase 2)
wire [7:0] save_data;
wire save_strobe;
// Slot 0 = save file (Phase 1), slot 1 = disk A (Phase 2), slot 2 = disk B
// (second drive, 2026-07-27), slots 3/4 = disks C/D (four-drive support,
// 2026-08-01).
wire [4:0] img_mounted;
wire [63:0] img_size;
wire [31:0] sd_lba[5];
wire [5:0] sd_blk_cnt[5];
wire [4:0] sd_rd;
wire [4:0] sd_wr;
wire [4:0] sd_ack;
wire [8:0] sd_buff_addr;
wire [7:0] sd_buff_dout;
wire [7:0] sd_buff_din[5];
wire sd_buff_wr;

assign sd_rd[0] = 1'b0;      // save slot never reads
assign sd_blk_cnt[0] = 6'd0;
assign sd_blk_cnt[1] = 6'd0;
assign sd_blk_cnt[2] = 6'd0;
assign sd_blk_cnt[3] = 6'd0;
assign sd_blk_cnt[4] = 6'd0;
wire save_busy;

// Disk-track read (Phase 2, Step 2/3). track_byte_a/track_byte_b are each
// disk_reader instance's own output; track_byte (fed into uk101.vhd) is the
// one MUXED by disk_drive_select, since there is only one ACIA/track_byte
// input - see the Layer 4 mux below.
wire [7:0] track_byte_a;
wire [7:0] track_byte_b;
wire [7:0] track_byte;
wire track_byte_strobe;
wire disk_busy;
wire disk_busy_b;
wire [6:0] track_number;
wire track_changed;
// Drive B has its OWN head position: a step pulse moves only the selected
// drive's head. See uk101.vhd's stepper process.
wire [6:0] track_number_b;
wire track_changed_b;
// Now the FULL two-bit drv_sel (0=A,1=B,2=C,3=D), not a single A/B bit plus
// a separate "armed" gate - see uk101.vhd's diskDriveSel2 (four-drive
// support, 2026-08-01).
wire [1:0] disk_drive_select;

// Drives C and D (four-drive support, 2026-08-01) - identical shape to
// drive B's declarations above.
wire [7:0] track_byte_c;
wire [7:0] track_byte_d;
wire disk_busy_c;
wire disk_busy_d;
wire [6:0] track_number_c;
wire track_changed_c;
wire [6:0] track_number_d;
wire track_changed_d;

// Disk-track write (Phase B, 2026-07-26). tx_byte/tx_strobe/n_write_enable
// are BROADCAST identically to all disk_reader instances - there is only
// one ACIA/PIA, hence only one write-side signal set - each instance's own
// `active` input (gated by disk_drive_select) decides whether it actually
// captures a given event. See disk_reader.sv's `active` port comment.
wire [7:0] disk_tx_byte;
wire disk_tx_strobe;
wire disk_n_write_enable;
wire disk_sd_wr;
wire [7:0] disk_sd_buff_din;
wire disk_b_sd_wr;
wire [7:0] disk_b_sd_buff_din;
wire disk_c_sd_wr;
wire [7:0] disk_c_sd_buff_din;
wire disk_d_sd_wr;
wire [7:0] disk_d_sd_buff_din;

wire img_readonly;
// Latched at the DISK slot's mount pulse, same reasoning as disk_is_8inch
// below: hps_io's img_readonly is shared across slots and reflects only the
// most recent mount, so it must be captured at our own slot's mount pulse
// rather than read live.
reg disk_img_readonly = 1'b1;
reg disk_img_readonly_b = 1'b1;
reg disk_img_readonly_c = 1'b1;
reg disk_img_readonly_d = 1'b1;
always @(posedge clk_sys) begin
	if (img_mounted[1]) disk_img_readonly <= img_readonly;
	if (img_mounted[2]) disk_img_readonly_b <= img_readonly;
	if (img_mounted[3]) disk_img_readonly_c <= img_readonly;
	if (img_mounted[4]) disk_img_readonly_d <= img_readonly;
end

// Default is Protected (status[20]=0) even for a freshly mounted read-write
// image - writes require both the user's explicit OSD opt-in AND the image
// itself not being mounted read-only. Also reads as Protected before any
// disk is mounted at all (disk_img_readonly initialises to 1).
//
// Named "..._ok" rather than "..._protect" deliberately: '1' means WRITES
// ARE ALLOWED. It feeds DiskPia's `write_protect` pin, which is genuinely
// active-low in the real hardware ("0 IF WRITE PROTECT" per the OS-65D
// Disassembly Manual), so the value passes through un-inverted - but naming
// this net "write_protect" while '1' means "not protected" is exactly the
// polarity trap that has already produced two bugs in this project (the
// early n_track0_sense inversion, and the Phase A write-protect catch).
//
// Drives B/C/D all share the SAME "Disk writes" OSD toggle (status[20]) -
// one global on/off rather than a separate row per drive - with each drive's
// own img_readonly latch still gating it independently.
wire disk_write_ok = status[20] & ~disk_img_readonly;
wire disk_write_ok_b = status[20] & ~disk_img_readonly_b;
wire disk_write_ok_c = status[20] & ~disk_img_readonly_c;
wire disk_write_ok_d = status[20] & ~disk_img_readonly_d;
// sd_wr/sd_buff_din gating is now a BACKSTOP only - disk_reader.sv's own
// write_ok input is the gate that actually prevents the flush FSM running
// (gating only these two would deadlock it waiting for an sd_ack that
// hps_io never sends). Kept as defence in depth.
assign sd_wr[1]        = disk_write_ok ? disk_sd_wr       : 1'b0;
assign sd_buff_din[1]  = disk_write_ok ? disk_sd_buff_din : 8'h00;
assign sd_wr[2]        = disk_write_ok_b ? disk_b_sd_wr       : 1'b0;
assign sd_buff_din[2]  = disk_write_ok_b ? disk_b_sd_buff_din : 8'h00;
assign sd_wr[3]        = disk_write_ok_c ? disk_c_sd_wr       : 1'b0;
assign sd_buff_din[3]  = disk_write_ok_c ? disk_c_sd_buff_din : 8'h00;
assign sd_wr[4]        = disk_write_ok_d ? disk_d_sd_wr       : 1'b0;
assign sd_buff_din[4]  = disk_write_ok_d ? disk_d_sd_buff_din : 8'h00;

// Disk geometry auto-detect from the mounted image size (Phase 2, 8" support):
//   92160 bytes = 5.25" (40 tracks x 2304), 295680 = 8" (77 tracks x 3840).
// disk_reader.sv derives its own track byte-size from img_size; uk101.vhd only
// needs the 1-bit select for the head-stepper's last-track clamp.
//
// LATCHED at the DISK slot's mount pulse (img_mounted[1]), NOT a bare
// combinational compare on img_size: hps_io's img_size is shared across all
// slots and reflects the *most recent* mount of ANY slot, so mounting a save
// .txt (slot 0) after an 8" disk (slot 1) would otherwise wrongly flip this
// back to 5.25" while the 8" disk is still in the drive. Latching here mirrors
// how disk_reader.sv latches its own trksiz at the same pulse. Drive B gets
// its own independent latch at ITS OWN mount pulse (img_mounted[2]), for the
// exact same reason.
reg disk_is_8inch = 1'b0;
reg disk_is_8inch_b = 1'b0;
reg disk_is_8inch_c = 1'b0;
reg disk_is_8inch_d = 1'b0;
always @(posedge clk_sys) begin
	if (img_mounted[1] && img_size != 0)
		disk_is_8inch <= (img_size == 64'd295680);
	if (img_mounted[2] && img_size != 0)
		disk_is_8inch_b <= (img_size == 64'd295680);
	if (img_mounted[3] && img_size != 0)
		disk_is_8inch_c <= (img_size == 64'd295680);
	if (img_mounted[4] && img_size != 0)
		disk_is_8inch_d <= (img_size == 64'd295680);
end

// Layer 4: only one ACIA feeds only one $C011 register, so only one drive's
// byte stream can be "live" at a time - muxed here by disk_drive_select
// (exported from uk101.vhd, sourced from DiskPia's own drive_select output).
// Now a full 4-way mux (four-drive support, 2026-08-01): every disk_drive_select
// value (0=A,1=B,2=C,3=D) names a real, implemented drive.
assign track_byte = (disk_drive_select == 2'd0) ? track_byte_a :
                     (disk_drive_select == 2'd1) ? track_byte_b :
                     (disk_drive_select == 2'd2) ? track_byte_c :
                                                    track_byte_d;

// Same mux, same reason, for the "my track buffer is being refilled from SD"
// flag that gates RDRF/TDRE in DiskAcia. It MUST follow the selected drive
// rather than being an OR of all four: a load on a DESELECTED drive is
// invisible to the CPU (its buffer is not what $C011 is reading), so ORing
// them would stall the drive that IS selected for no reason. Not registered
// anywhere here - disk_reader already produces it in clk_sys, which is the
// same clock uk101.vhd runs on (see the .clk(clk_sys) connection on the
// uk101 instance below).
wire disk_loading_a, disk_loading_b, disk_loading_c, disk_loading_d;
wire disk_loading = (disk_drive_select == 2'd0) ? disk_loading_a :
                     (disk_drive_select == 2'd1) ? disk_loading_b :
                     (disk_drive_select == 2'd2) ? disk_loading_c :
                                                    disk_loading_d;



always_comb
begin
if (machine_type==2'b00 && (monitor_type==2'b01 || monitor_type == 2'b10))
	resolution = 2'b00;
else if (machine_type == 2'b10)
	// Was hardcoded 2'b00 (no selectable screen mode at all for C1P) - now a
	// real Low/High choice, same status bit and same "O4" menu row UK101
	// uses (see CONF_STR above). High selects the new 64x16 mode (Step 4f).
	resolution = {1'b0,status[4]};
else if (machine_type == 2'b01)
	resolution = status[6:5];
else
	resolution = {1'b0,status[4]};
end



// Push the forced Machine/Monitor selection back into the OSD's own
// displayed status bits when 48K memory is chosen (2026-08-01), so the
// checked value visually matches what machine_type/monitor_type already
// force behaviourally above - hps_io's status_in/status_set ports were
// previously unconnected in this core. status_set is edge-triggered inside
// hps_io (fires once per 0->1 transition), so a single-cycle pulse on
// mem48k's rising edge is sufficient; it deliberately does not re-fire
// continuously while 48K stays selected, matching how every other D-greyed
// row in this CONF_STR relies on the grey alone rather than a repeated
// override.
reg mem48k_d = 0;
reg status_set_pulse = 0;
always @(posedge clk_sys) begin
	status_set_pulse <= mem48k & ~mem48k_d;
	mem48k_d <= mem48k;
end
// Only bits 28:27 (Machine) and 23:22 (Monitor) are overridden; every other
// bit passes through status[] unchanged.
wire [127:0] status_in = {status[127:29], 2'b01, status[26:24], 2'b10, status[21:0]};

// VDNUM raised from 3 to 5 (four-drive support, 2026-08-01): slot 0 = save
// file, 1 = disk A, 2 = disk B, 3 = disk C, 4 = disk D.
hps_io #(.CONF_STR(CONF_STR),.PS2DIV(2000),.VDNUM(5)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.buttons(buttons),
	.status(status),
	.ps2_kbd_clk_out(PS2_CLK),
	.ps2_kbd_data_out(PS2_DAT),
	.forced_scandoubler(forced_scandoubler),
	// Prepended (not appended) so existing bit positions 0-6 are unchanged -
	// concatenation makes the FIRST-listed signal the highest bit, so adding
	// new signals here only ever claims new, higher-numbered indices.
	// bit7=grey_mount_c (D7), bit8=grey_mount_d (D8), bit9=mem48k (D9).
	//
	// Bits 6 and 4 are machine_type's two bits - the EFFECTIVE (48K-
	// overridden) value, not raw status[28]/status[27]. They drive which of
	// the three mutually-exclusive Monitor rows is visible (H4H6 / h4 / h6),
	// so using raw status here meant that selecting 48K from UK101 showed
	// the UK101 monitor row and HID the C2P row carrying the D9 grey - the
	// grey was invisible in exactly the case it exists for, until the ARM
	// round-trip landed. Identical to the old expression whenever 48K is not
	// selected.
	.status_menumask({mem48k, grey_mount_d, grey_mount_c, machine_type[1],grey_res_menu, machine_type[0],status[6:3]}),
	.status_in(status_in),
	.status_set(status_set_pulse),
	.gamma_bus(gamma_bus),
	
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)

);

save_writer save_writer
(
	.clk_sys(clk_sys),
	.reset(reset),

	.save_btn(status[11]),
	.img_mounted(img_mounted[0]),
	.img_size(img_size),

	.save_data_raw(save_data),
	.save_strobe_raw(save_strobe),

	.sd_lba(sd_lba[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack[0]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_din(sd_buff_din[0]),

	.busy(save_busy)
);

disk_reader disk_reader
(
	.clk_sys(clk_sys),
	.reset(reset),

	.img_mounted(img_mounted[1]),
	.img_size(img_size),

	.sd_lba(sd_lba[1]),
	.sd_rd(sd_rd[1]),
	.sd_wr(disk_sd_wr),
	.sd_ack(sd_ack[1]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(disk_sd_buff_din),

	.track_byte_strobe_raw(track_byte_strobe),
	.track_byte(track_byte_a),

	.tx_byte_strobe_raw(disk_tx_strobe),
	.tx_byte_raw(disk_tx_byte),
	.n_write_enable_raw(disk_n_write_enable),
	.write_ok(disk_write_ok),

	.track_number_raw(track_number),
	.track_changed_raw(track_changed),

	// '1' only when the two-bit drive select names drive A specifically,
	// AND drive A is fitted (always true - see disk_drive_armed's
	// declaration comment; ANDed here purely for a uniform pattern across
	// all four drives, not because A can ever be unfitted).
	.active_raw((disk_drive_select == 2'd0) && disk_drive_armed),

	.rotational(disk_rotational),
	.rdrf(disk_rdrf_a),
	.tdre(disk_tdre_a),
	.index_hole_n(disk_index_hole_n_a),

	.busy(disk_busy),
	.loading(disk_loading_a)
);

// Second disk drive (2026-07-27). Same module, same broadcast tx_byte/
// tx_strobe/n_write_enable/track_byte_strobe signals as drive A (there is
// only one ACIA) - `active` is what makes only the selected one respond.
// Own SD slot (2), own geometry latch, own write-protect gate - see the
// declarations above.
disk_reader disk_reader_b
(
	.clk_sys(clk_sys),
	.reset(reset),

	.img_mounted(img_mounted[2]),
	.img_size(img_size),

	.sd_lba(sd_lba[2]),
	.sd_rd(sd_rd[2]),
	.sd_wr(disk_b_sd_wr),
	.sd_ack(sd_ack[2]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(disk_b_sd_buff_din),

	.track_byte_strobe_raw(track_byte_strobe),
	.track_byte(track_byte_b),

	.tx_byte_strobe_raw(disk_tx_strobe),
	.tx_byte_raw(disk_tx_byte),
	.n_write_enable_raw(disk_n_write_enable),
	.write_ok(disk_write_ok_b),

	// Drive B's OWN head position. A step pulse moves only the selected
	// drive's head, so these are separate nets from drive A's - see
	// uk101.vhd's stepper process for why a shared position is wrong (it
	// let drive B's seeks drag drive A's head, giving ERR #C on hardware).
	.track_number_raw(track_number_b),
	.track_changed_raw(track_changed_b),

	// '1' only when the two-bit drive select names drive B specifically,
	// AND drive B is fitted (always true - see drive A's active_raw comment).
	.active_raw((disk_drive_select == 2'd1) && disk_drive_armed),

	.rotational(disk_rotational),
	.rdrf(disk_rdrf_b),
	.tdre(disk_tdre_b),
	.index_hole_n(disk_index_hole_n_b),

	.busy(disk_busy_b),
	.loading(disk_loading_b)
);

// Drives C and D (four-drive support, 2026-08-01). Same module, same
// broadcast tx_byte/tx_strobe/n_write_enable/track_byte_strobe signals as
// drives A/B (there is only one ACIA) - `active` is what makes only the
// selected one respond. Own SD slots (3, 4), own geometry latch, own
// write-protect gate - see the declarations above.
disk_reader disk_reader_c
(
	.clk_sys(clk_sys),
	.reset(reset),

	.img_mounted(img_mounted[3]),
	.img_size(img_size),

	.sd_lba(sd_lba[3]),
	.sd_rd(sd_rd[3]),
	.sd_wr(disk_c_sd_wr),
	.sd_ack(sd_ack[3]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(disk_c_sd_buff_din),

	.track_byte_strobe_raw(track_byte_strobe),
	.track_byte(track_byte_c),

	.tx_byte_strobe_raw(disk_tx_strobe),
	.tx_byte_raw(disk_tx_byte),
	.n_write_enable_raw(disk_n_write_enable),
	.write_ok(disk_write_ok_c),

	// Drive C's OWN head position - see uk101.vhd's stepper process.
	.track_number_raw(track_number_c),
	.track_changed_raw(track_changed_c),

	// '1' only when the two-bit drive select names drive C AND drive C is
	// fitted (drives-fitted OSD option, 2026-08-01) - this is the drive
	// where disk_drive_armed actually restricts something: with only 2
	// drives fitted, C never captures a broadcast write even if something
	// is mounted in its slot. See uk101.vhd's disk_drive_armed comment for
	// why gating here (not just the CPU-visible status byte) matters.
	.active_raw((disk_drive_select == 2'd2) && disk_drive_armed),

	.rotational(disk_rotational),
	.rdrf(disk_rdrf_c),
	.tdre(disk_tdre_c),
	.index_hole_n(disk_index_hole_n_c),

	.busy(disk_busy_c),
	.loading(disk_loading_c)
);

disk_reader disk_reader_d
(
	.clk_sys(clk_sys),
	.reset(reset),

	.img_mounted(img_mounted[4]),
	.img_size(img_size),

	.sd_lba(sd_lba[4]),
	.sd_rd(sd_rd[4]),
	.sd_wr(disk_d_sd_wr),
	.sd_ack(sd_ack[4]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(disk_d_sd_buff_din),

	.track_byte_strobe_raw(track_byte_strobe),
	.track_byte(track_byte_d),

	.tx_byte_strobe_raw(disk_tx_strobe),
	.tx_byte_raw(disk_tx_byte),
	.n_write_enable_raw(disk_n_write_enable),
	.write_ok(disk_write_ok_d),

	// Drive D's OWN head position - see uk101.vhd's stepper process.
	.track_number_raw(track_number_d),
	.track_changed_raw(track_changed_d),

	// '1' only when the two-bit drive select names drive D AND drive D is
	// fitted - see drive C's active_raw comment.
	.active_raw((disk_drive_select == 2'd3) && disk_drive_armed),

	.rotational(disk_rotational),
	.rdrf(disk_rdrf_d),
	.tdre(disk_tdre_d),
	.index_hole_n(disk_index_hole_n_d),

	.busy(disk_busy_d),
	.loading(disk_loading_d)
);

// Layer 4 mux, extended: the single ACIA can only carry ONE drive's status,
// exactly as it can only carry one drive's track_byte (see the track_byte mux
// below). Selected the same way, off the same signal, so status and data
// always describe the same drive.
// Hardwired ON (2026-07-31): the runtime O[29] toggle that let access-driven
// and rotational timing be A/B compared on one bitstream has served its
// purpose and is removed. Rotational is now hardware-confirmed across every
// disk path this core has: 8" CREATE+SAVE, 5.25" format, a 26-track BEXEC*
// option-6 write, a from-blank COPIER run that produced a disk booting from
// its own track-0 bootstrap format, HEXDOS 4.0, PICO-DOS, UCSD Pascal boot,
// and a drive-B UCSD Filer Z(ero) - all byte-correct, no regressions found
// against the old access-driven behaviour. See SAVE_AND_DISK_PLAN.md's
// disk-emulation section for the full test log. The access-driven code paths
// in disk_reader.sv are left in place, gated on this now-constant signal,
// rather than excised - smaller diff, and `rotational` low is still exactly
// the prior shipped behaviour if this ever needs reverting.
wire disk_rotational = 1'b1;

// Drives fitted (2026-08-01, OSD O[2:1]): how many drive connectors exist,
// independent of whether a diskette is mounted in any of them. Passed
// straight through to uk101.vhd, which does all the gating - see its
// disk_drives_fitted port comment. Default status[2:1]=2'b00 = "2 drives",
// the only configuration ever hardware-confirmed.
wire [1:0] disk_drives_fitted = status[2:1];

// '1' when the drive currently addressed by the two-bit select is fitted -
// see uk101.vhd's disk_drive_armed port comment for why this must gate
// active_raw directly, not just rely on the CPU-visible status byte forcing
// TDRE clear. ANDed into all four active_raw expressions below; for A/B it
// is always '1' (they are unconditionally armed), so this changes nothing
// for them - only C/D are actually restricted by it.
wire disk_drive_armed;

wire disk_rdrf_a, disk_tdre_a, disk_index_hole_n_a;
wire disk_rdrf_b, disk_tdre_b, disk_index_hole_n_b;
wire disk_rdrf_c, disk_tdre_c, disk_index_hole_n_c;
wire disk_rdrf_d, disk_tdre_d, disk_index_hole_n_d;
// 4-way (four-drive support, 2026-08-01): every disk_drive_select value now
// names a real, implemented drive.
wire disk_rdrf         = (disk_drive_select == 2'd0) ? disk_rdrf_a :
                          (disk_drive_select == 2'd1) ? disk_rdrf_b :
                          (disk_drive_select == 2'd2) ? disk_rdrf_c :
                                                         disk_rdrf_d;
wire disk_tdre         = (disk_drive_select == 2'd0) ? disk_tdre_a :
                          (disk_drive_select == 2'd1) ? disk_tdre_b :
                          (disk_drive_select == 2'd2) ? disk_tdre_c :
                                                         disk_tdre_d;
wire disk_index_hole_n = (disk_drive_select == 2'd0) ? disk_index_hole_n_a :
                          (disk_drive_select == 2'd1) ? disk_index_hole_n_b :
                          (disk_drive_select == 2'd2) ? disk_index_hole_n_c :
                                                         disk_index_hole_n_d;
///////////////////
//  PLL - clocks are the most important part of a system
///////////////////////////////////////////////////
wire clk_sys, locked;
wire clk_VIDEO;
wire pll_clk_video;


pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys), // 48M

	.locked(locked)
);

///////////////////////////////////////////////////
wire reset = RESET | status[0] | buttons[1] | status[10] ;

assign CLK_VIDEO = clk_sys;


///////////////////////////////////////////////////
wire r, g, b;
wire vs,hs;
wire hsync, vsync;
wire hblank, vblank;
wire CE_PIX;
wire freeze_sync;
reg [3:0] count = 0;

wire [3:0] ce_pix_count;

//assign ce_pix_count = 11;

always_comb
begin
	if (machine_type == 1'b0)
		ce_pix_count = 5;
	else
		begin
			if (actual_res == 1'b0)
				ce_pix_count = 11;
			else
				ce_pix_count = 5;
		end
end

always_comb
begin
if (mem48k)
	// Forced Synmon (Disk) - see the mem48k/machine_type comment above.
	monitor_type=2'b10;
else if (machine_type==0)
	monitor_type=status[22:21];
else if (machine_type==2'b01)
	// OSI C2P: 3-way select (Cegmon/Synmon Basic/Synmon Disk) needs both
	// status[23:22], unlike C1P's single-bit Cegmon/Synmon choice below.
	monitor_type=status[23:22];
	else
	monitor_type={1'b0,status[23]};
end
	


always @(posedge clk_sys) begin
	if (count == ce_pix_count)
	begin
		count <= 0;
		CE_PIX <= 1'b1;
		end
	else	
		begin
		count <= count + 1'b1;
		CE_PIX <= 1'b0;
		end
end


wire [1:0] scale = status[13:12];
assign VGA_SL = scale ? scale - 1'd1 : 2'd0;
//assign VGA_SL=sl[1:0];
assign VGA_F1 = 0;
wire actual_res;

uk101 uk101
(
	.n_reset(~reset),
	.clk (clk_sys),
	.cpuOverclock(status[19:17]),
	.video_clock(CLK_VIDEO),
	.ps2Clk(PS2_CLK),
	.ps2Data(PS2_DAT),
	.hsync(hs),
	.vsync(vs),	
	.ce_pix(CE_PIX),	
	.r(r),			
	.g(g),
	.b(b),	
	.hblank(hblank),
	.vblank(vblank),
	//.colours(colour_scheme),
	.screen_mode(resolution),
	.actual_res(actual_res),
	// Effective (48K-overridden) values, NOT raw status - see mem48k above.
	.monitor_type(monitor_type_raw),
	.machine_type(machine_type),
	.memory_size(status[26:24]),
	.baud_rate(baud_rate),
	.rxd(UART_RXD),
	.txd(UART_TXD),
	.rts(UART_RTS),
	.loadFrom(loadFrom),
	.ioctl_download(ioctl_download),
   .ioctl_data(ioctl_data),
   .ioctl_addr(ioctl_addr),
	.ioctl_wr(ioctl_wr),
	.save_data(save_data),
	.save_strobe(save_strobe),
	.track_byte(track_byte),
	.disk_loading(disk_loading),
	.track_byte_strobe(track_byte_strobe),
	.track_number(track_number),
	.track_changed(track_changed),
	.track_number_b(track_number_b),
	.track_changed_b(track_changed_b),
	.track_number_c(track_number_c),
	.track_changed_c(track_changed_c),
	.track_number_d(track_number_d),
	.track_changed_d(track_changed_d),
	.disk_img_mounted(img_mounted[1]),
	.disk_is_8inch(disk_is_8inch),
	.disk_tx_byte(disk_tx_byte),
	.disk_tx_strobe(disk_tx_strobe),
	.disk_n_write_enable(disk_n_write_enable),
	.disk_write_ok(disk_write_ok),
	.disk_b_img_mounted(img_mounted[2]),
	.disk_is_8inch_b(disk_is_8inch_b),
	.disk_c_img_mounted(img_mounted[3]),
	.disk_is_8inch_c(disk_is_8inch_c),
	.disk_d_img_mounted(img_mounted[4]),
	.disk_is_8inch_d(disk_is_8inch_d),
	.disk_drive_select(disk_drive_select),
	.disk_write_ok_b(disk_write_ok_b),
	.disk_write_ok_c(disk_write_ok_c),
	.disk_write_ok_d(disk_write_ok_d),
	.disk_drives_fitted(disk_drives_fitted),
	.disk_drive_armed(disk_drive_armed),

	.disk_rotational(disk_rotational),
	.disk_rdrf(disk_rdrf),
	.disk_tdre(disk_tdre),
	.disk_index_hole_n(disk_index_hole_n)
);


wire [1:0] ar = status[9:8];

//assign VIDEO_ARX = 4;
//assign VIDEO_ARY = 3;

video_freak video_freak
(
	.*,
	.CE_PIXEL(CE_PIX),
	.CLK_VIDEO(CLK_VIDEO),
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[16:15])
);



video_mixer #(.LINE_LENGTH(494), .HALF_DEPTH(1), .GAMMA(1)) video_mixer
(
	.*,
	.CLK_VIDEO(CLK_VIDEO),
	.ce_pix(CE_PIX),
	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale == 1),

	.R({4{r}}),
	.G({4{g}}),
	.B({4{b}}),
	.HSync(hs),
	.VSync(vs),


	.HBlank(hblank),
	.VBlank(vblank)

);



endmodule
