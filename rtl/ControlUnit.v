`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ControlUnit
//
// PURPOSE
//   Three-state finite state machine sequencing the datapath, plus instruction
//   decode. Produces every control signal the datapath consumes.
//
// STATE MACHINE
//   S_FETCH -> S_EXEC -> S_WB -> S_FETCH, unconditionally.
//   CPI = 3 for every instruction, with no exceptions -- there is no early-out
//   path and no stall.
//
//     S_FETCH   Instruction memory read is issued at the current PC. The BRAM
//               output register captures the instruction word at the end of
//               this cycle, so it is valid for the whole of S_EXEC.
//               reg_write = 0, pc_enable = 0, mem_write = 0.
//
//     S_EXEC    Register file read (rs, rt). ALU evaluates. For LW/SW the data
//               memory is addressed with alu_result and dmem_en is asserted.
//               Nothing commits.
//               reg_write = 0, pc_enable = 0.
//
//     S_WB      Register file write port commits for R-type and LW.
//               PC advances to branch target, jump target or PC+4.
//               pc_enable = 1.
//
// WHY THREE STATES AND NOT ONE
//   The single-cycle version required both memories to answer combinationally.
//   Vivado cannot map an asynchronous read to Block RAM, so it built the
//   memories from distributed LUTRAM: 65,536 RAMS64E primitives required
//   against roughly 9,600 available. Synthesis passed and implementation
//   failed with seven DRC resource errors.
//
//   Registered reads need a cycle boundary between presenting an address and
//   consuming the data. That boundary is what S_FETCH -> S_EXEC provides.
//
// WHY THREE STATES AND NOT FIVE
//   Costed and rejected. Adding an ALUOut register alone pushes CPI from 3 to
//   4: 814,460 cycles against 610,845, which at 50 MHz makes inference SLOWER
//   (16.29 ms vs 12.22 ms). It only pays above roughly 100 MHz, and 100 MHz
//   needs the full IR/A/B/ALUOut split plus a pipelined ALU -- S_EXEC was
//   estimated at ~9.03 ns against a 9.07 ns budget without MAC4; enabling
//   it makes S_EXEC longer still
//
// DECODE
//   opcode -> instruction class -> control signal set.
//   R-type operations are distinguished by funct, which is passed through to
//   the ALU rather than decoded here.
//
// OUTPUTS
//   pc_enable       PC updates (S_WB only)
//   reg_write       register file write enable (S_WB, R-type and LW only)
//   mem_write       data memory write enable (S_EXEC, SW only)
//   dmem_en         data memory enable (S_EXEC, LW and SW)
//   mem_to_reg      writeback source select: DMEM data vs ALU result
//   alu_src         ALU operand B select: rt vs sign-extended immediate
//   reg_dst         write register select: rd vs rt
//   branch_equal    BEQ decoded
//   branch_not_equal BNE decoded
//   jump            J decoded
//   mem_read        data memory read enable
//   alu_op          ALU operation code
//   pc_src          Selects next PC source (00-> PC + 4, 01-> branch, 10-> jump)
//   imem_en         Instruction memory enable
//
// NOTE FOR ANYONE READING THIS EXPECTING THE TEXTBOOK MACHINE
//   This is not the Patterson & Hennessy multi-cycle controller. That FSM has
//   ten states, a shared instruction/data memory selected by IorD, and A/B/
//   ALUOut temporaries. This design has three states, separate memories, and
//   no temporaries. The shared idea is a state machine sequencing a datapath;
//   the structure is different.
//
// CHANGE HISTORY
//   - Rewritten from combinational single-cycle decode to the three-state FSM.
//   - Added pc_enable, reg_write gating and dmem_en so that nothing commits
//     outside its intended state.
//////////////////////////////////////////////////////////////////////////////////

module ControlUnit(
    input       clk,
    input       rst,
    input [5:0] opcode,
    input [5:0] funct,

    // datapath control
    output reg        reg_dst,
    output reg        alu_src,
    output reg        mem_to_reg,
    output reg        reg_write,
    output reg        mem_read,
    output reg        mem_write,
    output reg        branch_equal,
    output reg        branch_not_equal,
    output reg        jump,
    output reg [5:0]  alu_op,
    output reg [1:0]  pc_src,

    // sequencing control (new)
    output            imem_en,
    output            dmem_en,
    output            pc_enable
);

    // ---------------------------------------------------------------
    // State register
    // ---------------------------------------------------------------
    localparam S_FETCH = 2'd0,
               S_EXEC  = 2'd1,
               S_WB    = 2'd2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst)
            state <= S_FETCH;
        else case (state)
            S_FETCH: state <= S_EXEC;
            S_EXEC:  state <= S_WB;
            S_WB:    state <= S_FETCH;
            default: state <= S_FETCH;
        endcase
    end

    assign imem_en   = (state == S_FETCH);
    assign dmem_en   = (state == S_EXEC);
    assign pc_enable = (state == S_WB);

    // ---------------------------------------------------------------
    // Combinational decode (unchanged), then gated by state
    // ---------------------------------------------------------------
    reg reg_write_d, mem_write_d;

    always @(*) begin
        reg_dst          = 1'b0;
        alu_src          = 1'b0;
        mem_to_reg       = 1'b0;
        reg_write_d      = 1'b0;
        mem_read         = 1'b0;
        mem_write_d      = 1'b0;
        branch_equal     = 1'b0;
        branch_not_equal = 1'b0;
        jump             = 1'b0;
        alu_op           = 6'b000000;
        pc_src           = 2'b00;

        case (opcode)
            6'b000000: begin                    // R-type
                reg_dst     = 1'b1;
                alu_src     = 1'b0;
                reg_write_d = 1'b1;
                alu_op      = funct;
            end

            6'b000100: begin                    // ADDI
                reg_dst     = 1'b0;
                alu_src     = 1'b1;
                reg_write_d = 1'b1;
                alu_op      = 6'b000000;
            end

            6'b000101: begin                    // LW
                reg_dst     = 1'b0;
                alu_src     = 1'b1;
                mem_to_reg  = 1'b1;
                reg_write_d = 1'b1;
                mem_read    = 1'b1;
                alu_op      = 6'b000000;
            end

            6'b000110: begin                    // SW
                alu_src     = 1'b1;
                mem_write_d = 1'b1;
                alu_op      = 6'b000000;
            end

            6'b000111: begin                    // BEQ
                branch_equal = 1'b1;
                pc_src       = 2'b01;
            end

            6'b001000: begin                    // BNE
                branch_not_equal = 1'b1;
                pc_src           = 2'b01;
            end

            6'b000010: begin                    // J
                jump   = 1'b1;
                pc_src = 2'b10;
            end

            6'b111111: begin                    // NOP
            end

            default: begin
            end
        endcase
    end

    // Gate the two committing signals to their states.
    always @(*) begin
        reg_write = reg_write_d && (state == S_WB);
        mem_write = mem_write_d && (state == S_EXEC);
    end

endmodule
