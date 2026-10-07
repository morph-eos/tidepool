# What the lab cannot have, in small stand-ins: a test ACME CA (Pebble) and a DNS that answers 127.0.0.1 for every name, a mail sink and a heartbeat sink.
{ config, pkgs, lib, ... }:
let
  d = config.tidepool.domain;
  pebbleTls = pkgs.runCommand "lab-pebble-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out; cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=lab-minica" -keyout minica.key -out minica.pem
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout key.pem -out csr.pem
    openssl x509 -req -in csr.pem -CA minica.pem -CAkey minica.key -CAcreateserial -days 3650 -out cert.pem -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1")
  '';
  # a wildcard for the instances' names (compute-names.nix): a wildcard cannot be ordered by HTTP-01, so the lab serves it with a self-signed one (curl -k)
  computeTls = pkgs.runCommand "lab-compute-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out; cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=compute.${d}" -addext "subjectAltName=DNS:*.compute.${d}" -keyout key.pem -out cert.pem
  '';
  pebbleCfg = pkgs.writeText "pebble.json" (builtins.toJSON { pebble = {
    listenAddress = "127.0.0.1:14000"; managementListenAddress = "127.0.0.1:15000";
    certificate = "${pebbleTls}/cert.pem"; privateKey = "${pebbleTls}/key.pem";
    httpPort = 80; tlsPort = 443; ocspResponderURL = ""; externalAccountBindingRequired = false;
  }; });
  sink = pkgs.writeText "sink.py" ''
    import datetime, time
    from aiosmtpd.controller import Controller
    class H:
        async def handle_DATA(self, server, session, envelope):
            subj = [l for l in envelope.content.decode(errors="replace").splitlines() if l.lower().startswith("subject:")]
            open("/tmp/lab-mail.log", "a").write(f"{datetime.datetime.now():%H:%M:%S} {subj[:1]}\n")
            return "250 OK"
    Controller(H(), hostname="127.0.0.1", port=1025).start()
    while True: time.sleep(3600)
  '';
  ping = pkgs.writeText "ping.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import datetime
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            open("/tmp/lab-heartbeat.log", "a").write(f"{datetime.datetime.now():%H:%M:%S}\n"); self.send_response(200); self.end_headers()
        def log_message(self, *a): pass
    HTTPServer(("127.0.0.1", 8112), H).serve_forever()
  '';
in
{
  tidepool.compute.names.tls = lib.mkIf config.tidepool.compute.names.enable (lib.mkDefault { cert = "${computeTls}/cert.pem"; key = "${computeTls}/key.pem"; });
  security.pki.certificateFiles = [ "${pebbleTls}/minica.pem" ];
  security.acme.defaults = { server = "https://localhost:14000/dir"; email = "lab@example.test"; };
  systemd.services = {
    pebble-challtestsrv = {
      description = "Pebble challenge test server (a DNS that answers 127.0.0.1)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -defaultIPv4 127.0.0.1 -dns01 127.0.0.1:8053 -http01 '' -https01 '' -tlsalpn01 '' -management 127.0.0.1:8055";
    };
    pebble = {
      description = "Pebble, a test ACME CA";
      wantedBy = [ "multi-user.target" ]; after = [ "pebble-challtestsrv.service" ]; before = [ "nginx.service" ];
      environment = { PEBBLE_VA_NOSLEEP = "1"; PEBBLE_WFE_NONCEREJECT = "0"; };
      serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble -config ${pebbleCfg} -dnsserver 127.0.0.1:8053";
    };
    lab-smtp-sink = { wantedBy = [ "multi-user.target" ]; serviceConfig.ExecStart = "${pkgs.python3.withPackages (p: [ p.aiosmtpd ])}/bin/python ${sink}"; };
    lab-heartbeat-sink = { wantedBy = [ "multi-user.target" ]; serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${ping}"; };
  };
  networking.hosts."127.0.0.1" = map (n: "${n}.${d}") [ "vault" "photos" "media" "cloud" "backup" "push" "sync" "metrics" "alerts" ];
  environment.systemPackages = with pkgs; [ openssl python3 sops age ];
}
