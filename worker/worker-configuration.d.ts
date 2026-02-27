interface Env {
    ROOMS: DurableObjectNamespace<import("./src/room").SignalingRoom>;
}
