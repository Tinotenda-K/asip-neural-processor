`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ALU -- parameterised, timing-aware
//
// PURPOSE
//   Combinational arithmetic and logic unit. Operation selected by funct.
//   Includes the four instructions that make this an ASIP rather than a small
//   MIPS clone: MAC, MAC4, RELU and (load-bearing here) SRA.
//
// PARAMETERS
//   ENABLE_MAC4   default 0. Include the four-way SIMD multiply-accumulate.
//   ENABLE_MULT   default 0. Include the 32x32 multiplier.
//
//   WHY THESE ARE PARAMETERS AND NOT JUST UNUSED OPCODES
//   Every operation lives in the same combinational case statement, so an arm
//   that is present but never executed still lengthens the critical path and
//   widens the result mux on EVERY instruction -- including the LW/MAC/SRL
//   sequence the baseline program actually runs. 13 of the 24 logic levels on
//   the routed critical path sit in the MAC4 adder tree (dot4_carry,
//   dot4__47_carry, dot4__98_carry in the timing report).
//
//   Turn each on only when the assembled program uses it. The delta in LUTs,
//   WNS and instruction count between configurations is the project's central
//   quantitative result -- see results/benchmark.md.
//
// THE CUSTOM INSTRUCTIONS
//
//   MAC   rd <- rd + sext(rs[7:0]) * sext(rt[7:0])
//         rd is both source and destination; that is what makes it one
//         instruction instead of a MULT into a temporary followed by an ADD.
//         Reading only the LOW BYTE is deliberate: a packed weight word holds
//         four INT8 values, and SRL by 8 slides the next lane into place. So a
//         four-weight loop is MAC, SRL, MAC, SRL, ... with no masking and no
//         unpacking into separate registers.
//
//   MAC4  rd <- rd + sum over i of sext(rs[8i+7:8i]) * sext(rt[8i+7:8i])
//         All four lanes at once, four signed 8x8 products summed through a
//         balanced adder tree. Once activations are packed four-per-word as
//         well as weights, the entire SRL lane-sliding sequence disappears:
//         12 instructions per group of four become 3. Whole-program effect is
//         2.20x (447,785 -> 203,615 instructions).
//
//         Lane order is little-endian: lane 0 is bits [7:0]. It must match
//         tools/pack_data_mem_v3.py exactly. A lane-order mismatch computes a
//         valid-looking dot product of the wrong pairs.
//
//   RELU  rd <- rs[31] ? 32'd0 : rs
//         A sign-bit test in two's complement. Folding it in removes a compare
//         AND a branch from the inner loop -- and a branch costs three cycles
//         here like everything else.
//
//   SRA   arithmetic right shift, for requantisation between layers.
//         Must preserve sign. A logical shift turns small negative
//         accumulators into large positives; the network still runs and still
//         classifies, just wrongly. See docs/quantisation.md.
//
// TWO OVERFLOW BUGS FIXED HERE
//
//   ADD: the old test used sum[32] with
//            wire signed [32:0] sum = {rs[31], rs} + {rt[31], rt};
//        sum[32] is the UNSIGNED carry-out, which is not signed overflow.
//        Correct test: sum[32] != sum[31]. Signed overflow occurs only when
//        the two operands share a sign and the result does not.
//
//   MULT: the old test flagged overflow whenever prod[63:32] was non-zero.
//        For a negative product, sign extension fills the upper word with
//        ones, so it fired on every negative result. Correct test: the upper
//        33 bits must all equal the sign bit of the low word --
//            prod[63:31] != {33{prod[31]}}
//
//   Neither bug corrupted a result; both set a flag that nothing downstream
//   consumed. They are recorded because a flag that is wrong is worse than one
//   that is absent -- the next person to use it will trust it.
//
// SYNTHESIS NOTES
//   The multiplies infer DSP48E1 slices. Vivado emits DPIP-1 warnings that the
//   DSP A and B inputs are not pipelined. That is expected: pipelining the DSP
//   would add a cycle to S_EXEC, and the FSM has no state to absorb it. The
//   warnings are informational, not defects.
//
// CHANGE HISTORY
//   - MAC4 and MULT moved behind parameters after timing analysis showed the
//     MAC4 adder tree dominating the critical path in a build that never
//     executed a MAC4.
//   - ADD overflow: sum[32] -> sum[32] != sum[31].
//   - MULT overflow: |prod[63:32] -> prod[63:31] != {33{prod[31]}}.
//   - SRA added for inter-layer requantisation.
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
