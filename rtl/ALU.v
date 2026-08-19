`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ALU -- MAC4 build, timing-optimised
//
// CONFIGURATION FOR dnn_mac4.asm
//   ENABLE_MAC4 = 1   the program uses MAC4 exclusively
//   ENABLE_MAC  = 0   the program contains ZERO plain MAC instructions
//   ENABLE_MULT = 0   unused
//
// Set ENABLE_MAC = 1 and ENABLE_MAC4 = 0 to rebuild for dnn_final_packed.asm
// (the pre-MAC4 program) so the two can be compared on identical RTL.
//
// TIMING CHANGES vs the previous version
// --------------------------------------
// 1. BALANCED ADDER TREE.  "p0 + p1 + p2 + p3" synthesises left-associative:
//         ((p0+p1)+p2)+p3        3 carry chains in series
//    then "+ rd" makes a 4th.  Restructured as
//         (p0+p1) + (p2+p3)      2 carry chains
//    then "+ rd" makes 3.  One full carry-chain delay removed from the
//    critical path.
//
// 2. MAC ARM DISABLED.  The plain-MAC case arm carried its own 32-bit adder
//    and an input to the result mux, on every instruction, for an instruction
//    the program never issues.
//
// WHY NOT (* use_dsp = "yes" *)
// ----------------------------
// A DSP48E1 is a 25x18 multiplier; four 8x8 products would occupy four of
// them at ~5% utilisation each. More importantly an UNPIPELINED DSP48E1
// multiply costs roughly 3.5-4 ns on a -1 part, against ~1.5-2 ns for an 8x8
// LUT multiply. The DSP only wins when its input and output registers are
// used -- which is what Vivado's DPIP-1 warnings were asking for. This ALU is
// fully combinational inside S_EXEC, so there is nowhere to put those
// registers without adding FSM states. Forcing DSPs here makes WNS worse, and
// the earlier build with 3 DSPs (MULT enabled) confirmed that empirically.
//
// Revisit only if the ALU is ever pipelined.
//
// ALSO FIXED (carried over)
//   * MULT overflow: |prod[63:32] fires on every negative product, because
//     sign extension fills the upper word with ones.
//   * ADD overflow: sum[32] is the unsigned carry-out, not signed overflow.
//////////////////////////////////////////////////////////////////////////////////

module ALU #(
    parameter ENABLE_MAC4 = 1,
    parameter ENABLE_MAC  = 0,
    parameter ENABLE_MULT = 0
)(
    input  signed [31:0] rs,
    input  signed [31:0] rt,
    input  signed [31:0] rd,
    input         [5:0]  funct,
    input         [4:0]  shamt,
    output reg signed [31:0] result,
    output reg           overflow
);

    wire signed [32:0] sum = {rs[31], rs} + {rt[31], rt};

    // ---- lane 0 product, shared by MAC and MAC4 ---------------------------
    wire signed [7:0]  rs_b0 = rs[7:0];
    wire signed [7:0]  rt_b0 = rt[7:0];
    wire signed [15:0] p0    = rs_b0 * rt_b0;

    // ---- optional wide multiply -------------------------------------------
    wire signed [63:0] prod = ENABLE_MULT ? (rs * rt) : 64'sd0;

    // ---- optional SIMD 4-lane dot product ----------------------------------
    wire signed [17:0] dot4;
    generate
        if (ENABLE_MAC4) begin : g_mac4
            wire signed [15:0] p1 = $signed(rs[15: 8]) * $signed(rt[15: 8]);
            wire signed [15:0] p2 = $signed(rs[23:16]) * $signed(rt[23:16]);
            wire signed [15:0] p3 = $signed(rs[31:24]) * $signed(rt[31:24]);

            // Balanced tree: two adds in parallel, then one to combine.
            wire signed [16:0] s01 = p0 + p1;
            wire signed [16:0] s23 = p2 + p3;
            assign dot4 = s01 + s23;
        end else begin : g_no_mac4
            assign dot4 = 18'sd0;
        end
    endgenerate

    always @* begin
        result   = 32'b0;
        overflow = 1'b0;

        case (funct)
            6'b000000: begin                            // ADD
                result   = sum[31:0];
                overflow = (rs[31] == rt[31]) && (sum[31] != rs[31]);
            end
            6'b000001: result = rs - rt;                // SUB
            6'b000010: result = rs & rt;                // AND
            6'b000011: result = rs | rt;                // OR
            6'b000100: result = rs ^ rt;                // XOR
            6'b000101: result = rt << shamt;            // SLL
            6'b000110: result = rt >> shamt;            // SRL  (logical)

            6'b000111: begin                            // MAC
                if (ENABLE_MAC)
                    result = rd + {{16{p0[15]}}, p0};
            end

            6'b001000: result = (rs < 0) ? 32'b0 : rs;  // RELU
            6'b001001: result = ~rs;                    // NOT

            6'b001010: begin                            // MULT
                if (ENABLE_MULT) begin
                    result   = prod[31:0];
                    overflow = ~(&prod[63:31]) & ~(|prod[63:31]);
                end
            end

            6'b001011: result = rt >>> shamt;           // SRA  (arithmetic)

            6'b001100: begin                            // MAC4
                if (ENABLE_MAC4)
                    result = rd + {{14{dot4[17]}}, dot4};
            end

            default: result = 32'b0;
        endcase
    end
endmodule