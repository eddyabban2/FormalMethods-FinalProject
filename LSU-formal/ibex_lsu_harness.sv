// =============================================================================
// Module: ibex_lsu_harness
// Description:
//   Merged harness ("C"):
//   - Base: Harness B (minimal, spec-true Ibex LSU harness).
//   - Extensions: Safe modeling ideas from Harness A
//     * f_req_active + shadowed LSU inputs during a transaction
//     * Extra debug ports wired (lsu_resp_valid_o, misaligned_q_debug_o)
// =============================================================================

module ibex_lsu_harness(
    input clk_i,
    input rst_ni
);

    // =========================================================================
    // 1. Symbolic Inputs (Environment)
    // =========================================================================
    (* anyseq *) wire        data_gnt_i;
    (* anyseq *) wire        data_rvalid_i;
    (* anyseq *) wire        data_bus_err_i;
    (* anyseq *) wire        data_pmp_err_i;
    (* anyseq *) wire [31:0] data_rdata_i;

    (* anyseq *) wire        lsu_we_i;        
    (* anyseq *) wire [1:0]  lsu_type_i;      
    (* anyseq *) wire [31:0] lsu_wdata_i;     
    (* anyseq *) wire        lsu_sign_ext_i;  
    (* anyseq *) wire        lsu_req_i;       
    (* anyseq *) wire [31:0] adder_result_ex_i; 

    // =========================================================================
    // 2. DUT Outputs
    // =========================================================================
    wire        data_req_o;
    wire [31:0] data_addr_o;
    wire        data_we_o;
    wire [3:0]  data_be_o;
    wire [31:0] data_wdata_o;
    wire [31:0] lsu_rdata_o;
    wire        lsu_rdata_valid_o;
    wire        lsu_req_done_o;
    wire        busy_o;
    wire        load_err_o;
    wire        store_err_o;
    wire        addr_incr_req_o;
    wire [31:0] addr_last_o;
    wire        lsu_resp_valid_o;   // newly wired (from A, but harmless)

    // Debug taps
    wire [2:0]  fsm_state;
    wire        data_we_q;
    wire [31:0] data_rdata_ext;
    wire        handle_misaligned_q; // optional misaligned debug, not constrained

    // =========================================================================
    // 3. DUT Instantiation
    // =========================================================================
    ibex_load_store_unit #(
        .MemECC(0),
        .MemDataWidth(32)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),

        // Data interface
        .data_req_o(data_req_o),
        .data_gnt_i(data_gnt_i),
        .data_rvalid_i(data_rvalid_i),
        .data_bus_err_i(data_bus_err_i),
        .data_pmp_err_i(data_pmp_err_i),
        .data_addr_o(data_addr_o),
        .data_we_o(data_we_o),
        .data_be_o(data_be_o),
        .data_wdata_o(data_wdata_o),
        .data_rdata_i(data_rdata_i),

        // LSU <-> pipeline
        .lsu_we_i(lsu_we_i),
        .lsu_type_i(lsu_type_i),
        .lsu_wdata_i(lsu_wdata_i),
        .lsu_sign_ext_i(lsu_sign_ext_i),
        .lsu_rdata_o(lsu_rdata_o),
        .lsu_rdata_valid_o(lsu_rdata_valid_o),
        .lsu_req_i(lsu_req_i),
        .adder_result_ex_i(adder_result_ex_i),

        // Address / completion
        .addr_incr_req_o(addr_incr_req_o),
        .addr_last_o(addr_last_o),
        .lsu_req_done_o(lsu_req_done_o),
        .lsu_resp_valid_o(lsu_resp_valid_o),
        .load_err_o(load_err_o),
        .load_resp_intg_err_o(),
        .store_err_o(store_err_o),
        .store_resp_intg_err_o(),
        .busy_o(busy_o),
        .perf_load_o(),
        .perf_store_o(),

        // Formal debug ports
        .fsm_state_debug_o(fsm_state),
        .data_we_q_debug_o(data_we_q),
        .data_rdata_ext_debug_o(data_rdata_ext),

        // NOTE: This port must exist in your modified ibex_load_store_unit.
        // If you didn't actually add it, just comment this out.
        .misaligned_q_debug_o(handle_misaligned_q)
    );

`ifdef FORMAL

    // =========================================================================
    // 4. Formal Bookkeeping
    // =========================================================================
    reg f_past_valid = 0;
    always @(posedge clk_i)
        f_past_valid <= 1'b1;

    // Start in reset at time 0
    initial assume(!rst_ni);
    always @(posedge clk_i) if (!f_past_valid) assume(!rst_ni);

    // Track last granted request type (read vs write) for debugging (optional)
    reg last_req_was_read_q;
    always @(posedge clk_i) begin
        if (!rst_ni)
            last_req_was_read_q <= 1'b0;
        else if (data_req_o && data_gnt_i)
            last_req_was_read_q <= !data_we_o;
    end

    // =========================================================================
    // 5. Environment Assumptions (from B)
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            // No requests while in reset
            assume(lsu_req_i      == 1'b0);
            assume(data_gnt_i     == 1'b0);
            assume(data_rvalid_i  == 1'b0);
            assume(data_bus_err_i == 1'b0);
            assume(data_pmp_err_i == 1'b0);
        end else begin
            // No overlapping LSU requests while busy
            // if (busy_o)
            //     assume(!lsu_req_i);

            // Causality on handshake: grant implies request
            if (data_gnt_i)
                assume(data_req_o);

            // A bus error must coincide with a valid response
            if (data_bus_err_i)
                assume(data_rvalid_i);

            // Don't get rvalid from a totally idle bus unless there's something outstanding
            if (data_rvalid_i)
                assume(data_req_o || busy_o);
        end
    end

    // =========================================================================
    // 5b. Shadow-Mode Pipeline Mock (safe subset from A)
    //      - Models that the *external pipeline* does not wiggle LSU inputs
    //        mid-transaction.
    // =========================================================================
    reg        f_req_active;
    reg        f_shadow_we;
    reg [1:0]  f_shadow_type;
    reg [31:0] f_shadow_wdata;
    reg        f_shadow_signext;
    reg [31:0] f_shadow_addr; // derived from adder_result_ex_i

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            f_req_active      <= 1'b0;
            f_shadow_we       <= 1'b0;
            f_shadow_type     <= 2'b00;
            f_shadow_wdata    <= 32'h0;
            f_shadow_signext  <= 1'b0;
            f_shadow_addr     <= 32'h0;
        end else begin
            // Start of a new LSU request when LSU is idle
            if (!f_req_active && lsu_req_i && !busy_o) begin
                f_req_active     = 1'b1;
                f_shadow_we      = lsu_we_i;
                f_shadow_type    = lsu_type_i;
                f_shadow_wdata   = lsu_wdata_i;
                f_shadow_signext = lsu_sign_ext_i;
                f_shadow_addr    = adder_result_ex_i;
            end
            // End of transaction: when no longer busy and bus isn't driving a req
            else if (f_req_active && !busy_o && !data_req_o) begin
                f_req_active <= 1'b0;
            end
        end
    end

    always @(posedge clk_i) begin
        if (rst_ni && f_req_active) begin
            // Enforce stability to mimic static pipeline operands for this transaction
            assume(lsu_we_i       == f_shadow_we);
            assume(lsu_type_i     == f_shadow_type);
            assume(lsu_wdata_i    == f_shadow_wdata);
            assume(lsu_sign_ext_i == f_shadow_signext);
            // (We do not *force* data_addr_o == f_shadow_addr, because internal logic
            //   may adjust it for misaligned accesses. This is just pipeline input.)
        end
    end

    // =========================================================================
    // 6. Coverage + Safety Properties (from B)
    // =========================================================================
    always @(posedge clk_i) begin
        if (rst_ni) begin
            // Coverage to make sure the environment explores things
            if (data_req_o)
                cover(1);

            if (busy_o)
                cover(1);

            if (lsu_rdata_valid_o)
                cover(1);

            if (load_err_o || store_err_o)
                cover(1);

            // Optional: see some done pulses
            if (lsu_req_done_o)
                cover(1);
        end

        // ------------------------------------------------
        // STEP 1 — LSU-local safety properties
        // ------------------------------------------------

        // IDLE is 3'd0 in ls_fsm_e
        assert(busy_o == (fsm_state != 3'd0));

        // Load/store errors must be mutually exclusive and match access type
        if (load_err_o) begin
            assert(!store_err_o);
            assert(data_we_q == 1'b0); // load error => outstanding was a read
        end

        if (store_err_o) begin
            assert(!load_err_o);
            assert(data_we_q == 1'b1); // store error => outstanding was a write
        end

        // Once busy in consecutive cycles, keep incoming attrs stable (B)
        if (f_past_valid && $past(busy_o) && busy_o) begin
            assume($stable(lsu_we_i));
            assume($stable(lsu_type_i));
            assume($stable(lsu_wdata_i));
            assume($stable(lsu_sign_ext_i));
        end

        // ------------------------------------------------
        // STEP 2 — ADDRESS + HANDSHAKE PROPERTIES
        // ------------------------------------------------

        // P1: Address alignment must match LSU access type
        if (rst_ni && data_req_o) begin
            case (lsu_type_i)
                2'b10: begin // word
                    assert(data_addr_o[1:0] == 2'b00);
                end
                2'b01: begin // halfword
                    assert(data_addr_o[0] == 1'b0);
                end
                2'b00: begin // byte
                    assert(1);
                end
                default: begin
                    // forbid unknown/unsupported types in the harness environment
                    assume(0);
                end
            endcase
        end

        

        // ------------------------------------------------
        // STEP 3 — CLEAN LOAD RESPONSE PROPERTIES
        // ------------------------------------------------

        if (lsu_rdata_valid_o) begin
            // Must be in IDLE when a clean response is reported
            assert(fsm_state == 3'd0);

            // Clean load response must come with a bus rvalid
            assert(data_rvalid_i);

            // Response is for a load, not a store
            assert(data_we_q == 1'b0);

            // A "clean" rdata response cannot be flagged as an error
            assert(!load_err_o);
            assert(!store_err_o);
        end

        // ------------------------------------------------
        // STEP 4 — FSM STRUCTURE & COVERAGE
        // ------------------------------------------------

        // FSM reset behavior:
        // Under reset, we expect the LSU to be idle and not flag errors.
        if (!rst_ni) begin
            // IDLE is 3'd0 (by design, and consistent with busy_o linkage)
            assert(fsm_state == 3'd0);
            assert(!busy_o);
            assert(!load_err_o);
            assert(!store_err_o);
        end

        // Cover: visit non-IDLE states at least once
        if (rst_ni) begin
            cover(fsm_state == 3'd1);
            cover(fsm_state == 3'd2);
            cover(fsm_state == 3'd3);
        end

        // Cover: typical FSM transitions
        if (f_past_valid && rst_ni) begin
            // Leaving IDLE (start of some transaction)
            if ($past(fsm_state == 3'd0) && fsm_state != 3'd0)
                cover(1);

            // Returning to IDLE (transaction done / aborted)
            if ($past(fsm_state != 3'd0) && fsm_state == 3'd0)
                cover(1);

            // Error-handling path: busy previously, now idle with an error flag
            if ($past(busy_o) && (load_err_o || store_err_o) && fsm_state == 3'd0)
                cover(1);
        end

        // ------------------------------------------------
        // STEP 5 — Extra consistency check from A (safe)
        // ------------------------------------------------
        // When a transaction is active and the LSU is actually driving a bus request,
        // the external write-enable and bus write-enable should match.
        if (rst_ni && f_req_active && data_req_o) begin
            assert(data_we_o == f_shadow_we);
        end

        // ------------------------------------------------
        // STEP 6 — TARGETED COVERAGE
        // ------------------------------------------------
        if (rst_ni) begin
            // 1. See a "Split" transaction (Misaligned)
            // This proves your Mock Environment allows the FSM to go deep
            if (fsm_state == 3'd1 || fsm_state == 3'd2) // WAIT_GNT_MIS or WAIT_RVALID_MIS
                cover(1);

            // 2. See an Error Response
            if (load_err_o || store_err_o)
                cover(1);

            // 3. See Back-to-Back Transactions
            // (Busy goes low, then immediately high again in next cycle)
            if ($past(busy_o) && !busy_o && data_req_o)
                cover(1);

            // 4. See a Byte Write to an Odd Address (Logic check)
            // This ensures the byte-lane shifting logic is exercised
            if (data_req_o && data_we_o && lsu_type_i[1] && adder_result_ex_i[1:0] == 2'b01)
                cover(1);
        end

        

    end

`endif

endmodule
