# ==============================================================================
# RV32I Optimized Stress Test: Software Pipelined Matrix Multiply
# ==============================================================================
# Optimization: Interleaved Memory and ALU operations to saturate dual-issue/OoO queues.
# Strategy:
#   1. Load Row 0
#   2. Load Row 1 (Fill Load Queue)
#   3. Compute Row 0 (ALU busy while Row 1 loads arrive)
#   4. Load Row 2 (AGU busy while Row 0 stores / Row 1 computes)
#   5. Store Row 0
#   6. Compute Row 1
#   ... and so on.
# ==============================================================================

_start:
    addi x28, x0, 256       # Base Address 0x100
    addi x30, x0, 0         # Checksum Accumulator

    # --------------------------------------------------------------------------
    # 0. SETUP: Write Input Data to Memory (Initialization Phase)
    # --------------------------------------------------------------------------
    # Row 0: {1, 2, 3, 4}
    addi x1, x0, 1
    sw   x1, 0(x28)
    addi x1, x0, 2
    sw   x1, 4(x28)
    addi x1, x0, 3
    sw   x1, 8(x28)
    addi x1, x0, 4
    sw   x1, 12(x28)

    # Row 1: {5, 6, 7, 8}
    addi x1, x0, 5
    sw   x1, 16(x28)
    addi x1, x0, 6
    sw   x1, 20(x28)
    addi x1, x0, 7
    sw   x1, 24(x28)
    addi x1, x0, 8
    sw   x1, 28(x28)

    # Row 2: {10, 10, 10, 10}
    addi x1, x0, 10
    sw   x1, 32(x28)
    sw   x1, 36(x28)
    sw   x1, 40(x28)
    sw   x1, 44(x28)

    # Row 3: {1, 0, 1, 0}
    addi x1, x0, 1
    sw   x1, 48(x28)
    sw   x0, 52(x28)
    sw   x1, 56(x28)
    sw   x0, 60(x28)

    # --------------------------------------------------------------------------
    # 1. PIPELINE START: Pre-load Rows 0 and 1
    # --------------------------------------------------------------------------
    # Registers x1-x4 for Row 0
    lw   x1, 0(x28)
    lw   x2, 4(x28)
    lw   x3, 8(x28)
    lw   x4, 12(x28)

    # Registers x5-x8 for Row 1 (Issued immediately after to fill Load Queue)
    lw   x5, 16(x28)
    lw   x6, 20(x28)
    lw   x7, 24(x28)
    lw   x8, 28(x28)

    # --------------------------------------------------------------------------
    # 2. COMPUTE ROW 0 / LOAD ROW 2
    # --------------------------------------------------------------------------
    # While we compute Row 0 (ALU), we issue loads for Row 2 (AGU)
    # Output Row 0 goes to x9-x12
    # Row 2 Input goes to x17-x20

    # -- ISSUE LOADS FOR ROW 2 (Interleaved at start of block) --
    lw   x17, 32(x28)
    lw   x18, 36(x28)
    lw   x19, 40(x28)
    lw   x20, 44(x28)

    # -- COMPUTE ROW 0 (Inputs x1-x4) --
    # C[0,0] Scale 2
    slli x25, x1, 1         # Temp x25
    slli x26, x2, 1         # Temp x26
    add  x9, x25, x26       # Result Accumulator x9
    slli x25, x3, 1
    slli x26, x4, 1
    add  x25, x25, x26
    add  x9, x9, x25        # x9 = 20

    # C[0,1] Scale 3
    slli x25, x1, 1
    add  x25, x25, x1
    slli x26, x2, 1
    add  x26, x26, x2
    add  x10, x25, x26      # Result Accumulator x10
    slli x25, x3, 1
    add  x25, x25, x3
    slli x26, x4, 1
    add  x26, x26, x4
    add  x25, x25, x26
    add  x10, x10, x25      # x10 = 30

    # C[0,2] Scale 5
    slli x25, x1, 2
    add  x25, x25, x1
    slli x26, x2, 2
    add  x26, x26, x2
    add  x11, x25, x26      # Result Accumulator x11
    slli x25, x3, 2
    add  x25, x25, x3
    slli x26, x4, 2
    add  x26, x26, x4
    add  x25, x25, x26
    add  x11, x11, x25      # x11 = 50

    # C[0,3] Scale 10 (Reuse Scale 5 logic? No, independent chains for stress)
    slli x25, x1, 3
    slli x26, x1, 1
    add  x25, x25, x26      # x1 * 10
    slli x26, x2, 3
    slli x27, x2, 1
    add  x26, x26, x27
    add  x12, x25, x26      # Result Accumulator x12
    slli x25, x3, 3
    slli x26, x3, 1
    add  x25, x25, x26
    slli x26, x4, 3
    slli x27, x4, 1
    add  x26, x26, x27
    add  x25, x25, x26
    add  x12, x12, x25      # x12 = 100

    # --------------------------------------------------------------------------
    # 3. STORE ROW 0 / COMPUTE ROW 1 / LOAD ROW 3
    # --------------------------------------------------------------------------
    
    # -- STORE ROW 0 (Results x9-x12) --
    sw   x9,  256(x28)
    sw   x10, 260(x28)
    sw   x11, 264(x28)
    sw   x12, 268(x28)

    # -- ISSUE LOADS FOR ROW 3 (Inputs to x21-x24) --
    # Keeping AGU busy while we compute Row 1
    lw   x21, 48(x28)
    lw   x22, 52(x28)
    lw   x23, 56(x28)
    lw   x24, 60(x28)

    # -- COMPUTE ROW 1 (Inputs x5-x8) --
    # C[1,0] Scale 2
    slli x25, x5, 1
    slli x26, x6, 1
    add  x13, x25, x26      # Result x13
    slli x25, x7, 1
    slli x26, x8, 1
    add  x25, x25, x26
    add  x13, x13, x25      # x13 = 52

    # C[1,1] Scale 3
    slli x25, x5, 1
    add  x25, x25, x5
    slli x26, x6, 1
    add  x26, x26, x6
    add  x14, x25, x26      # Result x14
    slli x25, x7, 1
    add  x25, x25, x7
    slli x26, x8, 1
    add  x26, x26, x8
    add  x25, x25, x26
    add  x14, x14, x25      # x14 = 78

    # C[1,2] Scale 5
    slli x25, x5, 2
    add  x25, x25, x5
    slli x26, x6, 2
    add  x26, x26, x6
    add  x15, x25, x26      # Result x15
    slli x25, x7, 2
    add  x25, x25, x7
    slli x26, x8, 2
    add  x26, x26, x8
    add  x25, x25, x26
    add  x15, x15, x25      # x15 = 130

    # C[1,3] Scale 10
    slli x25, x5, 3
    slli x26, x5, 1
    add  x25, x25, x26
    slli x26, x6, 3
    slli x27, x6, 1
    add  x26, x26, x27
    add  x16, x25, x26      # Result x16
    slli x25, x7, 3
    slli x26, x7, 1
    add  x25, x25, x26
    slli x26, x8, 3
    slli x27, x8, 1
    add  x26, x26, x27
    add  x25, x25, x26
    add  x16, x16, x25      # x16 = 260

    # --------------------------------------------------------------------------
    # 4. STORE ROW 1 / COMPUTE ROW 2
    # --------------------------------------------------------------------------
    
    # -- STORE ROW 1 (Results x13-x16) --
    sw   x13, 272(x28)
    sw   x14, 276(x28)
    sw   x15, 280(x28)
    sw   x16, 284(x28)

    # -- COMPUTE ROW 2 (Inputs x17-x20) --
    # C[2,0] Scale 2
    slli x25, x17, 1
    slli x26, x18, 1
    add  x1, x25, x26       # Reuse x1 as result
    slli x25, x19, 1
    slli x26, x20, 1
    add  x25, x25, x26
    add  x1, x1, x25        # x1 = 80

    # C[2,1] Scale 3
    slli x25, x17, 1
    add  x25, x25, x17
    slli x26, x18, 1
    add  x26, x26, x18
    add  x2, x25, x26       # Reuse x2 as result
    slli x25, x19, 1
    add  x25, x25, x19
    slli x26, x20, 1
    add  x26, x26, x20
    add  x25, x25, x26
    add  x2, x2, x25        # x2 = 120

    # C[2,2] Scale 5
    slli x25, x17, 2
    add  x25, x25, x17
    slli x26, x18, 2
    add  x26, x26, x18
    add  x3, x25, x26       # Reuse x3 as result
    slli x25, x19, 2
    add  x25, x25, x19
    slli x26, x20, 2
    add  x26, x26, x20
    add  x25, x25, x26
    add  x3, x3, x25        # x3 = 200

    # C[2,3] Scale 10
    slli x25, x17, 3
    slli x26, x17, 1
    add  x25, x25, x26
    slli x26, x18, 3
    slli x27, x18, 1
    add  x26, x26, x27
    add  x4, x25, x26       # Reuse x4 as result
    slli x25, x19, 3
    slli x26, x19, 1
    add  x25, x25, x26
    slli x26, x20, 3
    slli x27, x20, 1
    add  x26, x26, x27
    add  x25, x25, x26
    add  x4, x4, x25        # x4 = 400

    # --------------------------------------------------------------------------
    # 5. STORE ROW 2 / COMPUTE ROW 3
    # --------------------------------------------------------------------------

    # -- STORE ROW 2 (Results x1-x4) --
    sw   x1, 288(x28)
    sw   x2, 292(x28)
    sw   x3, 296(x28)
    sw   x4, 300(x28)

    # -- COMPUTE ROW 3 (Inputs x21-x24) --
    # C[3,0] Scale 2
    slli x25, x21, 1
    slli x26, x22, 1
    add  x5, x25, x26       # Reuse x5 as result
    slli x25, x23, 1
    slli x26, x24, 1
    add  x25, x25, x26
    add  x5, x5, x25        # x5 = 4

    # C[3,1] Scale 3
    slli x25, x21, 1
    add  x25, x25, x21
    slli x26, x22, 1
    add  x26, x26, x22
    add  x6, x25, x26       # Reuse x6 as result
    slli x25, x23, 1
    add  x25, x25, x23
    slli x26, x24, 1
    add  x26, x26, x24
    add  x25, x25, x26
    add  x6, x6, x25        # x6 = 6

    # C[3,2] Scale 5
    slli x25, x21, 2
    add  x25, x25, x21
    slli x26, x22, 2
    add  x26, x26, x22
    add  x7, x25, x26       # Reuse x7 as result
    slli x25, x23, 2
    add  x25, x25, x23
    slli x26, x24, 2
    add  x26, x26, x24
    add  x25, x25, x26
    add  x7, x7, x25        # x7 = 10

    # C[3,3] Scale 10
    slli x25, x21, 3
    slli x26, x21, 1
    add  x25, x25, x26
    slli x26, x22, 3
    slli x27, x22, 1
    add  x26, x26, x27
    add  x8, x25, x26       # Reuse x8 as result
    slli x25, x23, 3
    slli x26, x23, 1
    add  x25, x25, x26
    slli x26, x24, 3
    slli x27, x24, 1
    add  x26, x26, x27
    add  x25, x25, x26
    add  x8, x8, x25        # x8 = 20

    # --------------------------------------------------------------------------
    # 6. FINAL STORE / CHECK
    # --------------------------------------------------------------------------
    
    # -- STORE ROW 3 (Results x5-x8) --
    sw   x5, 304(x28)
    sw   x6, 308(x28)
    sw   x7, 312(x28)
    sw   x8, 316(x28)

    # Checksum
    add x17, x1,  x2
    add x18, x3,  x4
    add x19, x5,  x6
    add x20, x7,  x8
    add x21, x9,  x10
    add x22, x11, x12
    add x23, x13, x14
    add x24, x15, x16
    add x17, x17, x18
    add x19, x19, x20
    add x21, x21, x22
    add x23, x23, x24
    add x17, x17, x19
    add x21, x21, x23
    add x30, x17, x21       # Total Checksum = 1560

    addi x31, x0, 255

done:
    beq x0, x0, done