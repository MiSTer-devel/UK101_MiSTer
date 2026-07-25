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

		-- Phase 2 Step 3: current head position, driven by DiskPia's own
		-- stepper outputs (see the track-counter process below) and consumed
		-- by disk_reader.sv (see UK101.sv) to re-load the newly seeked-to
		-- track. track_changed toggles once per confirmed step.
		track_number  : out std_logic_vector(6 downto 0);
		track_changed : out std_logic;

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
		disk_is_8inch : in std_logic
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
	signal i_memory_size : integer range 0 to 3 := 0;
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
	n_basRomCS <= '0' when cpuAddress(15 downto 13) = "101" else '1'; --8k
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
	n_ramCS <= not(n_dispRamCS and n_basRomCS and n_monitorRomCS and n_aciaCS and n_kbCS and n_diskPiaCS and n_diskAciaCS) when i_memory_size = 3 else  --41K
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
	-- that same counter instead of `open`. drive_select/write_enable/
	-- erase_enable/drive_pair_select/head_load remain unused - a single
	-- read-only virtual drive is assumed for now.
	u17: entity work.DiskPia
	port map(
		n_wr => n_diskPiaCS or cpuClock or n_WR,
		n_rd => n_diskPiaCS or cpuClock or (not n_WR),
		regSel => cpuAddress(1 downto 0),
		dataIn => cpuDataOut,
		dataOut => diskPiaData,
		drive0_not_ready => '0',
		drive1_not_ready => '1',
		n_track0_sense => diskTrack0Sense,
		write_protect => '0',
		index_hole => indexHole,
		drive_select => open,
		write_enable => open,
		erase_enable => open,
		step_direction => diskStepDirection,
		step_pulse => diskStepPulse,
		drive_pair_select => open,
		head_load => open
	);

	-- Phase 2 Step 3: track-stepper counter. Head position is tracked purely
	-- in this FPGA-side model (the real hardware has no register for it -
	-- only a track0 sense bit) and fed back into DiskPia's n_track0_sense
	-- input, plus exported as track_number/track_changed for disk_reader.sv
	-- to re-load the newly-seeked-to track (see UK101.sv).
	diskTrack0Sense <= '0' when trackNumber = 0 else '1';
	track_number    <= std_logic_vector(trackNumber);
	track_changed   <= trackChanged;
	-- Runtime last-track clamp: 76 for 8" (77 tracks), 39 for 5.25" (40).
	DISK_MAX_TRACK  <= to_unsigned(76,7) when disk_is_8inch = '1'
	                   else to_unsigned(39,7);
	-- indexHole: a real drive's index hole is a brief, rare once-per-revolution
	-- pulse (WinOSI models it as ~1.4% duty - 32 index bytes out of a ~2336-byte
	-- revolution). Taking indexHoleCounter's raw MSB gave a 50%-duty square
	-- wave instead - asserted HALF the time, vastly more than real hardware -
	-- which made any disk-driver code that treats "index asserted mid-read" as
	-- an abort condition (not just a revolution-bound wait) far more likely to
	-- trip here than on real hardware. Same free-running counter, narrower
	-- assert window (~1.5% duty, same order of magnitude as WinOSI's model).
	indexHole       <= '0' when indexHoleCounter < X"040000" else '1';

	process (clk)
	begin
		if rising_edge(clk) then
			indexHoleCounter <= indexHoleCounter + 1;

			stepPulse_s1 <= diskStepPulse;
			stepPulse_s2 <= stepPulse_s1;
			stepPulse_s3 <= stepPulse_s2;

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
			if disk_img_mounted = '1' then
				trackNumber <= (others => '0');
			elsif stepPulse_s3 = '1' and stepPulse_s2 = '0' then
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
		track_byte_strobe => track_byte_strobe
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
