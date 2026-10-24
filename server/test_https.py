"""HTTPS loopback fixture used only by the macOS iOS integration workflow."""
from __future__ import annotations

import os
import ssl
from http.server import ThreadingHTTPServer

import service


class PrefixHandler(service.Handler):
    """Expose the relay below the same path prefix used by production nginx."""

    def dispatch(self):
        original = self.path
        prefix = "/fuckin-locked"
        if original == prefix:
            self.path = "/"
        elif original.startswith(prefix + "/"):
            self.path = original[len(prefix):]
        try:
            return super().dispatch()
        finally:
            self.path = original


def main() -> None:
    certificate = os.environ["FL_TEST_TLS_CERT"]
    private_key = os.environ["FL_TEST_TLS_KEY"]
    port = int(os.environ.get("FL_PORT", "8787"))
    service.connect().close()
    server = ThreadingHTTPServer(("127.0.0.1", port), PrefixHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
