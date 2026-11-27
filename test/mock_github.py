"""Tiny mock of the GitHub REST endpoints bin/deploy uses. Test only."""
import hashlib, io, json, sys, tarfile
from http.server import BaseHTTPRequestHandler, HTTPServer


def st():
    # The scenario file is reread on every request so the test script can change it between runs.
    return json.load(open(sys.argv[2]))


def tarball(tag, broken=False):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, body in {"index.html": f"<h1>pipeline test {tag}</h1>",
                           "release.json": json.dumps({"tag": tag if not broken else "nope"})}.items():
            b = body.encode(); i = tarfile.TarInfo(name); i.size = len(b); t.addfile(i, io.BytesIO(b))
    return buf.getvalue()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj, raw=None):
        body = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        s = st(); p = self.path.split("?")[0]
        if self.headers.get("Authorization") != "Bearer test-token": return self.send(401, {})
        tag = s["tag"]; sha = s["sha"]
        if p.endswith(f"/git/ref/tags/{tag}"): return self.send(200, {"object": {"type": "commit", "sha": sha}})
        if "/compare/main..." in p: return self.send(200, {"status": s.get("compare", "identical")})
        if p.endswith(f"/commits/{sha}/pulls"):
            return self.send(200, [{"number": 7, "merged_at": "x", "base": {"ref": "main"}, "merge_commit_sha": s.get("merge_sha", sha)}])
        if p.endswith("/pulls/7"): return self.send(200, {"user": {"login": s["author"]}, "head": {"sha": "head1"}})
        if p.endswith("/pulls/7/reviews"): return self.send(200, s["reviews"])
        if p.endswith(f"/releases/tags/{tag}"):
            return self.send(200, {"assets": [{"id": 1, "name": f"frontend-{tag}.tar.gz"}, {"id": 2, "name": f"frontend-{tag}.tar.gz.sha256"}]})
        data = tarball(tag, s.get("broken_build", False))
        if p.endswith("/releases/assets/1"): return self.send(200, None, data)
        if p.endswith("/releases/assets/2"):
            h = hashlib.sha256(data).hexdigest() if not s.get("bad_sum") else "0" * 64
            return self.send(200, None, f"{h}  frontend-{tag}.tar.gz\n".encode())
        return self.send(404, {"path": p})


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
