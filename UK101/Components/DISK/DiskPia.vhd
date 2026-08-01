-- Minimal 6821 PIA emulation for the OSI floppy disk controller.
--
-- Register map ($C000-$C003) confirmed against six independent sources
-- (osiemu source, WinOSI source/binary, HEXDOS manual, and this core's own
-- CegmonRomC1P boot code and OS-65D's own boot code disassembled from a real
-- .65D image) - see SAVE_AND_DISK_PLAN.md, Phase 2 section, for the details.
--
--   $C000 Port A / DDRA (muxed on CRA bit2): bit0 drive0-not-ready (in),
--         bit1 track0-sense (in, active low - confirmed by disassembling
--         this core's own ROM: "LDA #$02; BIT $c000; BEQ ..." branches when
--         bit1 reads 0), bit4 drive1-not-ready (in), bit5 write-protect (in),
--         bit6 drive0/1-select (out), bit7 index-hole (in)
--   $C001 Control Register A
--   $C002 Port B / DDRB (muxed on CRB bit2): bit0 write-enable,
--         bit1 erase-enable, bit2 step-direction, bit3 step-pulse
--         (1->0 edge moves the head), bit5 drive-pair-select, bit7 head-load
--   $C003 Control Register B
--
-- Step 1 of Phase 2 (disk emulation): this module only implements the real
-- 6821 DDR/data-register semantics so it's testable via BASIC PEEK/POKE.
-- Nothing here is yet wired to a real disk mechanism or SD image - the
-- external status inputs are tied to stub constants in uk101.vhd until
-- Step 2 (SD-image mount + track read).

library ieee;
	use ieee.std_logic_1164.all;
	use ieee.numeric_std.all;
	use ieee.std_logic_unsigned.all;

entity DiskPia is
	port (
		-- A real 6821's RES pin clears every register. Without it, ALL port
		-- state survives a CPU reset - and drive_select lives here, so a
		-- program that left drive B selected (UCSD Pascal does) would have the
		-- next reset re-run the boot ROM against the WRONG DRIVE. Observed on
		-- hardware 2026-07-28: after running Pascal and swapping back to
		-- OS-65D disks, the first reset booted and then hung; only reloading
		-- the core - which reinitialises signals at FPGA configuration -
		-- restored it. Safe because the boot ROM reinitialises the PIA anyway
		-- (CRA=$00, DDRA=$00, CRA=$04 within its first five instructions).
		n_reset : in  std_logic;
		n_wr    : in  std_logic;
		n_rd    : in  std_logic;
		regSel  : in  std_logic_vector(1 downto 0);
		dataIn  : in  std_logic_vector(7 downto 0);
		dataOut : out std_logic_vector(7 downto 0);

		-- Port A inputs (disk status)
		drive0_not_ready : in std_logic;
		drive1_not_ready : in std_logic;
		n_track0_sense   : in std_logic; -- active low: '0' = head at track 0
		write_protect    : in std_logic;
		index_hole       : in std_logic;

		-- Port A output
		drive_select      : out std_logic;

		-- Port B outputs
		write_enable      : out std_logic;
		erase_enable      : out std_logic;
		step_direction    : out std_logic;
		step_pulse        : out std_logic;
		drive_pair_select : out std_logic;
		head_load         : out std_logic
	);
end DiskPia;

architecture rtl of DiskPia is
	signal ddra, ora, cra : std_logic_vector(7 downto 0) := (others => '0');
	signal ddrb, orb, crb : std_logic_vector(7 downto 0) := (others => '0');
	signal pa_in : std_logic_vector(7 downto 0);
	-- Drive select is LATCHED on ORA writes, not decoded combinationally -
	-- see the drive_select assignment below. Powers up as drive A.
	signal driveSelReg : std_logic := '0';
begin

	-- bit7=index_hole, bit6=n/a(output-only), bit5=write_protect,
	-- bit4=drive1_not_ready, bit3/2=n/a, bit1=track0 sense, bit0=drive0_not_ready
	-- n_track0_sense is already active-low ('0' = at track 0), and the real
	-- ROM's boot code confirms bit1 itself reads 0 at track 0 ("LDA #$02;
	-- BIT $c000; BEQ ..." branches when bit1=0) - so this bit is a direct
	-- passthrough, NOT inverted (an earlier draft of this file had that
	-- backwards).
	-- Bits 2, 3 and 6 corrected 2026-07-31 to match the reference exactly.
	-- WinOSI presets EVERY Port A read to Mask_A = $EE (6502.H:37, applied at
	-- 6502.H:340) and then only ever clears INDEX_D (bit7), TRACK0 (bit1) and
	-- DRVSEL_L (bit6) from it. So the bits it reports are:
	--
	--   bit0 = 0 always          bit4 = 0 always
	--   bit1 = track-0 sense     bit5 = 1 always (it models no write protect)
	--   bit2 = 1 always          bit6 = the PA6 drive-select state
	--   bit3 = 1 always          bit7 = index hole
	--
	-- We were returning bits 2 and 3 as '0'. MEASURED: UCSD Pascal performs
	-- 1,664,436 Port A reads during boot alone, so that was wrong on every one
	-- of them. It is also unphysical - PA2/PA3 are UNCONNECTED on the real
	-- board, and an unconnected 6821 input floats HIGH. That is what makes this
	-- safe for OS-65D despite being untested there: OS-65D ran on real hardware
	-- where these bits read 1, so it cannot be relying on 0.
	--
	-- bit6 now returns ora(6) unconditionally rather than '0' when DDRA bit6 is
	-- configured as an input. WinOSI derives it from portadat with no DDRA term
	-- (6502.H:393), and Pascal reads Port A 2,790 times while DDRA bit6 is still
	-- an input (first at instr 12027) - during which we were reporting "drive B
	-- selected" no matter what the CPU had actually selected. Same reasoning as
	-- the DDRA gate already dropped from drive_select below.
	--
	-- bit4 is DELIBERATELY still drive1_not_ready rather than WinOSI's constant
	-- '0': WinOSI models no drive-ready line at all, whereas ours produces the
	-- clean ERR #6 "drive not ready" for an empty drive B that was confirmed on
	-- hardware 2026-07-27. With a disk in drive B the two agree anyway. Revisit
	-- only if something is shown to need it.
	pa_in <= index_hole & ora(6) & write_protect & drive1_not_ready & '1' & '1' & n_track0_sense & drive0_not_ready;

	-- PA6 is the drive select, and it is ACTIVE LOW: driving it to 0 selects
	-- drive B, driving it to 1 (or leaving it undriven) selects drive A.
	-- Straight from WinOSI's own PIA write handler (6502.H:637-641, the
	-- reference emulator for this machine):
	--     #define DRVSEL_L 64                              // = PA6
	--     drv_sel=0x00;
	--     if ((portbdat&DRVSEL_H)==0) drv_sel^=0x02;       // PB5
	--     if ((writevalue&DRVSEL_L)==0) drv_sel^=0x01;     // PA6  Boot Drw=1
	--     drv_sel++;                                       // make it S1..S4
	-- with sel_A=1, sel_B=2 (Fileio.h:509-510). So PA6=1 -> drv_sel 1 = A,
	-- PA6=0 -> drv_sel 2 = B.
	--
	-- An earlier draft of this line had it as `ora(6) and ddra(6)` - i.e.
	-- bit6=1 meaning drive B - which is exactly backwards, and broke
	-- SINGLE-DRIVE operation outright (ERR #9 straight out of BASIC). The
	-- reason is that OS-65D routinely drives PA6 HIGH to select drive A as
	-- part of an ordinary boot, with no user action and no second drive
	-- involved. Its own bus trace, from a plain boot of a 5.25" OS-65D 3.3
	-- disk with no keystrokes at all (c4pmf_sim/ds_probe.py):
	--     879989  $C001 <= $00   CRA bit2=0 -> $C000 accesses DDRA
	--     879991  $C000 <= $40   DDRA bit6 = OUTPUT
	--     879992  $C001 <= $04   CRA bit2=1 -> $C000 accesses ORA
	--     880001  $C000 <= $40   ORA  bit6 = 1  -> select drive A
	-- Under the inverted polarity that deselected drive A for the rest of the
	-- session, freezing its read pointer and switching the ACIA byte mux to
	-- the (usually empty) drive B - hence a boot that reaches the A* prompt
	-- (track 0 is read before instruction 880001) and then fails every read
	-- after it. The earlier draft misread this very trace as COPIER answering
	-- "copy from which drive? B"; it is in fact ~2M instructions before any
	-- key is typed.
	--
	-- LATCHED ON ORA WRITES, not decoded combinationally from ora/ddra.
	--
	-- This mirrors WinOSI exactly. Its handler recomputes drv_sel ONLY when
	-- the CPU writes Port A, using the value being written, and returns early
	-- (no drv_sel update) when CRA bit2 selects DDRA instead. There is no
	-- DDRA term anywhere in its decode.
	--
	-- A previous draft here read `(not ora(6)) and ddra(6)`, adding a DDRA
	-- gate by analogy with write_enable's ddrb(0) gate below. That gate is
	-- WRONG for drive select, and UCSD Pascal is what exposed it: Pascal
	-- drives PA6 low to select drive B TWICE before it ever configures DDRA
	-- (instr 390808 and 555160 in c4pmf_sim/pascal_probe.py), so we ignored
	-- both and stayed on drive A while WinOSI switched to B.
	--
	-- Note the fix is NOT simply to drop the gate. ora powers up as $00, so
	-- a bare `not ora(6)` would select drive B from reset and OS-65D's whole
	-- boot would read the wrong drive - the same class of bug as the inverted
	-- polarity described above. WinOSI avoids it by starting drv_sel at "no
	-- drive" and only ever changing it on a write. A register reset to drive
	-- A reproduces that: OS-65D's first ORA write is $40 (drive A) at instr
	-- 880001, so its boot is unaffected, while Pascal's earlier $00 writes
	-- now register as drive B.
	drive_select      <= driveSelReg;
	-- Gated on ddrb(0) (Phase B, 2026-07-26): orb resets to all-zeros at
	-- power-up, and bit0=0 means "writing" (active low, confirmed against
	-- OS-65D's own disassembled write primitive - see SAVE_AND_DISK_PLAN.md).
	-- Without this gate, write_enable would read as "write window active"
	-- from power-on until OS-65D's own driver first configures and writes
	-- Port B - a real hardware pin only reflects the OR register once its
	-- direction bit selects output, so this models that: while ddrb(0)='0'
	-- (bit0 still configured as input), force the idle value ('1', not
	-- writing) regardless of orb(0)'s uninitialised-looking reset value.
	write_enable      <= orb(0) or (not ddrb(0));
	erase_enable      <= orb(1);
	step_direction    <= orb(2);
	step_pulse        <= orb(3);
	-- PB5, the HIGH bit of the two-bit drive select (see uk101.vhd's
	-- diskDriveArmed). DDRB-gated exactly like write_enable above, and for the
	-- same reason: orb resets to all-zeros, and uk101.vhd treats PB5 LOW as
	-- "drive C/D selected, nothing responds". Ungated, that would leave BOTH
	-- drives inert from power-on and after every CPU reset until software
	-- happened to write Port B with bit5 set - which would be a new and
	-- spectacular way to break every disk that works today. While bit5 is still
	-- configured as an input, force the idle value ('1' = drive A/B), matching a
	-- real pin that only reflects the output register once its direction bit
	-- selects output.
	--
	-- The measured traces show both DOSes write DDRB=$FF at instr 8 and ORB with
	-- bit5 set within a couple of instructions, long before any disk access, so
	-- this gate is belt-and-braces for THOSE two - but HEXDOS and PICO-DOS have
	-- never been traced here, and they are the reason it is not left ungated.
	drive_pair_select <= orb(5) or (not ddrb(5));
	head_load         <= orb(7);

	process(n_rd)
	begin
		if falling_edge(n_rd) then -- Standard CPU - present data on leading edge of rd
			case regSel is
				when "00" =>
					for i in 0 to 7 loop
						if ddra(i) = '1' then
							dataOut(i) <= ora(i);
						else
							dataOut(i) <= pa_in(i);
						end if;
					end loop;
				when "01" =>
					dataOut <= cra;
				when "10" =>
					for i in 0 to 7 loop
						if ddrb(i) = '1' then
							dataOut(i) <= orb(i);
						else
							dataOut(i) <= '0';
						end if;
					end loop;
				when others =>
					dataOut <= crb;
			end case;
		end if;
	end process;

	process(n_wr, n_reset)
	begin
		-- 6821 RES: clears all six registers. driveSelReg goes with them, so a
		-- reset always returns to drive A - see the n_reset port comment.
		if n_reset = '0' then
			ora  <= (others => '0');
			ddra <= (others => '0');
			cra  <= (others => '0');
			orb  <= (others => '0');
			ddrb <= (others => '0');
			crb  <= (others => '0');
			driveSelReg <= '0';
		elsif rising_edge(n_wr) then -- Standard CPU - capture data on trailing edge of wr
			case regSel is
				when "00" =>
					if cra(2) = '1' then
						ora <= dataIn;
						-- Drive select follows the value being WRITTEN, and
						-- only on an ORA write - see drive_select above. A
						-- DDRA write (the else branch) must not disturb it,
						-- matching WinOSI's early return.
						driveSelReg <= not dataIn(6);
					else
						ddra <= dataIn;
					end if;
				when "01" =>
					cra <= dataIn;
				when "10" =>
					if crb(2) = '1' then
						orb <= dataIn;
					else
						ddrb <= dataIn;
					end if;
				when others =>
					crb <= dataIn;
			end case;
		end if;
	end process;

end rtl;
