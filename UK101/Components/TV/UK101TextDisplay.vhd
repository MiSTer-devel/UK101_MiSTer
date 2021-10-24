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

entity UK101TextDisplay is
	port (
		charAddr : out std_LOGIC_VECTOR(10 downto 0);
		charData : in std_LOGIC_VECTOR(7 downto 0);
		dispAddr : out std_LOGIC_VECTOR(10 downto 0);
		dispData : in std_LOGIC_VECTOR(7 downto 0);
		clk    	: in  std_logic;
		ce_pix	: in std_logic; 	
		resolution	: in std_logic; 
		r		: out std_logic;
		g		: out std_logic;
		b		: out std_logic;
		sync  	: out  std_logic;
		hsync_out  	: out  std_logic;
		vsync_out  	: out  std_logic;
		hblank_out  	: out  std_logic;
		vblank_out 	: out  std_logic;
		machine_type : in std_logic
   );
end UK101TextDisplay;

architecture rtl of UK101TextDisplay is

	signal hSync   : std_logic := '1';
	signal vSync   : std_logic := '1';
	
	signal hblank   : std_logic;
	signal vblank   : std_logic;
	
	signal video   : std_logic;

	signal vActive   : std_logic := '0';
	signal hActive   : std_logic := '0';

	signal	pixelCount: STD_LOGIC_VECTOR(2 DOWNTO 0); 
	
	signal	horizCount: STD_LOGIC_VECTOR(11 DOWNTO 0); 
	signal	vertLineCount: STD_LOGIC_VECTOR(8 DOWNTO 0); 

	signal	charVert: STD_LOGIC_VECTOR(4 DOWNTO 0); 
	signal	charScanLine: STD_LOGIC_VECTOR(3 DOWNTO 0); 

	signal	charHoriz: STD_LOGIC_VECTOR(5 DOWNTO 0); 
	signal	charBit: STD_LOGIC_VECTOR(3 DOWNTO 0); 
	signal	charHeight: STD_LOGIC_VECTOR(3 DOWNTO 0); 

	signal 	charIn : std_LOGIC_VECTOR(7 downto 0);
	signal 	chartemp : std_LOGIC_VECTOR(7 downto 0);
	
	signal	rightBorder: integer range 0 to 550 := 0; 
	signal 	totalPixels : integer range 0 to 550 := 0;


begin

	hsync_out <= not hsync;
	vsync_out <= not vsync;
	hblank<= not hActive;
	vblank<= not vActive;
	hblank_out <= hblank;
	vblank_out <= vblank;
	r <= video;
	g <= video;
	b <= video;
	sync <= hSync and vSync;
	
	dispAddr <= charVert & charHoriz;
	charAddr <= dispData & charScanLine(3 DOWNTO 1) when resolution = '0' and machine_type = '0'
					else dispData & charScanLine(2 downto 0);
	charHeight(3 downto 0)<= "1111" when resolution = '0' and machine_type= '0' else "0111";

	
	--charIn <= charData(7 downto 0) when machine_type = '0' else charData(0 to 7);
	gen: for i in 0 to 7 generate
		charIn(i) <= charData(i) when machine_type='0' else charData(7-i);
	end generate;
	
	totalPixels <= 270 when machine_type = '1' and resolution = '0' 
					else 534;
	rightBorder <= 262 when machine_type = '1' and resolution = '0' 
					else 518;
	
	
	PROCESS (clk)
	BEGIN
	
-- UK101 display...
-- 64 bytes per line (48 chars displayed)	
-- 16 lines of characters
-- 8x8 per char
	
-- 5 lines vsync
-- 30 lines to start of display
-- 313 lines per frame
-- 64uS per horiz line (3200 clocks)
-- 4.7us horiz sync (235 clocks)
		if rising_edge(clk) then
		  if ce_pix = '1' then
			IF horizCount < totalPixels THEN
				horizCount <= horizCount + 1;
--				if (horizCount < 600) or (horizCount > 3000) then
				if (horizCount < 7) or (horizCount > rightBorder) then
					hActive <= '0';
					charHoriz <= (others => '0');
				else
					hActive <= '1';
				end if;

			else
				horizCount<= (others => '0');
				pixelCount<= (others => '0');
				charHoriz<= (others => '0');
				if vertLineCount > 312 then
					vertLineCount <= (others => '0');
				else
--					if vertLineCount < 42 or vertLineCount > 297 then
					if vertLineCount < 37 or vertLineCount > 292 then
						vActive <= '0';
						charVert <= (others => '0');
						charScanLine <= (others => '0');
					else
						vActive <= '1';
						if charScanLine = charHeight then
							charScanLine <= (others => '0');
							charVert <= charVert+1;
						else
							if vertLineCount /= 37 then
								charScanLine <= charScanLine+1;
							end if;
						end if;
					end if;

					vertLineCount <=vertLineCount+1;
				end if;

			END IF;
			if horizCount < 39 then
				hSync <= '0';
			else
				hSync <= '1';
			end if;
			if vertLineCount < 5 then
				vSync <= '0';
			else
				vSync <= '1';
			end if;
			
			if hActive='1' and vActive = '1' then
					video <= charIn(7-to_integer(unsigned(pixelCount)));
					if pixelCount = 7 then
						charHoriz <= charHoriz+1;
					end if;
					pixelCount <= pixelCount+1;
			else
				video <= '0';
			end if;
		end if;
	end if;	
	END PROCESS;	
  
 end rtl;
