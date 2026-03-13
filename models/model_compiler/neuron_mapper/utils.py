NEURONS_PER_CLUSTER = 32
MAX_WEIGHT_TABLE_ROWS = 2048

def weight_to_fixed_point(weight, bits=28):
    """
    Convert a floating-point weight to 32-bit signed fixed-point representation.
    :param weight: The weight value to convert.
    :param bits: The number of fractional bits for the fixed-point representation.
    :return: Fixed-point representation as a signed 32-bit integer.
    """
    scale = 2 ** bits
    value = int(round(weight * scale))
    # Make sure value fits in 32-bit signed integer range
    if value < -2**31 or value >= 2**31:
        raise ValueError("Fixed point value out of 32-bit signed int range")
    return value

def hex_encode(value):
    """
    Convert a signed 32-bit integer value to a list of 4 hex string flits (8 bits each).
    Handles negative values via 2's complement representation.
    """
    # Convert to unsigned 32-bit for byte extraction using 2's complement
    value_unsigned = value & 0xFFFFFFFF
    flits = []
    flits.append(f"{value_unsigned & 0xFF:02X}")         # Lower byte
    flits.append(f"{(value_unsigned >> 8) & 0xFF:02X}")  # 1st byte
    flits.append(f"{(value_unsigned >> 16) & 0xFF:02X}") # 2nd byte
    flits.append(f"{(value_unsigned >> 24) & 0xFF:02X}") # Upper byte
    return flits

def weight_to_hex_encord(weight):
    """
    Convert weight (float) to 4 hex encoded 8-bit flits (strings),
    handling negative weights correctly.
    """
    weight_fixed = weight_to_fixed_point(weight)
    return hex_encode(weight_fixed)

class Neuron_LIF:
    DECAY_MODE_LIF_2 = 0.5
    DECAY_MODE_LIF_4 = 0.25
    DECAY_MODE_LIF_8 = 0.125
    DECAY_MODE_LIF_2_4 = 0.75
    RESET_MODE_NO = 0
    RESET_MODE_ZERO = 1
    RESET_MODE_VTD = 2
    def __init__(self, neuron_id, cluster_id, decay_mode=DECAY_MODE_LIF_2, threshold=1.0, reset_mode= RESET_MODE_ZERO):
        self.neuron_id = neuron_id
        self.cluster_id = cluster_id
        self.decay_mode = decay_mode
        self.threshold = threshold
        self.reset_mode = reset_mode
    def get_work_mode(self):
        """
        Convert decay mode to a fixed-point representation.
        :param decay_mode: The decay mode value.
        :return: Fixed-point representation of the decay mode.
        """
        work_mode = 0
        if self.decay_mode == 0.5:
            work_mode = 0x01  # LIF 2
        elif self.decay_mode == 0.25:
            work_mode = 0x02  # LIF 4
        elif self.decay_mode == 0.125:
            work_mode = 0x03  # LIF 8
        elif self.decay_mode == 0.75:
            work_mode = 0x04  # LIF 24
        else:
            raise ValueError("Invalid decay mode")

        work_mode = self.reset_mode << 6 | work_mode
        return f"{work_mode:02X}"  # Return as hex string
    def generate_threshold_init(self):
        flits = []
        flits.append('F9')
        flits.extend(weight_to_hex_encord(self.threshold))
        flits.append('FF')  # End of threshold
        return flits
    def generate_work_mode_init(self):
        flits = []
        flits.append('F7')
        flits.append(self.get_work_mode())  # Decay mode
        return flits
    def generate_init(self):
        flits = []
        flits.extend(self.generate_threshold_init())
        flits.extend(self.generate_work_mode_init())
        return flits

    def log_neuron(self):
        """
        Log the neuron information.
        """
        print(f"Neuron ID: {self.neuron_id}, Cluster ID: {self.cluster_id}, Decay Mode: {self.decay_mode}, Threshold: {self.threshold}")

class Neuron_Cluster:
    def __init__(self, cluster_id):
        self.cluster_id = cluster_id
        self.neurons = []
        self.source_cluster_index = []
        self.incoming_weight_map = []
        self.next_neuron_id = 0
        self.neurons_full = False
        self.outgoing_mask = 0x00000000  # Default outgoing mask for the cluster
    def add_neuron(self, decay_mode=Neuron_LIF.DECAY_MODE_LIF_2, threshold=1.0, reset_mode=Neuron_LIF.RESET_MODE_ZERO):
        """
        Add a neuron to the cluster.
        :param neuron: Neuron_LIF instance to add.
        """
        self.neurons.append(
            Neuron_LIF(
                neuron_id=self.next_neuron_id,
                cluster_id=self.cluster_id,
                decay_mode=decay_mode,
                threshold=threshold,
                reset_mode=reset_mode
            )
        )
        self.next_neuron_id += 1
        if self.next_neuron_id >= NEURONS_PER_CLUSTER:
            self.neurons_full = True
        return self.next_neuron_id - 1
    def add_incoming_weight(self, src_cluster_id, src_neuron_id, address):
        """
        Add an incoming weight to the cluster.
        :param weight: Weight value to add.
        """
        if src_cluster_id not in self.source_cluster_index:
            self.source_cluster_index.append(src_cluster_id)
        self.incoming_weight_map.append([src_cluster_id, src_neuron_id, address])

    def generate_init(self):
        """
        Generate initialization flits for the cluster.
        :return: List of hexadecimal strings representing the initialization flits.
        """
        print("clusters", self.source_cluster_index)

        flits = []
        for index, neuron in enumerate(self.neurons):
            if index % 6 == 0:
                flits.append([])
            flits[-1].append('01')  # opcode for neuron initialization
            flits[-1].append(f"{neuron.neuron_id:02X}")  # Neuron ID
            neuron_init = neuron.generate_init()
            flits[-1].append(f"{len(neuron_init):02X}")  # Length of the neuron initialization
            flits[-1].extend(neuron_init)

        flits.append([])
        flits[-1].append('02')
        flits[-1].append(f"{self.incoming_weight_map[0][2] & 0xFF:02X}")
        flits[-1].append(f"{(self.incoming_weight_map[0][2] >> 8) & 0xFF:02X}")
        base_address = self.incoming_weight_map[0][2]

        # # Add incoming weights
        for idx, src_cluster_id in enumerate(self.source_cluster_index):
            flits.append([])
            flits[-1].append('03')
            flits[-1].append(f"{src_cluster_id:02X}")

        print("base address:", base_address)
        for idx, (src_cluster_id, src_neuron_id, address) in enumerate(self.incoming_weight_map):
            if address != (self.source_cluster_index.index(src_cluster_id)<<5)+src_neuron_id+base_address:
                print(address, (self.source_cluster_index.index(src_cluster_id)<<5)+src_neuron_id+base_address)

        return flits

    def log_cluster(self):
        """
        Log the cluster information.
        """
        print(f"Cluster ID: {self.cluster_id}")
        print(f"Neurons: {len(self.neurons)}")
        for neuron in self.neurons:
            neuron.log_neuron()
        print(f"Source Cluster Index: {self.source_cluster_index}")
        print(f"Incoming Weights: {self.incoming_weight_map}")

class Virtual_Cluster:
    def __init__(self, cluster_id):
        self.cluster_id = cluster_id
        self.neurons = []
        self.next_neuron_id = 0
        self.neurons_full = False
    def add_neuron(self):
        """
        Add a neuron to the virtual cluster.
        :param neuron: Neuron_LIF instance to add.
        """
        self.neurons.append(
            Neuron_LIF(
                neuron_id=self.next_neuron_id,
                cluster_id=self.cluster_id
            )
        )
        self.next_neuron_id += 1
        if self.next_neuron_id >= 32:
            self.neurons_full = True
        return self.next_neuron_id - 1
    def log_cluster(self):
        """
        Log the virtual cluster information.
        """
        print(f"Virtual Cluster ID: {self.cluster_id}")
        for neuron in self.neurons:
            neuron.log_neuron()
        print(f"Next Neuron ID: {self.next_neuron_id}")
        print(f"Neurons Full: {self.neurons_full}")

class Weight_Resolver:
    """
    Class to resolve weights between clusters.
    This class allows for the resolution of weights between different neuron clusters.
    It provides methods to add weights and retrieve weight information.
    """
    def __init__(self, resolver_id=None):
        self.weight_rows = {}
        self.next_row_id = 0
        self.max_rows = MAX_WEIGHT_TABLE_ROWS
        self.resolver_id = resolver_id
    def create_row(self):
        """
        Create a new weight row.
        :return: ID of the created row.
        """
        row_id = self.next_row_id
        self.weight_rows[row_id] = []
        self.next_row_id += 1
        return row_id
    def add_weight(self, row_id, weight):
        """
        Add a weight to the specified row.
        :param row_id: ID of the row to add the weight to.
        :param weight: Weight value to add.
        """
        if row_id in self.weight_rows:
            self.weight_rows[row_id].append(weight)
        else:
            raise ValueError(f"Row ID {row_id} does not exist.")

    def get_weights(self, row_id):
        """
        Get the weights for the specified row.
        :param row_id: ID of the row to retrieve weights from.
        :return: List of weights for the specified row.
        """
        if row_id in self.weight_rows:
            return self.weight_rows[row_id]
        else:
            raise ValueError(f"Row ID {row_id} does not exist.")  
        
    def is_possible_to_add(self, count):
        return self.next_row_id + count - 1 <= self.max_rows  
    
    def log_weights(self):
        for row_id, weights in self.weight_rows.items():
            print(row_id, weights)

    def generate_init(self):
        """
        Generate initialization code for the weight resolver.
        :return: List of hexadecimal strings representing the initialization code.
        """
        init_code = []
        for row_id, weights in self.weight_rows.items():
            init_code.append([])
            init_code[-1].append("01")
            init_code[-1].append(f"{len(weights)*4+3:02X}")
            init_code[-1].append(f"{row_id & 0xFF:02X}")
            init_code[-1].append(f"{(row_id >> 8) & 0xFF:02X}")
            init_code[-1].append(f"{len(weights)*4:02X}")
            for weight in weights:
                init_code[-1].extend(weight_to_hex_encord(weight))

        return init_code

class Forwarder:
    """
    Class to manage forwarding connections.
    This class allows for the management of forwarding connections between neuron clusters.
    It provides methods to add forwarders and retrieve forwarding information.
    """
    def __init__(self, forwarder_id):
        self.forwarder_id = forwarder_id
        self.connections = []
        self.map = []
    def add_connection(self, src_port_id, des_port_id):
        """
        Add a connection to the forwarder.
        :param src_port_id: Source port ID.
        :param des_port_id: Destination port ID.
        """
        self.connections.append([src_port_id, des_port_id])
    def generate_map(self, size=5):
        """
        Generate a map for the forwarder.
        :return: List of connections in the forwarder.
        """
        forwarder_map = [[0 for _ in range(size)] for _ in range(size)]
        for src_port_id, des_port_id in self.connections:
            if src_port_id < size and des_port_id < size:
                forwarder_map[src_port_id][des_port_id] = 1
        self.map = forwarder_map
        return forwarder_map
    def log_connections(self):
        """
        Log the connections in the forwarder.
        """
        print(f"Forwarder ID: {self.forwarder_id}")
        print("Connections:")
        print(self.map)

class Forwarder_8(Forwarder):
    """
    Class to manage 8-bit forwarding connections.
    This class extends the Forwarder class to handle 8-bit forwarding connections.
    It provides methods to add connections and retrieve forwarding information.
    """
    def __init__(self):
        super().__init__(0x80)

    def add_connection(self, src_port_id, des_port_id):
        return super().add_connection(src_port_id, des_port_id)
        
    def generate_map(self):
        return super().generate_map(size=9)

    def generate_init(self):
        init_code = []
        init_code.append(['A0'])
        init_code[-1].append(f"{18:02X}")
        for row_idx, row in enumerate(self.map):
            init_code[-1].append(f"{(row_idx << 4 | row[8]):02X}")
            binary_str = ''.join(map(str, row[7::-1]))
            print(binary_str)
            decimal_value = int(binary_str, 2)
            init_code[-1].append(f"{decimal_value:02X}")
        return init_code
            
class Forwarder_4(Forwarder):
    """
    Class to manage 4-bit forwarding connections.
    This class extends the Forwarder class to handle 4-bit forwarding connections.
    It provides methods to add connections and retrieve forwarding information.
    """
    def __init__(self, forwarder_id):
        super().__init__(forwarder_id)
    def add_connection(self, src_port_id, des_port_id):
        """
        Add a connection to the forwarder.
        :param src_port_id: Source port ID.
        :param des_port_id: Destination port ID.
        """
        if src_port_id < 5 and des_port_id < 5:
            super().add_connection(src_port_id, des_port_id)
        else:
            raise ValueError("Source and destination port IDs must be less than 5.", src_port_id, des_port_id)
    def generate_map(self):
        return super().generate_map(size=5)
    def generate_init(self):
        init_code = []
        init_code.append([f"{self.forwarder_id:02X}"])
        init_code[-1].append(f"{7:02X}")
        init_code[-1].append(f"00")
        init_code[-1].append(f"{5:02X}")
        for row_idx, row in enumerate(self.map):
            binary_str = ''.join(map(str, row[4::-1]))
            print(binary_str)
            decimal_value = int(binary_str, 2)
            init_code[-1].append(f"{(row_idx << 5 | decimal_value):02X}")
        return init_code
    
class Cluster_Group:
    """
    Class to manage a group of clusters.
    This class allows for the management of multiple neuron clusters as a group.
    It provides methods to add clusters and retrieve cluster information.
    """
    def __init__(self, group_id):
        self.group_id = group_id
        self.next_cluster_id = 0
        self.clusters = []
        self.weight_resolver = Weight_Resolver(group_id)
        self.forwarders_4 = Forwarder_4(group_id)

    def add_cluster(self):
        """
        Add a cluster to the group.
        :param cluster_id: ID of the cluster to add.
        """
        if self.next_cluster_id >= 4:
            raise ValueError("Cannot add more than 4 clusters to a group.")
        else:
            new_cluster = Neuron_Cluster((self.group_id & 0x1F) + self.next_cluster_id)
            self.clusters.append(new_cluster)
            self.next_cluster_id += 1
            return new_cluster
        
    def get_cluster(self, cluster_index):
        """
        Get a cluster by its ID.
        :param cluster_id: ID of the cluster to retrieve.
        :return: Neuron_Cluster instance with the specified ID.
        """
        if 0 <= cluster_index < len(self.clusters):
            return self.clusters[cluster_index]
        raise ValueError(f"Cluster index {cluster_index} is out of range.")

    def get_weight_resolver(self):
        """
        Get a weight resolver by its ID.
        :param resolver_id: ID of the weight resolver to retrieve.
        :return: Weight_Resolver instance with the specified ID.
        """
        return self.weight_resolver

    def get_forwarder_4(self):
        return self.forwarders_4
    
class Cluster_Manager:
    def __init__(self):
        self.cluster_groups = {}
        self.weight_buckets = {}
        self.virtual_clusters = []
        self.next_virtual_cluster_id = 32
        self.next_cluster_group = 0x80

    def create_cluster_group(self):
        """
        Create a new cluster group.
        :return: ID of the created cluster group.
        """
        new_group = Cluster_Group(self.next_cluster_group)
        self.cluster_groups[self.next_cluster_group] = new_group
        self.next_cluster_group += 4
        return new_group

    def create_virtual_cluster(self):
        """
        Create a new virtual cluster.
        :return: ID of the created virtual cluster.
        """
        new_virtual_cluster = Virtual_Cluster(self.next_virtual_cluster_id)
        self.virtual_clusters.append(new_virtual_cluster)
        self.next_virtual_cluster_id += 1
        return new_virtual_cluster

    def get_cluster_group(self, group_id):
        """
        Get a cluster group by its ID.
        :param group_id: ID of the cluster group to retrieve.
        :return: Cluster_Group instance with the specified ID.
        """
        if group_id in self.cluster_groups:
            return self.cluster_groups[group_id]
        raise ValueError(f"Cluster group ID {group_id} does not exist.")

    def update_weight_bucket(self, group_id, value):
        if group_id in self.weight_buckets.keys():
            self.weight_buckets[group_id] += value
        else:
            self.weight_buckets[group_id] = value

    def check_weight_bucket(self, group_id, value):
        if group_id in self.weight_buckets.keys():
            print("weight_bucket_check", self.weight_buckets[group_id], value)
            return self.weight_buckets[group_id] + value <= MAX_WEIGHT_TABLE_ROWS
        else:
            return True