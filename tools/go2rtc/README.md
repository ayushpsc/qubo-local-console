# Qubo local audio/video companion

This companion runs on the same LAN as the doorbell. Qubo cloud is used only
to signal a session; encrypted RTP travels directly from the doorbell to this
machine, where `qubo_p2p_client.py` decrypts Annex-B H.264 and writes it
alongside ADTS AAC into go2rtc's exec pipe. Optional experimental talkback
sends browser microphone audio back to the doorbell over the same P2P session.

## Start with Home Assistant credentials

1. Configure or re-authenticate `ha-qubo` in Home Assistant using the Qubo
   account email and password. The integration stores and refreshes the Qubo
   access tokens consumed by this relay; users should not paste those tokens
   into the Flutter GUI.
2. Copy `.env.example` to `.env`.
3. Set `QDEVICE`, `QUNIT`, `QMOB`, `QADVERT`, and `HA_CONFIG_DIR`.
   The Flutter Live View page shows the discovered device and unit UUIDs.
   `QMOB` is the paired phone UUID from Qubo's Logged In Devices or the
   `mobile_device_id` in the ha-qubo config entry. It is not the generated
   login installation ID.
4. Start the container:

   - Without Docker Compose (works with the base Docker CLI):

     ```sh
     ./run-docker.sh
     ```

   - With the optional Compose v2 plugin installed:

     ```sh
     docker compose up -d
     ```

   If `docker compose` prints `unknown shorthand flag: 'd'`, the Compose
   plugin is absent; use `run-docker.sh`.
5. Watch startup with `docker logs -f qubo-go2rtc` and media diagnostics with
   `tail -f qubo_err.log`.
6. Open `http://<QADVERT>:1984/stream.html?src=qubo_doorbell` for listening, or
   enter that go2rtc base URL and stream name on the Flutter Live View page.

When `HA_CONFIG_DIR` is set, the container mounts Home Assistant's
`.storage` directory read-only. Mounting the directory is important because
Home Assistant atomically replaces `core.config_entries` when credentials are
updated; binding only that file would leave Docker pinned to the expired inode.
The P2P client reads the Qubo access token there; ha-qubo remains responsible
for token refresh. For a standalone relay,
leave `HA_CONFIG_DIR` blank and set `QACCESS` and `QUUID` in the untracked
`.env`. The standalone token is not refreshed by the P2P client and must be
replaced when Qubo rejects it.

## Hosted Flutter app and HTTPS

An HTTPS-hosted console cannot embed an HTTP LAN HLS stream because the
browser blocks mixed content. The **Open low-latency player** button performs a
top-level navigation to go2rtc and works with its normal HTTP LAN endpoint.

For embedded playback, configure go2rtc's `api.tls_listen`, `tls_cert`, and
`tls_key`, or place it behind a trusted HTTPS reverse proxy. The certificate
must be trusted by the viewing device. Keep `api.origin: "*"` for cross-origin
HLS, and configure go2rtc Basic auth or equivalent reverse-proxy protection.
Never expose the unauthenticated go2rtc API to the public Internet: its `exec`
module can run programs on the relay host.

The in-app player requests:

```text
/api/stream.m3u8?src=qubo_doorbell&video=h264&audio=aac
```

The external player uses go2rtc's universal WebRTC/MSE/HLS viewer. The P2P
client publishes H.264 and corrected AAC for HLS/MSE. A separate on-demand
`ffmpeg:qubo_doorbell#audio=opus#backchannel=0` source supplies WebRTC listen
audio without claiming the microphone backchannel. Keeping
Opus out of the primary MPEG-TS is required with go2rtc 1.9.15: a multi-audio
MPEG-TS announces AAC but does not forward its packets to RTSP/HLS consumers.

## Enable experimental two-way talk

1. Confirm camera audio works first, then set `QTALK=true` in `.env`.
2. Restart the container. The exec source reads `.env` each time it starts, so
   an existing container does not need to be recreated:

   ```bash
   docker restart qubo-go2rtc
   ```

3. Open go2rtc through trusted HTTPS. For Tailscale, a separate Serve port
   preserves an existing service on the default HTTPS port:

   ```bash
   tailscale serve --bg --https=8443 http://127.0.0.1:1984
   ```

4. Enter `https://<tailscale-hostname>:8443` as the go2rtc base URL and select
   **Open two-way talk**, or open:

   ```text
   https://<tailscale-hostname>:8443/webrtc.html?src=qubo_doorbell&media=video%2Baudio%2Bmicrophone
   ```

5. Allow microphone permission and tap the microphone control. Use headphones
   during the first test to avoid acoustic feedback.

Talkback is reverse-engineered: `pttEnabled=true` is signalled to Qubo,
go2rtc writes PCMA/8 kHz to a separate send-only exec, and that helper forwards
it over a local Unix datagram socket to the active P2P client. The client
encodes and sends 32 kbit/s AAC-LC/16 kHz as encrypted RTP payload type 97.
A native Qubo Android packet capture confirmed marker bit 1, SSRC zero, and
MPEG4-GENERIC packets containing one or more 1024-sample ADTS access units; the
sender reproduces that packet shape and keeps each encrypted UDP datagram below
the path MTU. This split is required because go2rtc 1.9.15 treats
`backchannel=1` as send-only and does not read that exec's stdout. Set
`QTALK=false` immediately if the doorbell emits distorted sound.

Outgoing microphone gain defaults to `QTALKGAINDB=12`. A look-ahead limiter
caps peaks before AAC encoding, so normal speech is louder without hard
clipping. If the doorbell still sounds quiet, raise it gradually to `15` or
`18`; reduce it if the speaker sounds compressed or distorted.

## Start automatically after a reboot

The supplied Docker Compose file and `run-docker.sh` use Docker's `always`
restart policy. Enable the Docker service once on a systemd-based host:

```bash
sudo systemctl enable --now docker
docker update --restart always qubo-go2rtc
```

The second command also upgrades an already-created container from an older
restart policy. Confirm both settings with:

```bash
systemctl is-enabled docker
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' qubo-go2rtc
```

## Operational notes

- UDP `${QPORT}` (default 49700) must be reachable from the doorbell.
- `QADVERT` must be the relay host's LAN address, never a container address.
- Keep `QDUR=86400`; go2rtc does not restart a finished exec source underneath
  an existing viewer.
- `QVIDEOFPS=10` gives raw H.264 a stable clock after RTP reassembly. Change it
  only if a capture from your model reports a different frame rate.
- `QAUDIOGAINDB=20` compensates for the observed quiet doorbell microphone
  (about -54 dB mean in a real capture). Audio timestamps are regenerated from
  sample count before both AAC and Opus encoding so HLS and WebRTC receive a
  usable, synchronized track. A limiter prevents boosted transients clipping.
- Do not wrap the pipeline in a retry loop. Multiple publishers interrupt the
  attached viewer.
- The client copy-muxes H.264 and AAC and adds an Opus listen-audio track in
  MPEG-TS on stdout. If no valid ADTS arrives within `QAUDIOWAIT`, it
  automatically falls back to Annex-B H.264.
  Doorbell PT97 packets carry ADTS inside a 16-bit MPEG4-GENERIC AU header;
  the client removes it before muxing and restores it for talkback packets.
  Do not add an ffmpeg-to-RTSP stage; an early empty input makes that publisher
  exit and causes go2rtc/HLS to start several competing P2P sessions.
- A 401 in `qubo_err.log` means ha-qubo needs to refresh or reauthenticate.
- When the mounted Home Assistant entry contains a refresh token, the client
  now renews an expired access token in memory and retries `p2pCall` once. A
  refresh rejection still requires re-login in Home Assistant.
- `p2pCall rejected (400)` usually means a previous doorbell session has not
  released yet. Wait rather than retrying rapidly.

The Python client is derived from the companion documented by `ha-qubo` and
retains its protocol safeguards. Audio muxing and talkback are extensions in
this repository; they are not implemented by the upstream `ha-qubo` copy.
