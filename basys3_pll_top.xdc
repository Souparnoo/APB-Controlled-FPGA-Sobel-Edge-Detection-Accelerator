## basys3_pll_top.xdc
## Digilent Basys3 (Artix-7 xc7a35tcpg236-1)
##
## Same as basys3_top.xdc, except the top-level clock port is now
## called clk100 (basys3_pll_top wraps the Clocking Wizard, which
## generates its own internal clock constraints automatically when
## you generate the IP -- you do NOT need to add a create_clock line
## for clk50 yourself).

## 100 MHz onboard oscillator -> feeds the Clocking Wizard
## NOTE: do NOT add a create_clock here -- the Clocking Wizard IP
## already auto-generates its own input clock constraint for this
## pin (via clk_wiz_0's generated .xdc). Adding one here overrides
## it and breaks the IP's internal clock relationship constraints
## (Vivado will flag "Clock 'sys_clk' completely overrides clock
## 'clk100'" as a critical warning). Pin/IOSTANDARD only:
set_property PACKAGE_PIN W5 [get_ports clk100]
set_property IOSTANDARD LVCMOS33 [get_ports clk100]

## Center pushbutton (btnC) as reset
set_property PACKAGE_PIN U18 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

## USB-UART bridge
set_property PACKAGE_PIN B18 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]
set_property PACKAGE_PIN A18 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

## LEDs (status)
set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property PACKAGE_PIN W18 [get_ports {led[4]}]
set_property PACKAGE_PIN U15 [get_ports {led[5]}]
set_property PACKAGE_PIN U14 [get_ports {led[6]}]
set_property PACKAGE_PIN V14 [get_ports {led[7]}]
set_property PACKAGE_PIN V13 [get_ports {led[8]}]
set_property PACKAGE_PIN V3  [get_ports {led[9]}]
set_property PACKAGE_PIN W3  [get_ports {led[10]}]
set_property PACKAGE_PIN U3  [get_ports {led[11]}]
set_property PACKAGE_PIN P3  [get_ports {led[12]}]
set_property PACKAGE_PIN N3  [get_ports {led[13]}]
set_property PACKAGE_PIN P1  [get_ports {led[14]}]
set_property PACKAGE_PIN L1  [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
