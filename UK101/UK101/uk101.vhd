-- This file is copyright by Grant Searle 2014
-- You are free to use this file in your own projects but must never charge for it nor use it without
-- acknowledgement.
-- Please ask permission from Grant Searle before republishing elsewhere.
-- If you use this file or any part of it, please add an acknowledgement to myself and
-- a link back to my main web site http://searle.hostei.com/grant/    
-- and to the UK101 page at http://searle.hostei.com/grant/uk101FPGA/index.html
--
-- Please check on the above web pages to see if there are any updates before using this file.
-- If for some reason the page is no longer available, please search for "Grant Searle"
-- on the internet to see if I have moved to another web hosting service.
--
-- Grant Searle
-- eMail address available on my main web page link above.

library ieee;
	use ieee.std_logic_1164.all;
	use ieee.numeric_std.all;
	use ieee.std_logic_unsigned.all;

entity uk101 is
	port(
		n_reset		: in std_logic;
		clk			: in std_logic;
		video_clock	: in std_logic; 
		cpuOverclock	: in std_logic_vector(2 downto 0);
		ce_pix	: in std_logic; 	
		rxd			: in std_logic;
		txd			: out std_logic;
		rts			: out std_logic;
		--videoSync	: out std_logic;
		--video			: out std_logic;
		hsync			:	out std_logic;
		vsync			:	out std_logic;
		r				:	out std_logic;
		g				:	out std_logic;
		b				:	out std_logic;
		screen_mode	:	in std_logic_vector(1 downto 0);
		actual_res	:	out std_logic;
		--colours		:	in std_logic_vector(1 downto 0);
		monitor_type : in std_logic_vector(2 downto 0);
		memory_size : in std_logic_vector(2 downto 0);
		machine_type	: in std_logic_vector(1 downto 0);
		baud_rate : in std_logic;
		hblank		:	out std_logic;
		vblank		:	out std_logic;
		ps2Clk		: in std_logic;
		ps2Data		: in std_logic;
		loadFrom			: in std_logic;
	   ioctl_download : in std_logic;
		ioctl_wr : in std_logic;
		ioctl_data : in std_logic_vector(7 downto 0);
      ioctl_addr  : in std_logic_vector(15 downto 0);

		save_data : out std_logic_vector(7 downto 0);
		save_strobe : out std_logic;

		-- Phase 2 Step 2: real disk-track data, supplied by disk_reader.sv
		-- (see UK101.sv) and consumed by DiskAcia.vhd via u18 below.
		track_byte : in std_logic_vector(7 downto 0);
		track_byte_strobe : out std_logic;

		-- High while the SELECTED drive's disk_reader is refilling its track
		-- buffer from SD (muxed on drive select in UK101.sv, same as
		-- track_byte itself). Feeds DiskAcia so RDRF/TDRE read back clear for
		-- the duration - see DiskAcia.vhd's status read for the fault this
		-- fixes. Defaulted so an older instantiation still elaborates.
		disk_loading : in std_logic := '0';

		-- Phase 2 Step 3: current head position, driven by DiskPia's own
		-- stepper outputs (see the track-counter process below) and consumed
		-- by disk_reader.sv (see UK101.sv) to re-load the newly seeked-to
		-- track. track_changed toggles once per confirmed step.
		track_number  : out std_logic_vector(6 downto 0);
		track_changed : out std_logic;

		-- Drive B's head position. Separate from drive A's because a step
		-- pulse only moves the SELECTED drive's head - see the stepper
		-- process below for why a shared position is wrong.
		track_number_b  : out std_logic_vector(6 downto 0);
		track_changed_b : out std_logic;

		-- Drives C and D (four-drive support, 2026-08-01). Same reasoning as
		-- drive B: each drive's head position is independent, moved only when
		-- that exact drive is selected. See diskDriveSel2 below - the two-bit
		-- decode this core already computed from PA6+PB5 for the "armed"
		-- gate now addresses FOUR real drives instead of gating two and
		-- silencing two.
		track_number_c  : out std_logic_vector(6 downto 0);
		track_changed_c : out std_logic;
		track_number_d  : out std_logic_vector(6 downto 0);
		track_changed_d : out std_logic;

		-- Phase 2 Step 4c: disk-mount pulse (hps_io's img_mounted for the
		-- disk slot, see UK101.sv), used to reset trackNumber back to 0 on
		-- every (re-)mount. Without this, trackNumber - which has no reset
		-- other than FPGA configuration load - keeps whatever value was left
		-- over from a previous disk/session, silently desyncing
		-- n_track0_sense from disk_reader.sv's own mount-forced track-0
		-- load (which already resets correctly). Found via a hardware test
		-- that read n_track0_sense as "off track 0" before any stepping had
		-- occurred in that test run.
		disk_img_mounted : in std_logic;

		-- Phase 2 (8" support): geometry select from the mounted image size
		-- (UK101.sv derives it from img_size). '1' = 8" (77 tracks), '0' =
		-- 5.25" (40 tracks). Only affects the head-stepper's upper clamp; the
		-- track byte-size (2304 vs 3840) is handled entirely inside
		-- disk_reader.sv from the same img_size.
		disk_is_8inch : in std_logic;

		-- Phase B (write support, 2026-07-26): DiskAcia's write-side
		-- signals, exported for disk_reader.sv (see UK101.sv) to capture.
		-- disk_n_write_enable is DiskPia's own write_enable output
		-- (Port B bit0, active low - confirmed both against WinOSI's model
		-- and independently against OS-65D's own disassembled write
		-- primitive, see SAVE_AND_DISK_PLAN.md).
		disk_tx_byte        : out std_logic_vector(7 downto 0);
		disk_tx_strobe      : out std_logic;
		disk_n_write_enable : out std_logic;

		-- Phase B: '1' = writes are allowed. Named "..._ok" rather than
		-- "..._protect" so the polarity is unambiguous at every use site:
		-- it passes through un-inverted to DiskPia's `write_protect` pin,
		-- which is genuinely active-low in the real hardware ("0 IF WRITE
		-- PROTECT" per the OS-65D Disassembly Manual, confirmed against
		-- OS-65D's own write-protect check). See UK101.sv for why this
		-- naming is called out explicitly.
		disk_write_ok : in std_logic;

		-- Second disk drive (2026-07-27). Two things it depends on, both of
		-- which were got WRONG first time and are now settled - see
		-- SAVE_AND_DISK_PLAN.md's "second disk drive" section:
		--
		--   1. drive_select (DiskPia Port A bit6) is ACTIVE LOW: driven '0'
		--      selects drive B, driven '1' or left undriven selects drive A.
		--      From WinOSI's own PIA decode (6502.H:637-641, DRVSEL_L=64,
		--      sel_A=1/sel_B=2). The inverted reading of this broke SINGLE
		--      drive operation outright, because OS-65D drives PA6 high to
		--      select drive A during an ordinary boot - see DiskPia.vhd.
		--
		--   2. The head position is PER DRIVE. A step pulse moves only the
		--      selected drive's head; the other stays where it was left. Both
		--      WinOSI (independent track_a/track_b, stepped only when that
		--      drive is selected) and hardware agree - a shared counter let
		--      drive B's seeks drag drive A's head away, so reading B's
		--      directory and then loading from A gave ERR #C. Full evidence,
		--      including why the "OS-65D keeps one TKNUM so it must be
		--      shared" argument is wrong, is in the stepper process below.
		disk_b_img_mounted : in std_logic;
		-- Geometry is per-drive too: the last-track clamp follows whichever
		-- drive is selected, so a 5.25" disk in one drive and an 8" in the
		-- other each clamp correctly.
		disk_is_8inch_b    : in std_logic;

		-- Drives C and D (four-drive support, 2026-08-01). Mirrors drive B's
		-- mount pulse and geometry latch exactly - see UK101.sv for the SD
		-- slot wiring (slots 3 and 4).
		disk_c_img_mounted : in std_logic;
		disk_is_8inch_c    : in std_logic;
		disk_d_img_mounted : in std_logic;
		disk_is_8inch_d    : in std_logic;

		-- Drives fitted (2026-08-01, OSD status[2:1], default "00" = 2).
		-- Mirrors a real WinOSI settings panel ("Number of Drives: 1-4") that
		-- this core had no equivalent of until now: how many drive
		-- CONNECTORS actually exist, independent of whether a diskette is in
		-- any of them. "00"=2 (A/B only - the only configuration ever
		-- hardware-confirmed), "01"=3 (A/B/C), "10" or "11"=4 (A/B/C/D).
		--
		-- Exists because drives C/D becoming REAL drives (rather than
		-- permanently silenced) changes what an EMPTY C/D looks like to the
		-- CPU: previously "not there at all" (WinOSI's Mask_A preset - no
		-- index hole, no RDRF/TDRE, ever); now, unconditionally, "a drive is
		-- there, spinning, with nothing useful on it" (index hole pulses
		-- normally, RDRF/TDRE pace normally, reads return zeroed block RAM).
		-- Software that scans for drives by their index-hole behaviour -
		-- UCSD Pascal does, spin-polling Port A ~28,600 times per read run -
		-- sees a materially different signal either way, and the safe,
		-- default-on-power-up "00" preserves the EXACT hardware-confirmed
		-- Pascal-with-only-A/B-mounted environment: only a drive genuinely
		-- fitted by explicit user choice ever becomes a real drive.
		disk_drives_fitted : in std_logic_vector(1 downto 0) := "00";

		-- '1' when the addressed drive is fitted (2026-08-01, drives-fitted
		-- OSD option). Exported so UK101.sv can gate active_raw on all four
		-- disk_reader instances - NOT just the CPU-visible status byte.
		-- Reason this matters even though an unfitted drive's TDRE is always
		-- forced clear (so a well-behaved DOS never issues a write to it):
		-- disk_reader.sv's own tx_accept is gated on active_s2 (from
		-- active_raw) and its OWN internal write_ok/rotational-tdre, NOT on
		-- anything derived from the CPU-visible status byte. If a user has
		-- mounted an image in an unfitted C/D "for later" with writes
		-- enabled, and some driver ever writes to $C011 without polling TDRE
		-- first, that byte would otherwise still be captured and eventually
		-- flushed to the mounted image - a silent write to a drive the user
		-- told the core does not exist yet. This closes that gap the same
		-- way the original (pre-four-drive) design did, when a single
		-- disk_drive_armed bit gated both disk_reader instances' active_raw.
		disk_drive_armed   : out std_logic;

		-- Rotational disk timing (2026-07-30, OSD status[29], default '0').
		-- '0' selects the shipped access-driven behaviour and every signal
		-- below is bit-identical to it. Under '1', RDRF/TDRE and the index
		-- hole all come from the SELECTED disk_reader's rotation counter
		-- instead of being tied high / free-running respectively. The whole
		-- point is that the index hole and the head position become ONE
		-- clock, which they are not today - see disk_reader.sv.
		disk_rotational    : in std_logic := '0';
		disk_rdrf          : in std_logic := '1';
		disk_tdre          : in std_logic := '1';
		disk_index_hole_n  : in std_logic := '1';

		-- Exported so UK101.sv can mux which disk_reader instance's
		-- track_byte output feeds the single track_byte INPUT below -
		-- there is only one ACIA, so only one drive's byte stream can be
		-- "live" into it at a time. Now the FULL two-bit drv_sel (0=A, 1=B,
		-- 2=C, 3=D) rather than a single A/B bit plus a separate "armed" gate
		-- (four-drive support, 2026-08-01) - see diskDriveSel2 below. Every
		-- value now names a real, implemented drive, so there is no more
		-- "armed" concept to export separately.
		disk_drive_select : out std_logic_vector(1 downto 0);

		-- Drive B's write-protect gate. Separate from disk_write_ok because
		-- each image carries its own read-only flag; muxed by drive select
		-- into DiskPia's single write_protect pin below, exactly as
		-- n_track0_sense would be if it were not now shared.
		disk_write_ok_b : in std_logic;

		-- Drives C and D write-protect gates (four-drive support,
		-- 2026-08-01). Same reasoning as disk_write_ok_b.
		disk_write_ok_c : in std_logic;
		disk_write_ok_d : in std_logic
	);
end uk101;

architecture struct of uk101 is

	signal n_WR				: std_logic;
	signal cpuAddress		: std_logic_vector(15 downto 0);
	signal cpuDataOut		: std_logic_vector(7 downto 0);
	signal cpuDataIn		: std_logic_vector(7 downto 0);

	signal basRomData		: std_logic_vector(7 downto 0);
	signal basRomDataOSI		: std_logic_vector(7 downto 0);
	signal ramDataOut		: std_logic_vector(7 downto 0);
	signal monitorRomData : std_logic_vector(7 downto 0);
	signal monUKRomData : std_logic_vector(7 downto 0);
	signal SynmonRomData : std_logic_vector(7 downto 0);
	signal SynmonHDMRomData : std_logic_vector(7 downto 0);
	signal WemonRomData : std_logic_vector(7 downto 0);
	signal cegmonOSIRomData : std_logic_vector(7 downto 0);
	signal cegmonC1PRomData : std_logic_vector(7 downto 0);
	signal Syn600C1RomData : std_logic_vector(7 downto 0);
	signal aciaData		: std_logic_vector(7 downto 0);
	signal diskPiaData	: std_logic_vector(7 downto 0);
	signal diskAciaData	: std_logic_vector(7 downto 0);

	signal n_memWR			: std_logic;

	signal n_dispRamCS	: std_logic;
	signal n_ramCS			: std_logic;
	signal n_basRomCS		: std_logic;
	signal n_monitorRomCS : std_logic;
	signal n_aciaCS		: std_logic;
	signal n_kbCS			: std_logic;
	signal n_iocs			: std_logic;
	signal n_diskPiaCS	: std_logic;
	signal n_diskAciaCS	: std_logic;

	-- Phase 2 Step 3: track-stepper counter, driven by DiskPia's step_pulse/
	-- step_direction outputs (previously left `open`). Runs in the fast
	-- `clk` domain with its own 3-stage synchronizer on step_pulse, since
	-- orb (and hence step_pulse) is itself updated asynchronously by the
	-- CPU-bus-clocked n_wr process in DiskPia - the same CDC discipline used
	-- throughout this project, just entirely within uk101.vhd this time.
	signal diskStepPulse		: std_logic;
	signal diskStepDirection	: std_logic;
	signal diskTrack0Sense	: std_logic;

	-- Phase B (write support): DiskPia's write_enable output (already
	-- present in DiskPia.vhd, previously wired to `open`) fanned out to
	-- both DiskAcia (u18) and the new uk101 entity output above.
	signal diskWriteEnable	: std_logic;
	signal diskTxByte		: std_logic_vector(7 downto 0);
	signal diskTxStrobe		: std_logic;
	signal stepPulse_s1, stepPulse_s2, stepPulse_s3 : std_logic := '0';
	signal trackNumber		: unsigned(6 downto 0) := (others => '0');
	signal trackChanged		: std_logic := '0';
	-- Head-position upper clamp: 5.25" = 40 tracks (max index 39), 8" = 77
	-- tracks (max index 76). Selected at runtime from the mounted image
	-- (disk_is_8inch), so a real-world "recalibrate by stepping out N times
	-- unconditionally" routine parks at the correct last track instead of
	-- wrapping. The per-track byte size (2304 vs 3840) is handled separately
	-- inside disk_reader.sv from the same img_size.
	signal DISK_MAX_TRACK : unsigned(6 downto 0);

	-- Second disk drive (2026-07-27). Drive B's own head position - a step
	-- pulse moves only the SELECTED drive's head (see the stepper process for
	-- the evidence, including the hardware failure that a shared counter
	-- caused).
	signal trackNumber_b     : unsigned(6 downto 0) := (others => '0');
	signal trackChanged_b    : std_logic := '0';

	-- Drives C and D (four-drive support, 2026-08-01). Same per-drive head
	-- position reasoning as drive B.
	signal trackNumber_c     : unsigned(6 downto 0) := (others => '0');
	signal trackChanged_c    : std_logic := '0';
	signal trackNumber_d     : unsigned(6 downto 0) := (others => '0');
	signal trackChanged_d    : std_logic := '0';

	signal diskDriveSelect   : std_logic;
	-- DiskPia Port B bit5, the HIGH bit of the two-bit drive select.
	signal diskDrivePairSelect : std_logic;
	-- Full two-bit drive select (four-drive support, 2026-08-01), combining
	-- diskDriveSelect (PA6, the low bit) and diskDrivePairSelect (PB5, the
	-- high bit) into ONE clean value: "00"=A, "01"=B, "10"=C, "11"=D - taken
	-- from WinOSI's own drv_sel formula (6502.H:637-641/655-659). This is
	-- WHICH of the four drives is being addressed; it says nothing about
	-- whether that drive actually exists - see diskDriveArmed below for that.
	signal diskDriveSel2     : std_logic_vector(1 downto 0);
	-- Integer form of disk_drives_fitted, for the plain-integer comparisons
	-- below (matches the i_cpuOverclock/i_monitor_type style already used
	-- throughout this file).
	signal diskDrivesFitted  : integer range 0 to 3;
	-- REINTRODUCED (2026-08-01, drives-fitted OSD option): '1' when the
	-- addressed drive genuinely exists. A and B are unconditionally armed -
	-- the minimum configuration is always 2 drives, and that is the only
	-- configuration ever hardware-confirmed. C needs "3 or more" fitted, D
	-- needs "4" - see the assignment below. This is a DIFFERENT signal from
	-- the diskDriveArmed this branch briefly removed when C/D first became
	-- real drives: that one was permanently tied to PB5 (drive_pair_select);
	-- this one is driven by an explicit OSD choice, defaulting to the exact
	-- 2-drive behaviour every other test in this project was run against.
	signal diskDriveArmed    : std_logic;
	signal diskWriteProtect  : std_logic;
	-- Persistent "has drive B ever been mounted this session" latch, never
	-- cleared - matching the existing precedent that drive0_not_ready is
	-- hardcoded '0' (always ready) with no real mount-tracking at all.
	-- Tracking a genuine unmount is a later refinement, not required for
	-- basic two-drive read/write.
	--
	-- KNOWN GAP, deliberately not addressed in this pass (four-drive support,
	-- 2026-08-01): Port A only has two "drive not ready" bits (bit0, bit4),
	-- fixed at drive0/drive1 and never muxed by drive select even today - so
	-- there is no existing pattern to extend to drives C/D, and no measured
	-- reference for what a real 4-drive OSI system (or WinOSI) does here.
	-- Left exactly as-is: drive0_not_ready stays hardcoded '0' and
	-- drive1_not_ready stays tied to drive B specifically, regardless of
	-- which drive is actually selected. C and D therefore never report ERR #6
	-- "drive not ready" for an empty slot - they behave as drive A already
	-- does (also never reports it). Not required for basic read/write, which
	-- disk_reader.sv's own per-instance `ever_mounted` guard already handles
	-- safely for an empty drive regardless of this gap.
	signal diskB_everMounted : std_logic := '0';

	-- Phase 2 Step 3 fix: free-running index-hole pulse. CegmonRomC1P's disk
	-- boot routine ($FC00) polls Port A bit7 for a low->high transition
	-- before proceeding (a real once-per-revolution sensor pulse) - left
	-- hardcoded '0' since Step 1, it would hang that wait forever. Bit 23 of
	-- a free-running counter toggles at ~48MHz/2^24 =~ 2.9Hz, close to a
	-- real 300rpm (5rev/s) drive's index rate - exact timing doesn't matter
	-- here, just that the transition eventually happens.
	signal indexHoleCounter : unsigned(23 downto 0) := (others => '0');
	signal indexHole        : std_logic;

	signal dispAddrB 		: std_logic_vector(10 downto 0);
	signal dispRamDataOutA : std_logic_vector(7 downto 0);
	signal dispRamDataOutB : std_logic_vector(7 downto 0);
	signal charAddr 		: std_logic_vector(10 downto 0);
	signal charData 		: std_logic_vector(7 downto 0);
	signal charDataUK101 		: std_logic_vector(7 downto 0);
	signal charDataOSI 		: std_logic_vector(7 downto 0);

	signal serialClkCount: std_logic_vector(14 downto 0); 
	signal cpuClkCount	: std_logic_vector(5 downto 0); 
	signal cpuClock		: std_logic;
	signal serialClock	: std_logic;

	signal kbReadData 	: std_logic_vector(7 downto 0);
	signal kbRowSel 		: std_logic_vector(7 downto 0);
	--signal video_clock		: std_ulogic;
	
	--serial clock count thresholds
	constant c_9600BaudClkCount1 : integer:=325;
	constant c_9600BaudClkCount2 : integer:=162;
	constant c_300BaudClkCount1 : integer:=10416;
	constant c_300BaudClkCount2 : integer:=5208;
	
	signal serialClkCount1: integer := 0;
	signal serialClkCount2: integer := 0;
	signal i_clockThreshold1 : integer range 0 to 50 := 0;
	signal i_clockThreshold2 : integer range 0 to 25 := 0;
	signal i_cpuOverclock : integer range 0 to 5 := 0;
	signal i_monitor_type : integer range 0 to 3 := 0;
	signal i_memory_size : integer range 0 to 4 := 0;
	signal i_machine_type : integer range 0 to 3 := 0;
	signal latchedbits : std_logic_vector(7 downto 0);
	signal resolution : std_logic;

begin

	resolution <= latchedbits(0) when i_machine_type=1 and screen_mode(1)='1' else screen_mode(0);
	actual_res <= resolution;
	i_clockThreshold1 <= 49 when i_cpuOverclock = 0 else 	--1Mhz
								23 when i_cpuOverclock = 1 else	--2 Mhz
								11 when i_cpuOverclock = 2 else	--4 Mhz
								5 when i_cpuOverclock = 3 else 4; -- 8, 10 Mhz
								
	i_clockThreshold2 <= 25 when i_cpuOverclock = 0 else
							  12 when i_cpuOverclock = 1 else
							  6 when i_cpuOverclock = 2 else
							  3 when i_cpuOverclock = 3 else 2;
								
	serialClkCount1 <= c_9600BaudClkCount1 when baud_rate = '0' else c_300BaudClkCount1;
	serialClkCount2 <= c_9600BaudClkCount2 when baud_rate = '0' else c_300BaudClkCount2;
	
	i_cpuOverclock <= to_integer(unsigned(cpuOverclock));
	-- machine_type=0 (UK101): 3-way select via status[22:21] (2 bits).
	-- machine_type=1 (OSI C2P): 3-way select via status[23:22] (2 bits) -
	-- 0=Cegmon, 1=Synmon "C/W/M" (SynmonRom.VHD, ROM BASIC, no disk),
	-- 2=Synmon "H/D/M" (SynmonRomHDM.VHD, disk boot, no ROM BASIC) - the
	-- real SYNMON chip's $FF00 page is jumper-selected to one or the other,
	-- never both at once, so this core exposes them as separate OSD choices
	-- instead of picking one.
	-- machine_type=2 (OSI C1P): 2-way select via status[23] (1 bit) - only
	-- ever had one Synmon variant (SYN600), no C2-style page-swap ambiguity.
	i_monitor_type <= to_integer(unsigned(monitor_type(1 downto 0))) when i_machine_type = 0 else
							 to_integer(unsigned(monitor_type(2 downto 1))) when i_machine_type = 1 else
							 to_integer(unsigned('0' & monitor_type(2 downto 2)));
	i_memory_size <= to_integer(unsigned(memory_size(2 downto 0)));
	i_machine_type <= to_integer(unsigned(machine_type(1 downto 0)));
	charData <= charDataUK101 when i_machine_type = 0 else charDataOSI;
	
	n_memWR <= not(cpuClock) nand (not n_WR);

	n_dispRamCS <= '0' when cpuAddress(15 downto 11) = "11010" and  (i_machine_type = 0 or i_machine_type = 1) else
						'0' when cpuAddress(15 downto 10) = "110100" and  i_machine_type = 2 else 
						'1';
	-- 8K BASIC ROM at $A000-$BFFF, banked OUT in the 48K memory size.
	--
	-- This is the whole 48K feature: the ROM occupies exactly the 8K that
	-- takes contiguous low RAM from 40K to 48K, so the two are mutually
	-- exclusive. Mirrors WinOSI's own BASICENABLE setting, which its working
	-- UCSD Pascal configuration pairs with RAMTOP=$BFFF.
	--
	-- Root-caused 2026-07-28: UCSD Pascal's long-standing hang on this core
	-- is INSUFFICIENT RAM and nothing else. Bisected in WinOSI on one
	-- variable - BASICENABLE=0 (48K) runs, BASICENABLE=1 (40K) hangs, same
	-- disks. The index-hole poll loop at $3D11 that simulation had fingered
	-- was a red herring.
	--
	-- Safe for disk software: OS-65D's BASIC is a self-contained RAM-resident
	-- replacement, not an extension of ROM BASIC - a full 8M-instruction
	-- trace of a boots-straight-to-BASIC disk showed ZERO PC hits anywhere in
	-- $A000-$BFFF. What it does break is anything genuinely calling ROM BASIC
	-- (cassette BASIC, the monitor's "B" boot), hence opt-in via the menu
	-- rather than automatic.
	n_basRomCS <= '0' when cpuAddress(15 downto 13) = "101"
	                       and i_memory_size /= 4 else '1'; --8k
	n_monitorRomCS	<= '0' when cpuAddress(15 downto 11) = "11111" and ((i_machine_type = 0 and i_monitor_type < 2) or i_machine_type = 2) else --uk101
							'0' when cpuAddress(15 downto 12) = "1111" and i_machine_type = 0 and i_monitor_type = 2 else	--uk101 with wemon
						'0' when cpuAddress(15 downto 11) = "11111" and i_machine_type = 1 and (i_monitor_type = 1 or i_monitor_type = 2)  else		--OSI with Synmon (C/W/M or H/D/M)
						'0' when (cpuAddress(15 downto 11) = "11111" and cpuAddress(11 downto 8) /= "1100") and i_machine_type = 1 and i_monitor_type = 0  else		-- 2K      $F800-$FFFF  (except $FC00-$FCFF)  C2/C4
					   '0' when cpuAddress(15 downto 8)  = "11110100" and i_machine_type = 1 and i_monitor_type = 0 else	   										-- 256byte $F400-$F4FF  (relocated FC00-FCFF block)
					   '1';
	n_iocs <= '0' when cpuAddress(15 downto 0 ) = X"DE00" and i_machine_type = 1 else '1';
	-- Disk PIA/ACIA ($C000-$C003/$C010-$C011) - OSI C1P only for now (Phase 2
	-- Step 1). See SAVE_AND_DISK_PLAN.md: this is the recommended first target
	-- since it shares the plain UK101 $F000 ACIA decode and matches the
	-- best-understood C1PMF disk images. Extended to i_machine_type = 1 (C2/C4)
	-- once cross-checked against the real WinOSI binary: $C000 disk PIA /
	-- $C010 disk ACIA is the one and only disk-controller address across
	-- every OSI floppy-capable machine type (C1PMF/C4PMF/C8PDF/C3OEM), not
	-- board-variant dependent - confirmed again by disassembling both
	-- CegmonRomOSI's own disk routine (relocated to $F400 to dodge the
	-- $FC00 system ACIA) and the C2/C4 Synmon page-7 routine, both of which
	-- use these same addresses.
	n_diskPiaCS <= '0' when cpuAddress(15 downto 2) = "11000000000000" and (i_machine_type = 1 or i_machine_type = 2) else '1';
	n_diskAciaCS <= '0' when cpuAddress(15 downto 1) = "110000000001000" and (i_machine_type = 1 or i_machine_type = 2) else '1';
	-- 48K is a HARD CEILING at $BFFF, deliberately NOT the 41K "everything
	-- not otherwise claimed" rule.
	--
	-- Real hardware has no RAM above $BFFF - that is I/O and ROM space, and
	-- WinOSI's own ini documents "MAX is BFFF for 48K". The 41K rule answers
	-- as RAM in every gap above it too ($C004-$C00F, $C012-$CFFF,
	-- $E000-$EFFF, ...), which OS-65D never notices because it never probes.
	-- UCSD Pascal DOES size memory, finds RAM that should not exist, and puts
	-- its buffers past $BFFF - straight through screen RAM at $D000-$D7FF.
	-- Observed on hardware 2026-07-28: booting Pascal's system disk filled
	-- the display with its own volume directory (legible filenames, so the
	-- disk path was byte-perfect - only the destination was wrong).
	--
	-- Differential evidence: c4pmf_sim returns $FF for $C000-$CFFF and
	-- $E000-$F7FF, i.e. a correctly restricted map, and Pascal boots to its
	-- command prompt there. The RTL was the odd one out.
	--
	-- Nothing else decodes below $C000 once BASIC is banked out, so a plain
	-- top-two-bits test is complete: display RAM, keyboard, ACIA, monitor ROM
	-- and the disk PIA/ACIA all live at $C000 or above. 41K keeps its old
	-- behaviour untouched - it is unfaithful in the same way, but everything
	-- shipped today depends on it.
	n_ramCS <= '0' when cpuAddress(15 downto 14) /= "11" and i_memory_size = 4 else  --48K: $0000-$BFFF ONLY
					not(n_dispRamCS and n_basRomCS and n_monitorRomCS and n_aciaCS and n_kbCS and n_diskPiaCS and n_diskAciaCS) when i_memory_size = 3 else  --41K
					'0' when cpuAddress(15 downto 12) = "0000" and i_memory_size = 0 else											--4k
					'0' when cpuAddress(15 downto 13) = "000"  and i_memory_size = 1 else											--8k
					'0' when cpuAddress(15) = '0' and i_memory_size = 2																	--32K
					else '1';
	n_aciaCS <= '0' when cpuAddress(15 downto 1) = "111100000000000" and ((i_machine_type = 0 and i_monitor_type < 2) or i_machine_type = 2) else
					'0' when cpuAddress(15 downto 1) = "111000000000000" and i_machine_type = 0 and i_monitor_type = 2 else
					'0' when cpuAddress(15 downto 1) = "111111000000000" and i_machine_type = 1 else '1';
	n_kbCS <= '0' when cpuAddress(15 downto 10) = "110111" else '1';

 
	cpuDataIn <=
		    -- CEGMON PATCH TO CORRECT AUTO-REPEAT IN FAST MODE(UK101)
		x"A0" when cpuAddress = X"FCE0" and i_cpuOverclock = 4 and (i_machine_type = 0 or i_machine_type = 2) else -- Address = FCE0 and fastMode = 1 : CHANGE REPEAT RATE LOOP VALUE (was $10)
		x"80" when cpuAddress = X"FCE0" and i_cpuOverclock = 3 and (i_machine_type = 0 or i_machine_type = 2) else 
		x"40" when cpuAddress = X"FCE0" and i_cpuOverclock = 2 and (i_machine_type = 0 or i_machine_type = 2) else 	
		x"20" when cpuAddress = X"FCE0" and i_cpuOverclock = 1 and (i_machine_type = 0 or i_machine_type = 2) else 	
		x"10" when cpuAddress = X"FCE0" and i_cpuOverclock = 0 and (i_machine_type = 0 or i_machine_type = 2) else 	
	
		 -- CEGMON PATCH TO CORRECT AUTO-REPEAT IN FAST MODE(OSI)
		x"A0" when cpuAddress = X"F4E0" and i_cpuOverclock = 4 and i_machine_type = 1 else -- Address = F4E0 and fastMode = 1 : CHANGE REPEAT RATE LOOP VALUE (was $10)
		x"80" when cpuAddress = X"F4E0" and i_cpuOverclock = 3 and i_machine_type = 1 else 
		x"40" when cpuAddress = X"F4E0" and i_cpuOverclock = 2 and i_machine_type = 1 else 	
		x"20" when cpuAddress = X"F4E0" and i_cpuOverclock = 1 and i_machine_type = 1 else 	
		x"10" when cpuAddress = X"F4E0" and i_cpuOverclock = 0 and i_machine_type = 1 else 		
		
		
		
		-- CEGMON PATCH FOR 64x32 SCREEN
		x"3F" when cpuAddress = x"FBBC" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SWIDTH (was $47)
		x"00" when cpuAddress = x"FBBD" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON TOP L (was $0C (1st line) or $8C (3rd line))
		x"BF" when cpuAddress = x"FBBF" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON BASE L (was $CC)
		x"D7" when cpuAddress = x"FBC0" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON BASE H (was $D3)
		x"00" when cpuAddress = x"FBC2" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"00" when cpuAddress = x"FBC5" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"00" when cpuAddress = x"FBCB" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"10" when cpuAddress = x"FE62" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON CLR SCREEN SIZE (was $08)
		x"D8" when cpuAddress = x"FB8B" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SCREEN BOTTOM H (was $D4) - Part of CTRL-F code
		x"D7" when cpuAddress = x"FE3B" and resolution='1' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SCREEN BOTTOM H - 1 (was $D3) - Part of CTRL-A code
		
		x"2F" when cpuAddress = x"FBBC" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SWIDTH (was $47)
		x"1F" when cpuAddress = x"FBBC" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 1 else -- CEGMON SWIDTH (was $47)
		x"00" when cpuAddress = x"FBBD" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON TOP L (was $0C (1st line) or $8C (3rd line))
		x"85" when cpuAddress = x"FBBF" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON BASE L (was $CC)
		x"D3" when cpuAddress = x"FBC0" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON BASE H (was $D3)
		x"00" when cpuAddress = x"FBC2" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"00" when cpuAddress = x"FBC5" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"00" when cpuAddress = x"FBCB" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON STARTUP TOP L (was $0C (1st line) or $8C (3rd line))
		x"08" when cpuAddress = x"FE62" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON CLR SCREEN SIZE (was $08)
		x"D4" when cpuAddress = x"FB8B" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SCREEN BOTTOM H (was $D4) - Part of CTRL-F code
		x"D3" when cpuAddress = x"FE3B" and resolution='0' and screen_mode(1)='0' and i_monitor_type = 0 and i_machine_type = 0 else -- CEGMON SCREEN BOTTOM H - 1 (was $D3) - Part of CTRL-A code
		basRomData when n_basRomCS = '0' and i_machine_type = 0 else
		basRomDataOSI when n_basRomCS = '0' and (i_machine_type = 1 or i_machine_type = 2) else
		monitorRomData when n_monitorRomCS = '0' and i_machine_type = 0 and i_monitor_type = 0 else
		monUKRomData when n_monitorRomCS = '0' and i_machine_type = 0 and i_monitor_type = 1 else
		WemonRomData when n_monitorRomCS = '0' and i_machine_type = 0 and i_monitor_type = 2 else
		cegmonOSIRomData when n_monitorRomCS = '0' and i_machine_type = 1 and i_monitor_type = 0  else
		cegmonC1PRomData when n_monitorRomCS = '0' and i_machine_type = 2 and i_monitor_type = 0 else
		Syn600C1RomData when n_monitorRomCS = '0' and i_machine_type = 2 and i_monitor_type = 1 else
		SynmonRomData when n_monitorRomCS = '0' and i_machine_type = 1 and i_monitor_type = 1 and cpuAddress >=x"FD00"  else
		SynmonHDMRomData when n_monitorRomCS = '0' and i_machine_type = 1 and i_monitor_type = 2 and cpuAddress >=x"FD00"  else
		aciaData when n_aciaCS = '0' else
		diskPiaData when n_diskPiaCS = '0' else
		diskAciaData when n_diskAciaCS = '0' else
		ramDataOut when n_ramCS = '0' else
		dispRamDataOutA when n_dispRamCS = '0' else
		-- $DE00 read, OSI C2P (machine_type=1): 540 video board status - bit7
		-- is the vertical field flag. The OS-65D "$2214 -> $2E79" boot variant
		-- calibrates frame timing by polling this bit for a toggle ($2E93 BMI /
		-- $2E9A BPL loops); under the blanket $DC00-$DFFF keyboard decode this
		-- read returned keyboard data (bit7 never set) and those disks hung
		-- forever at $2E9A. bit19 of the free-running 48MHz indexHoleCounter
		-- toggles every ~10.9ms (~45.8Hz square) - close enough to the real
		-- board's 50/60Hz field rate for the timing loop. Sim-validated
		-- (c4pmf_sim): fail->pass for OS65D33/C4P-Tutorials/DEALERDEMO, and a
		-- provable no-op for everything else (no monitor ROM and no working
		-- disk ever READS $DE00). Writes to $DE00 are untouched (outlatch).
		indexHoleCounter(19) & "0000000" when cpuAddress = x"DE00" and i_machine_type = 1 else
		kbReadData when n_kbCS='0'
		else x"FF";
		
	u1 : entity work.T65
	port map(
		Enable => '1',
		Mode => "00",
		Res_n => n_reset,
		Clk => cpuClock,
		Rdy => '1',
		Abort_n => '1',
		IRQ_n => '1',
		NMI_n => '1',
		SO_n => '1',
		R_W_n => n_WR,
		A(15 downto 0) => cpuAddress,
		DI => cpuDataIn,
		DO => cpuDataOut);
			

	u2 : entity work.BasicRom -- 8KB
	port map(
		address => cpuAddress(12 downto 0),
		clock => clk,
		q => basRomData
	);
	
	
	u10 : entity work.BasicRomOSI -- 8KB
	port map(
		address => cpuAddress(12 downto 0),
		clock => clk,
		q => basRomDataOSI
	);

	u3: entity work.ProgRam 
	port map
	(
		address => cpuAddress(15 downto 0),
		clock => clk,
		data => cpuDataOut,
		wren => not(n_memWR or n_ramCS),
		q => ramDataOut
	);
		
	u4: entity work.CegmonRom
	port map
	(
		address => cpuAddress(10 downto 0),
		q => monitorRomData
	);
	
	u11: entity work.MonUK02Rom
	port map
	(
		address => cpuAddress(10 downto 0),
		q => monUKRomData
	);
	
	
	u12: entity work.CegmonRomOSI
	port map
	(
		address => cpuAddress(10 downto 0),
		q => cegmonOSIRomData
	);
	
	u16: entity work.CegmonRomC1P
	port map
	(
		address => cpuAddress(10 downto 0),
		q => cegmonC1PRomData
	);

	u19: entity work.Syn600RomC1
	port map
	(
		address => cpuAddress(10 downto 0),
		q => Syn600C1RomData
	);

	u14: entity work.SynmonRom
	port map
	(
		address => cpuAddress(10 downto 0),
		q => SynmonRomData
	);

	u20: entity work.SynmonRomHDM
	port map
	(
		address => cpuAddress(10 downto 0),
		q => SynmonHDMRomData
	);

	u15: entity work.WemonRom
	port map
	(
		address => cpuAddress(11 downto 0),
		q => WemonRomData
	);

	u5: entity work.bufferedUART
	port map(
		clk => clk,
		n_wr => n_aciaCS or cpuClock or n_WR,
		n_rd => n_aciaCS or cpuClock or (not n_WR),
		regSel => cpuAddress(0),
		dataIn => cpuDataOut,
		dataOut => aciaData,
		rxClock => serialClock,
		txClock => serialClock,
		rxd => rxd,
		txd => txd,
		n_cts => '0',
		n_dcd => '0',
		n_rts => rts,
		ioctl_download => ioctl_download,
	   ioctl_data => ioctl_data,
		ioctl_addr => ioctl_addr,
		ioctl_wr => ioctl_wr,
		loadFrom => loadFrom,
		save_data => save_data,
		save_strobe => save_strobe

	);

	-- Phase 2 Step 1: disk PIA + ACIA register plumbing, no SD-image
	-- interaction yet - see DiskPia.vhd/DiskAcia.vhd for details.
	-- Phase 2 Step 3: n_track0_sense is now live (fed back from the
	-- trackNumber counter below) and step_direction/step_pulse are wired to
	-- that same counter instead of `open`. drive_select/erase_enable/
	-- drive_pair_select/head_load remain unused - a single virtual drive is
	-- assumed for now.
	-- Phase B (write support): write_enable now feeds DiskAcia (u18) and the
	-- new uk101 entity output, instead of `open`; write_protect now comes
	-- from the new disk_write_ok entity input, instead of a hardcoded
	-- '0' (which unconditionally told OS-65D every disk was write-protected -
	-- the correct behaviour for a read-only core, but no longer correct now
	-- that writes can be enabled).
	u17: entity work.DiskPia
	port map(
		n_reset => n_reset,
		n_wr => n_diskPiaCS or cpuClock or n_WR,
		n_rd => n_diskPiaCS or cpuClock or (not n_WR),
		regSel => cpuAddress(1 downto 0),
		dataIn => cpuDataOut,
		dataOut => diskPiaData,
		drive0_not_ready => '0',
		drive1_not_ready => not diskB_everMounted,
		n_track0_sense => diskTrack0Sense,
		-- Un-inverted: DiskPia's write_protect pin is itself active-low
		-- ('0' = protected), and disk_write_ok is '1' = writes allowed.
		write_protect => diskWriteProtect,
		index_hole => indexHole,
		drive_select => diskDriveSelect,
		-- PB5, the HIGH drive-select bit. No longer `open` - see
		-- diskDriveSel2 below for the full reasoning and the measurements.
		drive_pair_select => diskDrivePairSelect,
		write_enable => diskWriteEnable,
		erase_enable => open,
		step_direction => diskStepDirection,
		step_pulse => diskStepPulse,
		head_load => open
	);

	disk_n_write_enable <= diskWriteEnable;
	disk_tx_byte        <= diskTxByte;
	disk_tx_strobe      <= diskTxStrobe;

	-- Phase 2 Step 3: track-stepper counter. Head position is tracked purely
	-- in this FPGA-side model (the real hardware has no register for it -
	-- only a track0 sense bit) and fed back into DiskPia's n_track0_sense
	-- input, plus exported as track_number/track_changed for disk_reader.sv
	-- to re-load the newly-seeked-to track (see UK101.sv).
	--
	-- PER-DRIVE head position (see the entity comment): a step pulse only
	-- moves the SELECTED drive's head, so each drive has its own counter and
	-- everything derived from head position is muxed on drive select.
	-- ===== TWO-BIT DRIVE SELECT (PB5 + PA6), 2026-07-31 =====
	--
	-- Real hardware and WinOSI decode the selected drive from BOTH Port B bit5
	-- and Port A bit6, giving four drives (6502.H:637-641 and again at 655-659):
	--
	--     drv_sel = 0;
	--     if ((portbdat & DRVSEL_H) == 0) drv_sel ^= 0x02;   // PB5
	--     if ((portadat & DRVSEL_L) == 0) drv_sel ^= 0x01;   // PA6
	--     drv_sel++;                                          // -> 1..4
	--
	-- with sel_A=1, sel_B=2 (Fileio.h:509-510). So PB5 HIGH gives drive A or B,
	-- PB5 LOW gives drive C or D. WinOSI then gates EVERY disk operation on the
	-- result being exactly A or B and that drive existing, e.g.
	--     if ((drv_sel==sel_A)&((sel_drv&1)==1))
	-- so for drives C/D it does nothing at all: no step, no index hole, no
	-- track-0 sense, no data, no RDRF/TDRE. Its Port A read just returns the
	-- Mask_A preset (6502.H:340).
	--
	-- We previously decoded PA6 ONLY and left drive_pair_select `open`, so
	-- drive C silently aliased onto A and D onto B, both answering with real
	-- data where the reference gives silence.
	--
	-- WHY THIS IS WORTH CHANGING, and why it is safe - both MEASURED, not
	-- reasoned (c4pmf_sim/pascal_pb5_probe.py; both write DDRB=$FF once at
	-- instr 8, so Port B is all-outputs and every later $C002 write really does
	-- drive the pins):
	--   UCSD Pascal : 212 ORB writes drive PB5 LOW, first at instr 381063.
	--   OS-65D 8"   : ZERO. Every single ORB write has bit5 = 1.
	-- So this cannot alter the behaviour of OS-65D - and therefore of any disk
	-- that works today - while it does change what Pascal sees, which is the
	-- software that is broken. Pascal was getting drive A's or B's real data on
	-- accesses where a real machine's drives stay silent, which with a disk in
	-- drive B puts the same volume on two different units.
	--
	-- NOT gated on head_load (PB7) as well: WinOSI's decode does not consult it
	-- for drive selection, and OS-65D's own head_load usage has never been
	-- traced here. One measured change at a time.
	-- FOUR-DRIVE SUPPORT (2026-08-01): diskDriveSel2 replaces the old
	-- diskDriveArmed ('1'=A-or-B selected, '0'=C-or-D-silenced) now that C
	-- and D are real, implemented drives rather than a silence case. Built
	-- straight from WinOSI's own drv_sel formula quoted above:
	--     drv_sel-1 bit1 = (PB5==0), bit0 = (PA6==0)
	-- diskDrivePairSelect is already '1' for PB5 HIGH (the A/B pair) and
	-- diskDriveSelect is already '1' for PA6 LOW (the higher of the pair,
	-- i.e. B or D) - see DiskPia.vhd's own derivation of both signals. So:
	--     "00" (0) = A   (pair=1, sel=0)
	--     "01" (1) = B   (pair=1, sel=1)
	--     "10" (2) = C   (pair=0, sel=0)
	--     "11" (3) = D   (pair=0, sel=1)
	diskDriveSel2 <= "00" when diskDrivePairSelect = '1' and diskDriveSelect = '0' else
	                 "01" when diskDrivePairSelect = '1' and diskDriveSelect = '1' else
	                 "10" when diskDrivePairSelect = '0' and diskDriveSelect = '0' else
	                 "11";
	disk_drive_select <= diskDriveSel2;

	-- Drives-fitted gate (2026-08-01). A and B are unconditionally armed -
	-- see diskDriveArmed's declaration comment for why. C needs "3" or more
	-- fitted (diskDrivesFitted >= 1, since "00"=2/"01"=3/"10"or"11"=4), D
	-- needs "4" (diskDrivesFitted >= 2). Using >= rather than exact equality
	-- means the unused encoding "11" degrades safely to "4 drives" (the most
	-- permissive real setting) rather than to an undefined state.
	diskDrivesFitted <= to_integer(unsigned(disk_drives_fitted));
	diskDriveArmed <= '1' when diskDriveSel2 = "00" or diskDriveSel2 = "01" else
	                  '1' when diskDriveSel2 = "10" and diskDrivesFitted >= 1 else
	                  '1' when diskDriveSel2 = "11" and diskDrivesFitted >= 2 else
	                  '0';
	disk_drive_armed <= diskDriveArmed;

	-- Everything derived from head position checks the addressed drive's own
	-- counter, but ONLY if that drive is actually fitted - an unfitted C/D
	-- reports "no such drive" (track-0 sense high, matching WinOSI's Mask_A
	-- preset for an unconfigured unit) exactly as it did before C/D became
	-- real drives at all.
	diskTrack0Sense <= '1' when diskDriveArmed = '0'
	                   else '0' when (diskDriveSel2 = "00" and trackNumber = 0)
	                         or (diskDriveSel2 = "01" and trackNumber_b = 0)
	                         or (diskDriveSel2 = "10" and trackNumber_c = 0)
	                         or (diskDriveSel2 = "11" and trackNumber_d = 0)
	                   else '1';
	track_number    <= std_logic_vector(trackNumber);
	track_changed   <= trackChanged;
	track_number_b  <= std_logic_vector(trackNumber_b);
	track_changed_b <= trackChanged_b;
	track_number_c  <= std_logic_vector(trackNumber_c);
	track_changed_c <= trackChanged_c;
	track_number_d  <= std_logic_vector(trackNumber_d);
	track_changed_d <= trackChanged_d;
	-- write_protect IS muxed, because unlike the head position it genuinely
	-- differs per drive: each mounted image carries its own read-only flag.
	-- Un-inverted on all four arms for the reason given at the entity port.
	diskWriteProtect <= disk_write_ok   when diskDriveSel2 = "00" else
	                    disk_write_ok_b when diskDriveSel2 = "01" else
	                    disk_write_ok_c when diskDriveSel2 = "10" else
	                    disk_write_ok_d;
	-- Runtime last-track clamp: 76 for 8" (77 tracks), 39 for 5.25" (40).
	-- Follows the SELECTED drive, so each of the four drives clamps to its
	-- own mounted geometry independently.
	DISK_MAX_TRACK  <= to_unsigned(76,7)
	                     when (diskDriveSel2 = "00" and disk_is_8inch = '1')
	                       or (diskDriveSel2 = "01" and disk_is_8inch_b = '1')
	                       or (diskDriveSel2 = "10" and disk_is_8inch_c = '1')
	                       or (diskDriveSel2 = "11" and disk_is_8inch_d = '1')
	                   else to_unsigned(39,7);
	-- indexHole: a real drive's index hole is a brief, rare once-per-revolution
	-- pulse (WinOSI models it as ~1.4% duty - 32 index bytes out of a ~2336-byte
	-- revolution). Taking indexHoleCounter's raw MSB gave a 50%-duty square
	-- wave instead - asserted HALF the time, vastly more than real hardware -
	-- which made any disk-driver code that treats "index asserted mid-read" as
	-- an abort condition (not just a revolution-bound wait) far more likely to
	-- trip here than on real hardware. Same free-running counter, narrower
	-- assert window (~1.5% duty, same order of magnitude as WinOSI's model).
	--
	-- Under ROTATIONAL timing (2026-07-30) this counter is bypassed entirely
	-- in favour of the selected disk_reader's own rotation position, and that
	-- substitution is the whole reason the mode exists. The counter below is
	-- free-running with NO relationship to read_ptr, so software that waits
	-- for the index and then reads is told a position unrelated to the index
	-- it just saw. That is harmless while access-driven - a seek resets
	-- read_ptr to 0, so "the first byte after the index" IS image byte 0
	-- whatever phase the counter happens to be in - and it is fatal once the
	-- position actually rotates. Real hardware cannot have this bug: the
	-- index hole is a feature of the same spinning disk that carries the
	-- data, so one cannot drift against the other.
	--
	-- MEASURED, and it is why these two changes belong together: UCSD Pascal
	-- spin-polls Port A ~28,600 times before every read run, i.e. it syncs on
	-- the index hole for every transfer. Under access-driven timing it is
	-- therefore waiting on a signal that says nothing about where the data is.
	-- OS-65D is immune because it hunts $76 markers and re-syncs from any
	-- position; Pascal has no such recovery.
	--
	-- "Drive not fitted" (diskDriveArmed='0') wins over everything else,
	-- matching WinOSI leaving INDEX_D at its Mask_A preset (high, i.e. no
	-- index hole) for a drv_sel with no configured drive behind it. Restored
	-- 2026-08-01 alongside the drives-fitted OSD option - this is the exact
	-- override that made an unmounted C/D indistinguishable from "does not
	-- exist" before C/D became real drives at all.
	indexHole       <= '1' when diskDriveArmed = '0'
	                   else disk_index_hole_n when disk_rotational = '1'
	                   else '0' when indexHoleCounter < X"040000" else '1';

	process (clk)
	begin
		if rising_edge(clk) then
			indexHoleCounter <= indexHoleCounter + 1;

			stepPulse_s1 <= diskStepPulse;
			stepPulse_s2 <= stepPulse_s1;
			stepPulse_s3 <= stepPulse_s2;

			if disk_b_img_mounted = '1' then
				diskB_everMounted <= '1';
			end if;

			-- Head movement happens on the 1->0 edge of step_pulse (per
			-- DiskPia.vhd's own doc comment on Port B bit3). Direction
			-- polarity is now CONFIRMED against OS-65D's own seek primitives
			-- (disassembled from the boot track's $2683/$268a): the driver
			-- SETS bit2 (step_direction=1) to step OUT toward track 0, and
			-- CLEARS it (=0) to step IN toward higher track numbers - the
			-- opposite of this code's first draft, which hung the "D" boot the
			-- instant OS-65D tried to read any non-zero track (it searches the
			-- incoming stream for the $76 sector marker, which never appears
			-- on the boot track the stuck-at-0 head kept serving).
			--
			-- Mount takes priority over a same-cycle step edge (can't
			-- coincide in practice, but resolves the priority unambiguously):
			-- trackNumber has no reset other than FPGA configuration load, so
			-- without this a fresh mount would leave it holding whatever
			-- value was left over from an earlier disk/session, desyncing
			-- n_track0_sense from disk_reader.sv's own mount-forced track-0
			-- load (which already resets correctly via img_mounted).
			--
			-- Second drive (2026-07-27, corrected): the step edge IS gated on
			-- diskDriveSelect, and each drive keeps its OWN head position.
			-- Only the selected drive's head moves; the other stays exactly
			-- where it was left.
			--
			-- This reverses a shared-counter design that shipped earlier the
			-- same day, so the evidence is recorded here:
			--
			--  1. WinOSI, the reference emulator, models it this way - two
			--     independent positions (`int track_a=4, track_b=4;`) with
			--     the step edge applied only to the selected drive
			--     (6502.H:662-686, `if ((drv_sel==sel_A)...) track_a--/++`
			--     and the matching sel_B block). That is also what the real
			--     board must do: drive select gates the step line.
			--
			--  2. Hardware, on the shared-counter build: boot from A, read
			--     drive B's directory, then load COPIER from A -> ERR #C.
			--     Without the drive-B read, COPIER loads fine; and drive A
			--     recovers after a reset, with B's directory re-readable any
			--     number of times. Buffers intact, head position desynced -
			--     which is exactly a shared counter letting drive B's seeks
			--     drag drive A's head away from where OS-65D left it.
			--
			--  3. The argument originally used to justify sharing - OS-65D
			--     keeps ONE track variable (TKNUM = $265D), so a relative
			--     seek after a drive switch must assume the other drive's
			--     position - is simply wrong: OS-65D HOMES the drive when it
			--     switches to it. Confirmed in simulation under the corrected
			--     PA6 polarity: drive B, starting at track 0 with drive A at
			--     16, reached track 12 and rendered a correct directory. It
			--     could only get there from 0 by being homed first. Every
			--     earlier experiment had PA6 inverted, so drive B was selected
			--     from instr ~880k of the BOOT onward and no run ever
			--     performed a genuine mid-session A->B switch - which is why
			--     this went unobserved twice.
			--
			-- Each counter is reset by ITS OWN mount pulse only. Inserting a
			-- diskette must not move the other drives' heads.
			--
			-- FOUR-DRIVE SUPPORT (2026-08-01), and this is the one place the
			-- extension is NOT purely additive: the old gates here were
			-- `diskDriveSelect = '0'` (drive A) and `= '1'` (drive B), which
			-- was fine when diskDriveSelect's only other possible reading was
			-- "C/D, and diskDriveArmed='0' blocks it anyway". With C and D now
			-- real drives, diskDriveSelect='0' ALSO matches drive C and ='1'
			-- ALSO matches drive D - so those old single-bit gates would have
			-- let drive A's (and B's) head move on a step pulse actually aimed
			-- at C (or D). Every gate below now checks the FULL two-bit
			-- diskDriveSel2 instead, which is the fix this comment is about.
			if disk_img_mounted = '1' then
				trackNumber <= (others => '0');
			elsif stepPulse_s3 = '1' and stepPulse_s2 = '0'
			      and diskDriveSel2 = "00" then
				if diskStepDirection = '1' then
					-- step OUT toward track 0
					if trackNumber /= 0 then
						trackNumber <= trackNumber - 1;
						trackChanged <= not trackChanged;
					end if;
				else
					-- step IN toward higher track numbers
					if trackNumber /= DISK_MAX_TRACK then
						trackNumber <= trackNumber + 1;
						trackChanged <= not trackChanged;
					end if;
				end if;
			end if;

			if disk_b_img_mounted = '1' then
				trackNumber_b <= (others => '0');
			elsif stepPulse_s3 = '1' and stepPulse_s2 = '0'
			      and diskDriveSel2 = "01" then
				if diskStepDirection = '1' then
					if trackNumber_b /= 0 then
						trackNumber_b <= trackNumber_b - 1;
						trackChanged_b <= not trackChanged_b;
					end if;
				else
					if trackNumber_b /= DISK_MAX_TRACK then
						trackNumber_b <= trackNumber_b + 1;
						trackChanged_b <= not trackChanged_b;
					end if;
				end if;
			end if;

			-- Drives C and D (four-drive support, 2026-08-01): identical
			-- pattern, gated on the two remaining diskDriveSel2 values, PLUS
			-- diskDriveArmed (drives-fitted OSD option, 2026-08-01) - an
			-- unfitted C/D's head must not move on a step pulse, exactly as
			-- WinOSI gates its own stepping on drive existence (6502.H:
			-- 662/675). A and B need no such gate: they are unconditionally
			-- armed, so adding it there would be a tautology.
			if disk_c_img_mounted = '1' then
				trackNumber_c <= (others => '0');
			elsif stepPulse_s3 = '1' and stepPulse_s2 = '0'
			      and diskDriveSel2 = "10" and diskDriveArmed = '1' then
				if diskStepDirection = '1' then
					if trackNumber_c /= 0 then
						trackNumber_c <= trackNumber_c - 1;
						trackChanged_c <= not trackChanged_c;
					end if;
				else
					if trackNumber_c /= DISK_MAX_TRACK then
						trackNumber_c <= trackNumber_c + 1;
						trackChanged_c <= not trackChanged_c;
					end if;
				end if;
			end if;

			if disk_d_img_mounted = '1' then
				trackNumber_d <= (others => '0');
			elsif stepPulse_s3 = '1' and stepPulse_s2 = '0'
			      and diskDriveSel2 = "11" and diskDriveArmed = '1' then
				if diskStepDirection = '1' then
					if trackNumber_d /= 0 then
						trackNumber_d <= trackNumber_d - 1;
						trackChanged_d <= not trackChanged_d;
					end if;
				else
					if trackNumber_d /= DISK_MAX_TRACK then
						trackNumber_d <= trackNumber_d + 1;
						trackChanged_d <= not trackChanged_d;
					end if;
				end if;
			end if;
		end if;
	end process;

	u18: entity work.DiskAcia
	port map(
		n_wr => n_diskAciaCS or cpuClock or n_WR,
		n_rd => n_diskAciaCS or cpuClock or (not n_WR),
		regSel => cpuAddress(0),
		dataIn => cpuDataOut,
		dataOut => diskAciaData,
		track_byte => track_byte,
		track_byte_strobe => track_byte_strobe,
		n_write_enable => diskWriteEnable,
		tx_byte => diskTxByte,
		tx_strobe => diskTxStrobe,
		-- "or not armed" term RESTORED (drives-fitted OSD option,
		-- 2026-08-01): forces the WHOLE status byte to 0 (both RDRF and TDRE
		-- clear) whenever the addressed drive isn't fitted, regardless of
		-- whatever the underlying disk_reader instance's own rotation model
		-- says. This is what stops an unfitted C/D presenting as "a drive is
		-- here, spinning, ready" - without it, the CPU would see normal
		-- RDRF/TDRE pacing from a real but empty disk_reader instance, which
		-- is a materially different signal from "no such drive" to software
		-- that scans for drives by index-hole/status behaviour (UCSD Pascal
		-- does, ~28,600 Port A polls per read run).
		loading => (disk_loading or (not diskDriveArmed)),
		-- Already muxed to the SELECTED drive up in UK101.sv, the same way
		-- track_byte is - there is only one ACIA, so only one drive's status
		-- can be live in it. Both are '1' unless disk_rotational is set.
		rdrf => disk_rdrf,
		tdre => disk_tdre
	);

	u6 : entity work.UK101TextDisplay
	port map (
		charAddr => charAddr,
		charData => charData,
		dispAddr => dispAddrB,
		dispData => dispRamDataOutB,
		clk => video_clock,
		ce_pix => ce_pix,
		hsync_out => hsync,
		vsync_out => vsync,
		hblank_out => hblank,
		vblank_out => vblank,
		--colours => colours,
		resolution => resolution,
		machine_type => i_machine_type,
		--monitor_type => monitor_type,
		r => r,
		g => g,
		b => b
	);

	process (clk)
	begin
		if rising_edge(clk) then

			if cpuClkCount < i_clockThreshold1 then
				 cpuClkCount <= cpuClkCount + 1;
			else
				 cpuClkCount <= (others=>'0');
			end if;
			if cpuClkCount < i_clockThreshold2 then
				 cpuClock <= '0';
			else
				 cpuClock <= '1';
			end if;
     
							
			if serialClkCount < serialClkCount1 then
				serialClkCount <= serialClkCount + 1;
			else
				serialClkCount <= (others => '0');
			end if;

			if serialClkCount < serialClkCount2 then 
				serialClock <= '0';
			else
				serialClock <= '1';
			end if;	
		end if;
	end process;
	

	u7: entity work.CharRom
	port map
	(
		address => charAddr,
		q => charDataUK101
	);
	
	u13: entity work.CharRomOSI
	port map
	(
		address => charAddr,
		q => charDataOSI
	);

	u8: entity work.DisplayRam 
	port map
	(
		address_a => cpuAddress(10 downto 0),
		address_b => dispAddrB,
		clock	=> clk,
		data_a => cpuDataOut,
		data_b => (others => '0'),
		wren_a => not(n_memWR or n_dispRamCS),
		wren_b => '0',
		q_a => dispRamDataOutA,
		q_b => dispRamDataOutB
	);
	
	u9 : entity work.UK101keyboard
	port map(
		CLK => clk,
		nRESET => n_reset,
		PS2_CLK	=> ps2Clk,
		PS2_DATA	=> ps2Data,
		A	=> kbRowSel,
		KEYB	=> kbReadData,
		machine_type => i_machine_type
	);
	
	
	DisplayRegister	:	entity work.OutLatch
	port map (
		dataIn	=> cpuDataOut,
		clock		=> clk,
		load		=> n_iocs,
		clear		=> n_reset,
		latchOut	=> latchedbits
	);
	
	process (n_kbCS,n_memWR)
	begin
		if	n_kbCS='0' and n_memWR = '0' then
			kbRowSel <= cpuDataOut;
		end if;
	end process;
	
end;
