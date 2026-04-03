#----------------------------------------------------------------------------------------
# Project Title: Risc-V Assembler (Corrected & Modified)
# Original Contributor: Josh Heeren
# Description: converts a text file written in assembly code to a hexadecimal text
# file where each line in the memory file is an 8 digit hexadecimal number
# representing a 32 bit instruction
# Notes:
# - does not use .text and .data directives
# - Only labels work for branch statements, not immediate values
# - You must manually load the starting location of your stack pointer in the asm program
# using the li instruction
# 
# Usage: python3 riscv_assembler.py input_file.s [output_file.hex]
#---------------------------------------------------------------------
import sys
import os

# Parse command-line arguments
if len(sys.argv) < 2:
    print("Usage: python3 riscv_assembler.py input_file.s [output_file.hex]")
    print("  If output file is not specified, will use input filename with .hex extension")
    sys.exit(1)

input_filename = sys.argv[1]

# Generate output filename
if len(sys.argv) >= 3:
    output_filename = sys.argv[2]
else:
    # Replace extension with .hex
    base_name = os.path.splitext(input_filename)[0]
    output_filename = base_name + ".hex"

# Check if input file exists
if not os.path.exists(input_filename):
    print(f"Error: Input file '{input_filename}' not found!")
    sys.exit(1)

print(f"Assembling: {input_filename}")
print(f"Output to:  {output_filename}")

file = open(input_filename, "r")
mem_file = open(output_filename, "w") 
lines = file.readlines()

instr_arr = []
# get rid of comments
for line in lines:
    idx = line.find('#')
    if (idx != -1):
        if (idx != 0):
            instr_arr.append(line[:idx])
    else:
        instr_arr.append(line)

new_arr = []
# get rid of new line and tab characters
for instr in instr_arr:
    new_list = instr.split()
    new_str = " ".join(new_list)
    new_arr.append(new_str)

instr_arr = []

# get rid of blank lines
for instr in new_arr:
    if (instr != ''):
        instr_arr.append(instr)


instr_dict = {
    'lui' : 1,
    'auipc' : 1,
    'jal' : 1,
    'jalr' : 1,
    'beq' : 1,
    'bne' : 1,
    'blt' : 1,
    'bge' : 1,
    'bltu' : 1,
    'bgeu' : 1,
    'lw' : 1,
    'sw' : 1,
    'addi' : 1,
    'slti' : 1,
    'sltiu' : 1,
    'xori' : 1,
    'ori' : 1,
    'andi' : 1,
    'slli' : 1,
    'srli' : 1,
    'srai' : 1,
    'add' : 1,
    'sub' : 1,
    'sll' : 1,
    'slt' : 1,
    'sltu' : 1,
    'xor' : 1,
    'srl' : 1,
    'sra' : 1,
    'or' : 1,
    'and' : 1,
    'la' : 2,
    'li' : 2,
    'mv' : 1,
    'beqz' : 1,
    'bnez' : 1,
    'blez' : 1,
    'bgez' : 1,
    'bltz' : 1,
    'bgtz' : 1,
    'j' : 1,
    'call' : 1,
    'ret' : 1,
    'mret' : 1,
    'csrrw' : 1,
    'csrw' : 1,

    #added
    'mul' : 1,
    'div' : 1,
    'lb' : 1,
    'lbu' : 1,
    'lh' : 1,
    'lhu' : 1,
    'sb' : 1,
    'sh' : 1,
    }

    
var_dict = {} # define variables
label_dict = {} # define labels
PC_cnt = 0
PC_arr = [] # holds addresse for each actual instruction, -1 for non-instructions
# fill var dict and create PC_arr
for i in range(0,len(instr_arr)):
    instruction = instr_arr[i].split()
    if (instruction[0] == ".equ"):
        var_dict[instruction[1].strip(',')] = str(bin(int(instruction[2][2:],16)))[2:].zfill(32)
        PC_arr.append(-1) 
    elif (':' in instruction[0]):
        PC_arr.append(-1)
    else:
        if (instr_dict[instruction[0]] == 1):
            PC_arr.append(PC_cnt)
            PC_cnt += 4
        else:
            PC_arr.append(PC_cnt)
            PC_cnt += 4
            PC_arr.append(PC_cnt)
            PC_cnt += 4

# fill label_dict
j = 0
i = 0
instr_cnt = 0
while j < len(PC_arr) - 1:
    instruction = instr_arr[i].split()
    if (':' in instruction[0]):
        label_dict[instruction[0].strip(':')] = str(PC_arr[j+1]) # make label point to correct address
        i += 1
    elif (instruction[0] == '.equ'):
        i += 1
    else:
        if (instr_dict[instruction[0]] == 2):
            if (instr_cnt == 1):
                i += 1
                instr_cnt = 0
            else:
                instr_cnt += 1
        elif (instr_dict[instruction[0]] == 1):
            i += 1
    j += 1

def write_to_file(line, PC_cnt):
    #print("LINE 2 PRINT: ", line)
    mem_file.write((str(hex(int(line, 2)))[2:]).zfill(8) + "\n")
    PC_cnt += 4
    return PC_cnt

# define registers
registers = {
'ra' : '00001',
'sp' : '00010',
'tp' : '00100',
't0' : '00101',
't1' : '00110',
't2' : '00111',
's0' : '01000',
's1' : '01001',
'a0' : '01010',
'a1' : '01011',
'a2' : '01100',
'a3' : '01101',
'a4' : '01110',
'a5' : '01111',
'a6' : '10000',
'a7' : '10001',
's2' : '10010',
's3' : '10011',
's4' : '10100',
's5' : '10101',
's6' : '10110',
's7' : '10111',
's8' : '11000',
's9' : '11001',
's10' : '11010',
's11' : '11011',
't3' : '11100',
't4' : '11101',
't5' : '11110',
't6' : '11111',


'x0'  : '00000',
'x1'  : '00001',
'x2'  : '00010',
'x3'  : '00011',
'x4'  : '00100',
'x5'  : '00101',
'x6'  : '00110',
'x7'  : '00111',
'x8'  : '01000',
'x9'  : '01001',
'x10' : '01010',
'x11' : '01011',
'x12' : '01100',
'x13' : '01101',
'x14' : '01110',
'x15' : '01111',
'x16' : '10000',
'x17' : '10001',
'x18' : '10010',
'x19' : '10011',
'x20' : '10100',
'x21' : '10101',
'x22' : '10110',
'x23' : '10111',
'x24' : '11000',
'x25' : '11001',
'x26' : '11010',
'x27' : '11011',
'x28' : '11100',
'x29' : '11101',
'x30' : '11110',
'x31' : '11111',


}

# define csr addresses
csr_dict = {
    'mie' : '0x304',
    'mtvec' : '0x305',
    'mepc' : '0x341'
    }

PC_cnt = 0
for i in range(0,len(instr_arr)):
    mem_line = ''
    # base instruction set
    instruction = instr_arr[i].split()
    if (instruction[0] == 'lui'):
        #imm = str(bin(int(instruction[2][2:],16))[2:])
        if ('0x' in instruction[2]):
            imm = str(bin(int(instruction[2][2:],16))[2:])  # Hex
        else:
            imm = str(bin(int(instruction[2]))[2:])         # Decimal

        if (int(imm,2) > 2**20 - 1):
            raise ValueError("Line %d: Immediate value must be less than 2^20." % i)
            exit
        rd = instruction[1].strip(',')
        opcode = '0110111'
        mem_line = imm.zfill(20) + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'auipc'):
        #imm = str(bin(int(instruction[2][2:],16))[2:])
        if ('0x' in instruction[2]):
            imm = str(bin(int(instruction[2][2:],16))[2:])  # Hex
        else:
            imm = str(bin(int(instruction[2]))[2:])         # Decimal
        if (int(imm,2) > 2**20 - 1):
            raise ValueError("Line %d: Immediate value must be less than 2^20." % i)
            exit
        rd = instruction[1].strip(',')
        opcode = '0010111'
        mem_line = imm.zfill(20) + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'jal'):
        if ('0x' in instruction[2]):
            offset = int(instruction[2], 16)
        else:
            target_addr = int(label_dict[instruction[2]])
            offset = target_addr - PC_cnt
        
        # Handle negative offsets (backward jumps)
        if offset < 0:
            # Mask to 20 bits for two's complement
            imm = str(bin(offset & 0xFFFFF))[2:].zfill(20)
        else:
            imm = str(bin(offset))[2:].zfill(20)
        
        if (len(imm) > 20):
            raise ValueError("Line %d: JAL offset too large (max ±1MB)." % i)
            exit
        rd = instruction[1].strip(',')
        opcode = '1101111'
        mem_line = imm[0] + imm[9:19] + imm[8] + imm[0:8] + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'jalr'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('-' in instruction[3]):
            if ('0x' in instruction[3]):
                imm = str(bin(int(instruction[3][3:], 16)))[3:].zfill(12)
            else:
                imm = str(bin(int(instruction[3][1:])))[2:].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12, '1')
        else:
            if ('0x' in instruction[3]):
                imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
            else:
                imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '000'
        opcode = '1100111'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'beq'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1') 
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '000'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bne'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '001'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'blt'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '100'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bge'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '101'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bltu'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '110'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bgeu'):
        imm = int(label_dict[instruction[3]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '111'
        rs2 = instruction[2].strip(',')
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'lw'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0000011'
        funct3 = '010'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sw'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rs2 = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0100011'
        funct3 = '010'
        mem_line = imm[-12:-5:1] + registers[rs2] + registers[rs1] + funct3 + imm[-5::1] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'addi'):
        #print("INSTRUCTION", instruction[0], instruction[1], instruction[2], instruction[3])
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('-' in instruction[3]):
            if ('0x' in instruction[3]):
                imm = str(bin(int(instruction[3][3:], 16)))[3:].zfill(12)
            else:
                imm = str(bin(int(instruction[3][1:])))[2:].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12, '1')
        else:
            if ('0x' in instruction[3]):
                imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
            else:
                imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '000'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'slti'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '010'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sltiu'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '011'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'xori'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '100'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'ori'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '110'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'andi'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '111'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'slli'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '001'
        funct7 = '0000000'
        opcode = '0010011'
        mem_line = funct7 + imm[-5::1] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'srli'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '101'
        funct7 = '0000000'
        opcode = '0010011'
        mem_line = funct7 + imm[-5::1] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'srai'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        if ('0x' in instruction[3]):
            imm = str(bin(int(instruction[3][2:], 16)))[2:].zfill(12)
        else:
            imm = str(bin(int(instruction[3])))[2:].zfill(12)
        if (len(imm) > 12):
            raise ValueError("Instruction %d: Immediate Value must not exceed 12 bits." % PC_cnt)
        funct3 = '101'
        funct7 = '0100000'
        opcode = '0010011'
        mem_line = funct7 + imm[-5::1] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'add'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '000'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sub'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '000'
        funct7 = '0100000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sll'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '001'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'slt'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '010'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sltu'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '011'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'xor'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '100'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'srl'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '101'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sra'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '101'
        funct7 = '0100000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'or'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '110'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'and'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '111'
        funct7 = '0000000'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    #pseudo instructions
    elif(instruction[0] == 'mv'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2]
        imm = '000000000000'
        funct3 = '000'
        opcode = '0010011'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'li'):
        rd = instruction[1].strip(',')
        if ('0x' in instruction[2]):
            imm = str(bin(int(instruction[2][2:], 16)))[2:].zfill(32)
        elif (instruction[2].isnumeric() == False):
            imm = var_dict[instruction[2]]
        else:
            imm = str(bin(int(instruction[2])))[2:].zfill(32)
        if (imm[-12] == '1'):
            upper_imm = bin(int(imm[-32:-12:1],2) + 1)[2:]
        else:
            upper_imm = imm[-32:-12:1]
        lower_imm = imm[-12::1]
        opcode = '0110111'
        mem_line = upper_imm.zfill(20) + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
        opcode = '0010011'
        rs1 = rd
        mem_line = lower_imm.zfill(12) + registers[rs1] + '000' + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
                

    elif(instruction[0] == 'beqz'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '000'
        rs2 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bnez'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '001'
        rs2 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bltz'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '100'
        rs2 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bgez'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs1 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '101'
        rs2 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'blez'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs2 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '101'
        rs1 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'bgtz'):
        imm = int(label_dict[instruction[2]])
        offset = imm - PC_cnt
        if (offset < 0):
            imm = str(bin(offset))[3:-1:1].zfill(12)
            twos_comp = bin((int(imm,2) ^ 0b111111111111) + 1)
            imm = str(twos_comp)[2:].rjust(12,'1')
        else:
            imm = str(bin(offset))[2:-1:1].zfill(12)
        if (int(imm,2) > 2**12 - 1):
            raise ValueError("Line %d: Immediate value must be less than or equal to 4095." % i)     
            exit
        rs2 = instruction[1].strip(',')
        opcode = '1100011'
        funct3 = '100'
        rs1 = 'x0'
        mem_line = imm[-12] + imm[-10:-4:1] + registers[rs2] + registers[rs1] + funct3 + imm[-4::1] + imm[-11] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
            
    elif (instruction[0] == 'j'):
        # FIXED: Use JAL with PC-relative offset (not JALR with absolute address)
        target_addr = int(label_dict[instruction[1]])
        offset = target_addr - PC_cnt
        
        if offset < 0:
            imm = str(bin(offset & 0xFFFFF))[2:].zfill(20)
        else:
            imm = str(bin(offset))[2:].zfill(20)
        
        if (len(imm) > 20):
            raise ValueError("Line %d: Jump offset too large (max ±1MB)." % i)
            exit
        rd = 'x0'
        opcode = '1101111'  # JAL opcode
        mem_line = imm[-20] + imm[-10::1] + imm[-11] + imm[-19:-11:-1] + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'la'):
        rd = instruction[1].strip(',')
        imm = str(bin(int(label_dict[instruction[2]])))[2:].zfill(32)
        # use lui instruction then addi instruction
        upper_imm = imm[-32:-12:1]
        lower_imm = imm[-12::1]
        opcode = '0110111'
        mem_line = upper_imm.zfill(20) + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
        opcode = '0010011'
        rs1 = rd
        mem_line = lower_imm.zfill(12) + registers[rs1] + '000' + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'call'):
        # FIXED: Use JAL with PC-relative offset (not JALR with absolute address)
        target_addr = int(label_dict[instruction[1]])
        offset = target_addr - PC_cnt
        
        if offset < 0:
            imm = str(bin(offset & 0xFFFFF))[2:].zfill(20)
        else:
            imm = str(bin(offset))[2:].zfill(20)
        
        if (len(imm) > 20):
            raise ValueError("Line %d: Call offset too large (max ±1MB)." % i)
            exit
        rd = 'ra'  # Link register
        opcode = '1101111'  # JAL opcode
        mem_line = imm[-20] + imm[-10::1] + imm[-11] + imm[-19:-11:-1] + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'ret'):
        imm = '0'.zfill(12)
        rd = 'x0'
        opcode = '1100111'
        funct3 = '000'
        rs1 = 'ra'
        mem_line = imm.zfill(12) + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
    
    # csr instructions
    elif(instruction[0] == 'csrrw'):
        csr = instruction[2].strip(',')
        csr_adr = str(bin(int(csr_dict[csr][2:],16)))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = instruction[3]
        mem_line = csr_adr + registers[rs1] + '001' + registers[rd] + '1110011'
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif (instruction[0] == 'csrw'):
        csr = instruction[1].strip(',')
        csr_adr = str(bin(int(csr_dict[csr][2:],16)))[2:].zfill(12)
        rd = 'x0'
        rs1 = instruction[2]
        mem_line = csr_adr + registers[rs1] + '001' + registers[rd] + '1110011'
        PC_cnt = write_to_file(mem_line, PC_cnt)
        
    elif(instruction[0] == 'mret'):
        mem_line = '00110000001000000000000001110011'
        PC_cnt = write_to_file(mem_line, PC_cnt)
    
    elif(instruction[0] == 'mul'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '000'
        funct7 = '0000001'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
        
    elif(instruction[0] == 'div'):
        rd = instruction[1].strip(',')
        rs1 = instruction[2].strip(',')
        rs2 = instruction[3]
        funct3 = '100'
        funct7 = '0000001'
        opcode = '0110011'
        mem_line = funct7 + registers[rs2] + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'lb'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0000011'
        funct3 = '000'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'lbu'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0000011'
        funct3 = '100'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
            
    elif(instruction[0] == 'lh'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0000011'
        funct3 = '001'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)
    
    elif(instruction[0] == 'lhu'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rd = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0000011'
        funct3 = '101'
        mem_line = imm + registers[rs1] + funct3 + registers[rd] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sb'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rs2 = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0100011'
        funct3 = '000'
        mem_line = imm[-12:-5:1] + registers[rs2] + registers[rs1] + funct3 + imm[-5::1] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

    elif(instruction[0] == 'sh'):
        arr = instruction[2].split('(')
        imm = str(bin(int(arr[0])))[2:].zfill(12)
        rs2 = instruction[1].strip(',')
        rs1 = arr[1].strip(')')
        opcode = '0100011'
        funct3 = '001'
        mem_line = imm[-12:-5:1] + registers[rs2] + registers[rs1] + funct3 + imm[-5::1] + opcode
        PC_cnt = write_to_file(mem_line, PC_cnt)

file.close()
mem_file.close()

print(f"\nAssembly complete! Generated {output_filename}")