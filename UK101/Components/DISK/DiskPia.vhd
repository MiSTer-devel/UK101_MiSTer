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
begin

	-- bit7=index_hole, bit6=n/a(output-only), bit5=write_protect,
	-- bit4=drive1_not_ready, bit3/2=n/a, bit1=track0 sense, bit0=drive0_not_ready
	-- n_track0_sense is already active-low ('0' = at track 0), and the real
	-- ROM's boot code confirms bit1 itself reads 0 at track 0 ("LDA #$02;
	-- BIT $c000; BEQ ..." branches when bit1=0) - so this bit is a direct
	-- passthrough, NOT inverted (an earlier draft of this file had that
	-- backwards).
	pa_in <= index_hole & '0' & write_protect & drive1_not_ready & '0' & '0' & n_track0_sense & drive0_not_ready;

	drive_select      <= ora(6);
	write_enable      <= orb(0);
	erase_enable      <= orb(1);
	step_direction    <= orb(2);
	step_pulse        <= orb(3);
	drive_pair_select <= orb(5);
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

	process(n_wr)
	begin
		if rising_edge(n_wr) then -- Standard CPU - capture data on trailing edge of wr
			case regSel is
				when "00" =>
					if cra(2) = '1' then
						ora <= dataIn;
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
