module sobel_core (
    input  logic [7:0] p00, p01, p02,
    input  logic [7:0] p10, p11, p12,
    input  logic [7:0] p20, p21, p22,
    output logic [7:0] magnitude_o
);
    //making pixel values 11 bit for secure computation
    logic signed [10:0] s_p00, s_p01, s_p02;
    logic signed [10:0] s_p10, s_p12;
    logic signed [10:0] s_p20, s_p21, s_p22;

    assign s_p00 = 11'(p00);
    assign s_p01 = 11'(p01);
    assign s_p02 = 11'(p02);
    assign s_p10 = 11'(p10);
    assign s_p12 = 11'(p12);
    assign s_p20 = 11'(p20);
    assign s_p21 = 11'(p21);
    assign s_p22 = 11'(p22);

    logic signed [10:0] gx, gy;

    assign gx = (s_p02 -s_p00)+((s_p12-s_p10)<<<1)+(s_p22-s_p20);
    assign gy = (s_p20-s_p00)+((s_p21-s_p01)<<<1)+(s_p22-s_p02);

    logic [11:0] abs_gx, abs_gy;

    assign abs_gx=gx[10]?12'(-gx):12'(gx);
    assign abs_gy=gy[10]?12'(-gy):12'(gy);

    logic [12:0] sum; 
    assign sum = abs_gx + abs_gy;
    assign magnitude_o = (sum > 13'd255) ? 8'd255 : sum[7:0];
    
endmodule