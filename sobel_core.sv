// sobel_core.sv
//
// Purpose: Pure combinational datapath. Given a 3x3 window of 8-bit
//          unsigned grayscale pixels, compute the Sobel gradient
//          magnitude approximation |Gx| + |Gy|, saturated to 8 bits.
//
// This module has NO clock, NO reset, NO state. It is a "wire it up
// and the answer appears" block, same spirit as an ALU in your 8085
// project, just with a fixed function instead of an opcode-selected one.

module sobel_core (
    // 3x3 pixel window, each pixel unsigned 8-bit (0-255)
    input  logic [7:0] p00, p01, p02,
    input  logic [7:0] p10, p11, p12,   // p11 unused in the math but kept
                                         // for interface completeness /
                                         // future use (e.g. debug, or a
                                         // different kernel later)
    input  logic [7:0] p20, p21, p22,

    output logic [7:0] magnitude_o      // saturated result
);

    // ------------------------------------------------------------
    // Step 1: Gx and Gy
    //
    // Gx = (p02 - p00) + 2*(p12 - p10) + (p22 - p20)
    // Gy = (p20 - p00) + 2*(p21 - p01) + (p22 - p02)
    //
    // Each pixel is unsigned 8-bit. We cast each one into a signed
    // 11-bit value before doing any math, so subtraction never wraps
    // and every intermediate term has room for its true range.
    // Why 11 bits signed: max |Gx| = 1020 (see Chat 1, Part A.6-7),
    // which needs ceil(log2(1020)) + 1 sign bit = 11 bits.
    // ------------------------------------------------------------

    logic signed [10:0] s_p00, s_p01, s_p02;
    logic signed [10:0] s_p10, s_p12;
    logic signed [10:0] s_p20, s_p21, s_p22;

    // Zero-extend each unsigned 8-bit pixel into an 11-bit signed value.
    // Because the top bits are 0, the signed value equals the unsigned
    // value (0-255) -- this cast only matters for what happens in the
    // *subtractions* below, not here.
    assign s_p00 = 11'(p00);
    assign s_p01 = 11'(p01);
    assign s_p02 = 11'(p02);
    assign s_p10 = 11'(p10);
    assign s_p12 = 11'(p12);
    assign s_p20 = 11'(p20);
    assign s_p21 = 11'(p21);
    assign s_p22 = 11'(p22);

    logic signed [10:0] gx, gy;

    assign gx = (s_p02 - s_p00) + ((s_p12 - s_p10) <<< 1) + (s_p22 - s_p20);
    assign gy = (s_p20 - s_p00) + ((s_p21 - s_p01) <<< 1) + (s_p22 - s_p02);

    // ------------------------------------------------------------
    // Step 2: Absolute value
    //
    // abs(x) = x if x >= 0, else -x.
    // We widen to 12 bits unsigned here as a safety margin: gx's
    // signed range is -1024..1023, so -(-1024) would be 1024, which
    // does NOT fit back into 11 bits. Using 12 bits for the abs
    // result avoids any overflow-on-negate corner case entirely.
    // ------------------------------------------------------------

    logic [11:0] abs_gx, abs_gy;

    assign abs_gx = gx[10] ? 12'(-gx) : 12'(gx);
    assign abs_gy = gy[10] ? 12'(-gy) : 12'(gy);

    // ------------------------------------------------------------
    // Step 3: Sum and saturate
    //
    // sum = |Gx| + |Gy|, max possible = 1020 + 1020 = 2040, which
    // needs 12 bits unsigned (max 4095) -- comfortably fits.
    // Saturate: if sum > 255, clamp to 255, else pass through low byte.
    // ------------------------------------------------------------

    logic [12:0] sum;   // 13 bits: room for 2040 with margin, avoids
                         // any accidental truncation while adding two
                         // 12-bit values (max representable sum of two
                         // 12-bit unsigned numbers is 8190, so 13 bits
                         // unsigned, max 8191, is the safe width).

    assign sum = abs_gx + abs_gy;

    assign magnitude_o = (sum > 13'd255) ? 8'd255 : sum[7:0];

endmodule