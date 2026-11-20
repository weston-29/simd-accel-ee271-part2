`timescale 1ns / 1ps
`include "defines.sv"

// Self-checking random test for buffer.
// Generate inputs first:   python3 gen_buffer_vectors.py
// Plusargs:  +VEC_FILE=<buffer_vec.hex>  +NVEC=<lines>  +MEM0_FILE=<...>  +MEM1_FILE=<...>
//            +STRICT   (optional) also check that matrix/vector outputs HOLD on non-READ cycles
//
// Each vector is one clock cycle:
//   {pad[2], valid[1], opcode[2], mode[2], mema[16], memb[16], output_data[512],
//    check_data[1], exp_matrix[512], exp_vector[32], exp_mem2_row[512]}
// Vector i's inputs are on the pins at rising edge i. Just after that edge the NEXT
// vector's inputs are applied (as the controller would), then vector i's results are
// checked -- that is when a synchronous SRAM has produced the data for that READ.
//
// Every cycle this test checks:
//   * after a READ:  matrix_data and vector_data
//   * every cycle:   MEM2 row [mema] -- catches writes that are missing, wrong, or
//                    happen when they shouldn't (output_data is random junk every cycle)

// array.sv keeps its contents in "logic [DW-1:0] data [0:NW-1]", so MEM2's
// row k is dut.u_output_mem.data[k]. (Memory files are loaded with $readmemb,
// which is the binary format gen_buffer_vectors.py writes by default.)
`ifndef MEM2_ROW
`define MEM2_ROW(addr) dut.u_output_mem.data[addr]
`endif

module tb_buffer_rand;

    localparam int VW      = 1608;
    localparam int MAX_VEC = 100000;

    logic clk = 1'b0;
    logic rst_n;
    buf_inst_t                   buf_inst;
    logic                        buf_inst_valid;
    logic [`MEM2_BITWIDTH-1:0]   output_data;
    wire  [`MEM0_BITWIDTH-1:0]   matrix_data;
    wire  [`MEM1_BITWIDTH-1:0]   vector_data;

    buffer dut (
        .clk(clk), .rst_n(rst_n),
        .buf_inst(buf_inst), .buf_inst_valid(buf_inst_valid),
        .matrix_data(matrix_data), .vector_data(vector_data),
        .output_data(output_data)
    );

    always #5 clk = ~clk;

    logic [VW-1:0] vec [0:MAX_VEC-1];
    string         vec_file, mem0_file, mem1_file;
    integer        nvec, i, w, strict;
    integer        errors, err_matrix, err_vector, err_mem2, n_reads, n_writes, seen_read;

    logic [1:0]                 pad, op, mode;
    logic                       v, chk;
    logic [15:0]                a, b;
    logic [`MEM2_BITWIDTH-1:0]  od, exp_m2;
    logic [`MEM0_BITWIDTH-1:0]  exp_mat;
    logic [`MEM1_BITWIDTH-1:0]  exp_vec;
    logic [`MEM2_BITWIDTH-1:0]  got_m2;

    function automatic string opname(input logic [1:0] o);
        case (o)
            `BUF_READ:  return "READ";
            `BUF_WRITE: return "WRITE";
            `BUF_NOP:   return "NOP";
            default:    return "???";
        endcase
    endfunction

    function automatic string modename(input logic [1:0] m);
        case (m)
            `MODE_INT8:  return "INT8";
            `MODE_INT16: return "INT16";
            `MODE_INT32: return "INT32";
            default:     return "???";
        endcase
    endfunction

    // Drive one vector's inputs onto the buffer.
    task automatic apply(input integer k);
        logic [1:0]                pd, o, m;
        logic                      vv, c;
        logic [15:0]               aa, bb;
        logic [`MEM2_BITWIDTH-1:0] d, e2;
        logic [`MEM0_BITWIDTH-1:0] e0;
        logic [`MEM1_BITWIDTH-1:0] e1;
        {pd, vv, o, m, aa, bb, d, c, e0, e1, e2} = vec[k];
        buf_inst_valid = vv;
        buf_inst       = {o, m, aa, bb};
        output_data    = d;
    endtask

    task automatic header();
        $display("MISMATCH at vector %0d: valid=%0b %s %s  MemAOffset=%0d MemBOffset=%0d",
                 i, v, opname(op), modename(mode), a, b);
    endtask

    initial begin
        errors = 0; err_matrix = 0; err_vector = 0; err_mem2 = 0; n_reads = 0; n_writes = 0;
        if (!$value$plusargs("VEC_FILE=%s", vec_file))   $fatal(1, "+VEC_FILE not given");
        if (!$value$plusargs("NVEC=%d", nvec))           $fatal(1, "+NVEC not given");
        if (!$value$plusargs("MEM0_FILE=%s", mem0_file)) $fatal(1, "+MEM0_FILE not given");
        if (!$value$plusargs("MEM1_FILE=%s", mem1_file)) $fatal(1, "+MEM1_FILE not given");
        if (nvec > MAX_VEC)                              $fatal(1, "NVEC too large (max %0d)", MAX_VEC);
        strict = $test$plusargs("STRICT");

        $readmemh(vec_file, vec, 0, nvec-1);
        dut.u_matrix_mem.loadmem(mem0_file);
        dut.u_vector_mem.loadmem(mem1_file);

        rst_n = 1'b0; buf_inst_valid = 1'b0; buf_inst = '0; output_data = '0;
        seen_read = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Apply vector 0 before the first edge.
        @(negedge clk);
        apply(0);

        for (i = 0; i < nvec; i++) begin
            // Remember what vector i expects, then let the clock edge happen.
            {pad, v, op, mode, a, b, od, chk, exp_mat, exp_vec, exp_m2} = vec[i];
            @(posedge clk);
            #1;
            // Like real hardware, the NEXT instruction arrives right after the edge.
            // A design that wrongly uses the live instruction (instead of the one
            // it registered) for its lane select gets caught here.
            if (i + 1 < nvec) apply(i + 1);
            else              begin buf_inst_valid = 1'b0; buf_inst = '0; end
            #1;
            if (v && op == `BUF_READ)  begin n_reads++; seen_read = 1; end
            if (v && op == `BUF_WRITE) n_writes++;

            // ---- READ results (or every cycle with +STRICT, once a READ has happened) ----
            if (chk || (strict && seen_read)) begin
                if (matrix_data !== exp_mat) begin
                    errors++; err_matrix++;
                    if (errors <= 5) begin
                        header();
                        for (w = 0; w < `MEM0_BITWIDTH/32; w++)
                            if (matrix_data[w*32 +: 32] !== exp_mat[w*32 +: 32])
                                $display("   matrix_data word %0d (bits %0d..%0d): expected %h got %h",
                                         w, w*32+31, w*32, exp_mat[w*32 +: 32], matrix_data[w*32 +: 32]);
                    end
                end
                if (vector_data !== exp_vec) begin
                    errors++; err_vector++;
                    if (errors <= 5) begin
                        header();
                        $display("   vector_data expected %h got %h", exp_vec, vector_data);
                        if (chk)
                            $display("   (MEM1 word address %0d, lane %0d)",
                                     (mode == `MODE_INT8) ? b >> 2 : (mode == `MODE_INT16) ? b >> 1 : b,
                                     (mode == `MODE_INT8) ? b[1:0] : (mode == `MODE_INT16) ? b[0] : 0);
                    end
                end
            end

            // ---- MEM2 row at this vector's MemAOffset, every cycle ----
            got_m2 = `MEM2_ROW(a);
            if (got_m2 !== exp_m2) begin
                errors++; err_mem2++;
                if (errors <= 5) begin
                    header();
                    $display("   MEM2[%0d] expected ...%h got ...%h  (low 64 bits shown)",
                             a, exp_m2[63:0], got_m2[63:0]);
                    if (!(v && op == `BUF_WRITE))
                        $display("   (this instruction should NOT have written MEM2)");
                end
            end
        end

        $display("%0d cycles: %0d READs, %0d WRITEs checked%s", nvec, n_reads, n_writes,
                 strict ? " (STRICT: outputs checked every cycle)" : "");
        if (errors == 0) $display("PASS: all %0d vectors matched the Python reference", nvec);
        else             $display("FAIL: %0d mismatches (matrix %0d, vector %0d, MEM2 %0d)",
                                  errors, err_matrix, err_vector, err_mem2);
        $finish;
    end

endmodule
