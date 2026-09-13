// basys3_pll_top.sv
//
// New top-level for the Basys3 build. Wraps basys3_top with a
// Clocking Wizard MMCM that divides the 100MHz onboard oscillator
// down to 50MHz, doubling the timing budget (20ns instead of 10ns)
// to comfortably close the setup-timing violation seen at 100MHz
// (WNS was only -1.3ns short, so 50MHz gives large margin).
//
// Requires the "clk_wiz_0" Clocking Wizard IP (see setup steps).

module basys3_pll_top (
    input  logic clk100,     // W5, 100MHz onboard oscillator
    input  logic btn_rst,    // btnC, active-high
    input  logic uart_rxd,
    output logic uart_txd,
    output logic [15:0] led
);

    logic clk50;
    logic mmcm_locked;

    // Clocking Wizard IP: 100MHz in -> 50MHz out.
    // Port names match the Vivado-generated default for a Clocking
    // Wizard configured with reset + locked ports enabled.
    clk_wiz_0 u_clkgen (
        .clk_in1  (clk100),
        .reset    (btn_rst),
        .clk_out1 (clk50),
        .locked   (mmcm_locked)
    );

    // Hold basys3_top in reset until the MMCM has locked, in addition
    // to the button. basys3_top already double-flops this internally.
    logic rst_in;
    assign rst_in = btn_rst | ~mmcm_locked;

    basys3_top #(
        .WIDTH(256), .HEIGHT(256),
        .CLK_FREQ(50_000_000),   // must match the IP's actual clk_out1 frequency
        .BAUD(115200)
    ) u_core (
        .clk      (clk50),
        .btn_rst  (rst_in),
        .uart_rxd (uart_rxd),
        .uart_txd (uart_txd),
        .led      (led)
    );

endmodule
