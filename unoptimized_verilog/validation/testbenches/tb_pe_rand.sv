`timescale 1ns / 1ps
`include "defines.sv"

// Self-checking random test for processing_element.
// Plusargs:  +VEC_FILE=<hex file from gen_pe_vectors.py>   +NVEC=<number of lines>
//
// Each vector is one clock cycle:
//   {valid[1], opcode[2], mode[2], value[5], A[32], B[32], exp_acc[64], exp_out[32]}
// Inputs are applied on the falling edge; results are checked just after the rising edge.

module tb_pe_rand;

    localparam int VW      = 170;
    localparam int MAX_VEC = 1500000;

    logic clk = 1'b0;
    logic rst_n;
    pe_inst_t           pe_inst;
    logic               pe_inst_valid;
    logic [`PE_INPUT_BITWIDTH-1:0]  vector_input, matrix_input;
    wire  [`PE_OUTPUT_BITWIDTH-1:0] vector_output;

    processing_element dut (
        .clk(clk), .rst_n(rst_n),
        .pe_inst(pe_inst), .pe_inst_valid(pe_inst_valid),
        .vector_input(vector_input), .matrix_input(matrix_input),
        .vector_output(vector_output)
    );

    always #5 clk = ~clk;

    logic [VW-1:0] vec [0:MAX_VEC-1];
    string         vec_file;
    integer        nvec, errors, i;

    logic        v;
    logic [1:0]  op, mode;
    logic [4:0]  val;
    logic [31:0] a, b, exp_out;
    logic [63:0] exp_acc;

    initial begin
        errors = 0;
        if (!$value$plusargs("VEC_FILE=%s", vec_file)) $fatal(1, "+VEC_FILE not given");
        if (!$value$plusargs("NVEC=%d", nvec))         $fatal(1, "+NVEC not given");
        if (nvec > MAX_VEC)                            $fatal(1, "NVEC too large");
        $readmemh(vec_file, vec, 0, nvec-1);

        rst_n = 1'b0; pe_inst_valid = 1'b0; pe_inst = '0;
        vector_input = '0; matrix_input = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (i = 0; i < nvec; i++) begin
            @(negedge clk);
            {v, op, mode, val, a, b, exp_acc, exp_out} = vec[i];
            pe_inst_valid = v;
            pe_inst       = {op, mode, val};
            vector_input  = a;
            matrix_input  = b;
            @(posedge clk);
            #1;
            if (dut.acc_q !== exp_acc || vector_output !== exp_out) begin
                errors++;
                if (errors <= 5) begin
                    $display("MISMATCH at vector %0d: valid=%0b opcode=%0d mode=%0d value=%0d", i, v, op, mode, val);
                    $display("   A=%h B=%h", a, b);
                    $display("   acc expected %h got %h", exp_acc, dut.acc_q);
                    $display("   out expected %h got %h", exp_out, vector_output);
                end
            end
        end

        if (errors == 0) $display("PASS: all %0d vectors matched the Python reference", nvec);
        else             $display("FAIL: %0d of %0d vectors mismatched", errors, nvec);
        $finish;
    end

endmodule
