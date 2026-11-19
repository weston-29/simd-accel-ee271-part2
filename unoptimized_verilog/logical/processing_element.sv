`include "defines.sv"

module processing_element(

    // Clock and Reset Inputs
    input wire clk,
    input wire rst_n,

    // Input Instruction
    input pe_inst_t     pe_inst,
    input logic         pe_inst_valid,

    // Input Operands
    input logic [`PE_INPUT_BITWIDTH-1:0] vector_input,
    input logic [`PE_INPUT_BITWIDTH-1:0] matrix_input,

    // Output Operand
    output logic [`PE_OUTPUT_BITWIDTH-1:0] vector_output


);

    // START IMPLEMENTATION
    //
    // Lane layout (identical to the Python reference, lane 0 = least significant):
    //   INT8 : 4 lanes   input 8 bits   accumulator 16 bits   output  8 bits
    //   INT16: 2 lanes   input 16 bits  accumulator 32 bits   output 16 bits
    //   INT32: 1 lane    input 32 bits  accumulator 64 bits   output 32 bits
    // Written for PE_INPUT_BITWIDTH = 32, PE_ACCUMULATION_BITWIDTH = 64,
    // PE_OUTPUT_BITWIDTH = 32.
    //
    // Only two registers: the accumulator and the output register. Every
    // instruction is a single clock cycle with a short combinational path
    // (one multiply and one add for MAC; nothing deeper for the others).

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    logic [`PE_ACCUMULATION_BITWIDTH-1:0] acc_q, acc_d;
    logic [`PE_OUTPUT_BITWIDTH-1:0]       out_q, out_d;

    assign vector_output = out_q;

    // ------------------------------------------------------------------
    // Products for each mode. vector_input is input A (Data0, the MEM1
    // broadcast) and matrix_input is input B (Data1, this PE's MEM0 slice).
    // Operands are declared signed, so each product is the full signed
    // product (no saturation, no truncation of the product itself).
    // ------------------------------------------------------------------
    logic [63:0] prod8;     // four  16-bit products, lane k in [16k+15:16k]
    logic [63:0] prod16;    // two   32-bit products, lane k in [32k+31:32k]
    logic [63:0] prod32;    // one   64-bit product

    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : g_mul8
            logic signed [7:0]  a, b;
            logic signed [15:0] p;
            assign a = vector_input[8*g +: 8];
            assign b = matrix_input[8*g +: 8];
            assign p = a * b;
            assign prod8[16*g +: 16] = p;
        end
        for (g = 0; g < 2; g++) begin : g_mul16
            logic signed [15:0] a, b;
            logic signed [31:0] p;
            assign a = vector_input[16*g +: 16];
            assign b = matrix_input[16*g +: 16];
            assign p = a * b;
            assign prod16[32*g +: 32] = p;
        end
    endgenerate

    logic signed [31:0] a32, b32;
    logic signed [63:0] p32;
    assign a32    = vector_input;
    assign b32    = matrix_input;
    assign p32    = a32 * b32;
    assign prod32 = p32;

    // ------------------------------------------------------------------
    // MAC: accumulate each lane independently (a lane wraps on overflow,
    // which the course does not test).
    // ------------------------------------------------------------------
    logic [63:0] mac_result;
    always_comb begin
        case (pe_inst.mode)
            `MODE_INT8: begin
                for (int k = 0; k < 4; k++)
                    mac_result[16*k +: 16] = acc_q[16*k +: 16] + prod8[16*k +: 16];
            end
            `MODE_INT16: begin
                for (int k = 0; k < 2; k++)
                    mac_result[32*k +: 32] = acc_q[32*k +: 32] + prod16[32*k +: 32];
            end
            default: begin
                mac_result = acc_q + prod32;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // PASS: sign-extend each lane of input A into its accumulator lane.
    // ------------------------------------------------------------------
    logic [63:0] pass_result;
    always_comb begin
        case (pe_inst.mode)
            `MODE_INT8: begin
                for (int k = 0; k < 4; k++)
                    pass_result[16*k +: 16] = {{8{vector_input[8*k+7]}}, vector_input[8*k +: 8]};
            end
            `MODE_INT16: begin
                for (int k = 0; k < 2; k++)
                    pass_result[32*k +: 32] = {{16{vector_input[16*k+15]}}, vector_input[16*k +: 16]};
            end
            default: begin
                pass_result = {{32{vector_input[31]}}, vector_input};
            end
        endcase
    end

    // ------------------------------------------------------------------
    // OUT: clamp each accumulator lane to the signed range of the (half
    // as wide) output lane. The accumulator itself is not modified.
    // ------------------------------------------------------------------
    logic [31:0] out8, out16, out32, out_result;
    generate
        for (g = 0; g < 4; g++) begin : g_out8
            pe_out_lane #(.W(16), .OW(8)) u_lane (.x(acc_q[16*g +: 16]), .y(out8[8*g +: 8]));
        end
        for (g = 0; g < 2; g++) begin : g_out16
            pe_out_lane #(.W(32), .OW(16)) u_lane (.x(acc_q[32*g +: 32]), .y(out16[16*g +: 16]));
        end
    endgenerate
    pe_out_lane #(.W(64), .OW(32)) u_out32 (.x(acc_q), .y(out32));

    always_comb begin
        case (pe_inst.mode)
            `MODE_INT8:  out_result = out8;
            `MODE_INT16: out_result = out16;
            default:     out_result = out32;
        endcase
    end

    // ------------------------------------------------------------------
    // RND: divide each accumulator lane by 2**value, round to nearest,
    // ties to even. The shift amount is the 5-bit value field.
    // ------------------------------------------------------------------
    logic [63:0] rnd8, rnd16, rnd32, rnd_result;
    generate
        for (g = 0; g < 4; g++) begin : g_rnd8
            pe_rnd_lane #(.W(16)) u_lane (.x(acc_q[16*g +: 16]), .s(pe_inst.value), .y(rnd8[16*g +: 16]));
        end
        for (g = 0; g < 2; g++) begin : g_rnd16
            pe_rnd_lane #(.W(32)) u_lane (.x(acc_q[32*g +: 32]), .s(pe_inst.value), .y(rnd16[32*g +: 32]));
        end
    endgenerate
    pe_rnd_lane #(.W(64)) u_rnd32 (.x(acc_q), .s(pe_inst.value), .y(rnd32));

    always_comb begin
        case (pe_inst.mode)
            `MODE_INT8:  rnd_result = rnd8;
            `MODE_INT16: rnd_result = rnd16;
            default:     rnd_result = rnd32;
        endcase
    end

    // ------------------------------------------------------------------
    // Instruction decode. RND is the only instruction identified by the
    // OPCODE field. All others have opcode 0 and are identified by the
    // VALUE field. (RND and NOP share the number 1, but in different
    // fields, so the opcode is checked first.)
    // ------------------------------------------------------------------
    always_comb begin
        acc_d = acc_q;
        out_d = out_q;
        if (pe_inst_valid) begin
            if (pe_inst.opcode == `PE_RND_OPCODE) begin
                acc_d = rnd_result;
            end else if (pe_inst.opcode == `PE_MAC_OPCODE) begin
                case (pe_inst.value)
                    `PE_MAC_VALUE:  acc_d = mac_result;
                    `PE_PASS_VALUE: acc_d = pass_result;
                    `PE_OUT_VALUE:  out_d = out_result;
                    `PE_CLR_VALUE: begin
                        acc_d = '0;
                        out_d = '0;
                    end
                    default: ;      // NOP, or any undefined value: hold state
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Registers (asynchronous active-low reset, like instruction_memory)
    // ------------------------------------------------------------------
    always_ff @(posedge clk, negedge rst_n) begin
        if (rst_n == 1'b0) begin
            acc_q <= '0;
            out_q <= '0;
        end else begin
            acc_q <= acc_d;
            out_q <= out_d;
        end
    end

    // END IMPLEMENTATION

endmodule


// ----------------------------------------------------------------------
// Helper modules. They live in this file because dc_synth.tcl reads only
// the files it lists, and make generate_submission zips the logical
// directory, so no new file is needed.
// ----------------------------------------------------------------------

// Clamp one signed W-bit lane into a signed OW-bit lane.
module pe_out_lane #(
    parameter int W  = 16,
    parameter int OW = 8
) (
    input  logic [W-1:0]  x,
    output logic [OW-1:0] y
);
    // x fits in OW bits exactly when bits [W-1:OW-1] are all copies of the sign.
    logic fits;
    assign fits = (&x[W-1:OW-1]) | ~(|x[W-1:OW-1]);

    always_comb begin
        if (fits)        y = x[OW-1:0];
        else if (x[W-1]) y = {1'b1, {(OW-1){1'b0}}};    // below range: most negative
        else             y = {1'b0, {(OW-1){1'b1}}};    // above range: most positive
    end
endmodule


// Divide one signed W-bit lane by 2**s, rounding to nearest, ties to even.
//   floor = x >>> s
//   round bit = bit (s-1) of x        (the first bit shifted out)
//   sticky    = OR of bits [s-2:0]    (everything below it)
//   increment = round & (sticky | floor[0])
// For s >= W the true quotient lies in [-0.5, 0.5), which rounds to 0.
module pe_rnd_lane #(
    parameter int W = 16
) (
    input  logic [W-1:0] x,
    input  logic [4:0]   s,
    output logic [W-1:0] y
);
    logic signed [W-1:0] q;
    logic [W-1:0]        shifted, below_mask;
    logic                round_bit, sticky, inc;

    always_comb begin
        q          = $signed(x) >>> s;
        shifted    = x >> (s - 5'd1);                         // only used when s != 0
        round_bit  = (s == 5'd0) ? 1'b0 : shifted[0];
        below_mask = ~({W{1'b1}} << (s - 5'd1));              // ones below bit s-1
        sticky     = (s == 5'd0) ? 1'b0 : (|(x & below_mask));
        inc        = round_bit & (sticky | q[0]);

        if ({27'd0, s} >= W) y = '0;
        else        y = q + {{(W-1){1'b0}}, inc};
    end
endmodule
