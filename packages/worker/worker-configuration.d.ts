interface Env {
    ROOMS: DurableObjectNamespace<import("./src/room").SignalingRoom>;
    ASSETS: Fetcher;
    TURN_KEY_ID: string;
    TURN_KEY_API_TOKEN: string;
}
