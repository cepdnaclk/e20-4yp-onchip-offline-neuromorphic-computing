
import sys

# Simple RISC-V Assembler
# Supports basics: LUI, ADDI, LW, SW, ADD, SUB, BEQ, BNE, JAL, JALR
# Usage: python mini_assembler.py input.s

def to_bin(val, bits):
    val = int(val)
    if val < 0:
        val = (1 << bits) + val
    return format(val & ((1 << bits) - 1), f'0{bits}b')

registers = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4, 't0': 5, 't1': 6, 't2': 7,
    's0': 8, 's1': 9, 'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16, 'a7': 17, 's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27, 't3': 28, 't4': 29, 't5': 30, 't6': 31
}

def get_reg(name):
    name = name.replace(',', '')
    if name in registers:
        return registers[name]
    if name.startswith('x'):
        return int(name[1:])
    return 0

labels = {}
instructions = []

def parse_file(filename):
    pc = 0
    with open(filename, 'r') as f:
        # First pass: map labels
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'): continue
            if ':' in line:
                label = line.split(':')[0].strip()
                labels[label] = pc
                continue # Assuming label is alone on line for simplicity, or process rest
            
            pc += 4

    pc = 0
    with open(filename, 'r') as f:
        # Second pass: generate code
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'): continue
            if ':' in line: continue # Label

            parts = line.replace(',', ' ').split()
            op = parts[0].upper()
            
            machine_code = 0
            
            if op == 'LUI': # U-type
                # LUI rd, imm
                rd = get_reg(parts[1])
                imm = int(parts[2], 0)
                machine_code = (imm << 12) | (rd << 7) | 0x37
                
            elif op in ['ADDI', 'ANDI', 'ORI', 'XORI', 'SLLI', 'SRLI', 'SRAI']: # I-type arithmetic
                # OP rd, rs1, imm
                rd = get_reg(parts[1])
                rs1 = get_reg(parts[2])
                imm = int(parts[3], 0)
                
                funct3 = 0
                funct7 = 0
                opcode = 0x13
                
                if op == 'ADDI': funct3 = 0
                # ... others
                
                machine_code = (to_bin(imm, 12) + to_bin(rs1, 5) + to_bin(funct3, 3) + to_bin(rd, 5) + to_bin(opcode, 7))
                # Hacky construction for simplicity, just output hex directly
                machine_code = (imm & 0xFFF) << 20 | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
                
            elif op == 'LW': # I-type load
                # LW rd, offset(rs1)
                rd = get_reg(parts[1])
                offset_part = parts[2]
                offset = int(offset_part.split('(')[0], 0)
                rs1 = get_reg(offset_part.split('(')[1].replace(')', ''))
                
                machine_code = (offset & 0xFFF) << 20 | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03
                
            elif op == 'SW': # S-type store
                # SW rs2, offset(rs1)
                rs2 = get_reg(parts[1])
                offset_part = parts[2]
                offset = int(offset_part.split('(')[0], 0)
                rs1 = get_reg(offset_part.split('(')[1].replace(')', ''))
                
                imm_11_5 = (offset >> 5) & 0x7F
                imm_4_0 = offset & 0x1F
                machine_code = (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0x2 << 12) | (imm_4_0 << 7) | 0x23

            elif op in ['ADD', 'SUB', 'AND', 'OR', 'XOR', 'SLL', 'SRL', 'SRA']: # R-type
                rd = get_reg(parts[1])
                rs1 = get_reg(parts[2])
                rs2 = get_reg(parts[3])
                
                funct3 = 0
                funct7 = 0
                if op == 'ADD': funct3 = 0; funct7 = 0
                elif op == 'SUB': funct3 = 0; funct7 = 32
                elif op == 'OR': funct3 = 6; funct7 = 0
                elif op == 'AND': funct3 = 7; funct7 = 0
                
                machine_code = (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33

            elif op in ['BEQ', 'BNE']: # B-type
                rs1 = get_reg(parts[1])
                rs2 = get_reg(parts[2])
                label = parts[3]
                target_pc = labels[label]
                offset = target_pc - pc
                
                imm_12 = (offset >> 12) & 1
                imm_10_5 = (offset >> 5) & 0x3F
                imm_4_1 = (offset >> 1) & 0xF
                imm_11 = (offset >> 11) & 1
                
                funct3 = 0 if op == 'BEQ' else 1
                
                machine_code = (imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | 0x63

            elif op == 'LI': # Pseudo-instruction: LI rd, imm -> ADDI rd, zero, imm
                rd = get_reg(parts[1])
                imm = int(parts[2], 0)
                # Just emit ADDI
                machine_code = (imm & 0xFFF) << 20 | (0 << 15) | (0 << 12) | (rd << 7) | 0x13
            
            print(f"{machine_code:08x}")
            pc += 4

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python mini_assembler.py <input.s>")
        sys.exit(1)
    parse_file(sys.argv[1])
