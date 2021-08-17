This is a Mister core based on Grant Searle's UK101 project. It is a reconstruction of a kit computer from the late 1970s, which was based on a 6502 processor.

The original project is here: http://searle.x10host.com/uk101FPGA/ind ... reDownload

I also used a VGA interface by someone who goes by the name of Cray Ze Ape, which is available here:

https://github.com/douggilliland/MultiC ... A_CraZeApe

I am a total noob at FPGA programming, so this very simple computer seemed to be a good starting point. I included some enhancements which Grant added to his own project, such as the 64x32 display, and I expanded the RAM to 32K. Saving and loading of Basic programs can be done via the UART, at 9600 baud. This is exactly the way that Grant wrote it. Ideally, I would like to save and load via the ADC, but I don't yet know what this entails.

The manual for the system is available here: http://uk101.sourceforge.net/docs/pdf/manual.pdf.
