`timescale 1ns / 1ps
/*
 * ===========================================================================
 * wake_controller - Multi-channel debounced wake/event controller
 * ===========================================================================
 * 4-channel input controller with per-channel debounce, priority encoding,
 * and two wake modes:
 *   - OR mode  (mode_and=0): any enabled, debounced channel triggers a wake
 *   - AND mode (mode_and=1): a wake only fires once ALL enabled channels are
 *     simultaneously stable; a partial assertion that later drops out is
 *     logged as a "false wake" instead.
 *
 * This file also contains the TinyTapeout top-level wrapper
 * (tt_um_sreemathesh_k_wake_controller) that maps the design onto the
 * fixed TT pin budget:
 *   ui_in[7:0]  = 8 dedicated inputs
 *   uo_out[7:0] = 8 dedicated outputs
 *   uio[7:0]    = 8 bidirectional pins
 *
 * wake_controller needs 9 input bits and 40 output bits, so the wide
 * status/counter registers (wake_count, false_wake_cnt, evt_flags,
 * priority_ch, wake_out) are exposed through a small byte-wide readback
 * bus instead of being wired out directly -- see the register map below.
 * ===========================================================================
 */

module wake_controller #(
    parameter N  = 4,
    parameter DB = 8,
    parameter PW = 4
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] thresh_in,
    input  wire [N-1:0] ch_en,
    input  wire         mode_and,
    output reg           wake_out,
    output reg  [N-1:0]  evt_flags,
    output reg  [2:0]    priority_ch,
    output reg  [15:0]   wake_count,
    output reg  [15:0]   false_wake_cnt
);

    // Debounce counter width scales with DB so any legal DB value works
    // correctly (previously hardcoded to 4 bits, which silently broke
    // for DB > 16 -- caught by testing DB=20 directly).
    localparam DBW = (DB <= 1) ? 1 : $clog2(DB);
    // Explicitly-sized compare constant so dbcnt[i] >= DB_M1 never mixes
    // a DBW-bit reg with an implicit 32-bit integer literal.
    localparam [DBW-1:0] DB_M1 = DB - 1;

    reg [N-1:0]   sync1, sync2;
    reg [DBW-1:0] dbcnt [0:N-1];
    reg [N-1:0]   stable;
    reg [N-1:0]   stable_prev;
    reg [PW-1:0]  pcnt;
    reg           firing;
    reg           wake_out_d;

    // Stage 1: Synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1 <= {N{1'b0}};
            sync2 <= {N{1'b0}};
        end else begin
            sync1 <= thresh_in;
            sync2 <= sync1;
        end
    end

    // Stage 2: Debouncer
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_debounce
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (!ch_en[i]) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (sync2[i]) begin
                    if (dbcnt[i] >= DB_M1)
                        stable[i] <= 1'b1;
                    else
                        dbcnt[i] <= dbcnt[i] + 1'b1;
                end else begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end
            end
        end
    endgenerate

    // Stage 3: Priority Encoder
    wire [N-1:0] pri_active = stable & ch_en;
    reg  [2:0]   pri_next;
    always @* begin
        pri_next = 3'd7; // none active
        if      (pri_active[0]) pri_next = 3'd0;
        else if (pri_active[1]) pri_next = 3'd1;
        else if (pri_active[2]) pri_next = 3'd2;
        else if (pri_active[3]) pri_next = 3'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            priority_ch <= 3'd7;
        else
            priority_ch <= pri_next;
    end

    // Stage 4: Event Detection FSM
    wire [N-1:0] active_stable    = stable & ch_en;
    wire [N-1:0] active_prev      = stable_prev & ch_en;
    wire         all_active       = (ch_en != {N{1'b0}}) && (active_stable == ch_en);
    wire         all_active_prev  = (ch_en != {N{1'b0}}) && (active_prev == ch_en);
    wire         all_active_edge  = all_active && !all_active_prev;
    wire         any_active       = (active_stable != {N{1'b0}});
    wire         new_edge         = (active_stable != active_prev) && any_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            firing         <= 1'b0;
            evt_flags      <= {N{1'b0}};
            stable_prev    <= {N{1'b0}};
            false_wake_cnt <= 16'd0;
        end else begin
            stable_prev <= stable;

            if (!firing) begin
                if (mode_and) begin
                    if (all_active_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end else if (all_active) begin
                        // condition still fully met but not a new edge:
                        // already fired for this assertion, do nothing
                    end else if (new_edge) begin
                        if (!(&false_wake_cnt))
                            false_wake_cnt <= false_wake_cnt + 1'b1;
                    end
                end else begin
                    if (any_active && new_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end
                end
            end else if (&pcnt) begin
                firing    <= 1'b0;
                evt_flags <= {N{1'b0}};
            end
        end
    end

    // Stage 5: Pulse Generator
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out <= 1'b0;
            pcnt     <= {PW{1'b0}};
        end else begin
            if (firing && !wake_out) begin
                wake_out <= 1'b1;
                pcnt     <= {PW{1'b0}};
            end else if (wake_out) begin
                if (&pcnt) begin
                    wake_out <= 1'b0;
                    pcnt     <= {PW{1'b0}};
                end else begin
                    pcnt <= pcnt + 1'b1;
                end
            end
        end
    end

    // Stage 6: Wake Counter (saturating)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out_d <= 1'b0;
            wake_count <= 16'd0;
        end else begin
            wake_out_d <= wake_out;
            if (wake_out && !wake_out_d && !(&wake_count))
                wake_count <= wake_count + 1'b1;
        end
    end

endmodule


/*
 * ===========================================================================
 * tt_um_sreemathesh_k_wake_controller - TinyTapeout top-level wrapper
 * ===========================================================================
 * Pinout:
 *   ui_in[3:0]  = thresh_in[3:0]
 *   ui_in[7:4]  = ch_en[3:0]
 *   uio_in[0]   = mode_and
 *   uio_in[3:1] = reg_sel[2:0]   (selects which byte appears on uo_out)
 *   uio_in[7:4] = unused
 *   uio_out     = all zero (uio only used as input here)
 *   uio_oe      = all zero (all uio pins configured as inputs)
 *
 *   reg_sel:
 *     0 -> {wake_out, priority_ch[2:0], evt_flags[3:0]}
 *     1 -> wake_count[7:0]
 *     2 -> wake_count[15:8]
 *     3 -> false_wake_cnt[7:0]
 *     4 -> false_wake_cnt[15:8]
 *     5-7 -> reads back 0x00
 * ===========================================================================
 */
module tt_um_sreemathesh_k_wake_controller (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire        ena,     // goes high when design is powered/enabled
    input  wire        clk,     // clock
    input  wire        rst_n    // reset_n - low to reset
);

    // ---- Input mapping ------------------------------------------------
    wire [3:0] thresh_in = ui_in[3:0];
    wire [3:0] ch_en     = ui_in[7:4];
    wire       mode_and  = uio_in[0];
    wire [2:0] reg_sel   = uio_in[3:1];

    // ---- Core instance --------------------------------------------------
    wire        wake_out;
    wire [3:0]  evt_flags;
    wire [2:0]  priority_ch;
    wire [15:0] wake_count;
    wire [15:0] false_wake_cnt;

    wake_controller #(
        .N  (4),
        .DB (8),
        .PW (4)
    ) u_wake_controller (
        .clk            (clk),
        .rst_n          (rst_n),
        .thresh_in      (thresh_in),
        .ch_en          (ch_en),
        .mode_and       (mode_and),
        .wake_out       (wake_out),
        .evt_flags      (evt_flags),
        .priority_ch    (priority_ch),
        .wake_count     (wake_count),
        .false_wake_cnt (false_wake_cnt)
    );

    // ---- Output readback mux --------------------------------------------
    reg [7:0] out_mux;
    always @(*) begin
        case (reg_sel)
            3'd0:    out_mux = {wake_out, priority_ch, evt_flags};
            3'd1:    out_mux = wake_count[7:0];
            3'd2:    out_mux = wake_count[15:8];
            3'd3:    out_mux = false_wake_cnt[7:0];
            3'd4:    out_mux = false_wake_cnt[15:8];
            default: out_mux = 8'h00;
        endcase
    end

    assign uo_out  = out_mux;
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule
