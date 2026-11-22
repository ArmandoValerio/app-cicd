import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://release.app.org';

export const options = {
  vus: 25,
  duration: '45s',
  thresholds: {
    http_req_duration: ['p(95)<250'],
    http_req_failed: ['rate<0.01'],
    'http_req_duration{endpoint:lesson}': ['p(95)<250'],
    'http_req_duration{endpoint:audio}': ['p(95)<850'],
  },
};

export default function () {
  const healthRes = http.get(`${BASE_URL}/healthz`, {
    tags: { endpoint: 'healthz' },
  });
  check(healthRes, {
    'healthz status es 200': (r) => r.status === 200,
  });

  const lessonRes = http.get(`${BASE_URL}/api/v1/lessons/nahuatl/unidad-1`, {
    tags: { endpoint: 'lesson' },
  });
  check(lessonRes, {
    'lección status es 200': (r) => r.status === 200,
    'lección declara charset UTF-8': (r) =>
      (r.headers['Content-Type'] || r.headers['content-type'] || '')
        .toLowerCase()
        .includes('charset=utf-8'),
    'lección preserva saltillo y macrones': (r) =>
      r.body.includes('ꞌ') && r.body.includes('ō') && r.body.includes('ā'),
  });

  const audioRes = http.get(`${BASE_URL}/api/v1/speech/sample/cualli-tonalli.wav`, {
    tags: { endpoint: 'audio' },
  });
  check(audioRes, {
    'audio status es 200': (r) => r.status === 200,
    'audio es audio/wav': (r) =>
      (r.headers['Content-Type'] || r.headers['content-type'] || '')
        .toLowerCase()
        .includes('audio/wav'),
  });

  sleep(1);
}
