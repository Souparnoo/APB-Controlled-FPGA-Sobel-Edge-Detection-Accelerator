module tb_apb_slave;
    logic        PCLK;
    logic        PRESETn;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [7:0]  PADDR;
    logic [7:0] PWDATA;
    logic [7:0] PRDATA;
    logic        PREADY;

    logic        start_pulse_o;

    logic [7:0] p00_o, p01_o, p02_o;
    logic [7:0] p10_o, p11_o, p12_o;
    logic [7:0] p20_o, p21_o, p22_o;

    logic       busy_i;
    logic       done_i;
    logic [7:0] result_i;

    int total_checks  = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    apb_slave dut (

        .PCLK(PCLK),
        .PRESETn(PRESETn),
        .PSEL(PSEL),
        .PENABLE(PENABLE),
        .PWRITE(PWRITE),
        .PADDR(PADDR),
        .PWDATA(PWDATA),
        .PRDATA(PRDATA),
        .PREADY(PREADY),
        // To controller
        .start_pulse_o(start_pulse_o),
        .p00_o(p00_o),.p01_o(p01_o),.p02_o(p02_o),
        .p10_o(p10_o),.p11_o(p11_o),.p12_o(p12_o),
        .p20_o(p20_o),.p21_o(p21_o),.p22_o(p22_o),
        // From controller
        .busy_i(busy_i),
        .done_i(done_i),
        .result_i(result_i)
    );
    // CLOCK
    initial begin
        PCLK = 1'b0;
        forever begin
            #5 PCLK = ~PCLK;
        end
    end
    task automatic reset_dut;
        begin
            PRESETn = 1'b0;
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = 8'd0;
            PWDATA  = 8'd0;
            busy_i   = 1'b0;
            done_i   = 1'b0;
            result_i = 8'd0;
            // Keep reset active for two clock cycles
            repeat (2) @(posedge PCLK);
            PRESETn = 1'b1;
            @(posedge PCLK);
            #1;
        end
    endtask

    // APB WRITE:
    //
    // SETUP:
    // PSEL    = 1
    // PENABLE = 0
    // PWRITE  = 1
    //
    // ACCESS:
    // PSEL    = 1
    // PENABLE = 1

    task automatic apb_write(
        input logic [7:0]  address,
        input logic [31:0] data
    );

        begin
            @(negedge PCLK);

            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b1;

            PADDR   = address;
            PWDATA  = data;

            // ACCESS PHASE
            @(negedge PCLK);
            PENABLE = 1'b1;

            // Write occurs at following positive edge
            @(posedge PCLK);
            #1;

            //return to idle
            @(negedge PCLK);

            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = 8'd0;
            PWDATA  = 8'd0;
        end
    endtask

    // APB READ TASK

    task automatic apb_read(
        input  logic [7:0]  address,
        output logic [7:0] read_data
    );
        begin

            // SETUP PHASE
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = address;

            // ACCESS PHASE
            @(negedge PCLK);
            PENABLE = 1'b1;

            // PRDATA is combinational
            @(posedge PCLK);
            #1;

            read_data = PRDATA;

            // RETURN TO IDLE

            @(negedge PCLK);

            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = 8'd0;
        end
    endtask

    // SINGLE BIT CHECK
    task automatic check_bit(
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
                $display("PASS: %s", check_name);
            end
        end
    endtask

    // 8-BIT CHECK
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
                $display("PASS: %s", check_name);
            end
        end
    endtask

    // 32-BIT CHECK
    task automatic check_word(
        input string check_name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        begin
            total_checks++;
            if (actual !== expected) begin
                failed_checks++;
                $display(
                    "FAIL: %s | Expected = %h, Actual = %h",
                    check_name,
                    expected,
                    actual
                );
            end
            else begin
                passed_checks++;
                $display("PASS: %s", check_name);
            end
        end
    endtask


    initial begin : main_test

        logic [7:0] read_data;

        // WAVEFORM

        $dumpfile("tb_apb_slave.vcd");
        $dumpvars(0, tb_apb_slave);


        $display("");
        $display("========================================");
        $display("STARTING APB SLAVE TEST");
        $display("========================================");

        // RESET
        reset_dut();

        $display("");
        $display("----------------------------------------");
        $display("TEST 1: RESET");
        $display("----------------------------------------");


        check_bit("PREADY should always be 1", PREADY,1'b1);
        check_byte("RESET p00",p00_o,8'd0);
        check_byte("RESET p01",p01_o,8'd0);
        check_byte("RESET p02",p02_o,8'd0);
        check_byte("RESET p10",p10_o,8'd0);
        check_byte("RESET p11",p11_o,8'd0);
        check_byte("RESET p12",p12_o,8'd0);
        check_byte("RESET p20",p20_o,8'd0);
        check_byte("RESET p21",p21_o,8'd0);
        check_byte("RESET p22",p22_o,8'd0);
        

        // TEST 2
        // WRITE ALL PIXEL REGISTERS

        $display("");
        $display("----------------------------------------");
        $display("TEST 2: PIXEL REGISTER WRITES");
        $display("----------------------------------------");

        apb_write(8'h08, 8'd10);
        apb_write(8'h0C, 8'd20);
        apb_write(8'h10, 8'd30);
        apb_write(8'h14, 8'd40);
        apb_write(8'h18, 8'd50);
        apb_write(8'h1C, 8'd60);
        apb_write(8'h20, 8'd70);
        apb_write(8'h24, 8'd80);
        apb_write(8'h28, 8'd90);


        check_byte("WRITE p00", p00_o, 8'd10);
        check_byte("WRITE p01", p01_o, 8'd20);
        check_byte("WRITE p02", p02_o, 8'd30);
        check_byte("WRITE p10", p10_o, 8'd40);
        check_byte("WRITE p11", p11_o, 8'd50);
        check_byte("WRITE p12", p12_o, 8'd60);
        check_byte("WRITE p20", p20_o, 8'd70);
        check_byte("WRITE p21", p21_o, 8'd80);
        check_byte("WRITE p22", p22_o, 8'd90);


        // TEST 3
        // READ BACK PIXEL REGISTERS

        $display("");
        $display("----------------------------------------");
        $display("TEST 3: PIXEL REGISTER READBACK");
        $display("----------------------------------------");


        apb_read(8'h08, read_data);
        check_word("READ p00",read_data,8'd10);

        apb_read(8'h0C, read_data);
        check_word("READ p01",read_data,8'd20);

        apb_read(8'h10, read_data);
        check_word("READ p02",read_data,8'd30);

        apb_read(8'h14, read_data);
        check_word("READ p10",read_data,8'd40);


        apb_read(8'h18, read_data);
        check_word("READ p11",read_data,8'd50);

        apb_read(8'h1C, read_data);
        check_word("READ p12",read_data,8'd60);

        apb_read(8'h20, read_data);
        check_word("READ p20",read_data,8'd70);

        apb_read(8'h24, read_data);
        check_word("READ p21",read_data,8'd80);


        apb_read(8'h28, read_data);
        check_word("READ p22",read_data,8'd90);


        // TEST 4
        // CONTROL START PULSE

        $display("");
        $display("----------------------------------------");
        $display("TEST 4: CONTROL START PULSE");
        $display("----------------------------------------");


        // START should be low before transaction
        check_bit("START initially low",start_pulse_o,1'b0);

        apb_write(8'h00, 8'h01);

        // Check that START is asserted during the write transaction
        check_bit("START pulse asserted", start_pulse_o, 1'b1);

        #1;

        // Check that START returns low after transaction
        check_bit("START pulse deasserted", start_pulse_o, 1'b0);


        // TEST 5
        // STATUS REGISTER

        $display("");
        $display("----------------------------------------");
        $display("TEST 5: STATUS REGISTER");
        $display("----------------------------------------");

        busy_i = 1'b1;
        done_i = 1'b0;
        #1;

        apb_read(8'h04, read_data);
        check_word("STATUS BUSY=1 DONE=0",read_data,8'h01);

        busy_i = 1'b0;
        done_i = 1'b1;
        #1;

        apb_read(8'h04, read_data);

        check_word("STATUS BUSY=0 DONE=1",read_data,8'h02);

        busy_i = 1'b1;
        done_i = 1'b1;
        #1;

        apb_read(8'h04, read_data);

        check_word("STATUS BUSY=1 DONE=1",read_data,8'h03);


        // TEST 6
        // RESULT REGISTER

        $display("");
        $display("----------------------------------------");
        $display("TEST 6: RESULT REGISTER");
        $display("----------------------------------------");


        result_i = 8'd173;
        #1;

        apb_read(8'h2C, read_data);

        check_word("RESULT readback",read_data,8'd173);


        // TEST 7
        // CONTROL READ SHOULD RETURN ZERO

        $display("");
        $display("----------------------------------------");
        $display("TEST 7: CONTROL READBACK");
        $display("----------------------------------------");


        apb_read(8'h00, read_data);

        check_word("CONTROL reads as zero",read_data,8'd0);


        // TEST 8
        // UNMAPPED ADDRESS

        $display("");
        $display("----------------------------------------");
        $display("TEST 8: UNMAPPED ADDRESS");
        $display("----------------------------------------");


        apb_read(8'hF0, read_data);

        check_word("Unmapped read returns zero",read_data,8'd0);


        // FINAL SUMMARY

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