/**
 * Message broker between the History service and the Fetcher: RabbitMQ or pgmq (USE_REDIS_RABBITMQ).
 * Both carry the same JSON request/reply, so fetcherClient.js does not care which one is used.
 */
import config from '../config.js';
import { REQUEST_TIMEOUT_MS } from './pending.js';

// Only the chosen module is loaded, so the other backend needs no configuration
const broker = await import(config.useRedisRabbitMQ ? './rabbitmq.js' : './pgmq.js');

export const isBrokerReady = () => broker.isReady();
export const connectBroker = () => broker.connectBroker();
export const request = (message, timeoutMs = REQUEST_TIMEOUT_MS) => broker.request(message, timeoutMs);
