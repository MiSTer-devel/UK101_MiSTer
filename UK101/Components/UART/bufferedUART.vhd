-- 6850 ACIA COMPATIBLE UART WITH HARDWARE INPUT BUFFER AND HANDSHAKE
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

entity bufferedUART is
	port (
		clk		:	in std_logic;
		n_wr    : in  std_logic;
		n_rd    : in  std_logic;
		regSel  : in  std_logic;
		dataIn  : in  std_logic_vector(7 downto 0);
		dataOut : out std_logic_vector(7 downto 0);
		n_int   : out std_logic; 
		rxClock : in  std_logic; -- 16 x baud rate
		txClock : in  std_logic; -- 16 x baud rate
		rxd     : in  std_logic;
		txd     : out std_logic;
		n_rts   : out std_logic :='0';
		n_cts   : in  std_logic; 
		n_dcd   : in  std_logic;
		ioctl_download : in std_logic;
		ioctl_wr : in std_logic;
		ioctl_data : in std_logic_vector(7 downto 0);
      ioctl_addr :  in std_logic_vector(15 downto 0);
		loadFrom : in std_logic

   );
end bufferedUART;

architecture rtl of bufferedUART is
	
	type byteArray is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal ascii_data : byteArray;
	signal ascii : std_logic_vector(7 downto 0);
   signal in_dl : std_logic;
	signal ascii_rdy : std_logic;
	signal w_data_ready : std_logic;
	signal i_outCounter  : integer range 0 to 65535 := 0;
	signal i_ascii_last_byte : integer range 0 to 65535 := 0;
	signal i_ioctl_addr : integer range 0 to 65535 := 0;
	signal prev_clk : std_logic;
	signal statusReg : std_logic_vector(7 downto 0) := (others => '0'); 
	signal n_int_internal   : std_logic := '1';
	signal controlReg : std_logic_vector(7 downto 0) := "00000000";
	 
	signal rxBitCount: std_logic_vector(3 DOWNTO 0); 
	signal txBitCount: std_logic_vector(3 DOWNTO 0); 

	signal rxClockCount: std_logic_vector(5 DOWNTO 0); 
	signal txClockCount: std_logic_vector(5 DOWNTO 0); 

	signal rxCurrentByteBuffer: std_logic_vector(7 DOWNTO 0); 
	signal txBuffer: std_logic_vector(7 DOWNTO 0); 

	signal txByteLatch: std_logic_vector(7 DOWNTO 0); 

	-- Use bit toggling to determine change of state
	-- If byte sent over serial, change "txByteSent" flag from 0-->1, or from 1-->0
	-- If byte written to tx buffer, change "txByteWritten" flag from 0-->1, or from 1-->0
	-- So, if "txByteSent" = "txByteWritten" then no new data to be sent
	-- otherwise (if "txByteSent" /= "txByteWritten") then new data available ready to be sent
	signal txByteWritten : std_logic := '0';
	signal txByteSent : std_logic := '0';

	type serialStateType is ( idle, dataBit, stopBit );
	signal rxState : serialStateType;
	signal txState : serialStateType;

	signal reset : std_logic := '0';

	type rxBuffArray is array (0 to 31) of std_logic_vector(7 downto 0);
	signal rxBuffer : rxBuffArray;

	signal rxInPointer: integer range 0 to 63 :=0;
	signal rxReadPointer: integer range 0 to 63 :=0;
	signal rxBuffCount: integer range 0 to 63 :=0;
	signal fileOut: std_logic_vector (7 downto 0);
	signal uartOut: std_logic_vector (7 downto 0);
	
begin

		i_ioctl_addr <= to_integer(unsigned(ioctl_addr));
		dataOut <= fileOut when loadFrom = '0' else uartOut;
		statusReg(0) <= '0' when loadFrom = '0' and i_ioctl_addr = i_outCounter
							else '0' when loadFrom = '1' and rxInPointer=rxReadPointer else '1';
		statusReg(1) <=  '1' when loadFrom = '0' else
						     '1' when loadFrom = '1' and txByteWritten=txByteSent else '0';
		statusReg(2) <= n_dcd;
		statusReg(3) <= n_cts;
		statusReg(7) <= not(n_int_internal);
		  
		-- interrupt mask
		n_int <= n_int_internal;
		n_int_internal <= '0' when loadFrom = '0' and (i_ioctl_addr /= i_outCounter) and in_dl ='1'
				else '0' when loadFrom = '1' and (rxInPointer /= rxReadPointer) and controlReg(7)='1'
	         else '0' when loadFrom = '1' and (txByteWritten=txByteSent) and controlReg(6)='0' and controlReg(5)='1'
				else '1';
	
	    w_data_ready <= (in_dl and (not ioctl_download)) when loadFrom = '0' else '1';
		 
		 -- raise (inhibit) n_rts when buffer over half-full
		--	6850 implementatit = n_rts <= '1' when controlReg(6)='1' and controlReg(5)='0' else '0';

			rxBuffCount <= 0 + rxInPointer - rxReadPointer when loadFrom = '1' and rxInPointer >= rxReadPointer
				else 32 + rxInPointer - rxReadPointer;
			n_rts <= '1' when loadFrom = '1' and rxBuffCount > 24 else '0';
		
	o1: process (clk)
	
	begin
	if loadFrom = '0' then
		if rising_edge (clk) then
					
					if prev_clk = '1' and n_rd = '0' then
							if ascii_rdy = '0' and w_data_ready = '1' and i_outCounter <= i_ascii_last_byte then
										ascii <= ascii_data(i_outCounter)(7 downto 0);
										i_outCounter <= i_outCounter+1;
										ascii_rdy <= '1';
							end if;
					 end if;
			
					if ioctl_download = '1' then
						ascii_data(i_ioctl_addr) <= ioctl_data;
						i_ascii_last_byte <= i_ioctl_addr;
						i_outCounter <= 0;
						in_dl <= '1';
					else
						if in_dl = '1' and i_outCounter = i_ioctl_addr then
							in_dl<= '0';
						end if;
					end if;
	
		
					if n_rd = '0' and in_dl = '1' then	
						if regSel = '1' then
					
									fileOut <= ascii(7 downto 0);

									ascii_rdy <= '0';
						else
									fileout<= statusReg;
						end if;
					end if;
				prev_clk <= n_rd;
		end if;
		
	end if;
	end process;
	
	
		-- write of xxxxxx11 to control reg will reset
	reset <= '1' when n_wr = '0' and dataIn(1 downto 0) = "11" and regSel = '0' else '0';
  
	process( n_rd )
	begin
	if loadFrom = '1' then
		if falling_edge(n_rd) then -- Standard CPU - present data on leading edge of rd
			if regSel='1' then
				uartOut <= rxBuffer(rxReadPointer);
				if rxInPointer /= rxReadPointer then
					if rxReadPointer < 31 then
						rxReadPointer <= rxReadPointer+1;
					else
						rxReadPointer <= 0;
					end if;
				end if;
			else
				uartOut <= statusReg;
			end if;
		end if;
		end if;
	end process;

	process( n_wr )
	begin
	if loadFrom = '1' then
		if rising_edge(n_wr) then -- Standard CPU - capture data on trailing edge of wr
			if regSel='1' then
				if txByteWritten=txByteSent then
					txByteWritten <= not txByteWritten;
				end if;
				txByteLatch <= dataIn;
			else
				controlReg <= dataIn;
			end if;
		end if;
		end if;
	end process;

	process( rxClock , reset )
	begin
	if loadFrom = '1' then
		if reset='1' then
			rxState <= idle;
			rxBitCount<="0000";
			rxClockCount<="000000";
		 
		elsif falling_edge(rxClock) then
			case rxState is
			when idle =>
				if rxd='1' then -- high so idle
					rxBitCount<="0000";
					rxClockCount<="000000";
				else -- low so in start bit
					if rxClockCount= 7 then -- wait to half way through bit
						rxClockCount<="000000";
						rxState <=dataBit;
					else
						rxClockCount<=rxClockCount+1;
					end if;
				end if;
			when dataBit =>
				if rxClockCount= 15 then -- 1 bit later - sample
					rxClockCount<="000000";
					rxBitCount <=rxBitCount+1;
					rxCurrentByteBuffer <= rxd & rxCurrentByteBuffer(7 downto 1);
					if rxBitCount= 7 then -- 8 bits read - handle stop bit
						rxState<=stopBit;
				end if;
				else
					rxClockCount<=rxClockCount+1;
				end if;
			when stopBit =>
				if rxClockCount= 15 then
					rxBuffer(rxInPointer) <= rxCurrentByteBuffer;
					if rxInPointer < 31 then
						rxInPointer <= rxInPointer+1;
					else
						rxInPointer <= 0;
					end if;
					rxClockCount<="000000";
					rxState <=idle;
				else
					rxClockCount<=rxClockCount+1;
				end if;
			end case;
		end if;      
	end if;
	end process;

	process( txClock , reset )
	begin
	if loadFrom = '1' then
		if reset='1' then
			txState <= idle;
			txBitCount<="0000";
			txClockCount<="000000";
			txByteSent <= '0';

		elsif falling_edge(txClock) then
			case txState is
			when idle =>
				txd <= '1';
				if (txByteWritten /= txByteSent) and n_cts='0' and n_dcd='0' then
					txBuffer <= txByteLatch;
					txByteSent <= not txByteSent;
					txState <=dataBit;
					txd <= '0'; -- start bit
					txBitCount<="0000";
					txClockCount<="000000";
				end if;
			when dataBit =>
				if txClockCount= 15 then -- 1 bit later
					txClockCount<="000000";
					if txBitCount= 8 then -- 8 bits read - handle stop bit
						txd <= '1';
						txState<=stopBit;
					else
						txd <= txBuffer(0);
						txBuffer <= '0' & txBuffer(7 downto 1); 
						txBitCount <=txBitCount+1;
					end if;
				else
					txClockCount<=txClockCount+1;
				end if;
			when stopBit =>
				if txClockCount= 15 then
					txState <=idle;
				else
					txClockCount<=txClockCount+1;
				end if;
			end case;
		end if; 
	end if;		
	end process;
	
		
end rtl;



