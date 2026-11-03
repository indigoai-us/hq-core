// Local stand-in for the HQ notify API that the native `hq core dm-bind`
// (hq-cli >= 5.345.193) calls directly when a human Cognito session exists.
// Usage: node fake-notify-api.mjs <port-file> <roster-file> <sent-file>
//   GET  /v1/notify/channels              -> one channel named "room"
//   GET  /v1/notify/channels/:id/members  -> rows of <roster-file> (name<TAB>uid)
//   POST /v1/notify/channels/:id/messages -> appends the JSON body as one line
//        to <sent-file>, answers {"eventId":"evt-<line count>"}
// The roster file is re-read on every request so a test can change it between
// posts; an empty or missing file is an unreadable roster.
import { createServer } from "node:http";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";

const [portFile, rosterFile, sentFile] = process.argv.slice(2);
const read = (file) => {
  try { return readFileSync(file, "utf8"); } catch { return ""; }
};
const reply = (res, status, value) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(value));
};

const server = createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/v1/notify/channels")
      return reply(res, 200, [{ channelId: "ch_room", name: "room" }]);
    if (req.method === "GET" && url.pathname === "/v1/notify/channels/ch_room/members") {
      const members = read(rosterFile).split(/\r?\n/).filter(Boolean).map((row) => {
        const [displayName, personUid] = row.split("\t");
        return { displayName, personUid };
      });
      return reply(res, 200, members);
    }
    if (req.method === "POST" && url.pathname === "/v1/notify/channels/ch_room/messages") {
      appendFileSync(sentFile, `${JSON.stringify(JSON.parse(body))}\n`);
      const count = read(sentFile).split("\n").filter(Boolean).length;
      return reply(res, 200, { eventId: `evt-${count}` });
    }
    return reply(res, 404, { error: `unexpected ${req.method} ${url.pathname}` });
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
