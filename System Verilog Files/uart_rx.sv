module uart_rx #(
    parameter int CLK_FREQ = 100_000_000,
    parameter int BAUD     = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid   // 1-cycle pulse when a byte has been received
);
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam int HALF_BIT     = CLKS_PER_BIT / 2;
    localparam int CW           = $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shift;
    logic          rx_s1, rx_s2;

    // 2-flop synchronizer for the async rx pin
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            clk_cnt <= '0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
            data    <= 8'd0;
            valid   <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= 3'd0;
                    if (!rx_s2) state <= START;
                end
                START: begin
                    if (clk_cnt == HALF_BIT-1) begin
                        if (!rx_s2) begin
                            clk_cnt <= '0;
                            state   <= DATA;
                        end else begin
                            state <= IDLE; // glitch, not a real start bit
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt        <= '0;
                        shift[bit_idx] <= rx_s2;
                        if (bit_idx == 3'd7) state <= STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        data  <= shift;
                        valid <= 1'b1;
                        state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
