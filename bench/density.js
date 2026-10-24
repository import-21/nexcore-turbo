// Many small sites behind one address: a steady stream of visitors spread over
// all sites. UNCACHED share of requests carry a search query (always rendered by PHP).
import http from "k6/http";
import { check } from "k6";

const SITES = JSON.parse(open("/bench/sites.json"));   // [{base, host, paths:[...]}]
const RATE = Number(__ENV.RATE);
const UNCACHED = Number(__ENV.UNCACHED || 0.1);
export const options = {
  scenarios: {
    visitors: {
      executor: "constant-arrival-rate",
      rate: RATE, timeUnit: "1s", duration: __ENV.DUR || "60s",
      preAllocatedVUs: Math.max(50, Math.ceil(RATE * 2)), maxVUs: Math.max(200, RATE * 20),
    },
  },
  summaryTrendStats: ["med", "p(95)", "p(99)", "max"],
  // Thresholds only make k6 report the per-kind numbers; pass/fail is decided by density.sh.
  thresholds: {
    "http_req_duration{kind:page}": ["p(95)<600000"],
    "http_req_duration{kind:uncached}": ["p(95)<600000"],
  },
};
export default function () {
  const s = SITES[Math.floor(Math.random() * SITES.length)];
  let path = s.paths[Math.floor(Math.random() * s.paths.length)];
  const dyn = Math.random() < UNCACHED;
  if (dyn) path = "/?s=word" + Math.floor(Math.random() * 1000);
  const r = http.get(s.base + path, {
    headers: s.host ? { Host: s.host } : {}, redirects: 0, timeout: "10s",
    tags: { kind: dyn ? "uncached" : "page" },
  });
  check(r, { "status 200": (x) => x.status === 200 });
}
