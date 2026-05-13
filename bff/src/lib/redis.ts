import { Redis } from 'ioredis';
import type { Env } from '../config/env.js';
import type { Logger } from './logger.js';

export const createRedis = (env: Pick<Env, 'REDIS_URL'>, log: Logger): Redis => {
  const client = new Redis(env.REDIS_URL, {
    maxRetriesPerRequest: 3,
    enableReadyCheck: true,
    lazyConnect: false,
  });
  client.on('error', (err: Error) => log.error({ err }, 'redis error'));
  client.on('connect', () => log.info('redis connected'));
  return client;
};
