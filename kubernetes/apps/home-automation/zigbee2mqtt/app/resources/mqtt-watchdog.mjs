const CHECK_INTERVAL_MS = 5_000;
const EXIT_AFTER_MS = 5 * 60_000;

export default class MqttWatchdog {
    constructor(zigbee, mqtt, state, publishEntityState, eventBus, enableDisableExtension, restartCallback, addExtension, settings, logger) {
        this.mqtt = mqtt;
        this.logger = logger;
        this.disconnectedSince = undefined;
        this.timer = undefined;
    }

    async start() {
        this.timer = setInterval(() => this.check(), CHECK_INTERVAL_MS);
    }

    async stop() {
        clearInterval(this.timer);
    }

    check() {
        const client = this.mqtt.client;

        if (!client || client.connected) {
            this.disconnectedSince = undefined;
            return;
        }

        this.disconnectedSince ??= Date.now();
        const downMs = Date.now() - this.disconnectedSince;

        if (downMs > EXIT_AFTER_MS) {
            this.logger.error(`MQTT watchdog: disconnected for ${Math.round(downMs / 1000)}s, exiting so the container restarts`);
            process.exit(1);
        }

        if (client.reconnectTimer || client.disconnecting) {
            return;
        }

        this.logger.warning(`MQTT watchdog: client is disconnected and not retrying (${Math.round(downMs / 1000)}s), forcing reconnect`);
        client.reconnect();
    }
}
