// Anonymous page views over the same URL mix for every candidate.
import http from "k6/http";
import { check } from "k6";

const PATHS = open("/bench/urls.txt").split("\n").filter(Boolean);
const BASE = __ENV.BASE;
export const options = {
  vus: Number(__ENV.VUS || 50),
  duration: __ENV.DUR || "30s",
  summaryTrendStats: ["avg", "med", "p(95)", "max"],
};
export default function () {
  const r = http.get(BASE + PATHS[Math.floor(Math.random() * PATHS.length)], { redirects: 0 });
  check(r, { "status 200": (x) => x.status === 200 });
}
