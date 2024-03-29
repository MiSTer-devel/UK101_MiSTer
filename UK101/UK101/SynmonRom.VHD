-- Copyright of the original ROM contents respectfully acknowleged

-- This file was created and maintaned by Grant Searle 2014
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

ENTITY SynmonRom IS

	PORT
	(
		address : in std_logic_vector(10 downto 0);
		q : out std_logic_vector(7 downto 0)
	);
END SynmonRom;

architecture behavior of SynmonRom is
type romtable is array (0 to 2047) of std_logic_vector(7 downto 0);
constant romdata : romtable :=
(
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"8A",x"48",x"98",x"48",x"A9",x"01",x"8D",x"00",
x"DF",x"AE",x"00",x"DF",x"D0",x"05",x"0A",x"D0",
x"F5",x"F0",x"53",x"4A",x"90",x"09",x"2A",x"E0",
x"21",x"D0",x"F3",x"A9",x"1B",x"D0",x"21",x"20",
x"C8",x"FD",x"98",x"8D",x"13",x"02",x"0A",x"0A",
x"0A",x"38",x"ED",x"13",x"02",x"8D",x"13",x"02",
x"8A",x"4A",x"20",x"C8",x"FD",x"D0",x"2F",x"18",
x"98",x"6D",x"13",x"02",x"A8",x"B9",x"CF",x"FD",
x"CD",x"15",x"02",x"D0",x"26",x"CE",x"14",x"02",
x"F0",x"2B",x"A0",x"05",x"A2",x"C8",x"CA",x"D0",
x"FD",x"88",x"D0",x"F8",x"F0",x"AE",x"C9",x"01",
x"F0",x"35",x"A0",x"00",x"C9",x"02",x"F0",x"47",
x"A0",x"C0",x"C9",x"20",x"F0",x"41",x"A9",x"00",
x"8D",x"16",x"02",x"8D",x"15",x"02",x"A9",x"02",
x"8D",x"14",x"02",x"D0",x"8F",x"A2",x"96",x"CD",
x"16",x"02",x"D0",x"02",x"A2",x"14",x"8E",x"14",
x"02",x"8D",x"16",x"02",x"A9",x"01",x"8D",x"00",
x"DF",x"AD",x"00",x"DF",x"4A",x"90",x"33",x"AA",
x"29",x"03",x"F0",x"0B",x"A0",x"10",x"AD",x"15",
x"02",x"10",x"0C",x"A0",x"F0",x"D0",x"08",x"A0",
x"00",x"E0",x"20",x"D0",x"02",x"A0",x"C0",x"AD",
x"15",x"02",x"29",x"7F",x"C9",x"20",x"F0",x"07",
x"8C",x"13",x"02",x"18",x"6D",x"13",x"02",x"8D",
x"13",x"02",x"68",x"A8",x"68",x"AA",x"AD",x"13",
x"02",x"60",x"D0",x"92",x"A0",x"20",x"D0",x"DF",
x"A0",x"08",x"88",x"0A",x"90",x"FC",x"60",x"D0",
x"BB",x"2F",x"20",x"5A",x"41",x"51",x"2C",x"4D",
x"4E",x"42",x"56",x"43",x"58",x"4B",x"4A",x"48",
x"47",x"46",x"44",x"53",x"49",x"55",x"59",x"54",
x"52",x"45",x"57",x"00",x"00",x"0D",x"0A",x"4F",
x"4C",x"2E",x"00",x"FF",x"2D",x"BA",x"30",x"B9",
x"B8",x"B7",x"B6",x"B5",x"B4",x"B3",x"B2",x"B1",
x"A2",x"28",x"9A",x"D8",x"AD",x"06",x"FB",x"A9",
x"FF",x"8D",x"05",x"FB",x"A2",x"D8",x"A9",x"D0",
x"85",x"FF",x"A9",x"00",x"85",x"FE",x"85",x"FB",
x"A8",x"A9",x"20",x"91",x"FE",x"C8",x"D0",x"FB",
x"E6",x"FF",x"E4",x"FF",x"D0",x"F5",x"84",x"FF",
x"F0",x"19",x"20",x"E9",x"FE",x"C9",x"2F",x"F0",
x"1E",x"C9",x"47",x"F0",x"17",x"C9",x"4C",x"F0",
x"43",x"20",x"93",x"FE",x"30",x"EC",x"A2",x"02",
x"20",x"DA",x"FE",x"B1",x"FE",x"85",x"FC",x"20",
x"AC",x"FE",x"D0",x"DE",x"6C",x"FE",x"00",x"20",
x"E9",x"FE",x"C9",x"2E",x"F0",x"D4",x"C9",x"0D",
x"D0",x"0F",x"E6",x"FE",x"D0",x"02",x"E6",x"FF",
x"A0",x"00",x"B1",x"FE",x"85",x"FC",x"4C",x"77",
x"FE",x"20",x"93",x"FE",x"30",x"E1",x"A2",x"00",
x"20",x"DA",x"FE",x"A5",x"FC",x"91",x"FE",x"20",
x"AC",x"FE",x"D0",x"D3",x"85",x"FB",x"F0",x"CF",
x"AD",x"00",x"FC",x"4A",x"90",x"FA",x"AD",x"01",
x"FC",x"EA",x"EA",x"EA",x"29",x"7F",x"60",x"00",
x"00",x"00",x"00",x"C9",x"30",x"30",x"12",x"C9",
x"3A",x"30",x"0B",x"C9",x"41",x"30",x"0A",x"C9",
x"47",x"10",x"06",x"38",x"E9",x"07",x"29",x"0F",
x"60",x"A9",x"80",x"60",x"A2",x"03",x"A0",x"00",
x"B5",x"FC",x"4A",x"4A",x"4A",x"4A",x"20",x"CA",
x"FE",x"B5",x"FC",x"20",x"CA",x"FE",x"CA",x"10",
x"EF",x"A9",x"20",x"8D",x"CA",x"D0",x"8D",x"CB",
x"D0",x"60",x"29",x"0F",x"09",x"30",x"C9",x"3A",
x"30",x"03",x"18",x"69",x"07",x"99",x"C6",x"D0",
x"C8",x"60",x"A0",x"04",x"0A",x"0A",x"0A",x"0A",
x"2A",x"36",x"FC",x"36",x"FD",x"88",x"D0",x"F8",
x"60",x"A5",x"FB",x"D0",x"91",x"4C",x"00",x"FD",
x"A9",x"FF",x"8D",x"00",x"DF",x"AD",x"00",x"DF",
x"60",x"EA",x"30",x"01",x"00",x"FE",x"C0",x"01",
x"A0",x"00",x"8C",x"01",x"C0",x"8C",x"00",x"C0",
x"A2",x"04",x"8E",x"01",x"C0",x"8C",x"03",x"C0",
x"88",x"8C",x"02",x"C0",x"8E",x"03",x"C0",x"8C",
x"02",x"C0",x"A9",x"FB",x"D0",x"09",x"A9",x"02",
x"2C",x"00",x"C0",x"F0",x"1C",x"A9",x"FF",x"8D",
x"02",x"C0",x"20",x"99",x"FF",x"29",x"F7",x"8D",
x"02",x"C0",x"20",x"99",x"FF",x"09",x"08",x"8D",
x"02",x"C0",x"A2",x"18",x"20",x"85",x"FF",x"F0",
x"DD",x"A2",x"7F",x"8E",x"02",x"C0",x"20",x"85",
x"FF",x"AD",x"00",x"C0",x"30",x"FB",x"AD",x"00",
x"C0",x"10",x"FB",x"A9",x"03",x"8D",x"10",x"C0",
x"A9",x"58",x"8D",x"10",x"C0",x"20",x"90",x"FF",
x"85",x"FE",x"AA",x"20",x"90",x"FF",x"85",x"FD",
x"20",x"90",x"FF",x"85",x"FF",x"A0",x"00",x"20",
x"90",x"FF",x"91",x"FD",x"C8",x"D0",x"F8",x"E6",
x"FE",x"C6",x"FF",x"D0",x"F2",x"86",x"FE",x"A9",
x"FF",x"8D",x"02",x"C0",x"60",x"A0",x"F8",x"88",
x"D0",x"FD",x"55",x"FF",x"CA",x"D0",x"F6",x"60",
x"AD",x"10",x"C0",x"4A",x"90",x"FA",x"AD",x"11",
x"C0",x"60",x"48",x"2F",x"44",x"2F",x"4D",x"3F",
x"D8",x"A2",x"D8",x"A9",x"D0",x"85",x"FE",x"A0",
x"00",x"84",x"FD",x"A9",x"20",x"91",x"FD",x"C8",
x"D0",x"FB",x"E6",x"FE",x"E4",x"FE",x"D0",x"F5",
x"A9",x"03",x"8D",x"00",x"FC",x"A9",x"B1",x"8D",
x"00",x"FC",x"B9",x"9A",x"FF",x"30",x"0E",x"99",
x"C6",x"D0",x"AE",x"01",x"FE",x"D0",x"03",x"20",
x"0B",x"FE",x"C8",x"D0",x"ED",x"AD",x"01",x"FE",
x"D0",x"05",x"20",x"00",x"FE",x"B0",x"03",x"20",
x"ED",x"FE",x"C9",x"48",x"F0",x"0A",x"C9",x"44",
x"D0",x"0C",x"20",x"00",x"FF",x"4C",x"00",x"22",
x"4C",x"00",x"FD",x"20",x"00",x"FF",x"6C",x"FC",
x"FE",x"EA",x"30",x"01",x"A0",x"FF",x"C0",x"01",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"8A",x"48",x"98",x"48",x"A9",x"01",x"8D",x"00",
x"DF",x"AE",x"00",x"DF",x"D0",x"05",x"0A",x"D0",
x"F5",x"F0",x"53",x"4A",x"90",x"09",x"2A",x"E0",
x"21",x"D0",x"F3",x"A9",x"1B",x"D0",x"21",x"20",
x"C8",x"FD",x"98",x"8D",x"13",x"02",x"0A",x"0A",
x"0A",x"38",x"ED",x"13",x"02",x"8D",x"13",x"02",
x"8A",x"4A",x"20",x"C8",x"FD",x"D0",x"2F",x"18",
x"98",x"6D",x"13",x"02",x"A8",x"B9",x"CF",x"FD",
x"CD",x"15",x"02",x"D0",x"26",x"CE",x"14",x"02",
x"F0",x"2B",x"A0",x"05",x"A2",x"C8",x"CA",x"D0",
x"FD",x"88",x"D0",x"F8",x"F0",x"AE",x"C9",x"01",
x"F0",x"35",x"A0",x"00",x"C9",x"02",x"F0",x"47",
x"A0",x"C0",x"C9",x"20",x"F0",x"41",x"A9",x"00",
x"8D",x"16",x"02",x"8D",x"15",x"02",x"A9",x"02",
x"8D",x"14",x"02",x"D0",x"8F",x"A2",x"96",x"CD",
x"16",x"02",x"D0",x"02",x"A2",x"14",x"8E",x"14",
x"02",x"8D",x"16",x"02",x"A9",x"01",x"8D",x"00",
x"DF",x"AD",x"00",x"DF",x"4A",x"90",x"33",x"AA",
x"29",x"03",x"F0",x"0B",x"A0",x"10",x"AD",x"15",
x"02",x"10",x"0C",x"A0",x"F0",x"D0",x"08",x"A0",
x"00",x"E0",x"20",x"D0",x"02",x"A0",x"C0",x"AD",
x"15",x"02",x"29",x"7F",x"C9",x"20",x"F0",x"07",
x"8C",x"13",x"02",x"18",x"6D",x"13",x"02",x"8D",
x"13",x"02",x"68",x"A8",x"68",x"AA",x"AD",x"13",
x"02",x"60",x"D0",x"92",x"A0",x"20",x"D0",x"DF",
x"A0",x"08",x"88",x"0A",x"90",x"FC",x"60",x"D0",
x"BB",x"2F",x"20",x"5A",x"41",x"51",x"2C",x"4D",
x"4E",x"42",x"56",x"43",x"58",x"4B",x"4A",x"48",
x"47",x"46",x"44",x"53",x"49",x"55",x"59",x"54",
x"52",x"45",x"57",x"00",x"00",x"0D",x"0A",x"4F",
x"4C",x"2E",x"00",x"FF",x"2D",x"BA",x"30",x"B9",
x"B8",x"B7",x"B6",x"B5",x"B4",x"B3",x"B2",x"B1",
x"A2",x"28",x"9A",x"D8",x"AD",x"06",x"FB",x"A9",
x"FF",x"8D",x"05",x"FB",x"A2",x"D8",x"A9",x"D0",
x"85",x"FF",x"A9",x"00",x"85",x"FE",x"85",x"FB",
x"A8",x"A9",x"20",x"91",x"FE",x"C8",x"D0",x"FB",
x"E6",x"FF",x"E4",x"FF",x"D0",x"F5",x"84",x"FF",
x"F0",x"19",x"20",x"E9",x"FE",x"C9",x"2F",x"F0",
x"1E",x"C9",x"47",x"F0",x"17",x"C9",x"4C",x"F0",
x"43",x"20",x"93",x"FE",x"30",x"EC",x"A2",x"02",
x"20",x"DA",x"FE",x"B1",x"FE",x"85",x"FC",x"20",
x"AC",x"FE",x"D0",x"DE",x"6C",x"FE",x"00",x"20",
x"E9",x"FE",x"C9",x"2E",x"F0",x"D4",x"C9",x"0D",
x"D0",x"0F",x"E6",x"FE",x"D0",x"02",x"E6",x"FF",
x"A0",x"00",x"B1",x"FE",x"85",x"FC",x"4C",x"77",
x"FE",x"20",x"93",x"FE",x"30",x"E1",x"A2",x"00",
x"20",x"DA",x"FE",x"A5",x"FC",x"91",x"FE",x"20",
x"AC",x"FE",x"D0",x"D3",x"85",x"FB",x"F0",x"CF",
x"AD",x"00",x"FC",x"4A",x"90",x"FA",x"AD",x"01",
x"FC",x"EA",x"EA",x"EA",x"29",x"7F",x"60",x"00",
x"00",x"00",x"00",x"C9",x"30",x"30",x"12",x"C9",
x"3A",x"30",x"0B",x"C9",x"41",x"30",x"0A",x"C9",
x"47",x"10",x"06",x"38",x"E9",x"07",x"29",x"0F",
x"60",x"A9",x"80",x"60",x"A2",x"03",x"A0",x"00",
x"B5",x"FC",x"4A",x"4A",x"4A",x"4A",x"20",x"CA",
x"FE",x"B5",x"FC",x"20",x"CA",x"FE",x"CA",x"10",
x"EF",x"A9",x"20",x"8D",x"CA",x"D0",x"8D",x"CB",
x"D0",x"60",x"29",x"0F",x"09",x"30",x"C9",x"3A",
x"30",x"03",x"18",x"69",x"07",x"99",x"C6",x"D0",
x"C8",x"60",x"A0",x"04",x"0A",x"0A",x"0A",x"0A",
x"2A",x"36",x"FC",x"36",x"FD",x"88",x"D0",x"F8",
x"60",x"A5",x"FB",x"D0",x"91",x"4C",x"00",x"FD",
x"A9",x"FF",x"8D",x"00",x"DF",x"AD",x"00",x"DF",
x"60",x"EA",x"30",x"01",x"00",x"FE",x"C0",x"01",
x"D8",x"A2",x"28",x"9A",x"20",x"22",x"BF",x"A0",
x"00",x"8C",x"12",x"02",x"8C",x"03",x"02",x"8C",
x"05",x"02",x"8C",x"06",x"02",x"AD",x"E0",x"FF",
x"8D",x"00",x"02",x"A9",x"20",x"99",x"00",x"D7",
x"99",x"00",x"D6",x"99",x"00",x"D5",x"99",x"00",
x"D4",x"99",x"00",x"D3",x"99",x"00",x"D2",x"99",
x"00",x"D1",x"99",x"00",x"D0",x"C8",x"D0",x"E5",
x"B9",x"5F",x"FF",x"F0",x"06",x"20",x"2D",x"BF",
x"C8",x"D0",x"F5",x"20",x"B8",x"FF",x"C9",x"4D",
x"D0",x"03",x"4C",x"00",x"FE",x"C9",x"57",x"D0",
x"03",x"4C",x"00",x"00",x"C9",x"43",x"D0",x"A8",
x"A9",x"00",x"AA",x"A8",x"4C",x"11",x"BD",x"43",
x"2F",x"57",x"2F",x"4D",x"20",x"3F",x"00",x"20",
x"2D",x"BF",x"48",x"AD",x"05",x"02",x"F0",x"22",
x"68",x"20",x"15",x"BF",x"C9",x"0D",x"D0",x"1B",
x"48",x"8A",x"48",x"A2",x"0A",x"A9",x"00",x"20",
x"15",x"BF",x"CA",x"D0",x"FA",x"68",x"AA",x"68",
x"60",x"48",x"CE",x"03",x"02",x"A9",x"00",x"8D",
x"05",x"02",x"68",x"60",x"48",x"A9",x"01",x"D0",
x"F6",x"AD",x"12",x"02",x"D0",x"19",x"A9",x"01",
x"8D",x"00",x"DF",x"2C",x"00",x"DF",x"50",x"0F",
x"A9",x"04",x"8D",x"00",x"DF",x"2C",x"00",x"DF",
x"50",x"05",x"A9",x"03",x"4C",x"36",x"A6",x"60",
x"2C",x"03",x"02",x"10",x"19",x"A9",x"02",x"8D",
x"00",x"DF",x"A9",x"10",x"2C",x"00",x"DF",x"D0",
x"0A",x"AD",x"00",x"FC",x"4A",x"90",x"EE",x"AD",
x"01",x"FC",x"60",x"EE",x"03",x"02",x"4C",x"ED",
x"FE",x"00",x"00",x"00",x"00",x"00",x"00",x"00",
x"40",x"3F",x"01",x"00",x"03",x"FF",x"3F",x"00",
x"03",x"FF",x"3F",x"4C",x"B8",x"FF",x"4C",x"67",
x"FF",x"4C",x"99",x"FF",x"4C",x"89",x"FF",x"4C",
x"94",x"FF",x"30",x"01",x"00",x"FF",x"C0",x"01"
);
begin
process (address)
begin
	q <= romdata (to_integer(unsigned(address)));
end process;
end behavior;

