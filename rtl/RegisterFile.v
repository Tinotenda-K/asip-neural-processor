`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// RegisterFile
//
// PURPOSE
//   32 x 32-bit general-purpose registers. Three asynchronous read ports, one
//   synchronous write port.
//
// INTERFACE
//   clk                                   core clock (50 MHz)
//   rst                                   synchronised reset
//   read_reg1, read_reg2, read_reg3       [4:0]  read addresses (rs, rt)
//   read_data1, read_data2, read_data2    [31:0] combinational reads
//   write_reg                             [4:0]  write address (rd or rt)
//   write_data                            [31:0] value to commit
//   reg_write                             write enable -- asserted in S_WB only
//
// TIMING CONTRACT
//   Reads are ASYNCHRONOUS and that is correct here. The array is 32 entries,
//   so it maps to distributed LUT logic cheaply -- unlike the 64K memories,
//   where async reads were the resource catastrophe. Do not "fix" this by
//   registering the read ports: S_EXEC needs rs and rt in the same cycle it
//   evaluates the ALU, and adding a cycle means adding an FSM state.
//
//   The write is synchronous and gated on reg_write, which ControlUnit asserts
//   only in S_WB. Read-during-write is not a hazard on this design because
//   reads happen in S_EXEC and writes in S_WB -- different cycles, never
//   concurrent.
//
// REGISTER 0
//   Hardwired to zero. Writes to it are silently discarded rather than
//   suppressed at the write port, so assembly may use r0 as a scratch
//   destination when a result is not wanted.
//
// CRITICAL PATH
//   The read mux is the second stage of the design's critical path
//   (IMEM BRAM out -> RF read mux -> ALU -> DMEM address). Widening the
//   register file or adding a third read port would extend it.
//
//   The third read port exists BECAUSE of MAC and MAC4. Both use rd as an
//   accumulator input as well as the destination, so a single instruction
//   reads rs, rt and rd. This is what makes the accumulate fused rather than
//   a multiply followed by a separate add, and it is the main structural
//   cost of the ASIP extension: a third 32:1 read mux on the critical path.
//
// CHANGE HISTORY
//   - Write port gated on reg_write from the FSM rather than on opcode decode.
//   - Register 0 write suppression made explicit rather than relying on
//     assembly discipline.
//////////////////////////////////////////////////////////////////////////////////


module RegisterFile(
    input clk,
    input rst,
    input reg_write,
    input [4:0] read_reg1,
    input [4:0] read_reg2,
    input [4:0] read_reg3,
    input [4:0] write_reg,
    input [31:0] write_data,
    output [31:0] read_data1,
    output [31:0] read_data2,
    output [31:0] read_data3
);

    reg [31:0] regs [0:31];
    integer i;

    // Reset all registers
    always @(posedge clk) begin
        if (rst)
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        else if (reg_write && (write_reg != 5'b0))
            regs[write_reg] <= write_data;
    end

    // Asynchronous read
    assign read_data1 = (read_reg1 == 5'b0) ? 32'b0 : regs[read_reg1];
    assign read_data2 = (read_reg2 == 5'b0) ? 32'b0 : regs[read_reg2];
    assign read_data3 = (read_reg3 == 5'b0) ? 32'b0 : regs[read_reg3];

endmodule

