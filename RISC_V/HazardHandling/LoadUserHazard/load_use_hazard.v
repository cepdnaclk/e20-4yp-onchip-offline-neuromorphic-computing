
module load_use_hazard (EX_MEMREAD,MEM_WRITE,RS1,RS2,WRITEADDRESS_IDOUT,MEMREAD_EXOUT,WRITEADDRESS_EXOUT,FRWD_RS1_WB,FRWD_RS2_WB,BUBBLE,FORWARD_MEMORY);

input EX_MEMREAD,MEM_WRITE,MEMREAD_EXOUT;
input [4:0] RS1, RS2, WRITEADDRESS_IDOUT,WRITEADDRESS_EXOUT;
output reg [1:0] FRWD_RS1_WB, FRWD_RS2_WB;
output reg BUBBLE,FORWARD_MEMORY;
always @(*) begin
    if ((EX_MEMREAD && ((RS1 == WRITEADDRESS_IDOUT) || (RS2 == WRITEADDRESS_IDOUT)) && !MEM_WRITE) ||
        (MEMREAD_EXOUT && ((RS1 == WRITEADDRESS_EXOUT) || (RS2 == WRITEADDRESS_EXOUT)) && !MEM_WRITE)) begin
        BUBBLE = 1'b1;         // Stall the pipeline
        FRWD_RS1_WB = 2'b00;   // Reset forwarding recommendations
        FRWD_RS2_WB = 2'b00;
        
        if (EX_MEMREAD) begin // N-1 Hazard recommendations
             if(RS1 == WRITEADDRESS_IDOUT) FRWD_RS1_WB = 2'b01;
             else if(RS2 == WRITEADDRESS_IDOUT) FRWD_RS2_WB = 2'b01;
             else begin FRWD_RS1_WB = 2'b01; FRWD_RS2_WB = 2'b01; end
        end

    end else if ( (RS2 == WRITEADDRESS_IDOUT) && MEM_WRITE) begin
            FORWARD_MEMORY = 1'b1;
            BUBBLE = 1'b0;
            FRWD_RS2_WB = 2'b00;
            FRWD_RS1_WB = 2'b00;
    end
    else begin
        FORWARD_MEMORY = 1'b0;
        BUBBLE = 1'b0;
        FRWD_RS1_WB = 2'b00;  // Forwarding if needed
        FRWD_RS2_WB = 2'b00;
    end
    
end
    
endmodule