# RV32IM CPU Comprehensive Test Program
# Tests all RV32IM instructions systematically

_start:
    # Initialize base values
    addi x1, x0, 5          # x1 = 5
    addi x2, x0, 7          # x2 = 7
    addi x25, x0, 0         # x25 = test counter

    # ===== Test 1: Basic Arithmetic =====
    add  x3, x1, x2         # x3 = 12
    sub  x4, x2, x1         # x4 = 2
    
    # ===== Test 2: Logical Operations =====
    and  x5, x1, x2         # x5 = 5
    or   x6, x1, x2         # x6 = 7
    xor  x7, x1, x2         # x7 = 2
    andi x8, x2, 3          # x8 = 3
    ori  x9, x1, 8          # x9 = 13
    xori x10, x2, 15        # x10 = 8
    
    # ===== Test 3: Shifts =====
    slli x11, x1, 2         # x11 = 20
    srli x12, x2, 1         # x12 = 3
    addi x13, x0, -8        # x13 = -8
    srai x14, x13, 1        # x14 = -4
    sll  x15, x1, x2        # x15 = 640
    srl  x16, x2, x1        # x16 = 0
    sra  x17, x13, x1       # x17 = -1
    
    # ===== Test 4: Comparisons =====
    slt  x18, x1, x2        # x18 = 1
    slt  x19, x2, x1        # x19 = 0
    sltu x20, x13, x1       # x20 = 0
    slti x21, x1, 10        # x21 = 1
    sltiu x22, x1, 3        # x22 = 0
    
    # ===== Test 5: Upper Immediates =====
    lui  x23, 0x12345       # x23 = 0x12345000
    auipc x24, 0x1000       # x24 = PC + 0x1000000
    
    # ===== Test 6: Branches =====
    addi x25, x0, 0         # Reset counter
    
    # Test branch taken (BEQ)
    beq  x1, x1, br1        # Should branch (5 == 5)
    addi x25, x0, 99        # Should NOT execute
br1:
    addi x25, x25, 1        # x25 = 1
    
    # Test branch not taken (BNE)
    bne  x1, x1, br_fail    # Should NOT branch (5 == 5)
    addi x25, x25, 1        # Should execute, x25 = 2
    jal  x0, br2            # Skip fail marker
br_fail:
    addi x25, x0, 88        # Should NOT execute
    
br2:
    # Test other branch types (just taken)
    blt  x1, x2, br3        # Should branch (5 < 7)
    addi x25, x0, 77        # Should NOT execute
br3:
    addi x25, x25, 1        # x25 = 3
    
    bge  x2, x1, br4        # Should branch (7 >= 5)
    addi x25, x0, 66        # Should NOT execute
br4:
    addi x25, x25, 1        # x25 = 4
    
    bltu x1, x2, br5        # Should branch (5 < 7 unsigned)
    addi x25, x0, 55        # Should NOT execute
br5:
    addi x25, x25, 1        # x25 = 5
    
    bgeu x2, x1, br6        # Should branch (7 >= 5 unsigned)
    addi x25, x0, 44        # Should NOT execute
br6:
    addi x25, x25, 1        # x25 = 6
    
    # Test backward branch (simple loop)
    addi x29, x0, 0         # Loop counter
    addi x30, x0, 3         # Loop limit
back_loop:
    addi x29, x29, 1        # Increment counter
    blt  x29, x30, back_loop # Branch backwards while x29 < 3
    # After loop: x29 = 3
    addi x25, x25, 1        # x25 = 7
    
    # ===== Test 7: JAL/JALR =====
    # Test JAL forward
    jal  x26, jmp1          # Jump forward, save return
    addi x25, x0, 99        # Should NOT execute
    
jmp1:
    addi x25, x25, 1        # x25 = 8
    
    # Test JAL backward
    jal  x0, jmp2           # Jump forward to set up backward test
    
jmp_back:
    addi x25, x25, 1        # x25 = 10 (from backward jump)
    jal  x0, jmp3           # Continue
    
jmp2:
    addi x25, x25, 1        # x25 = 9
    jal  x27, jmp_back      # Jump BACKWARD
    
jmp3:
    # Test JALR
    auipc x28, 0            # Get current PC
    jalr x29, x28, 20       # Jump to PC+20 (skip 4 instructions from auipc)
    addi x25, x0, 88        # Should NOT execute
    addi x25, x0, 77        # Should NOT execute
    addi x25, x0, 66        # Should NOT execute
    addi x25, x25, 1        # x25 = 11
    
    # ===== Test 8: Memory Operations (Store then Load) =====
    addi x28, x0, 100       # x28 = base address
    
    # Test word operations
    addi x1, x0, 42         # x1 = 42
    sw   x1, 0(x28)         # Store 42
    lw   x11, 0(x28)        # x11 = 42
    
    addi x2, x0, 100        # x2 = 100
    sw   x2, 4(x28)         # Store 100
    lw   x12, 4(x28)        # x12 = 100
    
    # Test byte operations
    addi x3, x0, 0xAB       # x3 = 0xAB
    sb   x3, 8(x28)         # Store byte
    lbu  x13, 8(x28)        # x13 = 0xAB (unsigned)
    lb   x14, 8(x28)        # x14 = 0xFFFFFFAB (signed)
    
    # Test halfword operations
    addi x4, x0, 0x123      # x4 = 0x123
    sh   x4, 12(x28)        # Store halfword
    lhu  x15, 12(x28)       # x15 = 0x123 (unsigned)
    lh   x16, 12(x28)       # x16 = 0x123 (signed)
    
    # Test signed byte load with negative value
    addi x5, x0, -1         # x5 = 0xFFFFFFFF
    sb   x5, 16(x28)        # Store 0xFF byte
    lb   x17, 16(x28)       # x17 = 0xFFFFFFFF (sign extended)
    lbu  x18, 16(x28)       # x18 = 0xFF (zero extended)
    
    # Test signed halfword with negative
    addi x6, x0, -1         # x6 = 0xFFFFFFFF  
    sh   x6, 20(x28)        # Store 0xFFFF halfword
    lh   x19, 20(x28)       # x19 = 0xFFFFFFFF (sign extended)
    lhu  x20, 20(x28)       # x20 = 0xFFFF (zero extended)

    # ===== Test 9: Multiply/Divide (M extension) =====
    #addi x1, x0, 6          # x1 = 6
    #addi x2, x0, 7          # x2 = 7
    #mul  x3, x1, x2         # x3 = 42
    
    #addi x4, x0, 100        # x4 = 100
    #addi x5, x0, 10         # x5 = 10
    #mul  x6, x4, x5         # x6 = 1000
    #div  x7, x4, x5         # x7 = 10
    
    #addi x9, x0, -3         # x9 = -3
    #mul  x10, x1, x9        # x10 = -18
    
    # ===== COMPLETION MARKER =====
    addi x31, x0, 0xFF      # x31 = 255 (signals done)

# Infinite loop to halt
done:
    beq x0, x0, done
