`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ControlUnit - 3-state multi-cycle FSM
//
// The original was purely combinational (single-cycle). Block RAM has a
// registered read, so a fetch and a data read each need their own clock edge.
// This adds a minimal 3-state FSM around the SAME combinational decoder.
//
//   S_FETCH : imem_en=1. At the closing edge, IMEM latches mem[pc].
//             'instruction' becomes valid for S_EXEC.
//             (Nothing else is enabled: 'instruction' still shows the
//              PREVIOUS instruction during this state, which is harmless
//              because every write enable is gated off here.)
//
//   S_EXEC  : decode, register read, ALU, dmem_en=1 with addr=alu_result.
//             SW commits here. At the closing edge DMEM latches its output.
//
//   S_WB    : mem_read_data valid. reg_write commits. pc_enable=1.
//
// No new datapath registers are required: the two BRAM output registers act
// as the instruction register and the memory data register, and alu_result
// stays valid through S_WB because 'instruction' is held and the register
// file is not written until the closing edge of S_WB.
//
// CPI = 3, but the ~1500-level LUTRAM mux chain is gone, so Fmax rises by far
// more than 3x. Net throughput is higher than the single-cycle version.
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
