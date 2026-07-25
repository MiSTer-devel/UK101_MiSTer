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

assign LED_DISK = {1'b1, save_busy | disk_busy}; // debug aid: lit during flush/track-load
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
	"O[28:27],Machine,UK101,OSI C2P,OSI C1P;",
	"O[19:17],Clock speed,1Mhz,2Mhz,4Mhz,8Mhz,10Mhz;",
	"O[26:24],Memory Size,4K,8K,32K,41K;",
	"H4H6O[22:21],Monitor,Cegmon,MonUK02,Wemon;",
	"h4O[23:22],Monitor,Cegmon,Synmon (Basic),Synmon (Disk);",
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
wire [1:0] machine_type=status[28:27];
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
wire [1:0] img_mounted;
wire [63:0] img_size;
wire [31:0] sd_lba[2];
wire [5:0] sd_blk_cnt[2];
wire [1:0] sd_rd;
wire [1:0] sd_wr;
wire [1:0] sd_ack;
wire [8:0] sd_buff_addr;
wire [7:0] sd_buff_dout;
wire [7:0] sd_buff_din[2];
wire sd_buff_wr;

assign sd_rd[0] = 1'b0;      // save slot never reads
assign sd_wr[1] = 1'b0;      // disk slot never writes (Step 2 is read-only)
assign sd_blk_cnt[0] = 6'd0;
assign sd_blk_cnt[1] = 6'd0;
assign sd_buff_din[1] = 8'h00; // disk slot never sourced for a write
wire save_busy;

// Disk-track read (Phase 2, Step 2/3)
wire [7:0] track_byte;
wire track_byte_strobe;
wire disk_busy;
wire [6:0] track_number;
wire track_changed;

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
// how disk_reader.sv latches its own trksiz at the same pulse.
reg disk_is_8inch = 1'b0;
always @(posedge clk_sys) begin
	if (img_mounted[1] && img_size != 0)
		disk_is_8inch <= (img_size == 64'd295680);
end



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



hps_io #(.CONF_STR(CONF_STR),.PS2DIV(2000),.VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.buttons(buttons),
	.status(status),
	.ps2_kbd_clk_out(PS2_CLK),
	.ps2_kbd_data_out(PS2_DAT),
	.forced_scandoubler(forced_scandoubler),
	.status_menumask({status[28],grey_res_menu, status[27],status[6:3]}),
	.gamma_bus(gamma_bus),
	
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
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
	.sd_ack(sd_ack[1]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),

	.track_byte_strobe_raw(track_byte_strobe),
	.track_byte(track_byte),

	.track_number_raw(track_number),
	.track_changed_raw(track_changed),

	.busy(disk_busy)
);
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
if (machine_type==0)
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
	.monitor_type(status[23:21]),
	.machine_type(status[28:27]),
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
	.track_byte_strobe(track_byte_strobe),
	.track_number(track_number),
	.track_changed(track_changed),
	.disk_img_mounted(img_mounted[1]),
	.disk_is_8inch(disk_is_8inch)
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
