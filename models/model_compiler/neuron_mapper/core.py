from .utils import (
    Cluster_Manager,
    NEURONS_PER_CLUSTER,
    Forwarder_8,
    Neuron_LIF
)


class Neuron_Mapper:
    """
    Class to map neurons and clusters.
    This class provides methods to map neurons to clusters and manage their weights.
    """

    def __init__(self, neuron_layers, neuron_weights):
        self.cm = Cluster_Manager()
        self.f = Forwarder_8()
        self.layer_to_neurons = {}           # layer_name -> [(cluster_id, neuron_id)]
        self.layer_to_clusters = {}          # layer_name -> [Neuron_Cluster]
        self.virtual_clusters = []        
        self.layer_to_cluster_groups = {}    # layer_name -> [Cluster_Group]
        self.neuron_layers = neuron_layers
        self.neuron_weights = neuron_weights

    def map_neurons(self):
        """
        neuron_layers = {
            "Input": {
                "decay_mode": Neuron_LIF.DECAY_MODE_LIF_2,
                "threshold": 1.0,
                "neurons": 16
            },
            "Layer1": {
                "decay_mode": Neuron_LIF.DECAY_MODE_LIF_2,
                "threshold": 1.0,
                "neurons": 16
            },
            "Layer2": {
                "decay_mode": Neuron_LIF.DECAY_MODE_LIF_2,
                "threshold": 1.0,
                "neurons": 16
            },
            "Layer3": {
                "decay_mode": Neuron_LIF.DECAY_MODE_LIF_2,
                "threshold": 1.0,
                "neurons": 16
            }
        }
        neuron_weights = {
            "Input-Layer1 = {
                "weights": [
                    [0.1, 0.2, 0.3, 0.4],
                    [0.5, 0.6, 0.7, 0.8],
                    [0.9, 1.0, 1.1, 1.2],
                    [1.3, 1.4, 1.5, 1.6]
                ]
            },
            "Layer1-Layer2": {
                "weights": [
                    [0.1, 0.2, 0.3, 0.4],
                    [0.5, 0.6, 0.7, 0.8],
                    [0.9, 1.0, 1.1, 1.2],
                    [1.3, 1.4, 1.5, 1.6]
                ]
            },
            "Layer2-Output": {
                "weights": [
                    [0.1, 0.2, 0.3, 0.4],
                    [0.5, 0.6, 0.7, 0.8],
                    [0.9, 1.0, 1.1, 1.2],
                    [1.3, 1.4, 1.5, 1.6]
                ]
            }
        }
        """

    def _get_prev_layer_name(self, layer_name):
        keys = list(self.layer_to_neurons.keys())
        if layer_name not in keys:
            return None
        idx = keys.index(layer_name)
        return keys[idx - 1] if idx > 0 else None

    def map_layer(self, layer_name, count, is_virtual=False, decay_mode=Neuron_LIF.DECAY_MODE_LIF_2, threshold=1.0):
        neurons = []
        clusters = []
        cluster_groups = []

        if is_virtual:
            remaining = count
            while remaining > 0:
                v_cluster = self.cm.create_virtual_cluster()
                self.virtual_clusters.append(v_cluster)
                to_add = min(NEURONS_PER_CLUSTER, remaining)
                for _ in range(to_add):
                    neuron_id = v_cluster.add_neuron()
                    neurons.append((v_cluster.cluster_id, neuron_id))
                remaining -= to_add
            self.layer_to_neurons[layer_name] = neurons
            return

        prev_layer = list(self.layer_to_neurons.keys())[-1]
        prev_neurons = self.layer_to_neurons.get(prev_layer, [])
        prev_groups = self.layer_to_cluster_groups.get(prev_layer, [])

        src_count = len(prev_neurons) if prev_neurons else 0
        remaining = count

        # 1. Try reusing previous cluster groups
        for group in prev_groups:
            if remaining <= 0:
                break
            while (
                group.next_cluster_id < 4 and
                remaining > 0 and
                self.cm.check_weight_bucket(group.group_id, src_count)
            ):
                self.cm.update_weight_bucket(group.group_id, src_count)
                cluster = group.add_cluster()
                clusters.append(cluster)
                cluster_groups.append(group)

                to_add = min(NEURONS_PER_CLUSTER, remaining)
                for _ in range(to_add):
                    neuron_id = cluster.add_neuron(decay_mode=decay_mode, threshold=threshold)
                    neurons.append((cluster.cluster_id, neuron_id))
                remaining -= to_add

        # 2. Allocate new groups if needed
        while remaining > 0:
            print("new_cluster_group", self.cm.next_cluster_group)
            new_group = self.cm.create_cluster_group()
            print("made cluster group", new_group.group_id)
            while (
                new_group.next_cluster_id < 4 and
                remaining > 0 and
                self.cm.check_weight_bucket(new_group.group_id, src_count)
            ):
                self.cm.update_weight_bucket(new_group.group_id, src_count)
                cluster = new_group.add_cluster()
                print("made cluster", cluster.cluster_id)
                clusters.append(cluster)
                cluster_groups.append(new_group)

                to_add = min(NEURONS_PER_CLUSTER, remaining)
                for _ in range(to_add):
                    neuron_id = cluster.add_neuron(decay_mode=decay_mode, threshold=threshold)
                    neurons.append((cluster.cluster_id, neuron_id))
                remaining -= to_add

        self.layer_to_neurons[layer_name] = neurons
        self.layer_to_clusters[layer_name] = clusters
        self.layer_to_cluster_groups[layer_name] = cluster_groups

    def map_weights(self, source_layer, target_layer, weights_matrix):
        """
        Map weights from source_layer to target_layer using transposed weights_matrix.
        Ensures each destination neuron maps each source neuron once per cluster group.
        """

        src_neurons = self.layer_to_neurons[source_layer]
        tgt_neurons = self.layer_to_neurons[target_layer]
        src_groups = self.layer_to_cluster_groups[source_layer] if source_layer in self.layer_to_cluster_groups else []
        tgt_groups = self.layer_to_cluster_groups[target_layer]

        # Validate shapes
        if len(weights_matrix) != len(tgt_neurons):
            raise ValueError("weights_matrix rows ≠ number of target neurons")
        if len(weights_matrix[0]) != len(src_neurons):
            raise ValueError("weights_matrix cols ≠ number of source neurons")

        # Build neuron→group and cluster maps
        tgt_cluster_map = {}
        neuron_to_group = {}
        for group in tgt_groups:
            for cluster in group.clusters:
                for neuron in cluster.neurons:
                    key = (cluster.cluster_id, neuron.neuron_id)
                    tgt_cluster_map[key] = cluster
                    neuron_to_group[key] = group
        for group in src_groups:
            for cluster in group.clusters:
                for neuron in cluster.neurons:
                    key = (cluster.cluster_id, neuron.neuron_id)
                    neuron_to_group[key] = group

        # Track created weight rows per group per source neuron
        row_id_map = {}  # (group_id, src_cluster_id, src_neuron_id) → row_id
        assigned = {} # Track src to avoid duplicate entries

        for dst_index, (dst_cluster_id, dst_neuron_id) in enumerate(tgt_neurons):
            for src_index, (src_cluster_id, src_neuron_id) in enumerate(src_neurons):
                weight = weights_matrix[dst_index][src_index]
                dst_key = (dst_cluster_id, dst_neuron_id)
                src_key = (src_cluster_id, src_neuron_id)

                group = neuron_to_group[dst_key]
                resolver = group.get_weight_resolver()
                row_key = (group.group_id, *src_key, dst_cluster_id)

                # Create row only once per group-source neuron
                if row_key not in row_id_map:
                    row_id = resolver.create_row()
                    row_id_map[row_key] = row_id
                else:
                    row_id = row_id_map[row_key]

                resolver.add_weight(row_id, weight)

                # Assign only once to each dst neuron
                if (group.group_id, dst_cluster_id) not in assigned:
                    assigned[(group.group_id, dst_cluster_id)] = set()
                assign_key = (src_key)
                if assign_key in assigned[(group.group_id, dst_cluster_id)]:
                    continue
                assigned[(group.group_id, dst_cluster_id)].add(assign_key)

                dst_cluster = tgt_cluster_map[dst_key]
                dst_cluster.add_incoming_weight(*src_key, row_id)

                # Connections
                src_port_8 = src_cluster_id // 4 + 1 if src_cluster_id < 32 else 0
                dst_port_8 = dst_cluster_id // 4 + 1
                src_port_4 = src_cluster_id % 4 + 1
                dst_port_4 = dst_cluster_id % 4 + 1

                if src_port_8 == dst_port_8:
                    group.get_forwarder_4().add_connection(src_port_4, dst_port_4)
                else:
                    self.f.add_connection(src_port_8, dst_port_8)
                    neuron_to_group[src_key].get_forwarder_4().add_connection(src_port_4, 0) if src_cluster_id < 32 else None
                    neuron_to_group[dst_key].get_forwarder_4().add_connection(0, dst_port_4)
        
            if target_layer == list(self.layer_to_neurons.keys())[-1]:  # If this is the last layer
                # Special handling for output layer
                src_port_8 = dst_cluster_id // 4 + 1
                src_port_4 = dst_cluster_id % 4 + 1
                self.f.add_connection(src_port_8, 0)  # Connect to main output
                neuron_to_group[dst_key].get_forwarder_4().add_connection(src_port_4, 0)

    def map(self):
        """
        Map neurons and weights based on provided configurations.
        :param neuron_layers: Dictionary of layer configurations.
        :param neuron_weights: Dictionary of weight mappings between layers.
        """
        for layer_name, config in self.neuron_layers.items():
            self.map_layer(
                layer_name,
                config['neurons'],
                is_virtual=config.get('is_virtual', False),
                decay_mode=config.get('decay_mode', Neuron_LIF.DECAY_MODE_LIF_2),
                threshold=config.get('threshold', 1.0)
            )

        for connection, weights in self.neuron_weights.items():
            src_layer, tgt_layer = connection.split('-')
            self.map_weights(src_layer, tgt_layer, weights['weights'])

        for group in self.cm.cluster_groups.values():
            group.get_forwarder_4().generate_map()
        self.f.generate_map()

    def log_mapping(self):
        """
        Log the current mapping of neurons and clusters.
        """

        for cluster in self.virtual_clusters:
            cluster.log_cluster()

        for layer_name, clusters in self.layer_to_clusters.items():
            print(f"Layer: {layer_name}, Clusters: {[c.cluster_id for c in clusters]}")
            for cluster in clusters:
                cluster.log_cluster()

        print("weight mapping")
        for layer_name, groups in self.layer_to_cluster_groups.items():
            print(f"Layer: {layer_name}, Groups: {[g.group_id for g in groups]}")
            for group in groups:
                print(f"  Group ID: {group.group_id}, Clusters: {[c.cluster_id for c in group.clusters]}")
                group.get_weight_resolver().log_weights()

        print("Forwarder connections:")
        self.f.log_connections()
        for group in self.cm.cluster_groups.values():
            print(f"Group ID: {group.group_id}, Forwarders: {group.get_forwarder_4().map}")



    def _get_group_for_cluster(self, cluster_id):
        for group in self.cm.cluster_groups.values():
            for cluster in group.clusters:
                if cluster.cluster_id == cluster_id:
                    return group
        raise ValueError(f"Cluster ID {cluster_id} not found in any group.")
    
    def generate_init(self):
        """
        Generate initialization code for the neuron mapper.
        This includes creating clusters, neurons, and connections.
        """
        init_code = []
        for group in self.cm.cluster_groups.values():
            
            weight_init = group.get_weight_resolver().generate_init()
            for line in weight_init:
                init_code.append([f"{group.group_id:02X}"])
                init_code[-1].append(f"{len(line):02X}")
                init_code[-1].extend(line)
                
            for cluster in group.clusters:
                cluster_init = cluster.generate_init()
                for line in cluster_init:
                    init_code.append([f"{cluster.cluster_id:02X}"])
                    init_code[-1].append(f"{len(line):02X}")
                    init_code[-1].extend(line)

            init_code.extend(group.get_forwarder_4().generate_init())
            
        init_code.extend(self.f.generate_init())
            
        return init_code
