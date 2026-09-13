module accelerator_top (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [7:0]  PADDR,
    input  logic [7:0] PWDATA,
    output logic [7:0] PRDATA,
    output logic        PREADY
);

    logic       start_pulse;
    logic [7:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    logic       busy, done;
    logic [7:0] result;

    // controller <-> sobel_core
    logic [7:0] cp00, cp01, cp02;
    logic [7:0] cp10, cp11, cp12;
    logic [7:0] cp20, cp21, cp22;
    logic [7:0] sobel_result;

    apb_slave u_apb_slave (
        .PCLK(PCLK), .PRESETn(PRESETn),
        .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),

        .start_pulse_o(start_pulse),
        .p00_o(p00), .p01_o(p01), .p02_o(p02),
        .p10_o(p10), .p11_o(p11), .p12_o(p12),
        .p20_o(p20), .p21_o(p21), .p22_o(p22),

        .busy_i(busy), .done_i(done), .result_i(result)
    );

    controller u_controller (
        .PCLK(PCLK), .PRESETn(PRESETn),

        .start_pulse_i(start_pulse),
        .p00_i(p00), .p01_i(p01), .p02_i(p02),
        .p10_i(p10), .p11_i(p11), .p12_i(p12),
        .p20_i(p20), .p21_i(p21), .p22_i(p22),

        .busy_o(busy), .done_o(done), .result_o(result),

        .cp00_o(cp00), .cp01_o(cp01), .cp02_o(cp02),
        .cp10_o(cp10), .cp11_o(cp11), .cp12_o(cp12),
        .cp20_o(cp20), .cp21_o(cp21), .cp22_o(cp22),
        .sobel_result_i(sobel_result)
    );

    sobel_core u_sobel_core (
        .p00(cp00), .p01(cp01), .p02(cp02),
        .p10(cp10), .p11(cp11), .p12(cp12),
        .p20(cp20), .p21(cp21), .p22(cp22),
        .magnitude_o(sobel_result)
    );

endmodule
