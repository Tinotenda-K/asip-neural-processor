`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ProgramCounter
//
// PURPOSE
//   Holds the program counter. Updates once per instruction, in S_WB only.
//
// INTERFACE
//   clk         core clock (50 MHz)
//   rst         synchronised reset; PC returns to 32'h0
//   pc_enable   update enable -- asserted by ControlUnit in S_WB only
//   pc_src         [1:0]  next-PC select: 00 = PC+4, 01 = branch, 10 = jump
//   branch_target  [31:0] computed in Datapath (already resolved: equals
//                         pc_plus4 when the branch is not taken)
//   jump_target    [31:0] {pc[31:28], jump_imm, 2'b00}
//   pc          [31:0] current value
//
// TIMING CONTRACT
//   pc_enable is the only thing preventing the PC from advancing three times
//   per instruction. It is asserted for exactly one of the three FSM states.
//   If the PC ever advances during S_FETCH or S_EXEC, the instruction memory
//   read is issued against an address the datapath has not finished using.
//
// ADDRESSING
//   Byte-oriented: PC + 4 per instruction, matching MIPS convention, with
//   branch offsets shifted left by 2 in Datapath. Note that DATA memory uses
//   word addressing instead - the two conventions differ deliberately and the
//   mismatch is documented in Datapath.v and docs/isa.md.
//
// OBSERVABILITY
//   pc is exported to the top level as pc_out[10:0]. The upper bits are
//   permanently zero for the programs this processor runs, so exporting all 32
//   wasted LEDs. Narrowing it is cosmetic on the board but also keeps the PC
//   observable to synthesis -- see the pruning note in TopModule.v.
//
// CHANGE HISTORY
//   - Update gated on pc_enable when the design became multi-cycle; previously
//     it advanced every clock edge.
//   - Output width to the top level reduced from 16 to 11 bits.
//////////////////////////////////////////////////////////////////////////////////


module ProgramCounter(

    input clk, // clock
    input rst, // reset
    
    input pc_enable, // set to 1 to stall PC when we have NOP or have load delays
    input [1:0] pc_src, // Selects next PC source (00-> PC + 4, 01-> branch, 10-> jump)
    input [31:0] branch_target, // Target address for branching instruction BEQ/ BNE
    input [31:0] jump_target, // Target for J-type Jump
    
    output reg [31:0] pc // Current PC output
    );
    
    // System has instructions that are 32 bits long.
    // However MIPS-like systems are byte-addressable. 
    // So the instruction is stored in 4 bytes in system.
    // And each 32-bit address points to a byte in system.
    // So 1 adress -> a quarter of the instruction.
    // So PC inceases by 4 to skip 3 bytes (from previous instruction)
    
    always @(posedge clk) begin
        if (rst)
            pc <= 32'b0;
        else if (pc_enable) begin
            case (pc_src)
                2'b00: pc <= pc + 4;             // normal
                2'b01: pc <= branch_target;      // BEQ/BNE
                2'b10: pc <= jump_target;        // Jump
                default: pc <= pc;               // hold (NOP)
            endcase
        end
    end
endmodule
