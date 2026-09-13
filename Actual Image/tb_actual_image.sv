// tb_actual_image.sv
//
// Runs a REAL 256x256 8-bit grayscale image through accelerator_top,
// pixel window by pixel window, entirely over the APB bus -- exactly
// as a CPU driver would. This is the same interaction pattern as
// tb_accelerator_top.sv, just applied to every 3x3 window of an
// actual picture instead of a handful of directed/random cases.
//
// ------------------------------------------------------------------
// WHY A PYTHON PRE/POST STEP IS NEEDED
// ------------------------------------------------------------------
// Verilog/SystemVerilog has no way to decode a .png file (PNG is a
// compressed, filtered, chunked binary format -- decoding it is not
// something $readmemh or $fread can do). So the flow is:
//
//   1. png_to_hex.py   : test.png  -> image_in.hex   (plain hex bytes)
//   2. this testbench  : image_in.hex -> output_image.hex (Sobel result)
//   3. hex_to_png.py   : output_image.hex -> edges_out.png (viewable)
//
// image_in.hex / output_image.hex are just one 8-bit hex value per
// line, row-major (row 0 left-to-right first), 256*256 = 65536 lines.
//
// ------------------------------------------------------------------
// BORDER HANDLING
// ------------------------------------------------------------------
// accelerator_top only computes a 3x3 Sobel window -- it has no
// concept of image padding. So the outermost 1-pixel border of the
// output (row 0, row 255, col 0, col 255) has no full 3x3
// neighborhood and is written as 0 (black), same convention many
// simple Sobel implementations use. All 254x254 interior pixels are
// computed by actually running them through the DUT over APB.
//
// ------------------------------------------------------------------
// SELF-CHECKING
// ------------------------------------------------------------------
// Every hardware result is compared against the same golden Sobel
// reference model used in tb_accelerator_top.sv. Mismatches are
// counted; only the first few are printed in detail so the log stays
// readable on a 64,516-pixel image, but the final summary reports the
// true total pass/fail count across the whole image.

`timescale 1ns/1ps

module tb_actual_image;

    // ---------------------------------------------------------------
    // Image geometry
    // ---------------------------------------------------------------
    localparam int WIDTH  = 256;
    localparam int HEIGHT = 256;
    localparam int NPIX   = WIDTH * HEIGHT;

    // ---------------------------------------------------------------
    // DUT I/O
    // ---------------------------------------------------------------
    logic        PCLK;
    logic        PRESETn;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [7:0]  PADDR;
    logic [7:0] PWDATA;
    logic [7:0] PRDATA;
    logic        PREADY;

    accelerator_top dut (
        .PCLK    (PCLK),
        .PRESETn (PRESETn),
        .PSEL    (PSEL),
        .PENABLE (PENABLE),
        .PWRITE  (PWRITE),
        .PADDR   (PADDR),
        .PWDATA  (PWDATA),
        .PRDATA  (PRDATA),
        .PREADY  (PREADY)
    );

    // ---------------------------------------------------------------
    // Register map (must match apb_slave.sv)
    // ---------------------------------------------------------------
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

    localparam int MAX_POLL_CYCLES = 20;

    // ---------------------------------------------------------------
    // Image storage
    // ---------------------------------------------------------------
    logic [7:0] image_mem  [0:NPIX-1];
    logic [7:0] result_mem [0:NPIX-1];

    // ---------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------
    initial begin
        PCLK = 1'b0;
        forever #5 PCLK = ~PCLK;
    end

    // ---------------------------------------------------------------
    // Reset
    // ---------------------------------------------------------------
    task automatic reset_dut;
        begin
            PRESETn = 1'b0;
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = 8'd0;
            PWDATA  = 8'd0;
            repeat (3) @(posedge PCLK);
            PRESETn = 1'b1;
            @(posedge PCLK);
            #1;
        end
    endtask

    // ---------------------------------------------------------------
    // APB write / read tasks (same protocol as tb_accelerator_top.sv)
    // ---------------------------------------------------------------
    task automatic apb_write(input logic [7:0] address, input logic [31:0] data);
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b1;
            PADDR   = address;
            PWDATA  = data;

            @(negedge PCLK);
            PENABLE = 1'b1;

            @(posedge PCLK);
            #1;

            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = 8'd0;
            PWDATA  = 8'd0;
        end
    endtask

    task automatic apb_read(input logic [7:0] address, output logic [7:0] read_data);
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = address;

            @(negedge PCLK);
            PENABLE = 1'b1;

            @(posedge PCLK);
            #1;
            read_data = PRDATA;

            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = 8'd0;
        end
    endtask

    task automatic load_window(
        input logic [7:0] q00, q01, q02,
        input logic [7:0] q10, q11, q12,
        input logic [7:0] q20, q21, q22
    );
        begin
            apb_write(ADDR_PIXEL00, {q00});
            apb_write(ADDR_PIXEL01, {q01});
            apb_write(ADDR_PIXEL02, {q02});
            apb_write(ADDR_PIXEL10, {q10});
            apb_write(ADDR_PIXEL11, {q11});
            apb_write(ADDR_PIXEL12, {q12});
            apb_write(ADDR_PIXEL20, {q20});
            apb_write(ADDR_PIXEL21, {q21});
            apb_write(ADDR_PIXEL22, {q22});
        end
    endtask

    task automatic start_job;
        begin
            apb_write(ADDR_CONTROL, 8'h01);
        end
    endtask

    task automatic wait_for_done;
        logic [7:0] status;
        int          n;
        begin
            n = 0;
            status = 8'd0;
            while (!status[1] && n < MAX_POLL_CYCLES) begin
                apb_read(ADDR_STATUS, status);
                n++;
            end
            if (!status[1]) begin
                $display("FATAL: DONE never asserted (poll timeout) - aborting");
                $finish;
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Golden reference model (same as tb_accelerator_top.sv)
    // ---------------------------------------------------------------
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

    // ---------------------------------------------------------------
    // Main
    // ---------------------------------------------------------------
    int total_checks;
    int passed_checks;
    int failed_checks;
    int printed_fails;

    initial begin
        int fd;
        int x, y;
        logic [7:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
        logic [31:0] result_word;
        logic [7:0]  expected;
        time t_start, t_end;

        total_checks   = 0;
        passed_checks  = 0;
        failed_checks  = 0;
        printed_fails  = 0;

        $display("========================================");
        $display("REAL IMAGE SOBEL TEST (%0dx%0d)", WIDTH, HEIGHT);
        $display("========================================");

        // ------------------------------------------------------
        // Load the pre-converted image (see png_to_hex.py)
        // ------------------------------------------------------
        $display("Loading image_in.hex ...");
        $readmemh("image_in.hex", image_mem);

        // Border pixels have no full 3x3 neighborhood -> output 0
        for (y = 0; y < HEIGHT; y++) begin
            result_mem[y*WIDTH + 0]         = 8'd0;
            result_mem[y*WIDTH + (WIDTH-1)] = 8'd0;
        end
        for (x = 0; x < WIDTH; x++) begin
            result_mem[0*WIDTH + x]           = 8'd0;
            result_mem[(HEIGHT-1)*WIDTH + x]  = 8'd0;
        end

        reset_dut();

        t_start = $time;
        $display("Processing %0d interior pixels through the DUT over APB ...",
                  (WIDTH-2)*(HEIGHT-2));

        // ------------------------------------------------------
        // Slide a 3x3 window over every interior pixel, run it
        // through the real hardware, and check it against the
        // golden model.
        // ------------------------------------------------------
        for (y = 1; y < HEIGHT-1; y++) begin
            for (x = 1; x < WIDTH-1; x++) begin
                p00 = image_mem[(y-1)*WIDTH + (x-1)];
                p01 = image_mem[(y-1)*WIDTH + (x  )];
                p02 = image_mem[(y-1)*WIDTH + (x+1)];
                p10 = image_mem[(y  )*WIDTH + (x-1)];
                p11 = image_mem[(y  )*WIDTH + (x  )];
                p12 = image_mem[(y  )*WIDTH + (x+1)];
                p20 = image_mem[(y+1)*WIDTH + (x-1)];
                p21 = image_mem[(y+1)*WIDTH + (x  )];
                p22 = image_mem[(y+1)*WIDTH + (x+1)];

                load_window(p00,p01,p02,p10,p11,p12,p20,p21,p22);
                start_job();
                wait_for_done();
                apb_read(ADDR_RESULT, result_word);

                result_mem[y*WIDTH + x] = result_word[7:0];

                expected = sobel_ref(p00,p01,p02,p10,p11,p12,p20,p21,p22);
                total_checks++;
                if (result_word[7:0] !== expected) begin
                    failed_checks++;
                    if (printed_fails < 20) begin
                        $display("FAIL @ (x=%0d,y=%0d): expected=%0d actual=%0d",
                                  x, y, expected, result_word[7:0]);
                        printed_fails++;
                    end
                end else begin
                    passed_checks++;
                end
            end

            // Progress ping every 32 rows so a long run isn't silent
            if ((y % 32) == 0)
                $display("  ... row %0d / %0d done", y, HEIGHT-2);
        end
        t_end = $time;

        // ------------------------------------------------------
        // Write the result image out as hex for hex_to_png.py
        // ------------------------------------------------------
        fd = $fopen("output_image.hex", "w");
        if (fd == 0) begin
            $display("FATAL: could not open output_image.hex for writing");
            $finish;
        end
        for (y = 0; y < HEIGHT; y++) begin
            for (x = 0; x < WIDTH; x++) begin
                $fwrite(fd, "%02h\n", result_mem[y*WIDTH + x]);
            end
        end
        $fclose(fd);
        $display("Wrote output_image.hex (%0d pixels)", NPIX);

        // ------------------------------------------------------
        // Summary
        // ------------------------------------------------------
        $display("");
        $display("========================================");
        $display("FINAL TEST SUMMARY");
        $display("========================================");
        $display("Interior pixels checked : %0d", total_checks);
        $display("Passed                  : %0d", passed_checks);
        $display("Failed                  : %0d", failed_checks);
        $display("Sim time elapsed        : %0d ns", t_end - t_start);
        $display("========================================");
        if (failed_checks == 0) $display("RESULT: ALL PIXELS MATCH GOLDEN MODEL");
        else                    $display("RESULT: MISMATCHES DETECTED");

        $display("");
        $display("Next step: python3 hex_to_png.py   (produces edges_out.png)");
        $finish;
    end

endmodule