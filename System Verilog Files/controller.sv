module controller (
    input  logic       PCLK,
    input  logic       PRESETn,

    // from apb_slave
    input  logic       start_pulse_i,
    input  logic [7:0] p00_i, p01_i, p02_i,
    input  logic [7:0] p10_i, p11_i, p12_i,
    input  logic [7:0] p20_i, p21_i, p22_i,

    // to apb_slave
    output logic       busy_o,
    output logic       done_o,
    output logic [7:0] result_o,

    // to sobel_core
    output logic [7:0] cp00_o, cp01_o, cp02_o,
    output logic [7:0] cp10_o, cp11_o, cp12_o,
    output logic [7:0] cp20_o, cp21_o, cp22_o,
    // from sobel_core
    input  logic [7:0] sobel_result_i
);

    logic [7:0] p00_r, p01_r, p02_r;
    logic [7:0] p10_r, p11_r, p12_r;
    logic [7:0] p20_r, p21_r, p22_r;
    logic [7:0] result_r;
    logic       done_r;
    logic       busy_r ;

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
            busy_r <= 1'b0;
            done_r     <= 1'b0;
            result_r   <= 8'd0;
            p00_r <= 8'd0; p01_r <= 8'd0; p02_r <= 8'd0;
            p10_r <= 8'd0; p11_r <= 8'd0; p12_r <= 8'd0;
            p20_r <= 8'd0; p21_r <= 8'd0; p22_r <= 8'd0;
        end else begin
            case (busy_r)
                1'b0: begin
                    if (start_pulse_i) begin
                        p00_r <= p00_i; p01_r <= p01_i; p02_r <= p02_i;
                        p10_r <= p10_i; p11_r <= p11_i; p12_r <= p12_i;
                        p20_r <= p20_i; p21_r <= p21_i; p22_r <= p22_i;
                        done_r     <= 1'b0; 
                        busy_r    <= 1'b1;
                    end
                end
                1'b1: begin
                    result_r <= sobel_result_i;
                    done_r   <= 1'b1;
                    busy_r     <= 1'b0;
                end

                default: busy_r <= 1'b0;
            endcase
        end
    end

    assign busy_o = busy_r;
    assign done_o = done_r;
    assign result_o = result_r;

    assign cp00_o = p00_r; assign cp01_o = p01_r; assign cp02_o = p02_r;
    assign cp10_o = p10_r; assign cp11_o = p11_r; assign cp12_o = p12_r;
    assign cp20_o = p20_r; assign cp21_o = p21_r; assign cp22_o = p22_r;

endmodule