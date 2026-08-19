`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Datapath
//
// PURPOSE
//   Wires the program counter, instruction memory, register file, ALU and data
//   memory together, and computes branch and jump targets. Holds no control
//   logic of its own -- every enable comes from ControlUnit.
//
// STRUCTURE
//   PC -> InstructionMemory -> decode fields
//                           -> RegisterFile (rs, rt)
//                           -> ALU -> DataMemory address
//                                  -> writeback mux -> RegisterFile write port
//
// CRITICAL PATH
//   The routed critical path runs:
//
//       IMEM BRAM output -> register-file read mux -> ALU -> DMEM address
//
//   24 logic levels, of which 13 sit inside the MAC4 adder tree when
//   ENABLE_MAC4 = 1. This is why MAC4 is parameterised rather than always
//   present: the arm lengthens this path on every instruction, executed or not.
//
// WHAT IS NOT ON THE CRITICAL PATH
//   branch_taken and the branch/jump target adders. The top five failing paths
//   all ended at DMEM address inputs or register-file write ports; none at the
//   PC. The 32-bit branch comparator has slack to spare, so splitting or
//   registering it buys nothing.
//
//   Similarly, these are pure wire aliases with zero logic and zero delay:
//
//       assign dmem_addr  = alu_result;
//       assign dmem_wdata = rt_data;
//       assign wb_data    = write_data;
//
//   Renaming a net is not a mux. Registering dmem_addr would break correctness:
//   DataMemory needs the address in the same cycle dmem_en is asserted
//   (S_EXEC), so adding a register would require an extra FSM state.
//
// ADDRESSING -- READ THIS BEFORE EDITING
//   Two conventions coexist deliberately:
//     * PC is byte-oriented: PC + 4 per instruction, branch offsets shifted
//       left by 2, as in MIPS.
//     * Data memory is WORD-addressed: LW r5, 3(r10) reads word r10+3, not
//       byte r10+3.
//
//   The packed network is an array of 32-bit words with no sub-word access
//   anywhere, so word addressing is the natural choice. Mixing the two up
//   produces offsets wrong by exactly 4x, which in a dense weight array still
//   lands on a plausible-looking weight. It cost a long debugging session; see
//   docs/debugging.md.
//
// BRANCH AND JUMP
//   wire branch_taken = (branch_equal     && (rs_data == rt_data)) ||
//                       (branch_not_equal && (rs_data != rt_data));
//
//   branch_target = branch_taken ? (pc_plus4 + {{14{imm16[15]}}, imm16, 2'b00})
//                                : pc_plus4;
//   jump_target   = {pc[31:28], jump_imm, 2'b00};
//
// SIMULATION TRACING
//   A $display block inside `synthesis translate_off` prints PC, opcode,
//   operands, ALU result and writeback each cycle. It is excluded from
//   synthesis and is the fastest way to find where hardware diverges from the
//   golden model in sim/.
//
// CHANGE HISTORY
//   - Split into fetch/execute/writeback phases driven by ControlUnit enables.
//   - Data memory addressing corrected from byte to word throughout.
//   - Added writeback bus to the port list so the top level can observe it.
//////////////////////////////////////////////////////////////////////////////////

module Datapath (
    input clk,
    input rst,

    // Control signals from Control Unit
    input        reg_dst,
    input        alu_src,
    input        mem_to_reg,
    input        reg_write,
    input        mem_read,
    input        mem_write,
    input        branch_equal,
    input        branch_not_equal,
    input        jump,
    input [5:0]  alu_op,
    input [1:0]  pc_src,

    // Sequencing from Control Unit (new)
    input        imem_en,
    input        dmem_en,
    input        pc_enable,

    output [31:0] pc,
    output [31:0] instruction,

    // Observability taps -- let TopModule latch the result and stop synthesis
    // pruning the datapath as unobservable.
    output [31:0] wb_data,
    output [31:0] dmem_addr,
    output [31:0] dmem_wdata,
    output        dmem_we
);

    // ===================================================================
    // Program Counter
    // ===================================================================
    wire [31:0] branch_target;
    wire [31:0] jump_target;

    ProgramCounter PC (
        .clk(clk),
        .rst(rst),
        .pc_enable(pc_enable),
        .pc_src(pc_src),
        .branch_target(branch_target),
        .jump_target(jump_target),
        .pc(pc)
    );

    // ===================================================================
    // Instruction Memory (BRAM; its output register is the IR)
    // ===================================================================
    InstructionMemory IMEM (
        .clk(clk),
        .en(imem_en),
        .addr(pc),
        .instruction(instruction)
    );

    // ===================================================================
    // Instruction field extraction
    // ===================================================================
    wire [5:0]  opcode   = instruction[31:26];
    wire [4:0]  rs_addr  = instruction[25:21];
    wire [4:0]  rt_addr  = instruction[20:16];
    wire [4:0]  rd_addr  = instruction[15:11];
    wire [15:0] imm16    = instruction[15:0];
    wire [25:0] jump_imm = instruction[25:0];
    wire [5:0]  funct    = instruction[5:0];
    wire [4:0]  shamt    = instruction[10:6];

    // ===================================================================
    // Register File
    // ===================================================================
    wire [31:0] rs_data, rt_data, rd_data, write_data;
    wire [4:0]  write_reg = (reg_dst) ? rd_addr : rt_addr;

    RegisterFile RF (
        .clk(clk),
        .rst(rst),
        .reg_write(reg_write),
        .read_reg1(rs_addr),
        .read_reg2(rt_addr),
        .read_reg3(rd_addr),
        .write_reg(write_reg),
        .write_data(write_data),
        .read_data1(rs_data),
        .read_data2(rt_data),
        .read_data3(rd_data)
    );

    // ===================================================================
    // ALU
    // ===================================================================
    wire [31:0] imm_ext   = {{16{imm16[15]}}, imm16};
    wire [31:0] alu_inputB = (alu_src) ? imm_ext : rt_data;

    wire [31:0] alu_result;
    wire        alu_overflow;

    ALU alu (
        .rs(rs_data),
        .rt(alu_inputB),
        .rd(rd_data),
        .funct(alu_op),
        .shamt(shamt),
        .result(alu_result),
        .overflow(alu_overflow)
    );

    // ===================================================================
    // Data Memory (BRAM; its output register is the MDR)
    // ===================================================================
    wire [31:0] mem_read_data;

    DataMemory DMEM (
        .clk(clk),
        .en(dmem_en),
        .mem_write(mem_write),
        .addr(alu_result),
        .write_data(rt_data),
        .read_data(mem_read_data)
    );

    // ===================================================================
    // Writeback
    // ===================================================================
    assign write_data = (mem_to_reg) ? mem_read_data : alu_result;

    // ===================================================================
    // Observability taps
    // ===================================================================
    assign wb_data    = write_data;
    assign dmem_addr  = alu_result;
    assign dmem_wdata = rt_data;
    assign dmem_we    = mem_write;

    // ===================================================================
    // Branch / jump targets
    // ===================================================================
    wire branch_taken = (branch_equal     && (rs_data == rt_data)) ||
                        (branch_not_equal && (rs_data != rt_data));

    wire [31:0] pc_plus4      = pc + 32'd4;
    wire [31:0] branch_offset = {{14{imm16[15]}}, imm16, 2'b00};

    assign branch_target = branch_taken ? (pc_plus4 + branch_offset) : pc_plus4;
    assign jump_target   = {pc[31:28], jump_imm, 2'b00};

    // ===================================================================
    // Simulation-only tracing
    // ===================================================================
    // synthesis translate_off
    always @(posedge clk) if (!rst && pc_enable) begin
        $display("DBG pc=%h op=%b rs=%0d rt=%0d rd=%0d aluB=%0d alu=%0d mem=%0d regW=%b W[%0d]=%0d",
                 pc, opcode, rs_data, rt_data, rd_data,
                 alu_inputB, alu_result, mem_read_data,
                 reg_write, write_reg, write_data);
    end
    // synthesis translate_on

endmodule
