`timescale 1ns/100ps


module init_router #(
    parameter PORTS = 4,               // Number of ports
    parameter FLIT_SIZE = 8,           // Packet size in bits
    parameter ROUTER_ID = 7'b1000000,  // Router ID
    parameter ROUTER_TYPE = 0,          // 0 for lower layer, 1 for upper layer
    parameter LOWER_LEVEL_ROUTERS = 4 // Number of lower level routers
)(

    input wire clk,
    input wire rst,

    // Top side
    input wire load_data_top_in,
    output reg ready_data_top_in,
    input wire [FLIT_SIZE-1:0] data_top_in,
    
    output reg load_data_top_out,
    input wire ready_data_top_out,
    output reg [FLIT_SIZE-1:0] data_top_out,
    output reg data_out_done,

    // Lower side
    input wire [PORTS-1:0] load_data_lower_in,
    output reg [PORTS-1:0] ready_data_lower_in,
    input wire [PORTS*FLIT_SIZE-1:0] data_lower_in,
    
    output reg [PORTS-1:0] load_data_lower_out,
    input wire [PORTS-1:0] ready_data_lower_out,
    output reg [PORTS*FLIT_SIZE-1:0] data_lower_out,

    // this router
    output reg load_data,
    input wire ready_data,
    output reg [FLIT_SIZE-1:0] data
);
    reg [FLIT_SIZE-1:0] packet_counter;
    reg routing_done;
    reg send_done;
    reg count_done;
    reg this_router;
    reg from_top;


    // State machine for routing
    localparam IDLE = 3'b000;
    localparam FIRST_FLIT = 3'b001;
    localparam ROUTE = 3'b010;
    localparam SECOND_FLIT = 3'b011;
    localparam FORWARD = 3'b100;
    localparam SEND = 3'b101;
    // localparam DONE = 3'b110;

    localparam PORT_BITS = $clog2(PORTS);
    localparam LOWER_BITS = $clog2(LOWER_LEVEL_ROUTERS);

    reg [2:0] state;
    reg [2:0] next_state;
    reg [2:0] pre_state;

    // Routing registers
    reg [FLIT_SIZE-1:0] current_flit;
    reg [FLIT_SIZE-1:0] header_flit;
    reg [PORT_BITS-1:0] port_select;
    reg [PORT_BITS-1:0] input_port;

    integer i;
    always @(*) begin
        for (i = 0; i < PORTS; i = i + 1) begin
            if (load_data_lower_in[i]) begin
                input_port = i;
            end
        end   
    end

    // Next state logic
    always @(*) begin
        case (state)
            IDLE: begin
                if (load_data_top_in) begin
                    next_state = FIRST_FLIT;
                    from_top = 1;
                end else if (|load_data_lower_in) begin
                    next_state = FIRST_FLIT;
                    from_top = 0;
                end else begin
                    next_state = IDLE;
                    from_top = 0;
                end
            end

            FIRST_FLIT: begin
                next_state = ROUTE;
            end

            ROUTE: begin
                if (routing_done) begin
                    next_state = SEND;
                end else begin
                    next_state = ROUTE;
                end
            end

            SECOND_FLIT: begin
                if (count_done) begin
                    next_state = SEND;
                end else begin
                    next_state = SECOND_FLIT;
                end
            end

            FORWARD: begin
                if (send_done) begin
                    next_state = FORWARD;
                end else begin
                    next_state = SEND;
                end
            end

            SEND: begin
                if (send_done) begin
                    case (pre_state)
                        ROUTE: next_state = SECOND_FLIT;
                        SECOND_FLIT: next_state = FORWARD;
                        FORWARD: begin
                            if (packet_counter > 1) begin
                                next_state = FORWARD;
                            end else begin
                                // next_state = DONE;
                                next_state = IDLE;
                            end
                        end
                        SEND: begin
                            if (packet_counter > 1) begin
                                next_state = FORWARD;
                            end else begin
                                // next_state = DONE;
                                next_state = IDLE;
                            end
                        end
                    endcase
                end else begin
                    next_state = SEND;
                end     
            end

            // DONE: next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            pre_state <= state;
            state <= next_state;

            case (next_state)
                IDLE: begin
                    packet_counter <= 0;
                    routing_done <= 0;
                    ready_data_top_in <= 1;
                    load_data_top_out <= 0;
                    data_top_out <= 0;
                    ready_data_lower_in <= {PORTS{1'b1}};
                    load_data_lower_out <= {PORTS{1'b0}};
                    load_data <= 0;
                    data_lower_out <= {PORTS{8'b0}};
                    data <= 0;
                    current_flit <= 0;
                    header_flit <= 0;
                    port_select <= 0;
                    this_router <= 0;
                    count_done <= 0;
                    send_done <= 0;
                    data_out_done <= 0;
                end

                FIRST_FLIT: begin
                    if (load_data_top_in) begin
                        ready_data_top_in <= 0; 
                        header_flit <= data_top_in;
                        current_flit <= data_top_in;
                    end else if (|load_data_lower_in) begin
                        ready_data_lower_in[input_port] <= 0;
                        header_flit <= data_lower_in[input_port*FLIT_SIZE +: FLIT_SIZE];
                        current_flit <= data_lower_in[input_port*FLIT_SIZE +: FLIT_SIZE];
                    end
                end

                ROUTE: begin
                    if (from_top) begin
                        if (header_flit == ROUTER_ID) begin
                            this_router <= 1;
                        end else if (ROUTER_TYPE == 0) begin
                            port_select <= header_flit[PORT_BITS-1:0];
                        end else begin
                            port_select <= header_flit[PORT_BITS+LOWER_BITS:LOWER_BITS];
                        end
                        routing_done <= 1; 
                    end else begin
                        routing_done <= 1;
                    end
                end

                SECOND_FLIT: begin
                    if (load_data_top_in) begin
                        ready_data_top_in <= 0; 
                        current_flit <= data_top_in;
                        packet_counter <= data_top_in + 1;
                        send_done <= 0;
                        count_done <= 1;    
                    end else if (|load_data_lower_in) begin
                        ready_data_lower_in[input_port] <= 0;
                        current_flit <= data_lower_in[input_port*FLIT_SIZE +: FLIT_SIZE];
                        packet_counter <= data_lower_in[input_port*FLIT_SIZE +: FLIT_SIZE] + 1;
                        send_done <= 0;
                        count_done <= 1;
                    end
                    load_data_lower_out <= {PORTS{1'b0}};
                    load_data <= 0;
                    load_data_top_out <= 0;
                end

                FORWARD: begin
                    if (load_data_top_in) begin
                        ready_data_top_in <= 0;
                        current_flit <= data_top_in;
                        
                        if (packet_counter > 0) begin
                            packet_counter <= packet_counter - 1;
                        end 
                        send_done <= 0;
                    end else if (|load_data_lower_in) begin
                        ready_data_lower_in[input_port] <= 0;
                        current_flit <= data_lower_in[input_port*FLIT_SIZE +: FLIT_SIZE];
                        
                        if (packet_counter > 0) begin
                            packet_counter <= packet_counter - 1;
                        end 
                        send_done <= 0;
                    end
                    load_data_lower_out <= {PORTS{1'b0}};
                    load_data <= 0;
                    load_data_top_out <= 0;
                end

                SEND: begin
                    if (from_top) begin
                        if (this_router) begin
                            if (ready_data) begin
                                if (state != ROUTE && state != SECOND_FLIT) begin
                                    data <= current_flit;
                                    load_data <= 1;
                                end

                                if (packet_counter == 1) begin
                                    ready_data_top_in <= 0;
                                end else begin
                                    ready_data_top_in <= 1;
                                end

                                send_done <= 1;
                            end
                        end else if (ready_data_lower_out[port_select]) begin
                            if (ROUTER_TYPE) begin
                                data_lower_out[port_select*FLIT_SIZE +: FLIT_SIZE] <= current_flit;
                                load_data_lower_out[port_select] <= 1;
                            end else begin
                                if (state != ROUTE && state != SECOND_FLIT) begin
                                    data_lower_out[port_select*FLIT_SIZE +: FLIT_SIZE] <= current_flit;
                                    load_data_lower_out[port_select] <= 1;
                                end
                            end

                            if (packet_counter == 1) begin
                                ready_data_top_in <= 0;
                            end else begin
                                ready_data_top_in <= 1;
                            end

                            send_done <= 1;
                        end
                    end else begin
                        if (ready_data_top_out) begin
                            data_top_out <= current_flit;
                            load_data_top_out <= 1;

                            if (packet_counter == 1) begin
                                ready_data_lower_in[input_port] <= 0;
                                data_out_done <= 1;
                            end else begin
                                ready_data_lower_in[input_port] <= 1;
                                data_out_done <= 0;
                            end

                            send_done <= 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule

