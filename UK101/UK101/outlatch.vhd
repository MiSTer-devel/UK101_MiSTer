-- OutLatch.vhd
-- Implement an n-bit output latch
-- Taken from https://github.com/douggilliland/MultiComp/blob/master/MultiComp%20(VHDL%20Template)/Components/IO/OutLatch.vhd
	
library ieee ;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

---------------------------------------------------

entity OutLatch is
	port(	
		dataIn	:	in std_logic_vector(7 downto 0);
		clock		:	in std_logic;
		load		:	in std_logic;
		clear		:	in std_logic;
		latchOut	:	out std_logic_vector(7 downto 0)
	);
end OutLatch;

----------------------------------------------------

architecture behv of OutLatch is

    signal Q_tmp: std_logic_vector(7 downto 0);

begin
	process(clock, load, clear)
	begin
		if clear = '0' then
			Q_tmp <= X"01";
		elsif rising_edge(clock) then
			if load = '0' then
				Q_tmp <= dataIn;
			end if;
		end if;
	end process;

	-- concurrent statement
	latchOut <= Q_tmp;

end behv;