module self_data_mng (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,
    input wire load_data_in,
    output reg [7:0] data_out_forwarder,
    output reg [7:0] data_out_resolver,
    output reg load_data_out_forwarder,
    output reg load_data_out_resolver
);

    reg [1:0] state;
    reg [7:0] count;
    reg [7:0] counter;
    reg port_selected;

    always @(posedge clk) begin
        if (rst) begin
            state <= 0;
            count <= 0;
            counter <= 0;
            port_selected <= 0;
            data_out_forwarder <= 8'b0;
            data_out_resolver <= 8'b0;
            load_data_out_forwarder <= 0;
            load_data_out_resolver <= 0;
        end else if (load_data_in) begin
            case (state)
                0: begin
                    port_selected <= data_in[0]; 
                    state <= 1;
                end
                1: begin
                    count <= data_in;
                    state <= 2;
                end
                2: begin
                    data_out_forwarder <= !port_selected ? data_in : 8'b0; // Store incoming data
                    data_out_resolver <= port_selected ? data_in : 8'b0; // Store incoming data
                    counter <= counter + 1;
                    load_data_out_forwarder <= !port_selected ? 1 : 0; // Indicate data is being processed
                    load_data_out_resolver <= port_selected ? 1 : 0; // Indicate data is being processed
                    if (counter == count - 1) begin
                        state <= 0; // Move to next state after processing all data
                        counter <= 0; // Reset counter for next operation
                    end 
                end
                default: state <= 0; // Reset to initial state on unexpected condition
            endcase
        end else begin
            // Default outputs when not loading data
            data_out_forwarder <= 8'b0;
            data_out_resolver <= 8'b0;
            load_data_out_forwarder <= 0;
            load_data_out_resolver <= 0;
        end
    end
    
endmodule