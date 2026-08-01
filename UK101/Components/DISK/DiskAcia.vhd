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
-- The status register reports RDRF (bit0, "byte ready") and, as of Phase B
-- below, TDRE (bit1, "ready to accept a byte"). Both are set whenever the
-- track buffer is valid - the same "instant, always-ready" trick already used
-- for cassette LOAD - and both are held CLEAR while disk_reader is refilling
-- that buffer from SD (the `loading` input, added 2026-07-31). See the status
-- read below for why reporting them set during a load was a real fault on both
-- the read and the write side.
--
-- Phase B (write support, 2026-07-26): writes to $C011 are latched into
-- tx_byte and tx_strobe toggles (same CDC-safe toggle idiom as
-- track_byte_strobe) whenever n_write_enable is asserted, for disk_reader.sv
-- to capture. Writes outside a write window are discarded - matching
-- OS-65D's own DKWTX write primitive, which (per a real disassembly, see
-- SAVE_AND_DISK_PLAN.md) only ever writes to $C011 inside its own tightly
-- bracketed write-enable-assert/deassert window, never outside it.
--
-- One deliberate simplification versus WinOSI: WinOSI also suppresses RDRF
-- during a write window, as a defensive measure for other DOS variants that
-- do a dummy read mid-write. OS-65D's own disassembled write primitive never
-- reads $C011 while write-enable is asserted, so that suppression has no
-- correctness benefit here and is skipped - it would only add a hang risk
-- (a driver polling RDRF during a write window that never sets it) for zero
-- gain. The read path (RDRF) is therefore completely unchanged by Phase B.

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
		track_byte_strobe : out std_logic;

		-- Phase B: write side. n_write_enable comes from DiskPia (Port B
		-- bit0, active low - confirmed both from WinOSI's model and
		-- independently from OS-65D's own disassembled write primitive).
		n_write_enable : in  std_logic;
		tx_byte        : out std_logic_vector(7 downto 0);
		tx_strobe      : out std_logic;

		-- High while disk_reader is refilling its track buffer from SD (the
		-- SELECTED drive's - see the mux in UK101.sv), OR while the two-bit
		-- drive select names drive C/D, which this core does not implement.
		-- Defaults to '0' so an instantiation that does not connect it keeps
		-- the old always-ready behaviour.
		loading        : in  std_logic := '0';

		-- Rotational timing (2026-07-30). Both are driven '1' by disk_reader
		-- whenever the OSD "Disk timing" toggle is Access-driven, so the
		-- status byte then reads $03 exactly as the hardcoded stub always
		-- did - the access-driven path is bit-identical, not merely
		-- equivalent. Under rotational timing they are paced by the head
		-- position instead. See disk_reader.sv's rotational port comment.
		--
		-- `loading` takes precedence over both: no byte can be served or
		-- accepted out of a buffer that is being refilled, whichever timing
		-- model is selected.
		rdrf           : in  std_logic := '1';
		tdre           : in  std_logic := '1'
	);
end DiskAcia;

architecture rtl of DiskAcia is
	signal controlReg : std_logic_vector(7 downto 0) := (others => '0');
	signal txReg       : std_logic_vector(7 downto 0) := (others => '0');
	signal i_track_byte_strobe : std_logic := '0';
	signal i_tx_strobe : std_logic := '0';
begin

	track_byte_strobe <= i_track_byte_strobe;
	tx_strobe <= i_tx_strobe;
	tx_byte   <= txReg;

	process(n_rd)
	begin
		if falling_edge(n_rd) then -- Standard CPU - present data on leading edge of rd
			if regSel = '1' then
				dataOut <= track_byte;
				i_track_byte_strobe <= not i_track_byte_strobe;
			elsif loading = '1' then
				-- A track load is in flight: disk_reader's buffer is being
				-- overwritten wholesale, so there is genuinely no byte to read
				-- and no byte can be accepted. Report BOTH clear and let the
				-- CPU's own status-poll loop wait, exactly as it would for a
				-- real drive that has not reached the next byte yet.
				--
				-- Reporting them SET here (what this did until now) was wrong in
				-- both directions: a read got a byte out of a buffer mid-rewrite
				-- and advanced disk_reader's read_ptr past it, and a write was
				-- told it had been accepted when disk_reader's tx_accept had
				-- already refused it for the same !loading reason. Whether
				-- either happened depended on a race between the DOS's post-seek
				-- code and how long hps_io took, which is why the faults were
				-- intermittent.
				dataOut <= "00000000";
			else
				-- RDRF (bit0) + TDRE (bit1). Reads "00000011" as before while
				-- the OSD selects access-driven timing (disk_reader ties both
				-- high); paced by head position under rotational timing.
				dataOut <= "000000" & tdre & rdrf;
			end if;
		end if;
	end process;

	process(n_wr)
	begin
		if rising_edge(n_wr) then -- Standard CPU - capture data on trailing edge of wr
			if regSel = '1' then
				txReg <= dataIn;
				if n_write_enable = '0' then
					i_tx_strobe <= not i_tx_strobe;
				end if;
			else
				controlReg <= dataIn;
			end if;
		end if;
	end process;

end rtl;
