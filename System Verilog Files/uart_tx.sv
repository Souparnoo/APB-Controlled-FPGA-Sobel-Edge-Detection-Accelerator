module uart_tx #(
    parameter int CLK_FREQ = 100_000_000,
    parameter int BAUD     = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data,
    input  logic       start,   // 1-cycle pulse: begin sending 'data'
    output logic       busy,
    output logic       tx
);
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam int CW           = $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] {IDLE, SETUP_BIT, DATA_BITS, STOP_BIT} state_t;
    state_t state;

    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shift;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            tx      <= 1'b1;
            clk_cnt <= '0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        shift   <= data;
                        clk_cnt <= '0;
                        state   <= SETUP_BIT;
                    end
                end
                SETUP_BIT: begin
                    tx <= 1'b0; // start bit
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= '0;
                        bit_idx <= 3'd0;
                        state   <= DATA_BITS;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                DATA_BITS: begin
                    tx <= shift[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7) state <= STOP_BIT;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                STOP_BIT: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= '0;
                        state   <= IDLE;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
