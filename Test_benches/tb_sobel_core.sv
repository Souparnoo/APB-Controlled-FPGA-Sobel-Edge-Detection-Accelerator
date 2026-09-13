module tb_sobel_core;
    // DUT INPUT SIGNALS
    logic [7:0] p00;
    logic [7:0] p01;
    logic [7:0] p02;
    logic [7:0] p10;
    logic [7:0] p11;
    logic [7:0] p12;
    logic [7:0] p20;
    logic [7:0] p21;
    logic [7:0] p22;
    // DUT OUTPUT SIGNAL
    logic [7:0] magnitude;
    // TEST STATISTICS
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;

    sobel_core dut (
        .p00(p00),
        .p01(p01),
        .p02(p02),
        .p10(p10),
        .p11(p11),
        .p12(p12),
        .p20(p20),
        .p21(p21),
        .p22(p22),
        .magnitude_o(magnitude)
    );

    // REFERENCE MODEL
    function automatic logic [7:0] sobel_ref(
        input logic [7:0] rp00,
        input logic [7:0] rp01,
        input logic [7:0] rp02,
        input logic [7:0] rp10,
        input logic [7:0] rp11,
        input logic [7:0] rp12,
        input logic [7:0] rp20,
        input logic [7:0] rp21,
        input logic [7:0] rp22
    );
        int p00_i, p01_i, p02_i;
        int p10_i, p11_i, p12_i;
        int p20_i, p21_i, p22_i;
        int gx, gy, rmagnitude;
        
        begin
        //safety due to unsigned to signed calculation
            p00_i = rp00;
            p01_i = rp01;
            p02_i = rp02;
            p10_i = rp10;
            p11_i = rp11;
            p12_i = rp12;
            p20_i = rp20;
            p21_i = rp21;
            p22_i = rp22;
            gx =(p02_i-p00_i)+2*(p12_i-p10_i)+(p22_i-p20_i);
            gy =(p20_i-p00_i)+2*(p21_i-p01_i)+ (p22_i-p02_i );
            rmagnitude =((gx<0)?-gx:gx)+((gy<0)?-gy:gy);
            if (rmagnitude > 255) sobel_ref = 8'd255;
            else sobel_ref = rmagnitude[7:0];
        end
    endfunction

    // CHECK TASK
    task automatic run_ref_case(

        input string test_name,

        input logic [7:0] tp00,
        input logic [7:0] tp01,
        input logic [7:0] tp02,
        input logic [7:0] tp10,
        input logic [7:0] tp11,
        input logic [7:0] tp12,
        input logic [7:0] tp20,
        input logic [7:0] tp21,
        input logic [7:0] tp22
    );
        logic [7:0] expected;
        begin
            p00 = tp00;
            p01 = tp01;
            p02 = tp02;
            p10 = tp10;
            p11 = tp11;
            p12 = tp12;
            p20 = tp20;
            p21 = tp21;
            p22 = tp22;

            // Combinational logic settle
            #1;

            // Count this test
            total_tests++;

            expected = sobel_ref(
                tp00,
                tp01,
                tp02,
                tp10,
                tp11,
                tp12,
                tp20,
                tp21,
                tp22
            );

            // Compare actual vs expected
            if (magnitude !== expected) begin
                failed_tests++;
                $display("FAIL: %s", test_name);
                $display(
                    "Pixels: [%0d %0d %0d]",tp00,tp01,tp02
                );
                $display(
                    "        [%0d %0d %0d]",tp10,tp11,tp12
                );
                $display(
                    "        [%0d %0d %0d]",tp20,tp21,tp22
                );
                $display(
                    "Expected = %0d, Actual = %0d",expected,magnitude
                );
            end
            else begin
                passed_tests++;
            end
        end
    endtask

    initial begin

    // Waveform dumping
        $dumpfile("tb_sobel_core_upgraded.vcd");
        $dumpvars(0, tb_sobel_core);

        // DIRECTED TESTS
        $display("========================================");
        $display("STARTING DIRECTED TESTS");
        $display("========================================");

        run_ref_case(
            "All zeros",
            8'd0, 8'd0, 8'd0,
            8'd0, 8'd0, 8'd0,
            8'd0, 8'd0, 8'd0
        );
        run_ref_case(
            "Horizontal edge",
            8'd0,   8'd0,   8'd0,
            8'd255, 8'd255, 8'd255,
            8'd255, 8'd255, 8'd255
        );
        run_ref_case(
            "Strong edge",
            8'd0,   8'd0,   8'd255,
            8'd0,   8'd0,   8'd255,
            8'd0,   8'd0,   8'd255
        );

        // p00 = 0 to 255
        // p02 = 0 to 255
        $display("========================================");
        $display("STARTING REDUCED EXHAUSTIVE TEST");
        $display("Testing p00 x p02");
        $display("========================================");
        for (int a = 0; a < 256; a++) begin
            for (int b = 0; b < 256; b++) begin
                run_ref_case(
                    "Exhaustive p00/p02",
                    a[7:0], 8'd0, b[7:0],
                    8'd0,  8'd0, 8'd0,
                    8'd0,  8'd0, 8'd0
                );
            end
        end

        $display("========================================");
        $display("STARTING RANDOM TESTS");
        $display("========================================");

        for (int test = 0; test < 1000; test++) begin
            run_ref_case(
                "Random test",
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255),
                $urandom_range(0, 255)
            );
        end
        $display("");
        $display("========================================");
        $display("FINAL TEST SUMMARY");
        $display("========================================");

        $display("Total Tests  : %0d", total_tests);
        $display("Passed Tests : %0d", passed_tests);
        $display("Failed Tests : %0d", failed_tests);

        $display("========================================");
        if (failed_tests == 0)$display("RESULT: ALL TESTS PASSED");
        else $display("RESULT: TEST FAILURES DETECTED");
        $finish;
    end
endmodule