`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module cpu_tb;

    //-------------------------------------------------------------
    // Test Configuration
    //-------------------------------------------------------------
    localparam TEST_CASE = 0;
    localparam TEST_FILE = (TEST_CASE == 0)? "rv32im_test.hex": (TEST_CASE == 1)? "matmul_test.hex" : "";
    localparam MAX_CYCLES = 300;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;
    int cycle_count = 0;
    int instruction_count = 0;
    real ipc;

    //-------------------------------------------------------------
    // Clock and Reset
    //-------------------------------------------------------------
    logic clk;
    logic rst;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    cpu #(
        .TEST_FILE(TEST_FILE),
        .SIMPLE_MEM_MODE(1)
    ) dut (
        .clk(clk),
        .rst(rst)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------
    
    task automatic check_register(
        input string test_name,
        input int reg_num,
        input logic [31:0] expected_value
    );
        logic [31:0] actual_value;
        actual_value = dut.core0.rename_stage.prf_inst.data_reg[reg_num];
        
        assertions_checked++;
        if (actual_value == expected_value) begin
            $display("  [PASS] x%02d: %-30s | Got: 0x%08h", reg_num, test_name, actual_value);
            tests_passed++;
        end else begin
            $display("  [FAIL] x%02d: %-30s | Got: 0x%08h | Exp: 0x%08h", 
                     reg_num, test_name, actual_value, expected_value);
            tests_failed++;
        end
    endtask

    task automatic check_assertion(
        input string test_name,
        input logic condition,
        input string fail_msg
    );
        assertions_checked++;
        if (condition) begin
            $display("  [PASS] %s", test_name);
            tests_passed++;
        end else begin
            $display("  [FAIL] %s: %s", test_name, fail_msg);
            tests_failed++;
        end
    endtask

    task automatic wait_for_completion();
        logic [31:0] completion_reg;
        logic done;
        instruction_count = 0;
        done = 0;
        cycle_count = 1;
        
        $display("\n[INFO] Waiting for program completion (x31 = 0xFF)...\n");
        
        while (!done && cycle_count < MAX_CYCLES) begin
            @(posedge clk);
            cycle_count++;
            instruction_count += dut.core0.commit_stage.commit_cnt;
            ipc = real'(instruction_count) / real'(cycle_count);

            completion_reg = dut.core0.rename_stage.prf_inst.data_reg[31];
            
            if (completion_reg == 32'h000000FF) begin 
                done = 1;
                $display("[INFO] Program completed after %0d cycles", cycle_count);
                $display("[INFO] Instructions committed: %0d", instruction_count);
            end
        end
        
        if (!done) begin
            $display("[WARNING] Program did not complete within %0d cycles", MAX_CYCLES);
        end
        
        // Wait for pipeline to settle
        repeat(2) @(posedge clk);
        cycle_count += 2;
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("cpu_tb.vcd");
        $dumpvars(0, cpu_tb);
        
        $display("========================================");
        $display("  RV32IM CPU Testbench");
        $display("========================================");
        $display("  Test Program: %s", TEST_FILE);
        $display("  Max Cycles: %0d", MAX_CYCLES);
        $display("========================================\n");
        
        // Reset
        rst = 1;
        repeat(2) @(posedge clk);
        rst = 0;
        
        // Run Program
        wait_for_completion();
        
        // Final Stats
        dump_performance_stats();
        dump_registers();
        if (TEST_FILE == "rv32im_test.hex") begin
            //-------------------------------------------------------------
            // Verify Final Register State
            //-------------------------------------------------------------
            $display("\n========================================");
            $display("  Final State Verification");
            $display("========================================\n");
            
            // Test 1: Basic Arithmetic
            $display("=== Test 1: Basic Arithmetic ===");
            check_register("ADD (Overwritten by Store Setup)", 3, 32'h000000AB); // Runtime: 12
            check_register("SUB (Overwritten by Store Setup)", 4, 32'h00000123); // Runtime: 2
            
            // Test 2: Logical Operations
            $display("\n=== Test 2: Logical Operations ===");
            check_register("AND (Overwritten by Store Setup)", 5, 32'hFFFFFFFF); // Runtime: 5
            check_register("OR  (Overwritten by Store Setup)", 6, 32'hFFFFFFFF); // Runtime: 7
            check_register("XOR: 5 ^ 7",                       7, 32'd2);
            check_register("ANDI: 7 & 3",                      8, 32'd3);
            check_register("ORI: 5 | 8",                       9, 32'd13);
            check_register("XORI: 7 ^ 15",                     10, 32'd8);
            
            // Test 3: Shifts
            $display("\n=== Test 3: Shift Operations ===");
            check_register("SLLI (Overwritten by LW 42)",      11, 32'd42);         // Runtime: 20
            check_register("SRLI (Overwritten by LW 100)",     12, 32'd100);        // Runtime: 3
            check_register("ADDI (Overwritten by LBU 0xAB)",   13, 32'h000000AB);   // Runtime: -8
            check_register("SRAI (Overwritten by LB 0xAB)",    14, 32'hFFFFFFAB);   // Runtime: -4
            check_register("SLL  (Overwritten by LHU 0x123)",  15, 32'h00000123);   // Runtime: 640
            check_register("SRL  (Overwritten by LH 0x123)",   16, 32'h00000123);   // Runtime: 0
            check_register("SRA  (Overwritten by LB 0xFF)",    17, 32'hFFFFFFFF);   // Runtime: -1
            
            // Test 4: Comparisons
            $display("\n=== Test 4: Comparison Operations ===");
            check_register("SLT  (Overwritten by LBU 0xFF)",   18, 32'h000000FF);   // Runtime: 1
            check_register("SLT  (Overwritten by LH -1)",      19, 32'hFFFFFFFF);   // Runtime: 0
            check_register("SLTU (Overwritten by LHU -1)",     20, 32'h0000FFFF);   // Runtime: 0
            check_register("SLTI: 5 < 10",                     21, 32'd1);          
            check_register("SLTIU: 5 < 3",                     22, 32'd0);          
            
            // Test 5: Upper Immediates
            $display("\n=== Test 5: Upper Immediate Operations ===");
            check_register("LUI: 0x12345000",                  23, 32'h12345000); 
            check_assertion("AUIPC executed", 
                        dut.core0.rename_stage.prf_inst.data_reg[24] != 32'h0,
                        "AUIPC result is zero");
            
            // Test 6: Branches
            $display("\n=== Test 6: Branch Operations ===");
            check_register("Branches completed",               25, 32'd11);
            
            // Test 7: JAL/JALR
            $display("\n=== Test 7: JAL/JALR Operations ===");
            check_register("JAL/JALR completed",               25, 32'd11);
            check_assertion("JAL saved return address",
                        dut.core0.rename_stage.prf_inst.data_reg[26] != 32'h0,
                        "x26 is zero");
            check_assertion("JAL backward saved return",
                        dut.core0.rename_stage.prf_inst.data_reg[27] != 32'h0,
                        "x27 is zero");
            check_assertion("JALR saved return address",
                        dut.core0.rename_stage.prf_inst.data_reg[29] != 32'h0,
                        "x29 is zero");
            
            // Test 8: Memory Operations (Store then Load)
            $display("\n=== Test 8: Memory Operations ===");
            check_register("LW: Word load (42)",               11, 32'd42);
            check_register("LW: Word load (100)",              12, 32'd100);
            check_register("LBU: Unsigned byte (0xAB)",        13, 32'h000000AB);
            check_register("LB: Signed byte (0xAB)",           14, 32'hFFFFFFAB);
            check_register("LHU: Unsigned halfword (0x123)",   15, 32'h00000123);
            check_register("LH: Signed halfword (0x123)",      16, 32'h00000123);
            check_register("LB: Signed byte (0xFF)",           17, 32'hFFFFFFFF);
            check_register("LBU: Unsigned byte (0xFF)",        18, 32'h000000FF);
            check_register("LH: Signed halfword (0xFFFF)",     19, 32'hFFFFFFFF);
            check_register("LHU: Unsigned halfword (0xFFFF)",  20, 32'h0000FFFF);
            
            // Completion marker
            $display("\n=== Completion Check ===");
            check_register("Completion marker",                31, 32'hFF);
        end else if (TEST_FILE == "matmul_test.hex") begin
            // --------------------------------------------------------
            // TEST CASE 2: 4x4 Matrix Multiply Stress Test
            // --------------------------------------------------------

            // Total Checksum (Calculated in registers before final reload)
            // Sum(Matrix A) * Sum(Weights) = 78 * 20 = 1560
            $display("\n=== Integrity Checks ===");
            check_register("Total Checksum (x30)", 30, 32'd1560);
        end
        
        //-------------------------------------------------------------
        // Summary
        //-------------------------------------------------------------
        $display("\n========================================");
        $display("  Test Summary");
        $display("========================================");
        $display("  Execution Cycles:     %0d", cycle_count);
        $display("  Instructions Retired: %0d", instruction_count);
        $display("  IPC:                  %0.3f", ipc);
        $display("  Tests Passed:         %0d", tests_passed);
        $display("  Tests Failed:         %0d", tests_failed);
        $display("  Total Checks:         %0d", assertions_checked);
        $display("========================================");
        
        if (tests_failed == 0) begin
            $display("\n  ✓ ALL TESTS PASSED!\n");
        end else begin
            $display("\n  ✗ SOME TESTS FAILED!\n");
        end
        $display("========================================\n");
        
        if (tests_failed > 0) begin
            $fatal(1, "Test failures detected");
        end
        
        $finish;
    end

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------
    task automatic dump_registers();
        $display("\n========================================");
        $display("  Register File State");
        $display("========================================");
        for (int i = 0; i < 32; i += 4) begin
            $display("  x%02d=0x%08h  x%02d=0x%08h  x%02d=0x%08h  x%02d=0x%08h",
                     i,   dut.core0.rename_stage.prf_inst.data_reg[i],
                     i+1, dut.core0.rename_stage.prf_inst.data_reg[i+1],
                     i+2, dut.core0.rename_stage.prf_inst.data_reg[i+2],
                     i+3, dut.core0.rename_stage.prf_inst.data_reg[i+3]);
        end
        $display("========================================\n");
    endtask

    task automatic dump_performance_stats();
        $display("\n========================================");
        $display("  Performance Statistics");
        $display("========================================");
        $display("  Total Cycles:           %0d", cycle_count);
        $display("  Instructions Committed: %0d", instruction_count);
        if (cycle_count > 0 && instruction_count > 0) begin
            ipc = real'(instruction_count) / real'(cycle_count);
            $display("  IPC (Instructions/Cycle): %0.3f", ipc);
            $display("  CPI (Cycles/Instruction): %0.3f", 1.0/ipc);
        end
        $display("========================================\n");
    endtask

    //-------------------------------------------------------------
    // Timeout Watchdog
    //-------------------------------------------------------------
    initial begin
        #(MAX_CYCLES * CLK_PERIOD * 2);
        $display("\n[ERROR] Global testbench timeout!");
        $display("[ERROR] Cycles: %0d, Instructions: %0d", cycle_count, instruction_count);
        $finish;
    end

endmodule
