// basys3_top.sv
//
// Wraps accelerator_top for the Basys3 board. Replaces what
// tb_actual_image.sv did in simulation (file I/O + testbench tasks
// driving APB) with real synthesizable hardware:
//
//   PC --(UART, raw bytes)--> image_mem (BRAM) --> APB master FSM
//        drives accelerator_top exactly like the testbench did -->
//        output_mem (BRAM) --(UART, raw bytes)--> PC
//
// Protocol (matches the Python host script):
//   1. FPGA waits for exactly WIDTH*HEIGHT bytes over UART RX and
//      fills image_mem in row-major order (same order as image_in.hex).
//   2. FPGA clears output_mem to 0 (borders stay 0, same convention
//      as tb_actual_image.sv).
//   3. FPGA slides a 3x3 window over every interior pixel, drives it
//      through accelerator_top over APB, and stores the result.
//   4. FPGA streams output_mem back over UART TX, WIDTH*HEIGHT bytes,
//      row-major (same order hex_to_png.py expects).
//   5. LEDs show phase; led[15] latches "done".

module basys3_top #(
    parameter int WIDTH    = 256,
    parameter int HEIGHT   = 256,
    parameter int CLK_FREQ = 100_000_000,
    parameter int BAUD     = 115200
)(
    input  logic clk,        // 100 MHz onboard oscillator
    input  logic btn_rst,    // active-high reset button (btnC)
    input  logic uart_rxd,   // from host PC
    output logic uart_txd,   // to host PC
    output logic [15:0] led
);

    localparam int NPIX  = WIDTH * HEIGHT;
    localparam int AW    = $clog2(NPIX);      // address width for the image memories
    localparam int XBITS = $clog2(WIDTH);     // WIDTH must be a power of two

    // -----------------------------------------------------------
    // Reset synchronizer
    // -----------------------------------------------------------
    logic rst_n_meta, rst_n;
    always_ff @(posedge clk) begin
        rst_n_meta <= ~btn_rst;
        rst_n      <= rst_n_meta;
    end

    // -----------------------------------------------------------
    // UART
    // -----------------------------------------------------------
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rxd),
        .data(rx_data), .valid(rx_valid)
    );

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(tx_data),
        .start(tx_start), .busy(tx_busy), .tx(uart_txd)
    );

    // -----------------------------------------------------------
    // Image memories (inferred as Block RAM)
    // -----------------------------------------------------------
    logic [7:0] image_mem  [0:NPIX-1];
    logic [7:0] output_mem [0:NPIX-1];

    // input image: write port (RX fill) + read port (window loader)
    logic [AW-1:0] img_wr_addr, img_rd_addr;
    logic [7:0]    img_wr_data, img_rd_data;
    logic          img_wr_en;

    always_ff @(posedge clk) begin
        if (img_wr_en) image_mem[img_wr_addr] <= img_wr_data;
    end
    always_ff @(posedge clk) begin
        img_rd_data <= image_mem[img_rd_addr];
    end

    // output image: write port (result store / clear) + read port (TX drain)
    logic [AW-1:0] out_wr_addr, out_rd_addr;
    logic [7:0]    out_wr_data, out_rd_data;
    logic          out_wr_en;

    always_ff @(posedge clk) begin
        if (out_wr_en) output_mem[out_wr_addr] <= out_wr_data;
    end
    always_ff @(posedge clk) begin
        out_rd_data <= output_mem[out_rd_addr];
    end

    // -----------------------------------------------------------
    // accelerator_top instance + APB master engine
    // -----------------------------------------------------------
    logic       PSEL, PENABLE, PWRITE;
    logic [7:0] PADDR, PWDATA, PRDATA;
    logic       PREADY;

    accelerator_top dut (
        .PCLK(clk), .PRESETn(rst_n),
        .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY)
    );

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

    function automatic logic [7:0] pix_addr(input logic [3:0] idx);
        case (idx)
            4'd0: pix_addr = ADDR_PIXEL00;
            4'd1: pix_addr = ADDR_PIXEL01;
            4'd2: pix_addr = ADDR_PIXEL02;
            4'd3: pix_addr = ADDR_PIXEL10;
            4'd4: pix_addr = ADDR_PIXEL11;
            4'd5: pix_addr = ADDR_PIXEL12;
            4'd6: pix_addr = ADDR_PIXEL20;
            4'd7: pix_addr = ADDR_PIXEL21;
            default: pix_addr = ADDR_PIXEL22; // idx == 8
        endcase
    endfunction

    // Generic single-transaction APB master: caller sets apb_op /
    // apb_addr_r / apb_wdata_r and pulses apb_start; apb_done pulses
    // one cycle when the transaction (SETUP + ACCESS) has completed,
    // with apb_rdata_r valid for reads. One full write/read APB
    // transfer, same protocol shape as the testbench tasks.
    typedef enum logic [1:0] {A_IDLE, A_SETUP, A_ACCESS, A_GAP} apb_state_t;
    apb_state_t apb_state;

    logic       apb_start;
    logic       apb_op;      // 0 = write, 1 = read
    logic [7:0] apb_addr_r, apb_wdata_r, apb_rdata_r;
    logic       apb_busy, apb_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apb_state <= A_IDLE;
            PSEL <= 1'b0; PENABLE <= 1'b0; PWRITE <= 1'b0;
            PADDR <= 8'd0; PWDATA <= 8'd0;
            apb_busy <= 1'b0; apb_done <= 1'b0; apb_rdata_r <= 8'd0;
        end else begin
            apb_done <= 1'b0;
            case (apb_state)
                A_IDLE: begin
                    if (apb_start) begin
                        PSEL     <= 1'b1;
                        PENABLE  <= 1'b0;
                        PWRITE   <= ~apb_op;
                        PADDR    <= apb_addr_r;
                        PWDATA   <= apb_wdata_r;
                        apb_busy <= 1'b1;
                        apb_state <= A_SETUP;
                    end
                end
                A_SETUP: begin
                    PENABLE   <= 1'b1;      // access phase begins next cycle
                    apb_state <= A_ACCESS;
                end
                A_ACCESS: begin
                    apb_rdata_r <= PRDATA;  // valid throughout this cycle
                    PSEL    <= 1'b0;
                    PENABLE <= 1'b0;
                    PWRITE  <= 1'b0;
                    apb_state <= A_GAP;
                end
                A_GAP: begin
                    apb_busy  <= 1'b0;
                    apb_done  <= 1'b1;
                    apb_state <= A_IDLE;
                end
                default: apb_state <= A_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------
    // Main control FSM
    // -----------------------------------------------------------
    typedef enum logic [4:0] {
        S_RESET, S_RX_FILL, S_CLEAR, S_PIX_START,
        S_LOAD_NEIGH,
        S_JOB_WR_START, S_JOB_WR_WAIT,
        S_JOB_POLL_START, S_JOB_POLL_WAIT,
        S_JOB_RD_START, S_JOB_RD_WAIT,
        S_STORE, S_ADVANCE,
        S_TX_START, S_TX_WAIT_MEM, S_TX_SEND, S_TX_WAIT_DONE, S_TX_ADV,
        S_DONE
    } state_t;
    state_t state;

    localparam int MAX_POLL = 20;

    logic [AW-1:0]  fill_cnt;
    logic [AW-1:0]  clear_cnt;
    logic [$clog2(WIDTH)-1:0]  x;
    logic [$clog2(HEIGHT)-1:0] y;
    logic [3:0]     neigh_idx;
    logic [7:0]     win [0:8];
    logic [3:0]     job_idx;
    logic [7:0]     poll_cnt;
    logic [7:0]     result_reg;
    logic [AW-1:0]  tx_cnt;
    logic           err_timeout;

    // neighbor coordinates / addresses for the current interior pixel (x,y)
    logic [$clog2(WIDTH)-1:0]  xm1, xp1;
    logic [$clog2(HEIGHT)-1:0] ym1, yp1;
    assign xm1 = x - 1'b1;
    assign xp1 = x + 1'b1;
    assign ym1 = y - 1'b1;
    assign yp1 = y + 1'b1;

    logic [AW-1:0] naddr [0:8];
    assign naddr[0] = (ym1 << XBITS) | xm1;
    assign naddr[1] = (ym1 << XBITS) | x;
    assign naddr[2] = (ym1 << XBITS) | xp1;
    assign naddr[3] = (y   << XBITS) | xm1;
    assign naddr[4] = (y   << XBITS) | x;
    assign naddr[5] = (y   << XBITS) | xp1;
    assign naddr[6] = (yp1 << XBITS) | xm1;
    assign naddr[7] = (yp1 << XBITS) | x;
    assign naddr[8] = (yp1 << XBITS) | xp1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_RESET;
            fill_cnt    <= '0;
            clear_cnt   <= '0;
            x           <= 1;
            y           <= 1;
            neigh_idx   <= '0;
            job_idx     <= '0;
            poll_cnt    <= '0;
            tx_cnt      <= '0;
            err_timeout <= 1'b0;
            img_wr_en   <= 1'b0;
            out_wr_en   <= 1'b0;
            apb_start   <= 1'b0;
            tx_start    <= 1'b0;
        end else begin
            img_wr_en <= 1'b0;
            out_wr_en <= 1'b0;
            apb_start <= 1'b0;
            tx_start  <= 1'b0;

            case (state)
                // -------------------------------------------------
                S_RESET: begin
                    fill_cnt <= '0;
                    state    <= S_RX_FILL;
                end

                // -------------------------------------------------
                // Fill image_mem from UART, row-major, NPIX bytes
                // -------------------------------------------------
                S_RX_FILL: begin
                    if (rx_valid) begin
                        img_wr_addr <= fill_cnt;
                        img_wr_data <= rx_data;
                        img_wr_en   <= 1'b1;
                        if (fill_cnt == NPIX-1) begin
                            clear_cnt <= '0;
                            state     <= S_CLEAR;
                        end else begin
                            fill_cnt <= fill_cnt + 1'b1;
                        end
                    end
                end

                // -------------------------------------------------
                // Zero output_mem (borders stay 0, same as testbench)
                // -------------------------------------------------
                S_CLEAR: begin
                    out_wr_addr <= clear_cnt;
                    out_wr_data <= 8'd0;
                    out_wr_en   <= 1'b1;
                    if (clear_cnt == NPIX-1) begin
                        x     <= 1;
                        y     <= 1;
                        state <= S_PIX_START;
                    end else begin
                        clear_cnt <= clear_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------
                // Per-pixel processing
                // -------------------------------------------------
                S_PIX_START: begin
                    neigh_idx   <= '0;
                    img_rd_addr <= naddr[0];
                    state       <= S_LOAD_NEIGH;
                end

                S_LOAD_NEIGH: begin
                    // 1-cycle read latency: img_rd_data this cycle reflects
                    // the address that was presented last cycle. Capture
                    // that into win[neigh_idx-1], and (unless we've already
                    // presented the last address) request the *next* one.
                    if (neigh_idx > 0) win[neigh_idx-1] <= img_rd_data;
                    if (neigh_idx == 9) begin
                        job_idx <= '0;
                        state   <= S_JOB_WR_START;
                    end else begin
                        if (neigh_idx < 8) img_rd_addr <= naddr[neigh_idx+1];
                        neigh_idx <= neigh_idx + 1'b1;
                    end
                end

                // 9 pixel writes (job_idx 0..8) then 1 START write (job_idx 9)
                S_JOB_WR_START: begin
                    apb_start  <= 1'b1;
                    apb_op     <= 1'b0; // write
                    apb_addr_r <= (job_idx < 9) ? pix_addr(job_idx) : ADDR_CONTROL;
                    apb_wdata_r<= (job_idx < 9) ? win[job_idx]      : 8'h01;
                    state      <= S_JOB_WR_WAIT;
                end
                S_JOB_WR_WAIT: begin
                    if (apb_done) begin
                        if (job_idx == 9) begin
                            poll_cnt <= '0;
                            state    <= S_JOB_POLL_START;
                        end else begin
                            job_idx <= job_idx + 1'b1;
                            state   <= S_JOB_WR_START;
                        end
                    end
                end

                // Poll STATUS until DONE (bit1) or timeout
                S_JOB_POLL_START: begin
                    apb_start  <= 1'b1;
                    apb_op     <= 1'b1; // read
                    apb_addr_r <= ADDR_STATUS;
                    state      <= S_JOB_POLL_WAIT;
                end
                S_JOB_POLL_WAIT: begin
                    if (apb_done) begin
                        if (apb_rdata_r[1]) begin
                            state <= S_JOB_RD_START;
                        end else if (poll_cnt == MAX_POLL-1) begin
                            err_timeout <= 1'b1;   // shouldn't happen; flagged on LEDs
                            state       <= S_JOB_RD_START;
                        end else begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= S_JOB_POLL_START;
                        end
                    end
                end

                // Read RESULT
                S_JOB_RD_START: begin
                    apb_start  <= 1'b1;
                    apb_op     <= 1'b1; // read
                    apb_addr_r <= ADDR_RESULT;
                    state      <= S_JOB_RD_WAIT;
                end
                S_JOB_RD_WAIT: begin
                    if (apb_done) begin
                        result_reg <= apb_rdata_r;
                        state      <= S_STORE;
                    end
                end

                S_STORE: begin
                    out_wr_addr <= (y << XBITS) | x;
                    out_wr_data <= result_reg;
                    out_wr_en   <= 1'b1;
                    state       <= S_ADVANCE;
                end

                S_ADVANCE: begin
                    if (x == WIDTH-2) begin
                        x <= 1;
                        if (y == HEIGHT-2) begin
                            tx_cnt <= '0;
                            state  <= S_TX_START;
                        end else begin
                            y     <= y + 1'b1;
                            state <= S_PIX_START;
                        end
                    end else begin
                        x     <= x + 1'b1;
                        state <= S_PIX_START;
                    end
                end

                // -------------------------------------------------
                // Stream output_mem back over UART, NPIX bytes
                // -------------------------------------------------
                S_TX_START: begin
                    out_rd_addr <= tx_cnt;
                    state       <= S_TX_WAIT_MEM;
                end
                S_TX_WAIT_MEM: begin
                    state <= S_TX_SEND; // one extra cycle for BRAM read latency
                end
                S_TX_SEND: begin
                    if (!tx_busy) begin
                        tx_data  <= out_rd_data;
                        tx_start <= 1'b1;
                        state    <= S_TX_WAIT_DONE;
                    end
                end
                S_TX_WAIT_DONE: begin
                    if (tx_busy) state <= S_TX_ADV; // wait for it to actually start
                end
                S_TX_ADV: begin
                    if (!tx_busy) begin
                        if (tx_cnt == NPIX-1) begin
                            state <= S_DONE;
                        end else begin
                            tx_cnt      <= tx_cnt + 1'b1;
                            out_rd_addr <= tx_cnt + 1'b1;
                            state       <= S_TX_WAIT_MEM;
                        end
                    end
                end

                S_DONE: begin
                    state <= S_DONE;
                end

                default: state <= S_RESET;
            endcase
        end
    end

    // -----------------------------------------------------------
    // Status LEDs
    // -----------------------------------------------------------
    assign led[0]  = (state == S_RX_FILL);
    assign led[1]  = (state == S_CLEAR);
    assign led[2]  = (state >= S_PIX_START) && (state <= S_ADVANCE);
    assign led[3]  = (state >= S_TX_START)  && (state <= S_TX_ADV);
    assign led[4]  = (state == S_DONE);
    assign led[14] = err_timeout;
    assign led[15] = rst_n;
    assign led[13:5] = '0;

endmodule
