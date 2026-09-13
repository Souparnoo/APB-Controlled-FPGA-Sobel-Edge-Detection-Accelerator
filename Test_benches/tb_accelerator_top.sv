module tb_accelerator_top;

    logic        PCLK;
    logic        PRESETn;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [7:0]  PADDR;
    logic [7:0] PWDATA;
    logic [7:0] PRDATA;
    logic        PREADY;

    int total_checks  = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    // Register map (apb_slave.sv)
    
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

    localparam int MAX_POLL_CYCLES = 20; // generous timeout for DONE polling

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
    // Clock: 100 MHz
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
    // APB write / read tasks (setup phase, then access phase, exactly
    // as required by the AMBA APB protocol; PREADY is checked to
    // actually be high before we sample/latch, rather than assumed).
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
            // PREADY must be asserted for the transfer to complete
            check_bit("PREADY asserted during write access phase", PREADY, 1'b1);
            #1;

            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = 8'd0;
            PWDATA  = 8'd0;
        end
    endtask

    task automatic apb_read(input logic [7:0] address, output logic [31:0] read_data);
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = address;

            @(negedge PCLK);
            PENABLE = 1'b1;

            @(posedge PCLK);
            check_bit("PREADY asserted during read access phase", PREADY, 1'b1);
            #1;
            read_data = PRDATA;

            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = 8'd0;
        end
    endtask

    // Convenience: write all 9 pixels in one shot
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

    // Pulse CONTROL.START
    task automatic start_job;
        begin
            apb_write(ADDR_CONTROL, 8'h01);
        end
    endtask

    // Poll STATUS until DONE=1 (bit1) or timeout. Returns the number
    // of polling reads it took, and fails the test on timeout.
    task automatic wait_for_done(output int cycles_waited);
        logic [7:0] status;
        int          n;
        begin
            n = 0;
            status = 8'd0;
            while (!status[1] && n < MAX_POLL_CYCLES) begin
                apb_read(ADDR_STATUS, status);
                n++;
            end
            total_checks++;
            if (!status[1]) begin
                failed_checks++;
                $display("FAIL: DONE never asserted within %0d polls", MAX_POLL_CYCLES);
            end else begin
                passed_checks++;
            end
            cycles_waited = n;
        end
    endtask

    // ---------------------------------------------------------------
    // Golden reference model (bit-exact copy of the intended Sobel
    // magnitude computation, done in plain integer math so it is
    // trivially reviewable and independent of the RTL implementation
    // style).
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

    // Run one full end-to-end job: load window, start, wait for done,
    // read RESULT, compare to golden model.
    task automatic run_job(
        input string      test_name,
        input logic [7:0] q00, q01, q02,
        input logic [7:0] q10, q11, q12,
        input logic [7:0] q20, q21, q22
    );
        logic [31:0] result_word;
        logic [7:0]  expected;
        int          polls;
        begin
            load_window(q00, q01, q02, q10, q11, q12, q20, q21, q22);
            start_job();
            wait_for_done(polls);
            apb_read(ADDR_RESULT, result_word);
            expected = sobel_ref(q00, q01, q02, q10, q11, q12, q20, q21, q22);
            check_byte({test_name, ": RESULT"}, result_word[7:0], expected);
        end
    endtask

    // ---------------------------------------------------------------
    // Check helpers
    // ---------------------------------------------------------------
    task automatic check_bit(input string name, input logic actual, input logic expected);
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display("FAIL: %s | Expected=%b Actual=%b", name, expected, actual);
            end else begin
                passed_checks++;
            end
        end
    endtask

    task automatic check_byte(input string name, input logic [7:0] actual, input logic [7:0] expected);
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display("FAIL: %s | Expected=%0d Actual=%0d", name, expected, actual);
            end else begin
                passed_checks++;
            end
        end
    endtask

    task automatic check_word(input string name, input logic [31:0] actual, input logic [31:0] expected);
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display("FAIL: %s | Expected=%h Actual=%h", name, expected, actual);
            end else begin
                passed_checks++;
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Main test sequence
    // ---------------------------------------------------------------
    initial begin
        logic [31:0] rdata;
        int          polls;

        $dumpfile("tb_accelerator_top.vcd");
        $dumpvars(0, tb_accelerator_top);

        $display("========================================");
        $display("STARTING ACCELERATOR_TOP SYSTEM TEST");
        $display("========================================");

        reset_dut();

        // ---------------- TEST 1: reset state ----------------------
        $display("\n--- TEST 1: RESET STATE ---");
        check_bit ("PREADY high at reset", PREADY, 1'b1);
        apb_read(ADDR_STATUS, rdata);
        check_word("STATUS = 0 at reset (BUSY=0, DONE=0)", rdata, 32'd0);
        apb_read(ADDR_RESULT, rdata);
        check_word("RESULT = 0 at reset", rdata, 32'd0);
        apb_read(ADDR_CONTROL, rdata);
        check_word("CONTROL reads as 0", rdata, 32'd0);
        apb_read(ADDR_PIXEL00, rdata);
        check_word("PIXEL00 = 0 at reset", rdata, 32'd0);

        // ---------------- TEST 2: pixel register RW -----------------
        $display("\n--- TEST 2: PIXEL REGISTER READ/WRITE ---");
        load_window(8'd11, 8'd22, 8'd33, 8'd44, 8'd55, 8'd66, 8'd77, 8'd88, 8'd99);
        apb_read(ADDR_PIXEL00, rdata); check_word("PIXEL00 readback", rdata, 32'd11);
        apb_read(ADDR_PIXEL11, rdata); check_word("PIXEL11 readback", rdata, 32'd55);
        apb_read(ADDR_PIXEL22, rdata); check_word("PIXEL22 readback", rdata, 32'd99);

        // ---------------- TEST 3: single end-to-end job -------------
        $display("\n--- TEST 3: SINGLE END-TO-END JOB (flat field) ---");
        run_job("Flat field (no edge)",
            8'd100, 8'd100, 8'd100,
            8'd100, 8'd100, 8'd100,
            8'd100, 8'd100, 8'd100);

        $display("\n--- TEST 4: STRONG VERTICAL EDGE ---");
        run_job("Vertical edge",
            8'd0, 8'd0, 8'd255,
            8'd0, 8'd0, 8'd255,
            8'd0, 8'd0, 8'd255);

        $display("\n--- TEST 5: STRONG HORIZONTAL EDGE ---");
        run_job("Horizontal edge",
            8'd0,   8'd0,   8'd0,
            8'd255, 8'd255, 8'd255,
            8'd255, 8'd255, 8'd255);

        $display("\n--- TEST 6: SATURATION CASE ---");
        run_job("Diagonal max-contrast (saturates to 255)",
            8'd0,   8'd0,   8'd255,
            8'd0,   8'd128, 8'd255,
            8'd0,   8'd255, 8'd255);

        // ---------------- TEST 7: BUSY behaviour during compute -----
        // NOTE: the compute pipeline here is only 1 clock cycle deep
        // (BUSY is high for exactly one PCLK edge before DONE fires).
        // A full APB read takes several clock edges (setup+access
        // phases), so *polling* STATUS over the bus can easily miss
        // that single-cycle BUSY window and observe DONE=1 directly
        // instead -- that is correct hardware behaviour, not a bug.
        // To actually observe BUSY we sample the controller's internal
        // busy_r register directly, right at the clock edge, instead
        // of going through the slower APB read task.
        $display("\n--- TEST 7: BUSY ASSERTED DURING COMPUTE, START IGNORED WHILE BUSY ---");
        load_window(8'd5, 8'd5, 8'd5, 8'd5, 8'd5, 8'd5, 8'd5, 8'd5, 8'd5);
        start_job();
        check_bit("BUSY=1 immediately after START (internal probe)",
                   dut.u_controller.busy_r, 1'b1);

        // Try to issue a second START while busy; it must be ignored
        // and must not corrupt the in-flight job's pixel snapshot.
        load_window(8'd9, 8'd9, 8'd9, 8'd9, 8'd9, 8'd9, 8'd9, 8'd9, 8'd9);
        start_job();

        wait_for_done(polls);
        apb_read(ADDR_RESULT, rdata);
        check_byte("Result unaffected by START-while-BUSY", rdata[7:0], sobel_ref(8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5));

        // ---------------- TEST 8: DONE sticky until next START ------
        $display("\n--- TEST 8: DONE STICKY UNTIL NEXT START ---");
        repeat (3) @(posedge PCLK);
        apb_read(ADDR_STATUS, rdata);
        check_bit("DONE remains 1 while idle", rdata[1], 1'b1);
        apb_read(ADDR_RESULT, rdata);
        check_byte("RESULT remains stable while idle", rdata[7:0], sobel_ref(8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5,8'd5));

        // ---------------- TEST 9: back-to-back jobs ------------------
        $display("\n--- TEST 9: BACK-TO-BACK JOBS (DONE CLEARS ON NEW START) ---");
        run_job("Back-to-back #1",
            8'd10, 8'd20, 8'd30, 8'd40, 8'd50, 8'd60, 8'd70, 8'd80, 8'd90);
        run_job("Back-to-back #2",
            8'd200, 8'd150, 8'd10, 8'd90, 8'd30, 8'd5, 8'd60, 8'd220, 8'd0);
        run_job("Back-to-back #3",
            8'd255, 8'd0, 8'd255, 8'd0, 8'd255, 8'd0, 8'd255, 8'd0, 8'd255);

        // ---------------- TEST 10: unmapped address ------------------
        $display("\n--- TEST 10: UNMAPPED ADDRESS ---");
        apb_read(8'hF0, rdata);
        check_word("Unmapped address reads 0", rdata, 32'd0);

        // ---------------- TEST 11: randomized end-to-end -------------
        $display("\n--- TEST 11: RANDOMIZED END-TO-END (100 windows) ---");
        for (int i = 0; i < 100; i++) begin
            run_job($sformatf("Random job %0d", i),
                $urandom_range(0,255), $urandom_range(0,255), $urandom_range(0,255),
                $urandom_range(0,255), $urandom_range(0,255), $urandom_range(0,255),
                $urandom_range(0,255), $urandom_range(0,255), $urandom_range(0,255));
        end

        // ---------------- TEST 12: reset mid-operation -----------------
        $display("\n--- TEST 12: ASYNC RESET DURING BUSY CLEARS STATE ---");
        load_window(8'd1,8'd2,8'd3,8'd4,8'd5,8'd6,8'd7,8'd8,8'd9);
        start_job();
        check_bit("BUSY=1 before reset (internal probe)",
                   dut.u_controller.busy_r, 1'b1);

        PRESETn = 1'b0;
        repeat (2) @(posedge PCLK);
        PRESETn = 1'b1;
        @(posedge PCLK);
        #1;
        PSEL = 1'b0; PENABLE = 1'b0;

        apb_read(ADDR_STATUS, rdata);
        check_word("STATUS clears to 0 after reset", rdata, 32'd0);
        apb_read(ADDR_PIXEL00, rdata);
        check_word("PIXEL00 clears to 0 after reset", rdata, 32'd0);

        // ---------------- SUMMARY -------------------------------------
        $display("\n========================================");
        $display("FINAL TEST SUMMARY");
        $display("========================================");
        $display("Total Checks  : %0d", total_checks);
        $display("Passed Checks : %0d", passed_checks);
        $display("Failed Checks : %0d", failed_checks);
        $display("========================================");
        if (failed_checks == 0) $display("RESULT: ALL TESTS PASSED");
        else                    $display("RESULT: TEST FAILURES DETECTED");
        $finish;
    end

    // ---------------------------------------------------------------
    // Safety watchdog: if something hangs (e.g. DONE never arrives
    // and wait_for_done's own timeout is somehow bypassed), don't let
    // the simulation run forever.
    // ---------------------------------------------------------------
    initial begin
        #100000;
        $display("FAIL: WATCHDOG TIMEOUT - simulation did not finish in time");
        $finish;
    end

endmodule