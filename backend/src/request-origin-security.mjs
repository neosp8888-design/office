// 로컬 UI의 상태 변경 요청과 WebSocket은 같은 Origin 규칙을 사용한다.

const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost", "::1"]);

export function isTrustedLoopbackOrigin({
  origin,
  host,
  protocol = "http:",
} = {}) {
  // 네이티브 클라이언트와 로컬 CLI는 Origin을 보내지 않는다.
  if (!origin) {
    return true;
  }
  if (!host) {
    return false;
  }
  try {
    const originURL = new URL(origin);
    return LOOPBACK_HOSTNAMES.has(originURL.hostname)
      && originURL.protocol === protocol
      && originURL.host === host;
  } catch {
    return false;
  }
}
