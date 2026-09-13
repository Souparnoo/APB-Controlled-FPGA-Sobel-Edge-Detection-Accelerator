module tb_controller;
    logic PCLK;
    logic PRESETn;
    // From APB slave
    logic start_pulse_i;

    logic [7:0] p00_i, p01_i, p02_i;
    logic [7:0] p10_i, p11_i, p12_i;
    logic [7:0] p20_i, p21_i, p22_i;
    // From Sobel core
    logic [7:0] sobel_result_i;
    // To APB slave
    logic busy_o;
    logic done_o;
    logic [7:0] result_o;
    // To Sobel core
    logic [7:0] cp00_o, cp01_o, cp02_o;
    logic [7:0] cp10_o, cp11_o, cp12_o;
    logic [7:0] cp20_o, cp21_o, cp22_o;

    int total_checks  = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    controller dut (

        .PCLK(PCLK),
        .PRESETn(PRESETn),

        // From APB slave
        .start_pulse_i(start_pulse_i),

        .p00_i(p00_i),
        .p01_i(p01_i),
        .p02_i(p02_i),
        .p10_i(p10_i),
        .p11_i(p11_i),
        .p12_i(p12_i),
        .p20_i(p20_i),
        .p21_i(p21_i),
        .p22_i(p22_i),

        // To APB slave
        .busy_o(busy_o),
        .done_o(done_o),
        .result_o(result_o),

        // To Sobel core
        .cp00_o(cp00_o),
        .cp01_o(cp01_o),
        .cp02_o(cp02_o),
        .cp10_o(cp10_o),
        .cp11_o(cp11_o),
        .cp12_o(cp12_o),
        .cp20_o(cp20_o),
        .cp21_o(cp21_o),
        .cp22_o(cp22_o),

        // From Sobel core
        .sobel_result_i(sobel_result_i)

    );

    task automatic send_start;
        begin
            // applying start at neg edge of clock to ensure controller samples it at posedge
            @(negedge PCLK);
            start_pulse_i = 1'b1;

            // Controller samples START here
            @(posedge PCLK);
            #1;

            // Remove START away at negedge
            @(negedge PCLK);
            start_pulse_i = 1'b0;
        end
    endtask

    //clock
    initial begin
        PCLK = 1'b0;
        forever begin
            #5 PCLK = ~PCLK;
        end
    end

    // RESET TASK just to reset before testing
    task automatic reset_dut;
        begin
            PRESETn = 1'b0;
            start_pulse_i = 1'b0;
            p00_i = 8'd0;
            p01_i = 8'd0;
            p02_i = 8'd0;
            p10_i = 8'd0;
            p11_i = 8'd0;
            p12_i = 8'd0;
            p20_i = 8'd0;
            p21_i = 8'd0;
            p22_i = 8'd0;
            sobel_result_i = 8'd0;
            // Hold reset for two clock cycles
            repeat (2) @(posedge PCLK);
            PRESETn = 1'b1;
            @(posedge PCLK);
        end
    endtask

    // REUSABLE CHECK TASK
    task automatic check_value(
        input string check_name,
        input logic actual,
        input logic expected
    );
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display(
                    "FAIL: %s | Expected = %b, Actual = %b",
                    check_name,
                    expected,
                    actual
                );
            end
            else begin
                passed_checks++;
                $display(
                    "PASS: %s",
                    check_name
                );
            end
        end
    endtask

    // 8-BIT CHECK TASK

    task automatic check_byte(
        input string check_name,
        input logic [7:0] actual,
        input logic [7:0] expected
    );
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display(
                    "FAIL: %s | Expected = %0d, Actual = %0d",
                    check_name,
                    expected,
                    actual
                );
            end
            else begin
                passed_checks++;
                $display(
                    "PASS: %s",
                    check_name
                );
            end
        end
    endtask

    initial begin

        total_checks  = 0;
        passed_checks = 0;
        failed_checks = 0;
        // WAVEFORM DUMPING
        $dumpfile("tb_controller.vcd");
        $dumpvars(0, tb_controller);

        $display("");
        $display("========================================");
        $display("STARTING CONTROLLER TEST");
        $display("========================================");

        reset_dut(); // After reset, controller should be idle

        check_value("RESET: BUSY should be 0",busy_o,1'b0);
        check_value("RESET: DONE should be 0",done_o,1'b0);
        check_byte("RESET: RESULT should be 0",result_o,8'd0);

        // TEST 1
        // START CAUSES PIXEL SNAPSHOT

        $display("");
        $display("----------------------------------------");
        $display("TEST 1: START AND SNAPSHOT");
        $display("----------------------------------------");

        // Give controller some pixel values
        p00_i = $urandom_range(0, 255);
        p01_i = $urandom_range(0, 255);
        p02_i = $urandom_range(0, 255);
        p10_i = $urandom_range(0, 255);
        p11_i = $urandom_range(0, 255);
        p12_i = $urandom_range(0, 255);
        p20_i = $urandom_range(0, 255);
        p21_i = $urandom_range(0, 255);
        p22_i = $urandom_range(0, 255);

        send_start(); // Send a start pulse to the controller

        check_value("START: BUSY should become 1",busy_o,1'b1);
        check_value("START: DONE should be 0",done_o,1'b0);
        check_byte("SNAPSHOT p00", cp00_o, p00_i);
        check_byte("SNAPSHOT p01", cp01_o, p01_i);
        check_byte("SNAPSHOT p02", cp02_o, p02_i);
        check_byte("SNAPSHOT p10", cp10_o, p10_i);
        check_byte("SNAPSHOT p11", cp11_o, p11_i);
        check_byte("SNAPSHOT p12", cp12_o, p12_i);
        check_byte("SNAPSHOT p20", cp20_o, p20_i);
        check_byte("SNAPSHOT p21", cp21_o, p21_i);
        check_byte("SNAPSHOT p22", cp22_o, p22_i);


        // TEST 2
        // COMPUTE CYCLE

        $display("");
        $display("----------------------------------------");
        $display("TEST 2: RESULT CAPTURE");
        $display("----------------------------------------");

        sobel_result_i = $urandom_range(0, 255);

        @(posedge PCLK);
        #1;
        check_value("COMPUTE: BUSY should return to 0",busy_o,1'b0);
        check_value("COMPUTE: DONE should become 1",done_o,1'b1);
        check_byte("COMPUTE: RESULT should be captured",result_o,sobel_result_i);


        // TEST 3
        // DONE SHOULD BE STICKY

        $display("");
        $display("----------------------------------------");
        $display("TEST 3: DONE STICKY");
        $display("----------------------------------------");

        repeat (3) @(posedge PCLK);
        #1;
        check_value("DONE should remain 1 while idle",done_o,1'b1);
        check_byte("RESULT should remain unchanged",result_o,sobel_result_i);


        // TEST 4
        // NEW START CLEARS DONE

        $display("");
        $display("----------------------------------------");
        $display("TEST 4: NEW START CLEARS DONE");
        $display("----------------------------------------");

        p00_i = 8'd1;
        p01_i = 8'd2;
        p02_i = 8'd3;
        p10_i = 8'd4;
        p11_i = 8'd5;
        p12_i = 8'd6;
        p20_i = 8'd7;
        p21_i = 8'd8;
        p22_i = 8'd9;

        send_start(); // Send a start pulse to the controller

        check_value("NEW START: BUSY should be 1",busy_o,1'b1);
        check_value("NEW START: DONE should clear to 0",done_o,1'b0);


        // TEST 5
        // START WHILE BUSY SHOULD BE IGNORED

        $display("");
        $display("----------------------------------------");
        $display("TEST 5: START WHILE BUSY");
        $display("----------------------------------------");

        p00_i = 8'd200;
        p01_i = 8'd201;
        p02_i = 8'd202;
        p10_i = 8'd203;
        p11_i = 8'd204;
        p12_i = 8'd205;
        p20_i = 8'd206;
        p21_i = 8'd207;
        p22_i = 8'd208;

        #1;
        start_pulse_i = 1'b1;
        @(posedge PCLK);
        #1;

        // Check that old snapshot remained
        check_byte("BUSY START ignored: p00 unchanged",cp00_o,8'd1);
        check_byte("BUSY START ignored: p01 unchanged",cp01_o,8'd2);
        check_byte("BUSY START ignored: p02 unchanged",cp02_o,8'd3);
        check_byte("BUSY START ignored: p10 unchanged",cp10_o,8'd4);
        check_byte("BUSY START ignored: p11 unchanged",cp11_o,8'd5);
        check_byte("BUSY START ignored: p12 unchanged",cp12_o,8'd6);
        check_byte("BUSY START ignored: p20 unchanged",cp20_o,8'd7);
        check_byte("BUSY START ignored: p21 unchanged",cp21_o,8'd8);
        check_byte("BUSY START ignored: p22 unchanged",cp22_o,8'd9);


        // TEST 6
        // RESULT AFTER SECOND COMPUTATION (already done in test 5)

        $display("");
        $display("----------------------------------------");
        $display("TEST 6: SECOND RESULT");
        $display("----------------------------------------");

        check_value("SECOND COMPUTE: BUSY should be 0",busy_o,1'b0);
        check_value("SECOND COMPUTE: DONE should be 1",done_o,1'b1);


        $display("");
        $display("========================================");
        $display("FINAL TEST SUMMARY");
        $display("========================================");

        $display("Total Checks  : %0d", total_checks);
        $display("Passed Checks : %0d", passed_checks);
        $display("Failed Checks : %0d", failed_checks);

        $display("========================================");

        if (failed_checks == 0) $display("RESULT: ALL TESTS PASSED");
        else $display("RESULT: TEST FAILURES DETECTED");
        $finish;
    end
endmodule