module apb_slave (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [7:0]  PADDR,
    input  logic [7:0] PWDATA,
    output logic [7:0] PRDATA,
    output logic        PREADY,

    // to controller
    output logic        start_pulse_o,
    output logic [7:0]  p00_o, p01_o, p02_o,
    output logic [7:0]  p10_o, p11_o, p12_o,
    output logic [7:0]  p20_o, p21_o, p22_o,

    // from controller (for STATUS / RESULT readback)
    input  logic        busy_i,
    input  logic        done_i,
    input  logic [7:0]  result_i
);

    // Address offsets (word-aligned byte addresses, as in Chat 1)
    localparam logic [7:0] ADDR_CONTROL = 8'h00;
    localparam logic [7:0] ADDR_STATUS  = 8'h04;
    localparam logic [7:0] ADDR_PIXEL00 = 8'h08;
    localparam logic [7:0] ADDR_PIXEL01 = 8'h0C;
    localparam logic [7:0] ADDR_PIXEL02 = 8'h10;
    localparam logic [7:0] ADDR_PIXEL10 = 8'h14;
    localparam logic [7:0] ADDR_PIXEL11 = 8'h18;
    localparam logic [7:0] ADDR_PIXEL12 = 8'h1C;
    localparam logic [7:0] ADDR_PIXEL20 = 8'h20;
    localparam logic [7:0] ADDR_PIXEL21 = 8'h24;
    localparam logic [7:0] ADDR_PIXEL22 = 8'h28;
    localparam logic [7:0] ADDR_RESULT  = 8'h2C;

    // PREADY: tied high always
    assign PREADY = 1'b1;

    logic wr_en;
    assign wr_en = PSEL & PENABLE & PWRITE;

    logic [7:0] p00_r, p01_r, p02_r;
    logic [7:0] p10_r, p11_r, p12_r;
    logic [7:0] p20_r, p21_r, p22_r;
    
    logic presetn_sync1, presetn_sync_n;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            presetn_sync1  <= 1'b0;
            presetn_sync_n <= 1'b0;
        end else begin
            presetn_sync1  <= 1'b1;
            presetn_sync_n <= presetn_sync1;
        end
    end
    // then use presetn_sync_n as the reset in your other always_ff blocks

    always_ff @(posedge PCLK or negedge presetn_sync_n) begin
        if (!presetn_sync_n) begin
            p00_r <= 8'd0; p01_r <= 8'd0; p02_r <= 8'd0;
            p10_r <= 8'd0; p11_r <= 8'd0; p12_r <= 8'd0;
            p20_r <= 8'd0; p21_r <= 8'd0; p22_r <= 8'd0;
        end else if (wr_en) begin
            case (PADDR)
                ADDR_PIXEL00: p00_r <= PWDATA[7:0];
                ADDR_PIXEL01: p01_r <= PWDATA[7:0];
                ADDR_PIXEL02: p02_r <= PWDATA[7:0];
                ADDR_PIXEL10: p10_r <= PWDATA[7:0];
                ADDR_PIXEL11: p11_r <= PWDATA[7:0];
                ADDR_PIXEL12: p12_r <= PWDATA[7:0];
                ADDR_PIXEL20: p20_r <= PWDATA[7:0];
                ADDR_PIXEL21: p21_r <= PWDATA[7:0];
                ADDR_PIXEL22: p22_r <= PWDATA[7:0];
                default: ; 
            endcase
        end
    end

    assign p00_o = p00_r; assign p01_o = p01_r; assign p02_o = p02_r;
    assign p10_o = p10_r; assign p11_o = p11_r; assign p12_o = p12_r;
    assign p20_o = p20_r; assign p21_o = p21_r; assign p22_o = p22_r;

    assign start_pulse_o = wr_en & (PADDR == ADDR_CONTROL) & PWDATA[0];

    always_comb begin
        case (PADDR)
            ADDR_CONTROL: PRDATA = 8'd0; // write-only
            ADDR_STATUS:  PRDATA = {6'd0, done_i, busy_i};
            ADDR_PIXEL00: PRDATA = {p00_r};
            ADDR_PIXEL01: PRDATA = {p01_r};
            ADDR_PIXEL02: PRDATA = {p02_r};
            ADDR_PIXEL10: PRDATA = {p10_r};
            ADDR_PIXEL11: PRDATA = {p11_r};
            ADDR_PIXEL12: PRDATA = {p12_r};
            ADDR_PIXEL20: PRDATA = {p20_r};
            ADDR_PIXEL21: PRDATA = {p21_r};
            ADDR_PIXEL22: PRDATA = {p22_r};
            ADDR_RESULT:  PRDATA = {result_i};
            default:      PRDATA = 8'd0;
        endcase
    end

endmodule
