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
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
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
assign HDMI_FREEZE = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////





`include "build_id.v"
localparam CONF_STR = {
	"UK101;;",
	"-;",
	"D0F,TXTBASLOD,Load Ascii;",
	"O33,Load programs from,File,UART;",
	"-;",
	"O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	//"OCD,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"OFG,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	//"O34,Colours,White on blue,White on black,Green on black,Yellow on black;",
	"d5O55,Screen resolution,Low,High;",
	"-;",
	"OOQ,Memory Size,4K,8K,32K,41K;",
	"H4OLM,Monitor,Cegmon,MonUK02,Wemon;",
	"h4ONN,Monitor,Cegmon,Synmon;",
	"-;",
	"O77,Baud Rate,9600,300;",
	"OHJ,Clock speed,1Mhz,2Mhz,4Mhz,8Mhz,10Mhz;",
	"OKK,Machine,UK101,OSI;",
	"-;",
	"RA,Reset;",
	"-;",
	"-;",
	"V,v",`BUILD_DATE
};



//
// HPS is the module that communicates between the linux and fpga
//
wire  [1:0] buttons;
wire [31:0] status;
wire PS2_CLK;
wire PS2_DAT;
wire loadFrom = status[3];
wire resolution;
wire [1:0]monitor_type;
wire baud_rate=status[7];
wire machine_type=status[20];
//assign resolution = status[5];
wire forced_scandoubler;
wire [21:0] gamma_bus;
wire grey_res_menu = (monitor_type==2'b0 || (machine_type==1'b1 && monitor_type == 2'b1));
wire ioctl_download;
wire ioctl_wr;
wire [15:0] ioctl_addr;
wire [7:0] ioctl_data;
wire [7:0] ioctl_index;
wire ioctl_wait;



always_comb
begin
if (machine_type==1'b0 && (monitor_type==2'b01 || monitor_type == 2'b10))
	resolution = 1'b0;
else
	resolution = status[5];
end


hps_io #(.CONF_STR(CONF_STR),.PS2DIV(2000)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.buttons(buttons),
	.status(status),
	.ps2_kbd_clk_out(PS2_CLK),
	.ps2_kbd_data_out(PS2_DAT),
	.forced_scandoubler(forced_scandoubler),
	.status_menumask({grey_res_menu, status[20],status[6:3]}),
	.gamma_bus(gamma_bus),
	
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait)

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
			if (resolution == 1'b0)
				ce_pix_count = 11;
			else
				ce_pix_count = 5;
		end
end

always_comb
begin
if (machine_type==0)
	monitor_type=status[22:21];
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
	.resolution(resolution),
	.monitor_type(status[23:21]),
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
	.ioctl_wr(ioctl_wr)
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
