-- Register-level implementation of the OSI disk ACIA (6850) at $C010-$C011.
--
-- Address confirmed against six independent sources - see DiskPia.vhd and
-- SAVE_AND_DISK_PLAN.md (Phase 2) for the details. This core's own
-- CegmonRomC1P ROM initialises this exact register with the standard 6850
-- reset-then-configure sequence (STA #$03 / STA #$58 to $c010) before
-- reading track data byte-by-byte via status-poll-then-read, exactly like
-- the existing cassette ACIA in bufferedUART.vhd.
--
-- Step 2 of Phase 2 (disk emulation): the data register now serves real
-- bytes from a mounted .65D SD image, via disk_reader.sv (a small track
-- buffer living in the clk_sys domain, fed over the SD-image read protocol).
-- track_byte is the byte currently pointed at by disk_reader's read pointer;
-- track_byte_strobe TOGGLES (not a pulse) each time this register is read,
-- telling disk_reader to advance to the next byte. This mirrors the
-- save_data/save_strobe CDC pattern already proven working in Phase 1
-- (bufferedUART.vhd -> save_writer.sv) - a toggle survives crossing into the
-- much-faster clk_sys domain safely, since the CPU is many clk_sys cycles
-- slower even at its fastest overclock setting.
--
-- The status register still always reports "byte ready" (bit0/RDRF set) -
-- the "instant, always-ready" trick already used for cassette LOAD. Whether
-- OS-65D's own driver tolerates this (vs. needing WinOSI-style realistic
-- rotational timing) is the open empirical question flagged in
-- SAVE_AND_DISK_PLAN.md, to be tested once a real boot is attempted (Step 3).

library ieee;
	use ieee.std_logic_1164.all;
	use ieee.numeric_std.all;
	use ieee.std_logic_unsigned.all;

entity DiskAcia is
	port (
		n_wr    : in  std_logic;
		n_rd    : in  std_logic;
		regSel  : in  std_logic;
		dataIn  : in  std_logic_vector(7 downto 0);
		dataOut : out std_logic_vector(7 downto 0);

		track_byte        : in  std_logic_vector(7 downto 0);
		track_byte_strobe : out std_logic
	);
end DiskAcia;

architecture rtl of DiskAcia is
	signal controlReg : std_logic_vector(7 downto 0) := (others => '0');
	signal txReg       : std_logic_vector(7 downto 0) := (others => '0');
	signal i_track_byte_strobe : std_logic := '0';
begin

	track_byte_strobe <= i_track_byte_strobe;

	process(n_rd)
	begin
		if falling_edge(n_rd) then -- Standard CPU - present data on leading edge of rd
			if regSel = '1' then
				dataOut <= track_byte;
				i_track_byte_strobe <= not i_track_byte_strobe;
			else
				dataOut <= "00000001"; -- status stub: RDRF always set ("byte ready")
			end if;
		end if;
	end process;

	process(n_wr)
	begin
		if rising_edge(n_wr) then -- Standard CPU - capture data on trailing edge of wr
			if regSel = '1' then
				txReg <= dataIn;
			else
				controlReg <= dataIn;
			end if;
		end if;
	end process;

end rtl;
