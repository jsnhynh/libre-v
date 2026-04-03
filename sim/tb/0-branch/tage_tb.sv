`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module tage_tb;

  // ------------------------------------------------------------
  // Stats
  // ------------------------------------------------------------
  int tests_passed = 0;
  int tests_failed = 0;

  // ------------------------------------------------------------
  // Clock/Reset
  // ------------------------------------------------------------
  logic clk = 1'b0;
  logic rst;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ------------------------------------------------------------
  // DUT I/O (match RTL shapes)
  // ------------------------------------------------------------
  logic [FETCH_WIDTH-1:0][CPU_ADDR_BITS-1:0] pc;
  tage_pred_t       [FETCH_WIDTH-1:0]   pred_ports;
  tage_ghr_t        [FETCH_WIDTH-1:0]   ghr_ports;
  tage_update_t     [FETCH_WIDTH-1:0]   update_ports;
  logic [GHR_WIDTH-1:0]                      ghr;

  // ------------------------------------------------------------
  // Module-scope temps (Verilator-friendly)
  // ------------------------------------------------------------
  localparam int BASE_IDX_WIDTH = $clog2(BASE_ENTRIES);
  localparam int TAG_IDX_WIDTH  = $clog2(TAGE_ENTRIES);

  // tuple snapshots
  logic [$clog2(TAGE_TABLES):0] prov0, prov1;
  logic                         pred0, alt0, pred1, alt1;

  // checkpoints
  logic [GHR_WIDTH-1:0]         ghr_cp0, ghr_cp1;
  logic [GHR_WIDTH-1:0]         ghr_saved;

  // misc
  int                           onehot_violations;

  int unsigned                  idx_a, idx_b;
  logic [1:0]                   base_before_a, base_after_a;
  logic [1:0]                   base_before_b, base_after_b;

  // used in tests 9/10
  logic                         act0, act1;

  // ------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------
  tage dut (
    .clk(clk),
    .rst(rst),
    .pc(pc),
    .pred_ports(pred_ports),
    .ghr_ports(ghr_ports),
    .update_ports(update_ports),
    .ghr(ghr)
  );

  // ------------------------------------------------------------
  // Small helpers
  // ------------------------------------------------------------
  function automatic int unsigned base_index(input logic [CPU_ADDR_BITS-1:0] pc_in);
    base_index = int'(pc_in[BASE_IDX_WIDTH+1:2]);
  endfunction

  function automatic logic [1:0] base_ctr_ref_next(input logic [1:0] ctr, input logic taken);
    base_ctr_ref_next = taken ? ((ctr == 2'b11) ? ctr : (ctr + 2'b01))
                              : ((ctr == 2'b00) ? ctr : (ctr - 2'b01));
  endfunction

  task automatic pass(input string msg);
    $display("  [PASS] %s", msg);
    tests_passed++;
  endtask

  task automatic fail(input string msg);
    $display("  [FAIL] %s", msg);
    tests_failed++;
  endtask

  task automatic info(input string msg);
    $display("  [INFO] %s", msg);
  endtask

  task automatic header(input string msg);
    $display("\n[%s]", msg);
  endtask

  task automatic clear_signals();
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      pc[i]           = '0;
      ghr_ports[i]    = '0;
      update_ports[i] = '{default:'0};
    end
  endtask

  task automatic do_reset();
    @(negedge clk);
    rst = 1'b1;
    clear_signals();
    @(negedge clk);
    @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
  endtask

  // Drive PCs on negedge
  task automatic drive_fetch(input logic [CPU_ADDR_BITS-1:0] pc0,
                             input logic [CPU_ADDR_BITS-1:0] pc1);
    @(negedge clk);
    pc[0] = pc0;
    pc[1] = pc1;
    ghr_ports[0] = '0;
    ghr_ports[1] = '0;
  endtask

  // Sample after next posedge + #1
  task automatic sample();
    @(posedge clk);
    #1;
  endtask

  task automatic fetch_and_sample(input logic [CPU_ADDR_BITS-1:0] pc0,
                                  input logic [CPU_ADDR_BITS-1:0] pc1);
    drive_fetch(pc0, pc1);
    sample();
  endtask

  // Snapshot tuple (provider/pred/alt) for commit feedback
  task automatic sample_tuple(input int slot,
                              output logic [$clog2(TAGE_TABLES):0] prov,
                              output logic pred,
                              output logic alt);
    prov = pred_ports[slot].provider;
    pred = pred_ports[slot].pred_taken;
    alt  = pred_ports[slot].pred_alt;
  endtask

  // Dispatch pulse
  task automatic do_dispatch(input int slot, input logic taken_bit);
    @(negedge clk);
    ghr_ports[0] = '0;
    ghr_ports[1] = '0;
    ghr_ports[slot].val   = 1'b1;
    ghr_ports[slot].taken = taken_bit;
    @(negedge clk);
    ghr_ports[0] = '0;
    ghr_ports[1] = '0;
  endtask

  // Dispatch pulse + onehot check
  task automatic do_dispatch_checked(input int slot, input logic taken_bit, input string tag);
    @(negedge clk);
    ghr_ports[0] = '0;
    ghr_ports[1] = '0;
    ghr_ports[slot].val   = 1'b1;
    ghr_ports[slot].taken = taken_bit;

    if (!$onehot0({ghr_ports[1].val, ghr_ports[0].val})) begin
      $display("  [FAIL] %s : ghr_ports.val=%b", tag, {ghr_ports[1].val, ghr_ports[0].val});
      tests_failed++;
    end else begin
      $display("  [PASS] %s : ghr_ports.val=%b", tag, {ghr_ports[1].val, ghr_ports[0].val});
      tests_passed++;
    end

    @(negedge clk);
    ghr_ports[0] = '0;
    ghr_ports[1] = '0;
  endtask

  // Commit pulse (val high across one posedge)
  task automatic do_commit(
    input int                           slot,
    input logic [CPU_ADDR_BITS-1:0]     commit_pc,
    input logic                         actual_taken,
    input logic [$clog2(TAGE_TABLES):0] provider,
    input logic                         pred_taken,
    input logic                         pred_alt,
    input logic [GHR_WIDTH-1:0]         ghr_cp_in
  );
    @(negedge clk);
    update_ports[slot].val          = 1'b1;
    update_ports[slot].pc           = commit_pc;
    update_ports[slot].actual_taken = actual_taken;
    update_ports[slot].provider     = provider;
    update_ports[slot].pred_taken   = pred_taken;
    update_ports[slot].pred_alt     = pred_alt;
    update_ports[slot].ghr_cp       = ghr_cp_in;
    @(negedge clk);
    update_ports[slot].val          = 1'b0;
  endtask

  task automatic check_pred(
    input string name,
    input int slot,
    input logic exp_taken,
    input bit   check_provider = 1'b0,
    input logic [$clog2(TAGE_TABLES):0] exp_provider = TAGE_TABLES
  );
    logic ok;
    ok = (pred_ports[slot].pred_taken === exp_taken);
    if (check_provider) ok &= (pred_ports[slot].provider === exp_provider);

    if (ok) begin
      $display("  [PASS] %s : slot%0d pred=%0d provider=%0d",
               name, slot, pred_ports[slot].pred_taken, pred_ports[slot].provider);
      tests_passed++;
    end else begin
      $display("  [FAIL] %s : slot%0d pred=%0d(exp %0d) provider=%0d(exp %0d)",
               name, slot,
               pred_ports[slot].pred_taken, exp_taken,
               pred_ports[slot].provider, exp_provider);
      tests_failed++;
    end
  endtask

  task automatic check_ghr_eq(input string name, input logic [GHR_WIDTH-1:0] exp);
    if (ghr === exp) begin
      $display("  [PASS] %s : ghr=0x%08h", name, ghr);
      tests_passed++;
    end else begin
      $display("  [FAIL] %s : ghr=0x%08h (exp 0x%08h)", name, ghr, exp);
      tests_failed++;
    end
  endtask

  // ------------------------------------------------------------
  // Main
  // ------------------------------------------------------------
  initial begin
    $dumpfile("tage_tb.vcd");
    $dumpvars(0, tage_tb);

    $display("========================================");
    $display("  TAGE Testbench (Comprehensive, ROB-accurate)");
    $display("========================================");
    $display("  GHR_WIDTH    = %0d", GHR_WIDTH);
    $display("  TABLES       = %0d", TAGE_TABLES);
    $display("  BASE_ENTRIES = %0d", BASE_ENTRIES);
    $display("  TAGE_ENTRIES = %0d", TAGE_ENTRIES);
    $display("  FETCH_WIDTH  = %0d", FETCH_WIDTH);
    $display("  ROB rule     = port0 older, port1 younger");
    $display("========================================");

    // ----------------------------------------------------------
    // TEST 1: Cold start predictions (base weak NT)
    // ----------------------------------------------------------
    header("TEST 1  Cold start");
    do_reset();
    fetch_and_sample(32'h1000, 32'h1004);
    check_pred("slot0 cold NT", 0, 1'b0);
    check_pred("slot1 cold NT", 1, 1'b0);

    // ----------------------------------------------------------
    // TEST 2: Base training to TAKEN (slot0)
    // ----------------------------------------------------------
    header("TEST 2  Base training to taken (slot0)");
    do_reset();

    fetch_and_sample(32'h500, 32'h0);
    idx_a = base_index(32'h500);
    base_before_a = dut.base_table[idx_a];

    sample_tuple(0, prov0, pred0, alt0);
    ghr_cp0 = ghr;
    do_dispatch(0, pred0);
    do_commit(0, 32'h500, 1'b1, prov0, pred0, alt0, ghr_cp0);

    fetch_and_sample(32'h500, 32'h0);
    base_after_a = dut.base_table[idx_a];

    if (base_after_a == base_ctr_ref_next(base_before_a, 1'b1))
      pass("base_table updated by taken (expected 01->10 from reset)");
    else begin
      $display("    DBG base[%0d] before=%b after=%b", idx_a, base_before_a, base_after_a);
      fail("base_table did not update as expected on taken");
    end
    check_pred("slot0 predicts taken after training", 0, 1'b1);

    // ----------------------------------------------------------
    // TEST 3: Base training to NOT-TAKEN (slot0)
    // ----------------------------------------------------------
    header("TEST 3  Base training to not-taken (slot0)");
    do_reset();

    fetch_and_sample(32'h600, 32'h0);
    idx_a = base_index(32'h600);
    base_before_a = dut.base_table[idx_a];

    sample_tuple(0, prov0, pred0, alt0);
    ghr_cp0 = ghr;
    do_dispatch(0, pred0);
    do_commit(0, 32'h600, 1'b0, prov0, pred0, alt0, ghr_cp0);

    fetch_and_sample(32'h600, 32'h0);
    base_after_a = dut.base_table[idx_a];

    if (base_after_a == base_ctr_ref_next(base_before_a, 1'b0))
      pass("base_table updated by not-taken (expected 01->00 from reset)");
    else begin
      $display("    DBG base[%0d] before=%b after=%b", idx_a, base_before_a, base_after_a);
      fail("base_table did not update as expected on not-taken");
    end
    check_pred("slot0 predicts NT after training", 0, 1'b0);

    // ----------------------------------------------------------
    // TEST 4: Port1-only base training (slot1)
    // ----------------------------------------------------------
    header("TEST 4  Port1-only base training to taken (slot1)");
    do_reset();

    fetch_and_sample(32'h100, 32'h200);
    idx_b = base_index(32'h200);
    base_before_b = dut.base_table[idx_b];

    sample_tuple(1, prov1, pred1, alt1);
    ghr_cp1 = ghr;
    do_dispatch(1, pred1);
    do_commit(1, 32'h200, 1'b1, prov1, pred1, alt1, ghr_cp1);

    fetch_and_sample(32'h100, 32'h200);
    base_after_b = dut.base_table[idx_b];

    if (base_after_b == base_ctr_ref_next(base_before_b, 1'b1))
      pass("slot1 base_table updated by taken");
    else begin
      $display("    DBG base[%0d] before=%b after=%b", idx_b, base_before_b, base_after_b);
      fail("slot1 base_table did not update as expected on taken");
    end
    check_pred("slot0 still cold NT", 0, 1'b0);
    check_pred("slot1 predicts taken after training", 1, 1'b1);

    // ----------------------------------------------------------
    // TEST 5: GHR dispatch advance + onehot
    // ----------------------------------------------------------
    header("TEST 5  GHR dispatch advance + onehot");
    do_reset();
    check_ghr_eq("ghr reset", '0);

    do_dispatch_checked(0, 1'b1, "dispatch onehot");
    sample();
    check_ghr_eq("ghr after 1", 32'h00000001);

    do_dispatch_checked(0, 1'b0, "dispatch onehot");
    sample();
    check_ghr_eq("ghr after 10", 32'h00000002);

    do_dispatch_checked(0, 1'b1, "dispatch onehot");
    sample();
    check_ghr_eq("ghr after 101", 32'h00000005);

    // ----------------------------------------------------------
    // TEST 6: Single mispredict recovery restores checkpoint
    // ----------------------------------------------------------
    header("TEST 6  GHR mispredict recovery (single)");
    do_reset();

    // Build ghr=3
    do_dispatch(0, 1'b1); sample();
    do_dispatch(0, 1'b1); sample();
    ghr_saved = ghr;

    // Advance more
    do_dispatch(0, 1'b0); sample();
    do_dispatch(0, 1'b0); sample();
    if (ghr != ghr_saved) pass($sformatf("ghr advanced to 0x%08h", ghr));
    else fail("ghr did not advance");

    // Recover via port0 mispred
    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'hB000;
    update_ports[0].actual_taken = 1'b1;
    update_ports[0].provider     = TAGE_TABLES;
    update_ports[0].pred_taken   = 1'b0; // mispred
    update_ports[0].pred_alt     = 1'b0;
    update_ports[0].ghr_cp       = ghr_saved;
    @(negedge clk);
    update_ports[0].val          = 1'b0;

    sample();
    check_ghr_eq("ghr restored to checkpoint", ghr_saved);

    // ----------------------------------------------------------
    // TEST 7: Dual commit (both correct) updates BOTH bases
    // ----------------------------------------------------------
    header("TEST 7  Dual commit same cycle (both correct)");
    do_reset();

    fetch_and_sample(32'h300, 32'h400);
    idx_a = base_index(32'h300);
    idx_b = base_index(32'h400);
    base_before_a = dut.base_table[idx_a];
    base_before_b = dut.base_table[idx_b];

    sample_tuple(0, prov0, pred0, alt0);
    sample_tuple(1, prov1, pred1, alt1);
    ghr_cp0 = ghr;
    ghr_cp1 = ghr;

    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'h300;
    update_ports[0].actual_taken = 1'b1;
    update_ports[0].provider     = prov0;
    update_ports[0].pred_taken   = pred0;
    update_ports[0].pred_alt     = alt0;
    update_ports[0].ghr_cp       = ghr_cp0;

    update_ports[1].val          = 1'b1;
    update_ports[1].pc           = 32'h400;
    update_ports[1].actual_taken = 1'b1;
    update_ports[1].provider     = prov1;
    update_ports[1].pred_taken   = pred1;
    update_ports[1].pred_alt     = alt1;
    update_ports[1].ghr_cp       = ghr_cp1;

    @(negedge clk);
    update_ports[0].val = 1'b0;
    update_ports[1].val = 1'b0;

    fetch_and_sample(32'h300, 32'h400);
    base_after_a = dut.base_table[idx_a];
    base_after_b = dut.base_table[idx_b];

    if (base_after_a == base_ctr_ref_next(base_before_a, 1'b1)) pass("slot0 base updated on dual commit");
    else fail("slot0 base did not update on dual commit");

    if (base_after_b == base_ctr_ref_next(base_before_b, 1'b1)) pass("slot1 base updated on dual commit");
    else fail("slot1 base did not update on dual commit");

    check_pred("slot0 predicts taken after dual commit", 0, 1'b1);
    check_pred("slot1 predicts taken after dual commit", 1, 1'b1);

    // ----------------------------------------------------------
    // TEST 8: Dual commit, base-index collision (same base idx)
    // ----------------------------------------------------------
    header("TEST 8  Dual commit base-index collision (port0 older)");
    do_reset();

    // Make them collide in [10:2] for BASE_ENTRIES=512
    fetch_and_sample(32'h0000_0000, 32'h0000_2000);

    idx_a = base_index(32'h0000_0000);
    idx_b = base_index(32'h0000_2000);

    if (idx_a != idx_b) begin
      $display("    DBG idx_a=%0d idx_b=%0d (expected equal)", idx_a, idx_b);
      fail("collision PCs did not collide; adjust constants if BASE_ENTRIES changes");
    end else pass($sformatf("collision confirmed at base_idx=%0d", idx_a));

    base_before_a = dut.base_table[idx_a];

    sample_tuple(0, prov0, pred0, alt0);
    sample_tuple(1, prov1, pred1, alt1);
    ghr_cp0 = ghr;
    ghr_cp1 = ghr;

    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'h0000_0000;
    update_ports[0].actual_taken = 1'b1; // inc
    update_ports[0].provider     = prov0;
    update_ports[0].pred_taken   = pred0;
    update_ports[0].pred_alt     = alt0;
    update_ports[0].ghr_cp       = ghr_cp0;

    update_ports[1].val          = 1'b1;
    update_ports[1].pc           = 32'h0000_2000;
    update_ports[1].actual_taken = 1'b0; // dec
    update_ports[1].provider     = prov1;
    update_ports[1].pred_taken   = pred1;
    update_ports[1].pred_alt     = alt1;
    update_ports[1].ghr_cp       = ghr_cp1;

    @(negedge clk);
    update_ports[0].val = 1'b0;
    update_ports[1].val = 1'b0;

    sample();
    base_after_a = dut.base_table[idx_a];
    base_after_b = base_ctr_ref_next(base_ctr_ref_next(base_before_a, 1'b1), 1'b0);

    if (base_after_a == base_after_b) pass("collision sequential update (port0 then port1) applied");
    else begin
      $display("    DBG base_before=%b expected=%b got=%b", base_before_a, base_after_b, base_after_a);
      fail("collision sequential update mismatch");
    end

    // ----------------------------------------------------------
    // TEST 9: Older correct, younger mispredict => restore to younger checkpoint
    // ----------------------------------------------------------
    header("TEST 9  Dual update: older correct, younger mispredict (ROB case)");
    do_reset();

    // create known history
    do_dispatch(0, 1'b1); sample(); // ghr=1
    do_dispatch(0, 1'b1); sample(); // ghr=3

    // fetch both branches
    fetch_and_sample(32'h900, 32'h904);
    sample_tuple(0, prov0, pred0, alt0);
    sample_tuple(1, prov1, pred1, alt1);

    // checkpoints around dispatches
    ghr_cp0 = ghr;          // before older dispatch
    do_dispatch(0, pred0); sample();
    ghr_cp1 = ghr;          // before younger dispatch
    do_dispatch(1, pred1); sample();

    // verify both bases train
    idx_a = base_index(32'h900);
    idx_b = base_index(32'h904);
    base_before_a = dut.base_table[idx_a];
    base_before_b = dut.base_table[idx_b];

    // FIX: older is correct, younger mispredict
    act0 = pred0;       // correct
    act1 = ~pred1;      // mispredict

    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'h900;
    update_ports[0].actual_taken = act0;
    update_ports[0].provider     = prov0;
    update_ports[0].pred_taken   = pred0;
    update_ports[0].pred_alt     = alt0;
    update_ports[0].ghr_cp       = ghr_cp0;

    update_ports[1].val          = 1'b1;
    update_ports[1].pc           = 32'h904;
    update_ports[1].actual_taken = act1;
    update_ports[1].provider     = prov1;
    update_ports[1].pred_taken   = pred1;
    update_ports[1].pred_alt     = alt1;
    update_ports[1].ghr_cp       = ghr_cp1;

    @(negedge clk);
    update_ports[0].val = 1'b0;
    update_ports[1].val = 1'b0;

    sample();

    base_after_a = dut.base_table[idx_a];
    base_after_b = dut.base_table[idx_b];

    if (base_after_a == base_ctr_ref_next(base_before_a, act0)) pass("older branch trained (port0)");
    else fail("older branch NOT trained (port0)");

    if (base_after_b == base_ctr_ref_next(base_before_b, act1)) pass("younger branch trained (port1)");
    else fail("younger branch NOT trained (port1)");

    // EXPECT restore to younger checkpoint (only younger mispred)
    check_ghr_eq("ghr restored to younger checkpoint (port1)", ghr_cp1);

    // ----------------------------------------------------------
    // TEST 10: Both mispredict => restore priority port0 (older)
    // ----------------------------------------------------------
    header("TEST 10 Dual mispredict -> restore priority port0 (older)");
    do_reset();

    do_dispatch(0, 1'b1); sample(); // ghr=1
    ghr_cp0 = ghr;
    do_dispatch(0, 1'b1); sample(); // ghr=3
    ghr_cp1 = ghr;

    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'hA100;
    update_ports[0].actual_taken = 1'b1;
    update_ports[0].provider     = TAGE_TABLES;
    update_ports[0].pred_taken   = 1'b0; // mispred
    update_ports[0].pred_alt     = 1'b0;
    update_ports[0].ghr_cp       = ghr_cp0;

    update_ports[1].val          = 1'b1;
    update_ports[1].pc           = 32'hA104;
    update_ports[1].actual_taken = 1'b0;
    update_ports[1].provider     = TAGE_TABLES;
    update_ports[1].pred_taken   = 1'b1; // mispred
    update_ports[1].pred_alt     = 1'b0;
    update_ports[1].ghr_cp       = ghr_cp1;

    @(negedge clk);
    update_ports[0].val = 1'b0;
    update_ports[1].val = 1'b0;

    sample();
    check_ghr_eq("ghr restored to older checkpoint (port0)", ghr_cp0);

    // ----------------------------------------------------------
    // TEST 11: Deterministic tagged allocation from base-provider mispredict
    // ----------------------------------------------------------
    header("TEST 11 Deterministic tagged allocation and provider hit");
    do_reset();

    // Build a known GHR pattern G = 4'b1011 in the low bits.
    do_dispatch(0, 1'b1); sample();
    do_dispatch(0, 1'b0); sample();
    do_dispatch(0, 1'b1); sample();
    do_dispatch(0, 1'b1); sample();
    ghr_cp0 = ghr;

    // Force a base-provider mispredict at a fixed history checkpoint.
    fetch_and_sample(32'h5000, 32'h0);
    @(negedge clk);
    update_ports[0].val          = 1'b1;
    update_ports[0].pc           = 32'h5000;
    update_ports[0].actual_taken = 1'b1;
    update_ports[0].provider     = TAGE_TABLES;
    update_ports[0].pred_taken   = 1'b0;
    update_ports[0].pred_alt     = 1'b0;
    update_ports[0].ghr_cp       = ghr_cp0;
    @(negedge clk);
    update_ports[0].val          = 1'b0;

    sample();
    check_ghr_eq("ghr restored to allocation checkpoint", ghr_cp0);
    fetch_and_sample(32'h5000, 32'h0);
    if (pred_ports[0].provider != TAGE_TABLES)
      pass($sformatf("provider became tagged table %0d", pred_ports[0].provider));
    else
      fail("provider remained base after deterministic allocation");

    // ----------------------------------------------------------
    // TEST 12: Useful counter updates on tagged provider
    // ----------------------------------------------------------
    header("TEST 12 Tagged useful counter increments and decrements");
    begin
      int tagged_provider;
      int hist_len;
      logic [TAG_IDX_WIDTH-1:0] t_idx;
      logic [1:0] u_before, u_after_inc, u_after_dec;
      logic [2:0] ctr_before, ctr_after_inc, ctr_after_dec;

      tagged_provider = int'(pred_ports[0].provider);
      hist_len = (tagged_provider == 0) ? 4 :
                 (tagged_provider == 1) ? 8 :
                 (tagged_provider == 2) ? 16 : 32;
      t_idx = dut.calc_index(32'h5000, ghr, hist_len);
      u_before   = dut.tag_tables[tagged_provider][t_idx].u;
      ctr_before = dut.tag_tables[tagged_provider][t_idx].ctr;

      // Drive the exact provider/alternate relationship required by update_useful().
      // After TEST 11 the live alternate predictor is no longer guaranteed to disagree,
      // because the base table was trained by the allocation-triggering mispredict.
      // So this unit test explicitly supplies pred_taken/pred_alt on the update port.

      // Case A: provider correct, alternate wrong -> useful increments.
      @(negedge clk);
      update_ports[0].val          = 1'b1;
      update_ports[0].pc           = 32'h5000;
      update_ports[0].actual_taken = 1'b1;
      update_ports[0].provider     = tagged_provider[$clog2(TAGE_TABLES):0];
      update_ports[0].pred_taken   = 1'b1;
      update_ports[0].pred_alt     = 1'b0;
      update_ports[0].ghr_cp       = ghr;
      @(negedge clk);
      update_ports[0].val          = 1'b0;
      sample();
      u_after_inc   = dut.tag_tables[tagged_provider][t_idx].u;
      ctr_after_inc = dut.tag_tables[tagged_provider][t_idx].ctr;

      if (u_after_inc == ((u_before == 2'b11) ? 2'b11 : (u_before + 2'b01)))
        pass("useful counter incremented on provider-correct / alt-wrong update");
      else
        fail($sformatf("useful counter failed to increment: before=%b after=%b", u_before, u_after_inc));

      if (ctr_after_inc == ((ctr_before == 3'b111) ? 3'b111 : (ctr_before + 3'b001)))
        pass("tagged counter incremented on taken provider update");
      else
        fail($sformatf("tagged counter failed to increment: before=%b after=%b", ctr_before, ctr_after_inc));

      // Case B: provider wrong, alternate correct -> useful decrements.
      @(negedge clk);
      update_ports[0].val          = 1'b1;
      update_ports[0].pc           = 32'h5000;
      update_ports[0].actual_taken = 1'b0;
      update_ports[0].provider     = tagged_provider[$clog2(TAGE_TABLES):0];
      update_ports[0].pred_taken   = 1'b1;
      update_ports[0].pred_alt     = 1'b0;
      update_ports[0].ghr_cp       = ghr;
      @(negedge clk);
      update_ports[0].val          = 1'b0;
      sample();
      u_after_dec   = dut.tag_tables[tagged_provider][t_idx].u;
      ctr_after_dec = dut.tag_tables[tagged_provider][t_idx].ctr;

      if (u_after_dec == ((u_after_inc == 2'b00) ? 2'b00 : (u_after_inc - 2'b01)))
        pass("useful counter decremented on provider-wrong / alt-correct update");
      else
        fail($sformatf("useful counter failed to decrement: after_inc=%b after_dec=%b", u_after_inc, u_after_dec));

      if (ctr_after_dec == ((ctr_after_inc == 3'b000) ? 3'b000 : (ctr_after_inc - 3'b001)))
        pass("tagged counter decremented on not-taken provider update");
      else
        fail($sformatf("tagged counter failed to decrement: after_inc=%b after_dec=%b", ctr_after_inc, ctr_after_dec));
    end

    // ----------------------------------------------------------
    // TEST 13: Reset returns tagged learning to cold base state
    // ----------------------------------------------------------
    header("TEST 13 Reset clears tagged learning");
    do_reset();
    fetch_and_sample(32'h5000, 32'h0);
    check_pred("provider reset to base after tagged learning", 0, 1'b0, 1'b1, TAGE_TABLES);
    check_ghr_eq("ghr reset to zero after tagged learning", '0);

    // ----------------------------------------------------------
    // Summary
    // ----------------------------------------------------------
    $display("\n========================================");
    $display("  Tests Passed: %0d", tests_passed);
    $display("  Tests Failed: %0d", tests_failed);
    $display("========================================");

    if (tests_failed == 0) begin
      $display("  ✓ ALL TESTS PASSED!");
      $finish;
    end else begin
      $fatal(1, "Test failures detected");
    end
  end

  // ------------------------------------------------------------
  // Timeout
  // ------------------------------------------------------------
  initial begin
    #1000000;
    $fatal(1, "Timeout!");
  end

endmodule
