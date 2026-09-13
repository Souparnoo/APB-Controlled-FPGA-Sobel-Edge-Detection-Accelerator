`timescale 1ns/1ps

module tb_basys3_top;

    localparam int WIDTH    = 8;
    localparam int HEIGHT   = 8;
    localparam int NPIX     = WIDTH*HEIGHT;
    localparam int CLK_FREQ = 100_000_000; // matches the actual #5 clk period below (10ns => 100MHz)
    localparam int BAUD     = 1_000_000;   // fast-but-real baud so sim finishes quickly
    localparam int BIT_NS   = 1_000_000_000 / BAUD;

    logic clk, btn_rst;
    logic host_tx;   // host -> FPGA (drives uart_rxd)
    logic fpga_tx;   // FPGA -> host (uart_txd)
    logic [15:0] led;

    basys3_top #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .CLK_FREQ(CLK_FREQ), .BAUD(BAUD)
    ) dut (
        .clk(clk), .btn_rst(btn_rst),
        .uart_rxd(host_tx), .uart_txd(fpga_tx), .led(led)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz-scaled clock period doesn't matter, just consistent
    end

    logic [7:0] image [0:NPIX-1];
    logic [7:0] result [0:NPIX-1];
    logic [7:0] expected [0:NPIX-1];

    function automatic logic [7:0] sobel_ref(
        input logic [7:0] rp00, input logic [7:0] rp01, input logic [7:0] rp02,
        input logic [7:0] rp10, input logic [7:0] rp11, input logic [7:0] rp12,
        input logic [7:0] rp20, input logic [7:0] rp21, input logic [7:0] rp22
    );
        int gx, gy, mag;
        begin
            gx = (int'(rp02) - int'(rp00)) + 2*(int'(rp12) - int'(rp10)) + (int'(rp22) - int'(rp20));
            gy = (int'(rp20) - int'(rp00)) + 2*(int'(rp21) - int'(rp01)) + (int'(rp22) - int'(rp02));
            mag = (gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy);
            sobel_ref = (mag > 255) ? 8'd255 : mag[7:0];
        end
    endfunction

    // ---- simulated host: UART byte send/receive over host_tx/fpga_tx ----
    task automatic uart_send_byte(input logic [7:0] b);
        begin
            host_tx = 1'b0; #(BIT_NS);            // start bit
            for (int i = 0; i < 8; i++) begin
                host_tx = b[i]; #(BIT_NS);
            end
            host_tx = 1'b1; #(BIT_NS);            // stop bit
        end
    endtask

    task automatic uart_recv_byte(output logic [7:0] b);
        begin
            @(negedge fpga_tx);                    // start bit begins
            #(BIT_NS/2);                            // sample mid-bit
            for (int i = 0; i < 8; i++) begin
                #(BIT_NS);
                b[i] = fpga_tx;
            end
            #(BIT_NS);                              // stop bit
        end
    endtask

    initial begin
        host_tx = 1'b1;
        btn_rst = 1'b1;
        repeat (5) @(posedge clk);
        btn_rst = 1'b0;
        repeat (5) @(posedge clk);

        // build a pseudo-random test image
        for (int i = 0; i < NPIX; i++) image[i] = $urandom_range(0,255);

        // golden model: border=0, interior = sobel of 3x3 neighborhood
        for (int yy = 0; yy < HEIGHT; yy++) begin
            for (int xx = 0; xx < WIDTH; xx++) begin
                if (xx==0 || yy==0 || xx==WIDTH-1 || yy==HEIGHT-1) begin
                    expected[yy*WIDTH+xx] = 8'd0;
                end else begin
                    expected[yy*WIDTH+xx] = sobel_ref(
                        image[(yy-1)*WIDTH+(xx-1)], image[(yy-1)*WIDTH+xx], image[(yy-1)*WIDTH+(xx+1)],
                        image[(yy  )*WIDTH+(xx-1)], image[(yy  )*WIDTH+xx], image[(yy  )*WIDTH+(xx+1)],
                        image[(yy+1)*WIDTH+(xx-1)], image[(yy+1)*WIDTH+xx], image[(yy+1)*WIDTH+(xx+1)]
                    );
                end
            end
        end

        $display("Sending %0d bytes to FPGA...", NPIX);
        for (int i = 0; i < NPIX; i++) uart_send_byte(image[i]);

        $display("Receiving %0d bytes from FPGA...", NPIX);
        for (int i = 0; i < NPIX; i++) begin
            uart_recv_byte(result[i]);
        end

        $display("--- image ---");
        for (int yy=0; yy<HEIGHT; yy++) begin
            string line = "";
            for (int xx=0; xx<WIDTH; xx++) line = {line, $sformatf("%4d", image[yy*WIDTH+xx])};
            $display("%s", line);
        end
        $display("--- expected ---");
        for (int yy=0; yy<HEIGHT; yy++) begin
            string line = "";
            for (int xx=0; xx<WIDTH; xx++) line = {line, $sformatf("%4d", expected[yy*WIDTH+xx])};
            $display("%s", line);
        end
        $display("--- actual ---");
        for (int yy=0; yy<HEIGHT; yy++) begin
            string line = "";
            for (int xx=0; xx<WIDTH; xx++) line = {line, $sformatf("%4d", result[yy*WIDTH+xx])};
            $display("%s", line);
        end

        // compare
        begin
            int fails;
            fails = 0;
            for (int i = 0; i < NPIX; i++) begin
                if (result[i] !== expected[i]) begin
                    fails++;
                    $display("FAIL @%0d: expected=%0d actual=%0d", i, expected[i], result[i]);
                end
            end
            $display("========================================");
            if (fails == 0) $display("RESULT: ALL %0d PIXELS MATCH (basys3_top FSM verified)", NPIX);
            else             $display("RESULT: %0d MISMATCHES", fails);
        end

        repeat (20) @(posedge clk);
        $finish;
    end

    initial begin
        #50_000_000; // watchdog
        $display("FAIL: WATCHDOG TIMEOUT, state=%0d fill_cnt=%0d tx_cnt=%0d",
                   dut.state, dut.fill_cnt, dut.tx_cnt);
        $finish;
    end

endmodule
